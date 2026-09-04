/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_v.cpp SDL3 Metal video driver for iOS. */

#include "../stdafx.h"
#include "../blitter/factory.hpp"
#include "../core/geometry_func.hpp"
#include "../error_func.h"
#include "../framerate_type.h"
#include "../gfx_func.h"
#include "../openttd.h"
#include "../progress.h"
#include "../window_func.h"
#include "ios_v.h"

#include "../safeguards.h"

static FVideoDriver_iOS iFVideoDriver_iOS;

std::optional<std::string_view> VideoDriver_iOS::Start(const StringList &param)
{
	if (BlitterFactory::GetCurrentBlitter()->GetScreenDepth() != 32) return "The iOS video driver requires a 32bpp blitter";

	SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");
	if (!SDL_InitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) return SDL_GetError();

	this->window = SDL_CreateWindow(VideoDriver::GetCaption().c_str(), 1024, 768,
			SDL_WINDOW_FULLSCREEN | SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_RESIZABLE);
	if (this->window == nullptr) return this->StartFailure(SDL_GetError());

	this->renderer = SDL_CreateRenderer(this->window, "metal");
	if (this->renderer == nullptr) return this->StartFailure(SDL_GetError());

	const char *renderer_name = SDL_GetRendererName(this->renderer);
	if (renderer_name == nullptr || std::string_view{renderer_name} != "metal") {
		return this->StartFailure("SDL3 did not create a Metal renderer");
	}

	if (!SDL_AddEventWatch(&VideoDriver_iOS::WatchLifecycle, this)) return this->StartFailure(SDL_GetError());
	this->event_watch_installed = true;

	if (!this->UpdateLayout(true)) return this->StartFailure(SDL_GetError());

	this->driver_info = fmt::format("{} ({})", this->GetName(), renderer_name);
	this->is_game_threaded = !GetDriverParamBool(param, "no_threads") && !GetDriverParamBool(param, "no_thread");
	_fullscreen = true;
	_video_vsync = true;
	this->ToggleVsync(true);
	MarkWholeScreenDirty();

	int output_width = 0;
	int output_height = 0;
	SDL_GetCurrentRenderOutputSize(this->renderer, &output_width, &output_height);
	SDL_Log("IOS_VIDEO READY renderer=%s output=%dx%d window=%dx%d safe=%d,%d %dx%d threaded=%s",
			renderer_name, output_width, output_height, this->window_width, this->window_height,
			this->safe_x, this->safe_y, _screen.width, _screen.height, this->is_game_threaded ? "yes" : "no");
	return std::nullopt;
}

std::optional<std::string_view> VideoDriver_iOS::StartFailure(std::string error)
{
	this->Stop();
	this->startup_error = std::move(error);
	return this->startup_error;
}

void VideoDriver_iOS::Stop()
{
	this->SetGameThreadSuspended(false);
	if (this->event_watch_installed) {
		SDL_RemoveEventWatch(&VideoDriver_iOS::WatchLifecycle, this);
		this->event_watch_installed = false;
	}

	_screen.dst_ptr = nullptr;
	this->framebuffer.clear();
	SDL_DestroyTexture(this->texture);
	SDL_DestroyRenderer(this->renderer);
	SDL_DestroyWindow(this->window);
	this->texture = nullptr;
	this->renderer = nullptr;
	this->window = nullptr;
	SDL_QuitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
}

void VideoDriver_iOS::MakeDirty(int left, int top, int width, int height)
{
	if (width <= 0 || height <= 0) return;
	this->dirty_rect = BoundingRect(this->dirty_rect, {left, top, left + width, top + height});
}

void VideoDriver_iOS::MainLoop()
{
	this->StartGameThread();
	while (!_exit_game) {
		if (this->backgrounded) {
			while (this->PollEvent()) {}
			SDL_Delay(10);
			continue;
		}

		this->Tick();
		this->SleepTillNextTick();
	}
	this->SetGameThreadSuspended(false);
	this->StopGameThread();
}

bool VideoDriver_iOS::ChangeResolution(int, int)
{
	return this->UpdateLayout(false);
}

bool VideoDriver_iOS::ToggleFullscreen(bool)
{
	_fullscreen = true;
	return true;
}

