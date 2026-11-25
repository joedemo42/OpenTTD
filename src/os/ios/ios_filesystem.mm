/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_filesystem.mm iOS container paths and bundled-data seeding. */

#include "../../stdafx.h"
#include "ios_filesystem.h"
#include "openttd_ios.h"

#include "../../safeguards.h"

#import <Foundation/Foundation.h>

/** User defaults key of the bundled data stamp that Documents was last seeded from. */
static NSString *const SEED_STAMP_KEY = @"SeedDataStamp";

static bool SetError(char *buffer, size_t size, NSString *message)
{
	if (buffer != nullptr && size != 0 && ![message getCString:buffer maxLength:size encoding:NSUTF8StringEncoding]) buffer[0] = '\0';
	return false;
}

static NSURL *GetDocumentsURL()
{
	return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
}

const std::string &GetIOSDocumentsDirectory()
{
	static const std::string path = [] {
		@autoreleasepool {
			NSURL *url = GetDocumentsURL();
			return url == nil ? std::string{} : std::string{url.fileSystemRepresentation};
		}
	}();
	return path;
}

/**
 * Copy the bundled seed into Documents.
 * @param refresh Also replace files that already exist; otherwise only missing files are copied.
 */
static bool CopySeedDirectory(NSFileManager *file_manager, NSURL *source, NSURL *destination, bool refresh, char *error_message, size_t error_message_size)
{
	NSError *error = nil;
	if (![file_manager createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:&error]) {
		return SetError(error_message, error_message_size, error.localizedDescription);
	}

	NSArray<NSURL *> *children = [file_manager contentsOfDirectoryAtURL:source includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:&error];
	if (children == nil) return SetError(error_message, error_message_size, error.localizedDescription);

	for (NSURL *child in children) {
		NSNumber *is_directory = nil;
		if (![child getResourceValue:&is_directory forKey:NSURLIsDirectoryKey error:&error]) {
			return SetError(error_message, error_message_size, error.localizedDescription);
		}

		NSURL *target = [destination URLByAppendingPathComponent:child.lastPathComponent isDirectory:is_directory.boolValue];
		if (is_directory.boolValue) {
			if (!CopySeedDirectory(file_manager, child, target, refresh, error_message, error_message_size)) return false;
			continue;
		}

		if (!refresh && [file_manager fileExistsAtPath:target.path]) continue;
		NSURL *temporary = [destination URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.%@", child.lastPathComponent, NSUUID.UUID.UUIDString]];
		if (![file_manager copyItemAtURL:child toURL:temporary error:&error]) {
			return SetError(error_message, error_message_size, error.localizedDescription);
		}
		/* rename() also replaces an outdated copy, atomically. */
		if (rename(temporary.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
			error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
			[file_manager removeItemAtURL:temporary error:nil];
			return SetError(error_message, error_message_size, error.localizedDescription);
		}
	}
	return true;
}

const char *OpenTTDIOSGetDocumentsPath(void)
{
	return GetIOSDocumentsDirectory().c_str();
}

bool OpenTTDIOSPrepareDocuments(char *error_message, size_t error_message_size)
{
	@autoreleasepool {
		NSFileManager *file_manager = NSFileManager.defaultManager;
		NSURL *documents = GetDocumentsURL();
		NSURL *seed = [NSBundle.mainBundle URLForResource:@"SeedData" withExtension:nil];
		if (documents == nil) return SetError(error_message, error_message_size, @"Documents directory is unavailable");
		if (seed == nil) return SetError(error_message, error_message_size, @"Bundled SeedData directory is unavailable");
		NSURL *stamp_url = [NSBundle.mainBundle URLForResource:@"data" withExtension:@"stamp"];
		NSString *stamp = stamp_url == nil ? nil : [NSString stringWithContentsOfURL:stamp_url encoding:NSUTF8StringEncoding error:nil];
		if (stamp == nil) return SetError(error_message, error_message_size, @"Bundled data stamp is unavailable");

		/* The seed holds only the engine's own data (languages, base sets, scripts) and empty directories.
		 * A build with other data replaces every seeded file, so an update never runs on stale data. */
		NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
		bool refresh = ![stamp isEqualToString:[defaults stringForKey:SEED_STAMP_KEY]];
		if (!CopySeedDirectory(file_manager, seed, documents, refresh, error_message, error_message_size)) return false;
		if (refresh) [defaults setObject:stamp forKey:SEED_STAMP_KEY];

		NSArray<NSString *> *directories = @[
			@"save/autosave", @"scenario/heightmap", @"baseset", @"newgrf", @"ai/library",
			@"game/library", @"screenshot", @"content_download"
		];
		for (NSString *relative in directories) {
			NSError *error = nil;
			NSURL *directory = [documents URLByAppendingPathComponent:relative isDirectory:YES];
			if (![file_manager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
				return SetError(error_message, error_message_size, error.localizedDescription);
			}
		}
	}
	return true;
}

bool OpenTTDIOSValidateDocuments(char *error_message, size_t error_message_size)
{
	@autoreleasepool {
		NSFileManager *file_manager = NSFileManager.defaultManager;
		NSURL *documents = GetDocumentsURL();
		if (documents == nil) return SetError(error_message, error_message_size, @"Documents directory is unavailable");

		NSArray<NSString *> *files = @[
			@"baseset/openttd.grf", @"baseset/opengfx-8.0.tar", @"baseset/opensfx-1.0.3.tar",
			@"baseset/openmsx-0.4.2/openmsx.obm", @"lang/english.lng"
		];
		for (NSString *relative in files) {
			NSString *path = [documents URLByAppendingPathComponent:relative].path;
			NSDictionary<NSFileAttributeKey, id> *attributes = [file_manager attributesOfItemAtPath:path error:nil];
			if (![attributes.fileType isEqualToString:NSFileTypeRegular] || attributes.fileSize == 0) {
				return SetError(error_message, error_message_size, [@"Required data is missing: " stringByAppendingString:relative]);
			}
		}

		NSArray<NSString *> *directories = @[@"baseset", @"save/autosave", @"scenario/heightmap", @"newgrf"];
		for (NSString *relative in directories) {
			BOOL is_directory = NO;
			NSString *path = [documents URLByAppendingPathComponent:relative].path;
			if (![file_manager fileExistsAtPath:path isDirectory:&is_directory] || !is_directory) {
				return SetError(error_message, error_message_size, [@"Required directory is missing: " stringByAppendingString:relative]);
			}
		}
	}
	return true;
}
