/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_platform.cpp Minimal platform services required during iOS engine bring-up. */

#include "../../stdafx.h"
#include "../../crashlog.h"
#include "../../debug.h"
#include "../../fios.h"
#include "../../library_loader.h"
#include "../../survey.h"
#include "../../thread.h"

#include "ios_filesystem.h"

#include <pthread.h>
#include <sys/mount.h>

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

std::optional<std::string> GetCurrentLocale(const char *)
{
	/* ponytail: Milestone 10 replaces the English fallback with the preferred iOS locale. */
	return std::nullopt;
}

std::optional<std::string> GetClipboardContents()
{
	/* ponytail: Milestone 10 adds UIKit clipboard access on the main thread. */
	return std::nullopt;
}

void OSOpenBrowser(const std::string &url)
{
	/* ponytail: Milestone 10 validates and opens this URL through UIApplication. */
	Debug(misc, 1, "Opening URLs is not available during iOS bring-up: {}", url);
}

void SetCurrentThreadName(const std::string &thread_name)
{
	pthread_setname_np(thread_name.substr(0, 63).c_str());
}

void SurveyOS(nlohmann::json &json)
{
	json["os"] = "iOS";
	json["hardware_concurrency"] = std::thread::hardware_concurrency();
	/* ponytail: Milestone 10 adds the iOS version and physical-memory fields. */
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
