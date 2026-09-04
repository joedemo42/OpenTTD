/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_m.h Native MIDI music playback for iOS. */

#ifndef MUSIC_IOS_H
#define MUSIC_IOS_H

#include "music_driver.hpp"

#include <AudioToolbox/AudioToolbox.h>
#include <SDL3/SDL.h>

#include <mutex>

class MusicDriver_iOS final : public MusicDriver {
public:
	std::optional<std::string_view> Start(const StringList &param) override;
	void Stop() override;
	void PlaySong(const MusicSongInfo &song) override;
	void StopSong() override;
	bool IsSongPlaying() override;
	void SetVolume(uint8_t volume) override;
	std::string_view GetName() const override { return "ios"; }

private:
	std::optional<std::string_view> StartFailure(std::string error);
	void StopSongLocked();
	void ApplyVolumeLocked();
	void HandleLifecycleEvent(Uint32 event_type);
	static bool SDLCALL WatchLifecycle(void *userdata, SDL_Event *event);

	std::mutex mutex{};
	AUGraph graph = nullptr;
	AudioUnit synth_unit = nullptr;
	AudioUnit mixer_unit = nullptr;
	MusicPlayer player = nullptr;
	MusicSequence sequence = nullptr;
	MusicTimeStamp end_beat = 0;
	MusicTimeStamp paused_beat = 0;
	std::string startup_error{};
	uint8_t volume = 127;
	bool event_watch_installed = false;
	bool playing = false;
	bool looping = false;
	bool backgrounded = false;
	bool lifecycle_paused = false;
	bool playback_logged = false;
};

class FMusicDriver_iOS final : public DriverFactoryBase {
public:
	FMusicDriver_iOS() : DriverFactoryBase(Driver::Type::Music, 10, "ios", "Audio Toolbox iOS MIDI Driver") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<MusicDriver_iOS>(); }
};

#endif /* MUSIC_IOS_H */