void VideoDriver_iOS::ToggleVsync(bool vsync)
{
	if (this->renderer != nullptr && !SDL_SetRenderVSync(this->renderer, vsync ? 1 : SDL_RENDERER_VSYNC_DISABLED)) {
		Debug(driver, 0, "iOS: could not {} vsync: {}", vsync ? "enable" : "disable", SDL_GetError());
	}
}

bool VideoDriver_iOS::AfterBlitterChange()
{
	return BlitterFactory::GetCurrentBlitter()->GetScreenDepth() == 32 && this->UpdateLayout(true);
}

Dimension VideoDriver_iOS::GetScreenSize() const
{
	if (_screen.width > 0 && _screen.height > 0) return {static_cast<uint>(_screen.width), static_cast<uint>(_screen.height)};
	return {1024, 768};
}

bool VideoDriver_iOS::LockVideoBuffer()
{
	if (this->buffer_locked) return false;
	this->buffer_locked = true;
	_screen.dst_ptr = this->framebuffer.data();
	return true;
}

void VideoDriver_iOS::UnlockVideoBuffer()
{
	_screen.dst_ptr = nullptr;
	this->buffer_locked = false;
}

void VideoDriver_iOS::CheckPaletteAnim()
{
	if (!CopyPalette(this->local_palette)) return;
	this->MakeDirty(0, 0, _screen.width, _screen.height);
}

bool VideoDriver_iOS::PollEvent()
{
	SDL_Event event;
	if (!SDL_PollEvent(&event)) return false;

	switch (event.type) {
		case SDL_EVENT_QUIT:
		case SDL_EVENT_TERMINATING:
		case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
			_exit_game = true;
			this->SetGameThreadSuspended(false);
			break;

		case SDL_EVENT_WINDOW_RESIZED:
		case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
		case SDL_EVENT_WINDOW_SAFE_AREA_CHANGED:
			if (!this->UpdateLayout(false)) Debug(driver, 0, "iOS: failed to update window layout: {}", SDL_GetError());
			this->redraw_requested = true;
			break;

		case SDL_EVENT_WINDOW_EXPOSED:
		case SDL_EVENT_DID_ENTER_FOREGROUND:
			this->redraw_requested = true;
			break;

		default:
			break;
	}
	return true;
}

void VideoDriver_iOS::Paint()
{
	PerformanceMeasurer framerate(PerformanceElement::Video);

	if (this->backgrounded) return;
	if (this->redraw_requested.exchange(false)) this->MakeDirty(0, 0, _screen.width, _screen.height);

	if (this->local_palette.count_dirty != 0) {
		Blitter *blitter = BlitterFactory::GetCurrentBlitter();
		if (blitter->UsePaletteAnimation() == Blitter::PaletteAnimation::Blitter) {
			blitter->PaletteAnimate(this->local_palette);
		}
		this->local_palette.count_dirty = 0;
	}

	if (IsEmptyRect(this->dirty_rect)) return;

	SDL_Rect update{
		std::clamp(this->dirty_rect.left, 0, _screen.width),
		std::clamp(this->dirty_rect.top, 0, _screen.height),
		0,
		0,
	};
	const int right = std::clamp(this->dirty_rect.right, 0, _screen.width);
	const int bottom = std::clamp(this->dirty_rect.bottom, 0, _screen.height);
	update.w = right - update.x;
	update.h = bottom - update.y;
	if (update.w <= 0 || update.h <= 0) {
		this->dirty_rect = {};
		return;
	}

	const uint32_t *pixels = this->framebuffer.data() + static_cast<size_t>(update.y) * _screen.pitch + update.x;
	if (!SDL_UpdateTexture(this->texture, &update, pixels, _screen.pitch * sizeof(uint32_t))) {
		Debug(driver, 0, "iOS: dirty texture upload failed: {}", SDL_GetError());
		return;
	}

	SDL_SetRenderDrawColor(this->renderer, 0, 0, 0, 255);
	SDL_RenderClear(this->renderer);
	const SDL_FRect destination{
		static_cast<float>(this->safe_x), static_cast<float>(this->safe_y),
		static_cast<float>(_screen.width), static_cast<float>(_screen.height),
	};
	if (!SDL_RenderTexture(this->renderer, this->texture, nullptr, &destination) || !SDL_RenderPresent(this->renderer)) {
		Debug(driver, 0, "iOS: Metal presentation failed: {}", SDL_GetError());
		return;
	}

	if (!this->logged_first_present) {
		SDL_Log("IOS_VIDEO PRESENT first_dirty=%d,%d %dx%d", update.x, update.y, update.w, update.h);
		this->logged_first_present = true;
	}
	this->dirty_rect = {};
}

