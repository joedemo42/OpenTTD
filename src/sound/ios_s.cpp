/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_s.cpp SDL3 sound output for iOS. */

#include "../stdafx.h"

#include "../base_media_sounds.h"
#include "../debug.h"
#include "../mixer.h"
#include "ios_s.h"

#include "../safeguards.h"

static FSoundDriver_iOS iFSoundDriver_iOS;

std::optional<std::string_view> SoundDriver_iOS::Start(const StringList &param)
{
	const int rate = GetDriverParamInt(param, "hz", 44100);
	if (rate < 8000 || rate > 192000) return this->StartFailure("iOS sound sample rate must be between 8000 and 192000 Hz");

	const size_t chunk_frames = OpenTTDIOSAudio::ClampChunkFrames(
			GetDriverParamInt(param, "samples", static_cast<int>(OpenTTDIOSAudio::DEFAULT_CHUNK_FRAMES)));
	this->mix_buffer.resize(chunk_frames * OpenTTDIOSAudio::CHANNELS);
	this->callback_count = 0;
	this->maximum_request = 0;
	this->callback_failed = false;
	this->route_changed = false;
	this->backgrounded = false;
	this->callback_logged = false;

	SDL_SetHint(SDL_HINT_AUDIO_CATEGORY, "ambient");
	if (!SDL_InitSubSystem(SDL_INIT_AUDIO)) return this->StartFailure(SDL_GetError());
	this->audio_initialized = true;

	const SDL_AudioSpec requested{SDL_AUDIO_S16, static_cast<int>(OpenTTDIOSAudio::CHANNELS), rate};
	this->stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &requested, &SoundDriver_iOS::FeedAudio, this);
	if (this->stream == nullptr) return this->StartFailure(SDL_GetError());

	MxInitialize(rate);
	if (!SDL_AddEventWatch(&SoundDriver_iOS::WatchLifecycle, this)) return this->StartFailure(SDL_GetError());
	this->event_watch_installed = true;
	if (!SDL_ResumeAudioStreamDevice(this->stream)) return this->StartFailure(SDL_GetError());

	SDL_AudioSpec source = requested;
	SDL_AudioSpec output{};
	if (!SDL_GetAudioStreamFormat(this->stream, &source, &output)) SDL_ClearError();
	const SoundsSet *sound_set = BaseSounds::GetUsedSet();
	const char *set_name = sound_set != nullptr ? sound_set->name.c_str() : "none";
	const char *bank_name = sound_set != nullptr ? sound_set->files[0].filename.c_str() : "none";
	SDL_Log("IOS_AUDIO READY rate=%d output_rate=%d channels=%d chunk_frames=%zu category=ambient sound_set=%s bank=%s",
			rate, output.freq, requested.channels, chunk_frames, set_name, bank_name);
	return std::nullopt;
}

std::optional<std::string_view> SoundDriver_iOS::StartFailure(std::string error)
{
	this->Stop();
	this->startup_error = std::move(error);
	return this->startup_error;
}

void SoundDriver_iOS::Stop()
{
	if (this->event_watch_installed) {
		SDL_RemoveEventWatch(&SoundDriver_iOS::WatchLifecycle, this);
		this->event_watch_installed = false;
	}
	if (this->stream != nullptr) {
		SDL_PauseAudioStreamDevice(this->stream);
		SDL_SetAudioStreamGetCallback(this->stream, nullptr, nullptr);
		SDL_DestroyAudioStream(this->stream);
		this->stream = nullptr;
	}
	if (this->audio_initialized) {
		SDL_QuitSubSystem(SDL_INIT_AUDIO);
		this->audio_initialized = false;
	}
	this->mix_buffer.clear();
	this->backgrounded = false;
}

void SoundDriver_iOS::MainLoop()
{
	const uint64_t callbacks = this->callback_count.load(std::memory_order_relaxed);
	if (!this->callback_logged && callbacks != 0) {
		SDL_Log("IOS_AUDIO CALLBACK active=yes count=%llu max_request_bytes=%d",
				static_cast<unsigned long long>(callbacks), this->maximum_request.load(std::memory_order_relaxed));
		this->callback_logged = true;
	}
	if (this->callback_failed.exchange(false, std::memory_order_relaxed)) {
		Debug(driver, 0, "iOS: failed to feed the SDL3 audio stream");
	}
	if (this->route_changed.exchange(false, std::memory_order_relaxed) && this->stream != nullptr) {
		SDL_AudioSpec output{};
		if (SDL_GetAudioStreamFormat(this->stream, nullptr, &output)) {
			SDL_Log("IOS_AUDIO ROUTE output_rate=%d channels=%d", output.freq, output.channels);
		}
	}
}

void SDLCALL SoundDriver_iOS::FeedAudio(void *userdata, SDL_AudioStream *stream, int additional_amount, int)
{
	auto *driver = static_cast<SoundDriver_iOS *>(userdata);
	if (additional_amount <= 0 || driver->mix_buffer.empty()) return;

	driver->callback_count.fetch_add(1, std::memory_order_relaxed);
	int observed = driver->maximum_request.load(std::memory_order_relaxed);
	while (observed < additional_amount && !driver->maximum_request.compare_exchange_weak(
			observed, additional_amount, std::memory_order_relaxed, std::memory_order_relaxed)) {}

	int bytes_left = additional_amount;
	const size_t maximum_frames = driver->mix_buffer.size() / OpenTTDIOSAudio::CHANNELS;
	while (bytes_left > 0) {
		const size_t frames = OpenTTDIOSAudio::FramesForByteRequest(bytes_left, maximum_frames);
		MxMixSamples(driver->mix_buffer.data(), static_cast<uint>(frames));
		const int bytes = static_cast<int>(frames * OpenTTDIOSAudio::BYTES_PER_FRAME);
		if (!SDL_PutAudioStreamData(stream, driver->mix_buffer.data(), bytes)) {
			driver->callback_failed = true;
			return;
		}
		bytes_left -= std::min(bytes_left, bytes);
	}
}

bool SDLCALL SoundDriver_iOS::WatchLifecycle(void *userdata, SDL_Event *event)
{
	static_cast<SoundDriver_iOS *>(userdata)->HandleLifecycleEvent(event);
	return true;
}

void SoundDriver_iOS::HandleLifecycleEvent(SDL_Event *event)
{
	if (this->stream == nullptr) return;

	switch (event->type) {
		case SDL_EVENT_WILL_ENTER_BACKGROUND:
		case SDL_EVENT_DID_ENTER_BACKGROUND:
			if (!this->backgrounded.exchange(true, std::memory_order_relaxed)) {
				SDL_PauseAudioStreamDevice(this->stream);
				SDL_ClearAudioStream(this->stream);
				SDL_Log("IOS_AUDIO LIFECYCLE background");
			}
			break;

		case SDL_EVENT_WILL_ENTER_FOREGROUND:
		case SDL_EVENT_DID_ENTER_FOREGROUND:
			if (this->backgrounded.exchange(false, std::memory_order_relaxed)) {
				if (!SDL_ResumeAudioStreamDevice(this->stream)) this->callback_failed = true;
				SDL_Log("IOS_AUDIO LIFECYCLE foreground");
			}
			break;

		case SDL_EVENT_AUDIO_DEVICE_ADDED:
		case SDL_EVENT_AUDIO_DEVICE_REMOVED:
		case SDL_EVENT_AUDIO_DEVICE_FORMAT_CHANGED:
			if (!event->adevice.recording) this->route_changed = true;
			break;

		default:
			break;
	}
}
