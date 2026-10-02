/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file http_nsurlsession.mm NSURLSession-based implementation for HTTP requests on iOS. */

#include "../../stdafx.h"

#import <Foundation/Foundation.h>

#include "../../debug.h"
#include "../../rev.h"
#include "../network_internal.h"

#include "http.h"
#include "http_policy.h"
#include "http_shared.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <vector>

#include "../../safeguards.h"

class NetworkHTTPRequest {
public:
	NetworkHTTPRequest(HTTPCallback *callback, bool is_post) : callback(callback), is_post(is_post) {}

	~NetworkHTTPRequest()
	{
		[this->task release];
	}

	HTTPThreadSafeCallback callback;
	NSURLSessionDataTask *task = nil;
	const bool is_post;
	std::atomic<bool> completion_started = false;
	std::atomic<bool> finished = false;
	std::atomic<size_t> received_bytes = 0;
	long status_code = 0;
	int redirect_count = 0;
	bool response_failed = false;
};

static std::vector<std::shared_ptr<NetworkHTTPRequest>> _http_requests;
static std::mutex _http_mutex;
static std::condition_variable _http_shutdown_cv;
static std::atomic<bool> _http_shutting_down = false;
static bool _http_session_invalidated = false;

@interface OTTDHTTPDelegate : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@end

static OTTDHTTPDelegate *_http_delegate = nil;
static NSOperationQueue *_http_delegate_queue = nil;
static NSURLSession *_http_session = nil;

static bool IsHTTPURL(NSURL *url)
{
	NSString *scheme = url.scheme.lowercaseString;
	return url != nil && url.host.length != 0 && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]);
}

static std::shared_ptr<NetworkHTTPRequest> FindRequest(NSURLSessionTask *task)
{
	std::lock_guard<std::mutex> lock(_http_mutex);
	auto it = std::find_if(_http_requests.begin(), _http_requests.end(), [task](const auto &request) {
		return request->task.taskIdentifier == task.taskIdentifier;
	});
	return it != _http_requests.end() ? *it : nullptr;
}

