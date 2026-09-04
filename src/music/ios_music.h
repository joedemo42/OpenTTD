/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_music.h Platform-independent iOS MIDI playback calculations. */

#ifndef MUSIC_IOS_MUSIC_H
#define MUSIC_IOS_MUSIC_H

#include <algorithm>
#include <cstdint>
#include <span>

namespace OpenTTDIOSMusic {

static constexpr double RELEASE_TAIL_BEATS = 8.0;

/** Convert OpenTTD's MIDI volume range to the mixer's linear gain. */
inline constexpr float VolumeToLinearGain(uint8_t volume)
{
	return static_cast<float>(volume) / 127.0f;
}

/** Return the end of the longest sequence track plus its note-release tail. */
inline double PlaybackEndBeat(std::span<const double> track_lengths)
{
	if (track_lengths.empty()) return 0.0;
	return *std::ranges::max_element(track_lengths) + RELEASE_TAIL_BEATS;
}

} // namespace OpenTTDIOSMusic

#endif /* MUSIC_IOS_MUSIC_H */
