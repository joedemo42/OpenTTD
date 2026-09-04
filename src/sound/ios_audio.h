/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_audio.h Platform-independent helpers for iOS audio callbacks. */

#ifndef SOUND_IOS_AUDIO_H
#define SOUND_IOS_AUDIO_H

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace OpenTTDIOSAudio {

inline constexpr size_t CHANNELS = 2;
inline constexpr size_t BYTES_PER_FRAME = sizeof(int16_t) * CHANNELS;
inline constexpr size_t MIN_CHUNK_FRAMES = 64;
inline constexpr size_t DEFAULT_CHUNK_FRAMES = 1024;
inline constexpr size_t MAX_CHUNK_FRAMES = 4096;

constexpr size_t ClampChunkFrames(int frames)
{
	return std::clamp<size_t>(frames > 0 ? static_cast<size_t>(frames) : 0, MIN_CHUNK_FRAMES, MAX_CHUNK_FRAMES);
}

constexpr size_t FramesForByteRequest(int bytes, size_t maximum_frames)
{
	if (bytes <= 0 || maximum_frames == 0) return 0;
	const size_t frames = (static_cast<size_t>(bytes) + BYTES_PER_FRAME - 1) / BYTES_PER_FRAME;
	return std::min(frames, maximum_frames);
}

} // namespace OpenTTDIOSAudio

#endif /* SOUND_IOS_AUDIO_H */
