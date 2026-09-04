/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_s.h SDL3 sound output for iOS. */

#ifndef SOUND_IOS_H
#define SOUND_IOS_H

#include "ios_audio.h"
#include "sound_driver.hpp"

#include <SDL3/SDL.h>

class SoundDriver_iOS : public SoundDriver {
public:
	std::optional<std::string_view> Start(const StringList &param) override;
	void Stop() override;
	void MainLoop() override;
	std::string_view GetName() const override { return "ios"; }

private:
	std::optional<std::string_view> StartFailure(std::string error);
	static void SDLCALL FeedAudio(void *userdata, SDL_AudioStream *stream, int additional_amount, int total_amount);
	static bool SDLCALL WatchLifecycle(void *userdata, SDL_Event *event);
	void HandleLifecycleEvent(SDL_Event *event);

	SDL_AudioStream *stream = nullptr;
	std::vector<int16_t> mix_buffer{};
	std::string startup_error{};
	std::atomic<uint64_t> callback_count = 0;
	std::atomic<int> maximum_request = 0;
	std::atomic<bool> callback_failed = false;
	std::atomic<bool> route_changed = false;
	std::atomic<bool> backgrounded = false;
	bool audio_initialized = false;
	bool event_watch_installed = false;
	bool callback_logged = false;
};

class FSoundDriver_iOS : public DriverFactoryBase {
public:
	FSoundDriver_iOS() : DriverFactoryBase(Driver::Type::Sound, 10, "ios", "SDL3 iOS Sound Driver (param hz,samples)") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<SoundDriver_iOS>(); }
};

#endif /* SOUND_IOS_H */
