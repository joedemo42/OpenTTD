/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_platform.mm Native iOS platform services. */

#include "../../stdafx.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "../../crashlog.h"
#include "../../debug.h"
#include "../../fios.h"
#include "../../library_loader.h"
#include "../../survey.h"
#include "../../thread.h"

#include "ios_filesystem.h"

#include <Availability.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <sys/mount.h>
#include <sys/utsname.h>

#include "../../safeguards.h"

bool FiosIsRoot(const std::string &path)
{
	return std::filesystem::path{path}.lexically_normal() == std::filesystem::path{GetIOSDocumentsDirectory()}.lexically_normal();
}

void FiosGetDrives(FileList &)
{
}

std::optional<uint64_t> FiosGetDiskFreeSpace(const std::string &path)
{
	struct statfs status;
	if (statfs(path.c_str(), &status) != 0) return std::nullopt;
	return static_cast<uint64_t>(status.f_bsize) * status.f_bavail;
}

bool FiosIsHiddenFile(const std::filesystem::path &path)
{
	return path.filename().string().starts_with(".");
}

void ShowInfoI(std::string_view message)
{
	fmt::print(stderr, "{}\n", message);
}

void ShowOSErrorBox(std::string_view message, bool)
{
	fmt::print(stderr, "Error: {}\n", message);
}

static std::optional<std::string> NSStringToString(NSString *string)
{
	if (string == nil || string.length == 0) return std::nullopt;
	const char *utf8 = string.UTF8String;
	return utf8 != nullptr ? std::optional<std::string>{utf8} : std::nullopt;
}

std::optional<std::string> GetCurrentLocale(const char *)
{
	@autoreleasepool {
		NSString *identifier = NSLocale.preferredLanguages.firstObject;
		if (identifier == nil) return std::nullopt;

		NSLocale *locale = [NSLocale localeWithLocaleIdentifier:identifier];
		NSString *language = [locale objectForKey:NSLocaleLanguageCode];
		NSString *region = [locale objectForKey:NSLocaleCountryCode];
		NSString *script = [locale objectForKey:NSLocaleScriptCode];
		if (language == nil) return std::nullopt;

		if (region == nil && [language isEqualToString:@"zh"]) {
			if ([script isEqualToString:@"Hans"]) region = @"CN";
			if ([script isEqualToString:@"Hant"]) region = @"TW";
		}

		NSString *result = region != nil ? [NSString stringWithFormat:@"%@_%@", language, region] : language;
		return NSStringToString(result);
	}
}

std::optional<std::string> GetClipboardContents()
{
	__block std::optional<std::string> result;
	dispatch_block_t read_clipboard = ^{
		@autoreleasepool {
			result = NSStringToString(UIPasteboard.generalPasteboard.string);
		}
	};

	if (NSThread.isMainThread) {
		read_clipboard();
	} else {
		dispatch_sync(dispatch_get_main_queue(), read_clipboard);
	}
	return result;
}

void OSOpenBrowser(const std::string &url)
{
	@autoreleasepool {
		NSString *string = [NSString stringWithUTF8String:url.c_str()];
		NSURLComponents *components = string != nil ? [NSURLComponents componentsWithString:string] : nil;
		NSString *scheme = components.scheme.lowercaseString;
		NSURL *target = components.URL;
		if (target == nil || components.host.length == 0 || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
			Debug(misc, 1, "Refusing to open invalid browser URL: {}", url);
			return;
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			[UIApplication.sharedApplication openURL:target options:@{} completionHandler:^(BOOL success) {
				if (!success) Debug(misc, 1, "Unable to open browser URL");
			}];
		});
	}
}

void SetCurrentThreadName(const std::string &thread_name)
{
	pthread_setname_np(thread_name.substr(0, 63).c_str());
}

void SurveyOS(nlohmann::json &json)
{
	NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
	struct utsname name{};
	const bool have_machine = uname(&name) == 0;

	json["os"] = "iOS";
	json["release"] = fmt::format("{}.{}.{}", version.majorVersion, version.minorVersion, version.patchVersion);
	json["machine"] = have_machine ? name.machine : "unknown";
	json["min_ver"] = __IPHONE_OS_VERSION_MIN_REQUIRED;
	json["max_ver"] = __IPHONE_OS_VERSION_MAX_ALLOWED;
	json["memory"] = SurveyMemoryToText(NSProcessInfo.processInfo.physicalMemory);
	json["hardware_concurrency"] = std::thread::hardware_concurrency();
}

void *LibraryLoader::OpenLibrary(const std::string &)
{
	this->error = "Dynamic loading is not supported on iOS.";
	return nullptr;
}

void LibraryLoader::CloseLibrary()
{
}

void *LibraryLoader::GetSymbol(const std::string &)
{
	this->error = "Dynamic loading is not supported on iOS.";
	return nullptr;
}

/* ponytail: Milestone 15 adds an iOS crash-reporting strategy. */
void CrashLog::InitialiseCrashLog()
{
}

void CrashLog::InitThread()
{
}