@implementation OTTDHTTPDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion_handler
{
	@autoreleasepool {
		(void)session;
		auto request = FindRequest(task);
		if (request == nullptr) {
			completion_handler(NSURLSessionResponseCancel);
			return;
		}

		NSHTTPURLResponse *http_response = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
		request->status_code = http_response != nil ? http_response.statusCode : 0;
		request->response_failed = http_response == nil || OpenTTDHTTP::IsErrorStatus(request->status_code);
		Debug(net, 3, "HTTP request status code: {}", request->status_code);
		completion_handler(request->response_failed ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
	}
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
	@autoreleasepool {
		(void)session;
		auto request = FindRequest(task);
		if (request == nullptr || data.length == 0) return;

		Debug(net, 6, "HTTP callback: {} bytes", data.length);
		auto buffer = std::make_unique<char[]>(data.length);
		[data getBytes:buffer.get() length:data.length];
		request->received_bytes += data.length;
		request->callback.OnReceiveData(std::move(buffer), data.length);
	}
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)new_request completionHandler:(void (^)(NSURLRequest *))completion_handler
{
	@autoreleasepool {
		(void)session;
		(void)response;
		auto request = FindRequest(task);
		if (request == nullptr) {
			completion_handler(nil);
			return;
		}
		if (!IsHTTPURL(new_request.URL)) {
			request->response_failed = true;
			Debug(net, 0, "HTTP request failed: redirect URL is not HTTP(S)");
			completion_handler(nil);
			return;
		}
		if (!OpenTTDHTTP::AllowRedirect(++request->redirect_count)) {
			request->response_failed = true;
			Debug(net, 0, "HTTP request failed: too many redirects");
			completion_handler(nil);
			return;
		}
		completion_handler(new_request);
	}
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
	@autoreleasepool {
		(void)session;
		auto request = FindRequest(task);
		if (request == nullptr || request->completion_started.exchange(true)) return;

		{
			/* Serialize terminal queueing with the finished-and-empty removal check. */
			std::lock_guard<std::mutex> lock(_http_mutex);
			if (error == nil && !request->response_failed) {
				Debug(net, 1, "HTTP request succeeded: method={}, status={}, bytes={}", request->is_post ? "POST" : "GET", request->status_code, request->received_bytes.load());
				request->callback.OnReceiveData(nullptr, 0);
			} else {
				const bool quiet = request->callback.cancelled || _http_shutting_down || request->status_code == HTTP_429_TOO_MANY_REQUESTS;
				Debug(net, quiet ? 1 : 0, "HTTP request failed: status_code={}, error={}", request->status_code, error != nil ? error.localizedDescription.UTF8String : "HTTP status");
				request->callback.OnFailure();
			}
			/* Publish completion only after its terminal callback is safely queued. */
			request->finished = true;
		}
		_http_shutdown_cv.notify_all();
	}
}

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error
{
	(void)session;
	(void)error;
	{
		std::lock_guard<std::mutex> lock(_http_mutex);
		_http_session_invalidated = true;
	}
	_http_shutdown_cv.notify_all();
}

@end

/* static */ void NetworkHTTPSocketHandler::Connect(std::string_view uri, HTTPCallback *callback, std::string &&data)
{
	@autoreleasepool {
		if (_http_shutting_down || _http_session == nil) {
			callback->OnFailure();
			return;
		}

		NSString *uri_string = [[NSString alloc] initWithBytes:uri.data() length:uri.size() encoding:NSUTF8StringEncoding];
		NSURLComponents *components = uri_string != nil ? [NSURLComponents componentsWithString:uri_string] : nil;
		NSURL *url = components.URL;
		if (!IsHTTPURL(url)) {
			[uri_string release];
			Debug(net, 0, "HTTP request failed: invalid URL");
			callback->OnFailure();
			return;
		}

		NSMutableURLRequest *native_request = [[NSMutableURLRequest alloc] initWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
		const bool is_post = !data.empty();
		const std::string user_agent = fmt::format("OpenTTD/{}", GetNetworkRevisionString());
		[native_request setValue:[NSString stringWithUTF8String:user_agent.c_str()] forHTTPHeaderField:@"User-Agent"];
		if (is_post) {
			native_request.HTTPMethod = @"POST";
			native_request.HTTPBody = [NSData dataWithBytes:data.data() length:data.size()];
			const std::string_view content_type = OpenTTDHTTP::ContentTypeForPayload(data);
			[native_request setValue:[NSString stringWithUTF8String:content_type.data()] forHTTPHeaderField:@"Content-Type"];
		}

		auto request = std::make_shared<NetworkHTTPRequest>(callback, is_post);
		request->task = [[_http_session dataTaskWithRequest:native_request] retain];
		{
			std::lock_guard<std::mutex> lock(_http_mutex);
			_http_requests.push_back(request);
		}

		Debug(net, 1, "HTTP {} request to {}", is_post ? "POST" : "GET", uri);
		[request->task resume];
		[native_request release];
		[uri_string release];
	}
}

/* static */ void NetworkHTTPSocketHandler::HTTPReceive()
{
	std::vector<std::shared_ptr<NetworkHTTPRequest>> requests;
	{
		std::lock_guard<std::mutex> lock(_http_mutex);
		requests = _http_requests;
	}

	for (const auto &request : requests) {
		request->callback.HandleQueue();
		if (request->callback.cancelled && !request->finished) [request->task cancel];
	}

	std::lock_guard<std::mutex> lock(_http_mutex);
	_http_requests.erase(std::remove_if(_http_requests.begin(), _http_requests.end(), [](const auto &request) {
		return request->finished && request->callback.IsQueueEmpty();
	}), _http_requests.end());
}

void NetworkHTTPInitialize()
{
	@autoreleasepool {
		_http_shutting_down = false;
		_http_session_invalidated = false;
		_http_delegate = [[OTTDHTTPDelegate alloc] init];
		_http_delegate_queue = [[NSOperationQueue alloc] init];
		_http_delegate_queue.maxConcurrentOperationCount = 1;
		_http_delegate_queue.name = @"org.openttd.http";

		NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
		configuration.HTTPMaximumConnectionsPerHost = 4;
		configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
		_http_session = [[NSURLSession sessionWithConfiguration:configuration delegate:_http_delegate delegateQueue:_http_delegate_queue] retain];
		Debug(net, 1, "IOS_HTTP READY backend=nsurlsession tls=system");
	}
}

void NetworkHTTPUninitialize()
{
	_http_shutting_down = true;

	std::vector<std::shared_ptr<NetworkHTTPRequest>> requests;
	{
		std::lock_guard<std::mutex> lock(_http_mutex);
		requests = _http_requests;
	}
	for (const auto &request : requests) [request->task cancel];
	[_http_session invalidateAndCancel];

	bool invalidated;
	{
		std::unique_lock<std::mutex> lock(_http_mutex);
		invalidated = _http_shutdown_cv.wait_for(lock, std::chrono::seconds(10), [] { return _http_session_invalidated; });
	}
	NetworkHTTPSocketHandler::HTTPReceive();

	if (!invalidated) {
		/* ponytail: shutdown waits at most ten seconds; an async engine shutdown could release these objects after invalidation instead of leaving process exit to reclaim them. */
		Debug(net, 0, "HTTP session did not invalidate within 10 seconds");
		return;
	}

	[_http_session release];
	_http_session = nil;
	[_http_delegate release];
	_http_delegate = nil;
	[_http_delegate_queue release];
	_http_delegate_queue = nil;
}
