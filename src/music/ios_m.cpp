/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_m.cpp Native MIDI music playback for iOS. */

#include "../stdafx.h"

#include "ios_m.h"

#include <AudioUnit/AudioUnit.h>

#include "../base_media_music.h"
#include "../debug.h"
#include "../os/ios/ios_filesystem.h"
#include "ios_music.h"
#include "midifile.hpp"

#include <sys/stat.h>

#include "../safeguards.h"

static FMusicDriver_iOS iFMusicDriver_iOS;

static std::string AudioError(std::string_view operation, OSStatus status)
{
	return fmt::format("{} ({})", operation, status);
}

std::optional<std::string_view> MusicDriver_iOS::Start(const StringList &)
{
	const std::string bank_path = GetIOSDocumentsDirectory() + "/baseset/timgm6mb/TimGM6mb.sf2";
	struct stat bank_status{};
	if (stat(bank_path.c_str(), &bank_status) != 0 || !S_ISREG(bank_status.st_mode)) {
		return this->StartFailure("TimGM6mb SoundFont is unavailable");
	}

	OSStatus status = NewAUGraph(&this->graph);
	if (status != noErr) return this->StartFailure(AudioError("failed to create MIDI audio graph", status));

	const AudioComponentDescription synth_description{
		kAudioUnitType_MusicDevice, kAudioUnitSubType_MIDISynth, kAudioUnitManufacturer_Apple, 0, 0};
	const AudioComponentDescription mixer_description{
		kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer, kAudioUnitManufacturer_Apple, 0, 0};
	const AudioComponentDescription output_description{
		kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};

	AUNode synth_node = 0;
	AUNode mixer_node = 0;
	AUNode output_node = 0;
	if ((status = AUGraphAddNode(this->graph, &synth_description, &synth_node)) != noErr) {
		return this->StartFailure(AudioError("failed to add MIDI synth node", status));
	}
	if ((status = AUGraphAddNode(this->graph, &mixer_description, &mixer_node)) != noErr) {
		return this->StartFailure(AudioError("failed to add MIDI mixer node", status));
	}
	if ((status = AUGraphAddNode(this->graph, &output_description, &output_node)) != noErr) {
		return this->StartFailure(AudioError("failed to add MIDI output node", status));
	}
	if ((status = AUGraphOpen(this->graph)) != noErr) return this->StartFailure(AudioError("failed to open MIDI audio graph", status));
	if ((status = AUGraphNodeInfo(this->graph, synth_node, nullptr, &this->synth_unit)) != noErr) {
		return this->StartFailure(AudioError("failed to open MIDI synth", status));
	}
	if ((status = AUGraphNodeInfo(this->graph, mixer_node, nullptr, &this->mixer_unit)) != noErr) {
		return this->StartFailure(AudioError("failed to open MIDI mixer", status));
	}
	if ((status = AUGraphConnectNodeInput(this->graph, synth_node, 0, mixer_node, 0)) != noErr) {
		return this->StartFailure(AudioError("failed to connect MIDI synth", status));
	}
	if ((status = AUGraphConnectNodeInput(this->graph, mixer_node, 0, output_node, 0)) != noErr) {
		return this->StartFailure(AudioError("failed to connect MIDI output", status));
	}

	CFURLRef bank_url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
			reinterpret_cast<const UInt8 *>(bank_path.data()), bank_path.size(), false);
	if (bank_url == nullptr) return this->StartFailure("failed to create SoundFont URL");
	status = AudioUnitSetProperty(this->synth_unit, kMusicDeviceProperty_SoundBankURL,
			kAudioUnitScope_Global, 0, &bank_url, sizeof(bank_url));
	CFRelease(bank_url);
	if (status != noErr) return this->StartFailure(AudioError("failed to load TimGM6mb SoundFont", status));

	if ((status = AUGraphInitialize(this->graph)) != noErr) {
		return this->StartFailure(AudioError("failed to initialize MIDI audio graph", status));
	}
	this->ApplyVolumeLocked();
	if ((status = AUGraphStart(this->graph)) != noErr) return this->StartFailure(AudioError("failed to start MIDI audio graph", status));
	if ((status = NewMusicPlayer(&this->player)) != noErr) return this->StartFailure(AudioError("failed to create MIDI player", status));
	if (!SDL_AddEventWatch(&MusicDriver_iOS::WatchLifecycle, this)) return this->StartFailure(SDL_GetError());
	this->event_watch_installed = true;

	const MusicSet *music_set = BaseMusic::GetUsedSet();
	SDL_Log("IOS_MUSIC READY synth=midisynth bank=TimGM6mb.sf2 bank_bytes=%llu music_set=%s",
			static_cast<unsigned long long>(bank_status.st_size),
			music_set != nullptr ? music_set->name.c_str() : "none");
	return std::nullopt;
}

