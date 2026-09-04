/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_audio.cpp Test iOS audio callback accounting. */

#include "../stdafx.h"

#include "../3rdparty/catch2/catch.hpp"

#include "../sound/ios_audio.h"

#include "../safeguards.h"

using namespace OpenTTDIOSAudio;

TEST_CASE("iOS audio callback chunk bounds")
{
	CHECK(ClampChunkFrames(1) == MIN_CHUNK_FRAMES);
	CHECK(ClampChunkFrames(static_cast<int>(DEFAULT_CHUNK_FRAMES)) == DEFAULT_CHUNK_FRAMES);
	CHECK(ClampChunkFrames(INT_MAX) == MAX_CHUNK_FRAMES);
}

TEST_CASE("iOS audio byte requests use complete stereo frames")
{
	CHECK(FramesForByteRequest(0, DEFAULT_CHUNK_FRAMES) == 0);
	CHECK(FramesForByteRequest(1, DEFAULT_CHUNK_FRAMES) == 1);
	CHECK(FramesForByteRequest(static_cast<int>(BYTES_PER_FRAME), DEFAULT_CHUNK_FRAMES) == 1);
	CHECK(FramesForByteRequest(static_cast<int>(BYTES_PER_FRAME + 1), DEFAULT_CHUNK_FRAMES) == 2);
	CHECK(FramesForByteRequest(INT_MAX, DEFAULT_CHUNK_FRAMES) == DEFAULT_CHUNK_FRAMES);
}
