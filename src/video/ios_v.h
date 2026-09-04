/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_v.h SDL3 Metal video driver for iOS. */

#ifndef VIDEO_IOS_H
#define VIDEO_IOS_H

#include "video_driver.hpp"

#include <SDL3/SDL.h>

class VideoDriver_iOS final : public VideoDriver {
public:
	VideoDriver_iOS() : VideoDriver(true) {}

	std::optional<std::string_view> Start(const StringList &param) override;
	void Stop() override;
	void MakeDirty(int left, int top, int width, int height) override;
	void MainLoop() override;
	bool ChangeResolution(int width, int height) override;
	bool ToggleFullscreen(bool fullscreen) override;
	void ToggleVsync(bool vsync) override;
	bool AfterBlitterChange() override;
	std::string_view GetName() const override { return "ios"; }
	std::string_view GetInfoString() const override { return this->driver_info; }

protected:
	Dimension GetScreenSize() const override;
	bool LockVideoBuffer() override;
	void UnlockVideoBuffer() override;
	void CheckPaletteAnim() override;
	bool PollEvent() override;
	void Paint() override;

private:
	static bool SDLCALL WatchLifecycle(void *userdata, SDL_Event *event);

	std::optional<std::string_view> StartFailure(std::string error);
	bool UpdateLayout(bool force);
	void HandleLifecycleEvent(Uint32 event_type);

	SDL_Window *window = nullptr;
	SDL_Renderer *renderer = nullptr;
	SDL_Texture *texture = nullptr;
	std::vector<uint32_t> framebuffer;
	Palette local_palette{};
	Rect dirty_rect{};
	std::string driver_info{};
	std::string startup_error{};
	int window_width = 0;
	int window_height = 0;
	int safe_x = 0;
	int safe_y = 0;
	bool buffer_locked = false;
	bool event_watch_installed = false;
	bool logged_first_present = false;
	std::atomic<bool> backgrounded = false;
	std::atomic<bool> redraw_requested = false;
};

class FVideoDriver_iOS final : public DriverFactoryBase {
public:
	FVideoDriver_iOS() : DriverFactoryBase(Driver::Type::Video, 10, "ios", "SDL3 Metal Video Driver") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<VideoDriver_iOS>(); }

protected:
	bool UsesHardwareAcceleration() const override { return true; }
};

#endif /* VIDEO_IOS_H */