std::optional<std::string_view> MusicDriver_iOS::StartFailure(std::string error)
{
	this->Stop();
	this->startup_error = std::move(error);
	return this->startup_error;
}

void MusicDriver_iOS::Stop()
{
	if (this->event_watch_installed) {
		SDL_RemoveEventWatch(&MusicDriver_iOS::WatchLifecycle, this);
		this->event_watch_installed = false;
	}

	std::lock_guard lock(this->mutex);
	this->StopSongLocked();
	if (this->player != nullptr) {
		DisposeMusicPlayer(this->player);
		this->player = nullptr;
	}
	if (this->graph != nullptr) {
		AUGraphStop(this->graph);
		AUGraphUninitialize(this->graph);
		AUGraphClose(this->graph);
		DisposeAUGraph(this->graph);
		this->graph = nullptr;
	}
	this->synth_unit = nullptr;
	this->mixer_unit = nullptr;
	this->backgrounded = false;
	this->lifecycle_paused = false;
}

void MusicDriver_iOS::PlaySong(const MusicSongInfo &song)
{
	std::lock_guard lock(this->mutex);
	this->StopSongLocked();

	const std::string filename = MidiFile::GetSMFFile(song);
	if (filename.empty()) {
		Debug(driver, 0, "iOS MIDI: failed to resolve song file");
		return;
	}

	OSStatus status = NewMusicSequence(&this->sequence);
	if (status != noErr) {
		Debug(driver, 0, "iOS MIDI: {}", AudioError("failed to create sequence", status));
		return;
	}
	if ((status = MusicSequenceSetAUGraph(this->sequence, this->graph)) != noErr) {
		Debug(driver, 0, "iOS MIDI: {}", AudioError("failed to attach audio graph", status));
		this->StopSongLocked();
		return;
	}

	CFURLRef file_url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
			reinterpret_cast<const UInt8 *>(filename.data()), filename.size(), false);
	if (file_url == nullptr) {
		Debug(driver, 0, "iOS MIDI: failed to create song URL");
		this->StopSongLocked();
		return;
	}
	status = MusicSequenceFileLoad(this->sequence, file_url, kMusicSequenceFile_AnyType, 0);
	CFRelease(file_url);
	if (status != noErr) {
		Debug(driver, 0, "iOS MIDI: {}", AudioError("failed to load song", status));
		this->StopSongLocked();
		return;
	}

	UInt32 track_count = 0;
	MusicSequenceGetTrackCount(this->sequence, &track_count);
	std::vector<double> track_lengths;
	track_lengths.reserve(track_count);
	for (UInt32 i = 0; i < track_count; ++i) {
		MusicTrack track = nullptr;
		MusicTimeStamp track_length = 0;
		UInt32 property_size = sizeof(track_length);
		if (MusicSequenceGetIndTrack(this->sequence, i, &track) != noErr ||
				MusicTrackGetProperty(track, kSequenceTrackProperty_TrackLength, &track_length, &property_size) != noErr) {
			continue;
		}
		track_lengths.push_back(track_length);
		if (song.loop && track_length > 0) {
			MusicTrackLoopInfo loop_info{track_length, 0};
			MusicTrackSetProperty(track, kSequenceTrackProperty_LoopInfo, &loop_info, sizeof(loop_info));
		}
	}
	this->end_beat = OpenTTDIOSMusic::PlaybackEndBeat(track_lengths);
	this->looping = song.loop;

	UInt32 preload = 1;
	if ((status = AudioUnitSetProperty(this->synth_unit, kAUMIDISynthProperty_EnablePreload,
			kAudioUnitScope_Global, 0, &preload, sizeof(preload))) == noErr) {
		status = MusicPlayerSetSequence(this->player, this->sequence);
		if (status == noErr) status = MusicPlayerPreroll(this->player);
		preload = 0;
		AudioUnitSetProperty(this->synth_unit, kAUMIDISynthProperty_EnablePreload,
				kAudioUnitScope_Global, 0, &preload, sizeof(preload));
	}
	if (status == noErr) status = MusicPlayerSetTime(this->player, 0);
	if (status == noErr && !this->backgrounded) status = MusicPlayerStart(this->player);
	if (status != noErr) {
		Debug(driver, 0, "iOS MIDI: {}", AudioError("failed to start song", status));
		this->StopSongLocked();
		return;
	}

	this->playing = true;
	this->lifecycle_paused = this->backgrounded;
	this->playback_logged = false;
	SDL_Log("IOS_MUSIC PLAY file=%s tracks=%u end_beat=%.3f loop=%s", filename.c_str(), track_count,
			this->end_beat, this->looping ? "yes" : "no");
}

