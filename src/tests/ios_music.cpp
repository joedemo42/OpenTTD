/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_music.cpp Test platform-independent iOS MIDI playback calculations. */

#include "../stdafx.h"

#include "../3rdparty/catch2/catch.hpp"

#include "../music/ios_music.h"

#include "../safeguards.h"

using namespace OpenTTDIOSMusic;

TEST_CASE("iOS music master volume uses linear gain")
{
	CHECK(VolumeToLinearGain(0) == 0.0f);
	CHECK(VolumeToLinearGain(127) == 1.0f);
	CHECK(VolumeToLinearGain(64) == 64.0f / 127.0f);
}

TEST_CASE("iOS music playback uses the longest track and a release tail")
{
	CHECK(PlaybackEndBeat(std::span<const double>{}) == 0.0);
	const std::array<double, 3> tracks{12.5, 40.0, 32.0};
	CHECK(PlaybackEndBeat(tracks) == 48.0);
}
