/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file openttd_ios.cpp Public bridge between the iOS application and engine. */

#include "../../stdafx.h"
#include "../../core/random_func.hpp"
#include "../../crashlog.h"
#include "../../openttd.h"
#include "../../rev.h"
#include "../../string_func.h"

#include "openttd_ios.h"

#include <signal.h>
#include <time.h>

#include "../../safeguards.h"

const char *OpenTTDIOSGetEngineRevision(void)
{
	return _openttd_revision.c_str();
}

int OpenTTDIOSMain(int argc, char *argv[])
{
	std::vector<std::string_view> params;
	params.reserve(static_cast<size_t>(argc) + 8);
	for (int i = 0; i < argc; ++i) {
		StrMakeValidInPlace(argv[i]);
		params.emplace_back(argv[i]);
	}

	params.insert(params.end(), {"-v", "ios", "-b", "32bpp-anim", "-s", "ios", "-m", "ios"});
	CrashLog::InitialiseCrashLog();
	SetRandomSeed(time(nullptr));
	signal(SIGPIPE, SIG_IGN);
	return openttd_main(params);
}