void MusicDriver_iOS::StopSong()
{
	std::lock_guard lock(this->mutex);
	this->StopSongLocked();
}

void MusicDriver_iOS::StopSongLocked()
{
	if (this->player != nullptr) {
		MusicPlayerStop(this->player);
		MusicPlayerSetSequence(this->player, nullptr);
	}
	if (this->sequence != nullptr) {
		DisposeMusicSequence(this->sequence);
		this->sequence = nullptr;
	}
	this->end_beat = 0;
	this->paused_beat = 0;
	this->playing = false;
	this->looping = false;
	this->lifecycle_paused = false;
	this->playback_logged = false;
}

bool MusicDriver_iOS::IsSongPlaying()
{
	std::lock_guard lock(this->mutex);
	if (!this->playing) return false;
	if (this->lifecycle_paused) return true;

	MusicTimeStamp beat = 0;
	if (MusicPlayerGetTime(this->player, &beat) != noErr) {
		this->playing = false;
		return false;
	}
	if (!this->playback_logged && beat > 0) {
		SDL_Log("IOS_MUSIC PLAYBACK active=yes beat=%.3f", beat);
		this->playback_logged = true;
	}
	if (this->looping || beat < this->end_beat) return true;

	this->playing = false;
	SDL_Log("IOS_MUSIC COMPLETE beat=%.3f end_beat=%.3f", beat, this->end_beat);
	return false;
}

void MusicDriver_iOS::SetVolume(uint8_t volume)
{
	std::lock_guard lock(this->mutex);
	this->volume = volume;
	this->ApplyVolumeLocked();
}

void MusicDriver_iOS::ApplyVolumeLocked()
{
	if (this->mixer_unit == nullptr) return;
	AudioUnitSetParameter(this->mixer_unit, kMultiChannelMixerParam_Volume,
			kAudioUnitScope_Output, 0, OpenTTDIOSMusic::VolumeToLinearGain(this->volume), 0);
}

bool SDLCALL MusicDriver_iOS::WatchLifecycle(void *userdata, SDL_Event *event)
{
	static_cast<MusicDriver_iOS *>(userdata)->HandleLifecycleEvent(event->type);
	return true;
}

void MusicDriver_iOS::HandleLifecycleEvent(Uint32 event_type)
{
	std::lock_guard lock(this->mutex);
	switch (event_type) {
		case SDL_EVENT_WILL_ENTER_BACKGROUND:
		case SDL_EVENT_DID_ENTER_BACKGROUND: {
			if (this->backgrounded) break;
			this->backgrounded = true;
			this->lifecycle_paused = this->playing;
			if (this->lifecycle_paused) {
				MusicPlayerGetTime(this->player, &this->paused_beat);
				MusicPlayerStop(this->player);
			}
			if (this->graph != nullptr) AUGraphStop(this->graph);
			SDL_Log("IOS_MUSIC LIFECYCLE background playing=%s", this->playing ? "yes" : "no");
			break;
		}

		case SDL_EVENT_WILL_ENTER_FOREGROUND:
		case SDL_EVENT_DID_ENTER_FOREGROUND: {
			if (!this->backgrounded) break;
			this->backgrounded = false;
			OSStatus status = this->graph != nullptr ? AUGraphStart(this->graph) : noErr;
			if (status == noErr && this->lifecycle_paused) status = MusicPlayerSetTime(this->player, this->paused_beat);
			if (status == noErr && this->lifecycle_paused) status = MusicPlayerStart(this->player);
			if (status != noErr) {
				Debug(driver, 0, "iOS MIDI: {}", AudioError("failed to resume playback", status));
				this->playing = false;
			}
			this->lifecycle_paused = false;
			SDL_Log("IOS_MUSIC LIFECYCLE foreground playing=%s", this->playing ? "yes" : "no");
			break;
		}

		default:
			break;
	}
}