bool VideoDriver_iOS::UpdateLayout(bool force)
{
	int new_window_width = 0;
	int new_window_height = 0;
	if (!SDL_GetWindowSize(this->window, &new_window_width, &new_window_height)) return false;

	SDL_Rect safe{0, 0, new_window_width, new_window_height};
	if (!SDL_GetWindowSafeArea(this->window, &safe)) SDL_ClearError();
	if (new_window_width <= 0 || new_window_height <= 0) return false;
	safe.x = std::clamp(safe.x, 0, new_window_width - 1);
	safe.y = std::clamp(safe.y, 0, new_window_height - 1);
	safe.w = std::clamp(safe.w, 1, new_window_width - safe.x);
	safe.h = std::clamp(safe.h, 1, new_window_height - safe.y);

	if (!SDL_SetRenderLogicalPresentation(this->renderer, new_window_width, new_window_height, SDL_LOGICAL_PRESENTATION_STRETCH)) return false;

	const bool size_changed = safe.w != _screen.width || safe.h != _screen.height;
	this->window_width = new_window_width;
	this->window_height = new_window_height;
	this->safe_x = safe.x;
	this->safe_y = safe.y;
	if (!force && !size_changed) return true;

	SDL_Texture *new_texture = SDL_CreateTexture(this->renderer, SDL_PIXELFORMAT_BGRA32,
			SDL_TEXTUREACCESS_STREAMING, safe.w, safe.h);
	if (new_texture == nullptr) return false;
	if (!SDL_SetTextureScaleMode(new_texture, SDL_SCALEMODE_NEAREST)) {
		SDL_DestroyTexture(new_texture);
		return false;
	}

	std::vector<uint32_t> new_framebuffer(static_cast<size_t>(safe.w) * safe.h);
	SDL_DestroyTexture(this->texture);
	this->texture = new_texture;
	this->framebuffer.swap(new_framebuffer);
	this->dirty_rect = {};
	_screen.width = safe.w;
	_screen.height = safe.h;
	_screen.pitch = safe.w;
	_screen.dst_ptr = this->framebuffer.data();
	_resolutions.assign(1, {static_cast<uint>(safe.w), static_cast<uint>(safe.h)});

	CopyPalette(this->local_palette, true);
	BlitterFactory::GetCurrentBlitter()->PostResize();
	GameSizeChanged();
	SDL_Log("IOS_VIDEO LAYOUT window=%dx%d safe=%d,%d %dx%d", new_window_width, new_window_height,
			safe.x, safe.y, safe.w, safe.h);
	return true;
}

bool SDLCALL VideoDriver_iOS::WatchLifecycle(void *userdata, SDL_Event *event)
{
	static_cast<VideoDriver_iOS *>(userdata)->HandleLifecycleEvent(event->type);
	return true;
}

void VideoDriver_iOS::HandleLifecycleEvent(Uint32 event_type)
{
	switch (event_type) {
		case SDL_EVENT_WILL_ENTER_BACKGROUND:
		case SDL_EVENT_DID_ENTER_BACKGROUND:
			this->backgrounded = true;
			this->SetGameThreadSuspended(true);
			SDL_Log("IOS_VIDEO LIFECYCLE background event=%u", event_type);
			break;

		case SDL_EVENT_WILL_ENTER_FOREGROUND:
		case SDL_EVENT_DID_ENTER_FOREGROUND:
			this->redraw_requested = true;
			this->backgrounded = false;
			this->SetGameThreadSuspended(false);
			SDL_Log("IOS_VIDEO LIFECYCLE foreground event=%u", event_type);
			break;

		case SDL_EVENT_TERMINATING:
			_exit_game = true;
			this->SetGameThreadSuspended(false);
			SDL_Log("IOS_VIDEO LIFECYCLE terminating");
			break;

		case SDL_EVENT_LOW_MEMORY:
			SDL_Log("IOS_VIDEO LIFECYCLE low-memory");
			break;

		default:
			break;
	}
}
