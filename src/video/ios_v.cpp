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
#include "../fios.h"
#include "../framerate_type.h"
#include "../gfx_func.h"
#include "../highscore.h"
#include "../hotkeys.h"
#include "../network/network.h"
#include "../openttd.h"
#include "../os/ios/ios_platform.h"
#include "../progress.h"
#include "../saveload/saveload_func.h"
#include "../settings_func.h"
#include "../string_func.h"
#include "../viewport_func.h"
#include "../window_func.h"
#include "../window_gui.h"
#include "ios_v.h"

#include "../safeguards.h"

static FVideoDriver_iOS iFVideoDriver_iOS;

namespace {

struct SDLKeyMapping {
	SDL_Keycode first;
	SDL_Keycode last;
	WindowKeyCodes mapped;
	bool unprintable;
};

static constexpr SDLKeyMapping _key_mapping[] = {
	{SDLK_PAGEUP, SDLK_PAGEUP, WKC_PAGEUP, true},
	{SDLK_PAGEDOWN, SDLK_PAGEDOWN, WKC_PAGEDOWN, true},
	{SDLK_UP, SDLK_UP, WKC_UP, true},
	{SDLK_DOWN, SDLK_DOWN, WKC_DOWN, true},
	{SDLK_LEFT, SDLK_LEFT, WKC_LEFT, true},
	{SDLK_RIGHT, SDLK_RIGHT, WKC_RIGHT, true},
	{SDLK_HOME, SDLK_HOME, WKC_HOME, true},
	{SDLK_END, SDLK_END, WKC_END, true},
	{SDLK_INSERT, SDLK_INSERT, WKC_INSERT, true},
	{SDLK_DELETE, SDLK_DELETE, WKC_DELETE, true},
	{SDLK_ESCAPE, SDLK_ESCAPE, WKC_ESC, true},
	{SDLK_PAUSE, SDLK_PAUSE, WKC_PAUSE, true},
	{SDLK_BACKSPACE, SDLK_BACKSPACE, WKC_BACKSPACE, true},
	{SDLK_F1, SDLK_F12, WKC_F1, true},
	{SDLK_A, SDLK_Z, WindowKeyCodes{'A'}, false},
	{SDLK_0, SDLK_9, WindowKeyCodes{'0'}, false},
	{SDLK_SPACE, SDLK_SPACE, WKC_SPACE, false},
	{SDLK_RETURN, SDLK_RETURN, WKC_RETURN, false},
	{SDLK_TAB, SDLK_TAB, WKC_TAB, false},
	{SDLK_KP_1, SDLK_KP_9, WindowKeyCodes{'1'}, false},
	{SDLK_KP_0, SDLK_KP_0, WindowKeyCodes{'0'}, false},
	{SDLK_KP_DIVIDE, SDLK_KP_DIVIDE, WKC_NUM_DIV, false},
	{SDLK_KP_MULTIPLY, SDLK_KP_MULTIPLY, WKC_NUM_MUL, false},
	{SDLK_KP_MINUS, SDLK_KP_MINUS, WKC_NUM_MINUS, false},
	{SDLK_KP_PLUS, SDLK_KP_PLUS, WKC_NUM_PLUS, false},
	{SDLK_KP_ENTER, SDLK_KP_ENTER, WKC_NUM_ENTER, false},
	{SDLK_KP_PERIOD, SDLK_KP_PERIOD, WKC_NUM_DECIMAL, false},
	{SDLK_SLASH, SDLK_SLASH, WKC_SLASH, false},
	{SDLK_SEMICOLON, SDLK_SEMICOLON, WKC_SEMICOLON, false},
	{SDLK_EQUALS, SDLK_EQUALS, WKC_EQUALS, false},
	{SDLK_LEFTBRACKET, SDLK_LEFTBRACKET, WKC_L_BRACKET, false},
	{SDLK_BACKSLASH, SDLK_BACKSLASH, WKC_BACKSLASH, false},
	{SDLK_RIGHTBRACKET, SDLK_RIGHTBRACKET, WKC_R_BRACKET, false},
	{SDLK_APOSTROPHE, SDLK_APOSTROPHE, WKC_SINGLEQUOTE, false},
	{SDLK_COMMA, SDLK_COMMA, WKC_COMMA, false},
	{SDLK_MINUS, SDLK_MINUS, WKC_MINUS, false},
	{SDLK_PERIOD, SDLK_PERIOD, WKC_PERIOD, false},
};

constexpr uint ConvertSDLKey(SDL_Keycode key, SDL_Scancode scancode, SDL_Keymod modifiers, char32_t *character = nullptr)
{
	uint mapped = 0;
	bool unprintable = false;
	for (const SDLKeyMapping &entry : _key_mapping) {
		if (key >= entry.first && key <= entry.last) {
			mapped = static_cast<uint>(entry.mapped) + key - entry.first;
			unprintable = entry.unprintable;
			break;
		}
	}

	if (scancode == SDL_SCANCODE_GRAVE) mapped = WKC_BACKQUOTE;
	if ((modifiers & SDL_KMOD_GUI) != 0) mapped |= WKC_META;
	if ((modifiers & SDL_KMOD_SHIFT) != 0) mapped |= WKC_SHIFT;
	if ((modifiers & SDL_KMOD_CTRL) != 0) mapped |= WKC_CTRL;
	if ((modifiers & SDL_KMOD_ALT) != 0) mapped |= WKC_ALT;

	if (character != nullptr) {
		const bool modified = (modifiers & (SDL_KMOD_GUI | SDL_KMOD_CTRL | SDL_KMOD_ALT)) != 0;
		*character = !modified && !unprintable && (key & (SDLK_EXTENDED_MASK | SDLK_SCANCODE_MASK)) == 0 ? key : 0;
	}
	return mapped;
}

constexpr bool HandleKeyWhileEditing(uint keycode, char32_t character)
{
	const uint base = keycode & ~WKC_SPECIAL_KEYS;
	return base == WKC_DELETE || base == WKC_BACKSPACE || base == WKC_RETURN || base == WKC_NUM_ENTER ||
			base == WKC_TAB || base == WKC_LEFT || base == WKC_RIGHT || base == WKC_UP || base == WKC_DOWN ||
			base == WKC_HOME || base == WKC_END || (keycode & (WKC_META | WKC_CTRL | WKC_ALT)) != 0 ||
			(base >= WKC_F1 && base <= WKC_F12) || !IsValidChar(character, CS_ALPHANUMERAL);
}

static_assert(ConvertSDLKey(SDLK_F12, SDL_SCANCODE_F12, SDL_KMOD_NONE) == WKC_F12);
static_assert(ConvertSDLKey(SDLK_A, SDL_SCANCODE_A, SDL_KMOD_CTRL) == (WKC_CTRL | 'A'));
static_assert(ConvertSDLKey(SDLK_GRAVE, SDL_SCANCODE_GRAVE, SDL_KMOD_NONE) == WKC_BACKQUOTE);

} // namespace

std::optional<std::string_view> VideoDriver_iOS::Start(const StringList &param)
{
	if (BlitterFactory::GetCurrentBlitter()->GetScreenDepth() != 32) return "The iOS video driver requires a 32bpp blitter";

	SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");
	SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0");
	SDL_SetHint(SDL_HINT_MOUSE_TOUCH_EVENTS, "0");
	SDL_SetHint(SDL_HINT_TRACKPAD_IS_TOUCH_ONLY, "0");
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
	SDL_StopTextInput(this->window);
	this->edit_box_focused = false;
	_cursor.in_window = true;

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
	SDL_Log("IOS_INPUT READY touch=direct pointer=indirect keyboard=physical ime=native");
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
	this->CancelTouchInput();
	if (this->window != nullptr && this->edit_box_focused) SDL_StopTextInput(this->window);
	this->edit_box_focused = false;
	this->text_input_area_valid = false;
	_left_button_down = false;
	_left_button_clicked = false;
	_right_button_down = false;
	_right_button_clicked = false;
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
		if (this->background_save_requested) {
			this->SaveForBackground();
			this->background_save_requested = false;
			EndIOSBackgroundTask();
		}

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

void VideoDriver_iOS::EditBoxGainedFocus()
{
	if (this->window == nullptr || this->edit_box_focused) return;
	this->UpdateTextInputArea();
	if (!SDL_StartTextInput(this->window)) {
		Debug(driver, 0, "iOS: could not start text input: {}", SDL_GetError());
		return;
	}
	this->edit_box_focused = true;
	SDL_Log("IOS_INPUT IME focus=on");
}

void VideoDriver_iOS::EditBoxLostFocus()
{
	if (this->window == nullptr || !this->edit_box_focused) return;
	SDL_ClearComposition(this->window);
	HandleTextInput({}, true);
	if (!SDL_StopTextInput(this->window)) Debug(driver, 0, "iOS: could not stop text input: {}", SDL_GetError());
	this->edit_box_focused = false;
	this->text_input_area_valid = false;
	SDL_Log("IOS_INPUT IME focus=off");
}

int VideoDriver_iOS::GetMinimumAutoUIScale() const
{
	/* At least one interface unit per UIKit point, the size iOS sizes text and touch targets for. On phones this is
	 * below the 640x480 design size, but anything smaller is too small to use there. Rounded to 25 % steps. */
	return std::max(MIN_INTERFACE_SCALE, static_cast<int>(std::lround(this->scale_x * 4)) * 25);
}

Dimension VideoDriver_iOS::GetScreenSize() const
{
	if (_screen.width > 0 && _screen.height > 0) return {static_cast<uint>(_screen.width), static_cast<uint>(_screen.height)};
	return {1024, 768};
}

void VideoDriver_iOS::CheckPaletteAnim()
{
	if (!CopyPalette(this->local_palette)) return;
	this->MakeDirty(0, 0, _screen.width, _screen.height);
}

void VideoDriver_iOS::InputLoop()
{
	this->HandleGestureActions(this->touch_gesture.Update(SDL_GetTicksNS()));

	const SDL_Keymod modifiers = SDL_GetModState();
	const bool *keys = SDL_GetKeyboardState(nullptr);
	const bool old_ctrl_pressed = _ctrl_pressed;
	_ctrl_pressed = (modifiers & SDL_KMOD_CTRL) != 0;
	_shift_pressed = (modifiers & SDL_KMOD_SHIFT) != 0;
	this->fast_forward_key_pressed = keys[SDL_SCANCODE_TAB] && (modifiers & SDL_KMOD_ALT) == 0;
	_dirkeys.Set(DirectionKey::Left, keys[SDL_SCANCODE_LEFT]);
	_dirkeys.Set(DirectionKey::Up, keys[SDL_SCANCODE_UP]);
	_dirkeys.Set(DirectionKey::Right, keys[SDL_SCANCODE_RIGHT]);
	_dirkeys.Set(DirectionKey::Down, keys[SDL_SCANCODE_DOWN]);
	if (old_ctrl_pressed != _ctrl_pressed) HandleCtrlChanged();

	if (this->edit_box_focused) this->UpdateTextInputArea();
}

OpenTTDIOSInput::LogicalPoint VideoDriver_iOS::GetLogicalPoint(float x, float y) const
{
	return OpenTTDIOSInput::TranslateWindowPoint(x * this->scale_x, y * this->scale_y, this->safe_x, this->safe_y, _screen.width, _screen.height);
}

void VideoDriver_iOS::MoveCursor(const OpenTTDIOSInput::LogicalPoint &point, bool dispatch)
{
	_cursor.in_window = point.inside;
	_cursor.UpdateCursorPosition(point.x, point.y);
	if (dispatch) HandleMouseEvents();
}

void VideoDriver_iOS::HandleMouseMotion(const SDL_MouseMotionEvent &event)
{
	const OpenTTDIOSInput::LogicalPoint point = this->GetLogicalPoint(event.x, event.y);
	_cursor.in_window = point.inside;
	if (_cursor.fix_at) {
		_cursor.UpdateCursorPositionRelative(static_cast<int>(std::lround(event.xrel * this->scale_x)), static_cast<int>(std::lround(event.yrel * this->scale_y)));
	} else {
		_cursor.UpdateCursorPosition(point.x, point.y);
	}
	HandleMouseEvents();
}

void VideoDriver_iOS::HandleMouseButton(const SDL_MouseButtonEvent &event)
{
	const OpenTTDIOSInput::LogicalPoint point = this->GetLogicalPoint(event.x, event.y);
	if (!_cursor.fix_at) this->MoveCursor(point, false);
	if (event.down && !point.inside) return;

	switch (event.button) {
		case SDL_BUTTON_LEFT:
			_left_button_down = event.down;
			if (!event.down) _left_button_clicked = false;
			break;

		case SDL_BUTTON_RIGHT:
			_right_button_down = event.down;
			if (event.down) _right_button_clicked = true;
			break;

		default:
			return;
	}
	SDL_Log("IOS_INPUT POINTER button=%u down=%s", event.button, event.down ? "yes" : "no");
	HandleMouseEvents();
}

void VideoDriver_iOS::HandleMouseWheel(const SDL_MouseWheelEvent &event)
{
	OpenTTDIOSInput::LogicalPoint point = this->GetLogicalPoint(event.mouse_x, event.mouse_y);
	if (point.inside && !_cursor.fix_at) this->MoveCursor(point, false);

	float x = event.x;
	float y = event.y;
	if (event.direction == SDL_MOUSEWHEEL_FLIPPED) {
		x = -x;
		y = -y;
	}
	if (y > 0) {
		--_cursor.wheel;
	} else if (y < 0) {
		++_cursor.wheel;
	}

	constexpr float SCROLL_BUILTIN_MULTIPLIER = 14.0f;
	_cursor.v_wheel -= y * this->scale_y * SCROLL_BUILTIN_MULTIPLIER * _settings_client.gui.scrollwheel_multiplier;
	_cursor.h_wheel += x * this->scale_x * SCROLL_BUILTIN_MULTIPLIER * _settings_client.gui.scrollwheel_multiplier;
	_cursor.wheel_moved = x != 0 || y != 0;
	SDL_Log("IOS_INPUT POINTER wheel=%.3f,%.3f", x, y);
}

void VideoDriver_iOS::HandleKeyDown(const SDL_KeyboardEvent &event)
{
	char32_t character = 0;
	const uint keycode = ConvertSDLKey(event.key, event.scancode, event.mod, &character);
	if (!this->edit_box_focused || HandleKeyWhileEditing(keycode, character)) HandleKeypress(keycode, character);
	SDL_Log("IOS_INPUT KEY scancode=%u keycode=%u repeat=%s", event.scancode, keycode, event.repeat ? "yes" : "no");
}

void VideoDriver_iOS::HandleTouch(const SDL_TouchFingerEvent &event)
{
	/* Gestures track window points, so their thresholds do not depend on the display's pixel density. */
	const float x = event.x * this->window_width;
	const float y = event.y * this->window_height;
	OpenTTDIOSInput::GestureActions actions;

	switch (event.type) {
		case SDL_EVENT_FINGER_DOWN: {
			if (!this->GetLogicalPoint(x, y).inside) return;
			const size_t previous_count = this->touch_gesture.ActiveCount();
			actions = this->touch_gesture.FingerDown(event.fingerID, x, y, event.timestamp);
			if (previous_count == 1 && this->touch_gesture.ActiveCount() == 2) {
				this->touch_pan_remainder_x = 0;
				this->touch_pan_remainder_y = 0;
				SDL_Log("IOS_INPUT TOUCH pan=begin");
			}
			break;
		}

		case SDL_EVENT_FINGER_MOTION:
			actions = this->touch_gesture.FingerMotion(event.fingerID, x, y);
			break;

		case SDL_EVENT_FINGER_UP:
		case SDL_EVENT_FINGER_CANCELED:
			actions = this->touch_gesture.FingerUp(event.fingerID, x, y,
					event.type == SDL_EVENT_FINGER_CANCELED);
			break;

		default:
			return;
	}

	this->HandleGestureActions(actions);
}

void VideoDriver_iOS::HandleGestureActions(const OpenTTDIOSInput::GestureActions &actions)
{
	using OpenTTDIOSInput::GestureActionType;
	for (size_t index = 0; index < actions.size; ++index) {
		const OpenTTDIOSInput::GestureAction &action = actions.items[index];
		OpenTTDIOSInput::LogicalPoint point = this->GetLogicalPoint(action.x, action.y);
		point.inside = true;

		switch (action.type) {
			case GestureActionType::PointerMove:
				this->MoveCursor(point);
				break;

			case GestureActionType::Tap:
				this->MoveCursor(point, false);
				_left_button_down = true;
				HandleMouseEvents();
				_left_button_down = false;
				_left_button_clicked = false;
				HandleMouseEvents();
				SDL_Log("IOS_INPUT TOUCH tap=%d,%d", point.x, point.y);
				break;

			case GestureActionType::DragBegin:
				this->MoveCursor(point, false);
				_left_button_down = true;
				HandleMouseEvents();
				SDL_Log("IOS_INPUT TOUCH drag=begin x=%d y=%d", point.x, point.y);
				break;

			case GestureActionType::DragMove:
			case GestureActionType::LongPressMove:
				if (_cursor.fix_at) {
					_cursor.UpdateCursorPositionRelative(static_cast<int>(std::lround(action.dx * this->scale_x)), static_cast<int>(std::lround(action.dy * this->scale_y)));
					HandleMouseEvents();
				} else {
					this->MoveCursor(point);
				}
				break;

			case GestureActionType::DragEnd:
				if (!_cursor.fix_at) this->MoveCursor(point, false);
				_left_button_down = false;
				_left_button_clicked = false;
				HandleMouseEvents();
				SDL_Log("IOS_INPUT TOUCH drag=end x=%d y=%d", point.x, point.y);
				break;

			case GestureActionType::LongPressBegin:
				this->MoveCursor(point, false);
				_right_button_down = true;
				_right_button_clicked = true;
				HandleMouseEvents();
				SDL_Log("IOS_INPUT TOUCH long_press=begin x=%d y=%d", point.x, point.y);
				break;

			case GestureActionType::LongPressEnd:
				if (!_cursor.fix_at) this->MoveCursor(point, false);
				_right_button_down = false;
				HandleMouseEvents();
				SDL_Log("IOS_INPUT TOUCH long_press=end x=%d y=%d", point.x, point.y);
				break;

			case GestureActionType::Pan: {
				this->MoveCursor(point, false);
				this->touch_pan_remainder_x -= action.dx * this->scale_x;
				this->touch_pan_remainder_y -= action.dy * this->scale_y;
				const int dx = static_cast<int>(this->touch_pan_remainder_x);
				const int dy = static_cast<int>(this->touch_pan_remainder_y);
				this->touch_pan_remainder_x -= dx;
				this->touch_pan_remainder_y -= dy;
				if (dx == 0 && dy == 0) break;

				Window *window = FindWindowFromPt(point.x, point.y);
				if (window != nullptr && IsPtInWindowViewport(window, point.x, point.y) != nullptr &&
						_game_mode != GameMode::Menu && !HasModalProgress()) {
					window->viewport->CancelFollow(*window);
					window->OnScroll({dx, dy});
				}
				break;
			}
		}
	}
}

void VideoDriver_iOS::UpdateTextInputArea()
{
	if (this->window == nullptr || !EditBoxInGlobalFocus() || _focused_window == nullptr) return;

	/* OpenTTD positions are drawable pixels inside the safe area; SDL expects window points. */
	const auto to_window_x = [this](int x) { return static_cast<int>(std::lround((this->safe_x + _focused_window->left + x) / this->scale_x)); };
	const auto to_window_y = [this](int y) { return static_cast<int>(std::lround((this->safe_y + _focused_window->top + y) / this->scale_y)); };

	const Point caret = _focused_window->GetCaretPosition();
	SDL_Rect area{to_window_x(caret.x), to_window_y(caret.y), 1, 24};
	if (_focused_window->nested_focus != nullptr && _focused_window->nested_focus->type == WWT_EDITBOX) {
		const Rect widget = _focused_window->nested_focus->GetCurrentRect();
		area.x = to_window_x(widget.left);
		area.y = to_window_y(widget.top);
		area.w = to_window_x(widget.right + 1) - area.x;
		area.h = to_window_y(widget.bottom + 1) - area.y;
	}
	const int cursor = std::clamp(to_window_x(caret.x) - area.x, 0, area.w);
	if (this->text_input_area_valid && area.x == this->text_input_area.x && area.y == this->text_input_area.y &&
			area.w == this->text_input_area.w && area.h == this->text_input_area.h && cursor == this->text_input_cursor) return;

	if (!SDL_SetTextInputArea(this->window, &area, cursor)) {
		Debug(driver, 0, "iOS: could not set text input area: {}", SDL_GetError());
		return;
	}
	this->text_input_area = area;
	this->text_input_cursor = cursor;
	this->text_input_area_valid = true;
}

void VideoDriver_iOS::CancelTouchInput()
{
	this->HandleGestureActions(this->touch_gesture.CancelAll());
	this->pinch_gesture.Reset();
	this->touch_pan_remainder_x = 0;
	this->touch_pan_remainder_y = 0;
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
		case SDL_EVENT_WINDOW_METAL_VIEW_RESIZED:
		case SDL_EVENT_WINDOW_SAFE_AREA_CHANGED:
			this->CancelTouchInput();
			if (!this->UpdateLayout(false)) Debug(driver, 0, "iOS: failed to update window layout: {}", SDL_GetError());
			this->redraw_requested = true;
			break;

		case SDL_EVENT_WINDOW_EXPOSED:
		case SDL_EVENT_DID_ENTER_FOREGROUND:
			this->redraw_requested = true;
			break;

		case SDL_EVENT_WILL_ENTER_BACKGROUND:
		case SDL_EVENT_DID_ENTER_BACKGROUND:
		case SDL_EVENT_WINDOW_FOCUS_LOST:
			this->CancelTouchInput();
			if (_left_button_down || _right_button_down) {
				_left_button_down = false;
				_left_button_clicked = false;
				_right_button_down = false;
				_right_button_clicked = false;
				HandleMouseEvents();
			}
			break;

		case SDL_EVENT_WINDOW_MOUSE_ENTER:
			_cursor.in_window = true;
			break;

		case SDL_EVENT_WINDOW_MOUSE_LEAVE:
			_cursor.in_window = false;
			break;

		case SDL_EVENT_MOUSE_MOTION:
			if (event.motion.which != SDL_TOUCH_MOUSEID) this->HandleMouseMotion(event.motion);
			break;

		case SDL_EVENT_MOUSE_BUTTON_DOWN:
		case SDL_EVENT_MOUSE_BUTTON_UP:
			if (event.button.which != SDL_TOUCH_MOUSEID) this->HandleMouseButton(event.button);
			break;

		case SDL_EVENT_MOUSE_WHEEL:
			this->HandleMouseWheel(event.wheel);
			break;

		case SDL_EVENT_FINGER_DOWN:
		case SDL_EVENT_FINGER_MOTION:
		case SDL_EVENT_FINGER_UP:
		case SDL_EVENT_FINGER_CANCELED:
			if (event.tfinger.touchID != SDL_MOUSE_TOUCHID) this->HandleTouch(event.tfinger);
			break;

		case SDL_EVENT_PINCH_BEGIN:
			this->pinch_gesture.Reset();
			SDL_Log("IOS_INPUT TOUCH pinch=begin");
			break;

		case SDL_EVENT_PINCH_UPDATE: {
			const int steps = this->pinch_gesture.Update(event.pinch.scale);
			if (steps != 0) {
				_cursor.wheel += steps;
				SDL_Log("IOS_INPUT TOUCH pinch_steps=%d", steps);
			}
			break;
		}

		case SDL_EVENT_PINCH_END:
			this->pinch_gesture.Reset();
			SDL_Log("IOS_INPUT TOUCH pinch=end");
			break;

		case SDL_EVENT_KEY_DOWN:
			this->HandleKeyDown(event.key);
			break;

		case SDL_EVENT_TEXT_EDITING:
			if (this->edit_box_focused) {
				std::optional<size_t> caret;
				if (event.edit.start >= 0) caret = OpenTTDIOSInput::Utf8ByteOffset(event.edit.text, event.edit.start);
				HandleTextInput(event.edit.text, true, caret);
				SDL_Log("IOS_INPUT IME composition_bytes=%zu caret=%d", strlen(event.edit.text), event.edit.start);
			}
			break;

		case SDL_EVENT_TEXT_INPUT:
			if (this->edit_box_focused) {
				const SDL_Keycode key = SDL_GetKeyFromName(event.text.text);
				const uint keycode = ConvertSDLKey(key, SDL_SCANCODE_UNKNOWN, SDL_KMOD_NONE);
				if (keycode == WKC_BACKQUOTE && FocusedWindowIsConsole()) {
					auto [length, character] = DecodeUtf8(event.text.text);
					if (length > 0) HandleKeypress(keycode, character);
				} else {
					HandleTextInput({}, true);
					HandleTextInput(event.text.text);
				}
				SDL_Log("IOS_INPUT IME commit_bytes=%zu", strlen(event.text.text));
			}
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

	const Uint64 paint_start = SDL_GetTicksNS();
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

	const Uint64 upload_start = SDL_GetTicksNS();
	const uint32_t *pixels = this->framebuffer.data() + static_cast<size_t>(update.y) * _screen.pitch + update.x;
	if (!SDL_UpdateTexture(this->texture, &update, pixels, _screen.pitch * sizeof(uint32_t))) {
		Debug(driver, 0, "iOS: dirty texture upload failed: {}", SDL_GetError());
		return;
	}
	const Uint64 present_start = SDL_GetTicksNS();

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
	this->RecordFrame(paint_start, upload_start, present_start, SDL_GetTicksNS(), update.w * update.h);

	if (!this->logged_first_present) {
		SDL_Log("IOS_VIDEO PRESENT first_dirty=%d,%d %dx%d", update.x, update.y, update.w, update.h);
		this->logged_first_present = true;
	}
	/* Logged here: the automatic scale is first resolved after Start(), and later by every layout change. */
	if (_gui_scale != this->logged_gui_scale) {
		SDL_Log("IOS_VIDEO SCALE gui=%d", _gui_scale);
		this->logged_gui_scale = _gui_scale;
	}
	this->dirty_rect = {};
}

/** Frame statistics for profiling, logged every 10 seconds with -d driver=2. All times in nanoseconds. */
void VideoDriver_iOS::RecordFrame(Uint64 start, Uint64 upload_start, Uint64 present_start, Uint64 end, int pixels)
{
	if (_debug_driver_level < 2) return;

	FrameStats &stats = this->frame_stats;
	if (stats.since == 0) stats.since = start;
	stats.frames++;
	stats.pixels += pixels;
	stats.palette += upload_start - start;
	stats.upload += present_start - upload_start;
	stats.present += end - present_start;
	stats.present_max = std::max(stats.present_max, end - present_start);
	if (end - stats.since < SDL_NS_PER_SECOND * 10) return;

	const double frames = stats.frames;
	Debug(driver, 2, "iOS video: {:.1f} presents/s; per present: palette {:.2f} ms, upload {:.2f} ms, present {:.2f} ms (max {:.2f}), {:.2f} Mpixels",
			frames * SDL_NS_PER_SECOND / (end - stats.since), stats.palette / frames / SDL_NS_PER_MS, stats.upload / frames / SDL_NS_PER_MS,
			stats.present / frames / SDL_NS_PER_MS, static_cast<double>(stats.present_max) / SDL_NS_PER_MS, stats.pixels / frames / 1e6);
	stats = {};
}

bool VideoDriver_iOS::UpdateLayout(bool force)
{
	int new_window_width = 0;
	int new_window_height = 0;
	if (!SDL_GetWindowSize(this->window, &new_window_width, &new_window_height)) return false;

	int output_width = 0;
	int output_height = 0;
	if (!SDL_GetRenderOutputSize(this->renderer, &output_width, &output_height)) return false;
	if (new_window_width <= 0 || new_window_height <= 0 || output_width <= 0 || output_height <= 0) return false;

	/* OpenTTD draws in drawable pixels and presents them 1:1, so text is rasterized at the display's resolution.
	 * Its automatic interface scale follows the pixel size. */
	const float new_scale_x = static_cast<float>(output_width) / new_window_width;
	const float new_scale_y = static_cast<float>(output_height) / new_window_height;
	SDL_Rect safe_points{0, 0, new_window_width, new_window_height};
	if (!SDL_GetWindowSafeArea(this->window, &safe_points)) SDL_ClearError();
	const int left = std::clamp(static_cast<int>(std::lround(safe_points.x * new_scale_x)), 0, output_width - 1);
	const int top = std::clamp(static_cast<int>(std::lround(safe_points.y * new_scale_y)), 0, output_height - 1);
	const int right = std::clamp(static_cast<int>(std::lround((safe_points.x + safe_points.w) * new_scale_x)), left + 1, output_width);
	const int bottom = std::clamp(static_cast<int>(std::lround((safe_points.y + safe_points.h) * new_scale_y)), top + 1, output_height);
	const SDL_Rect safe{left, top, right - left, bottom - top};

	const bool size_changed = safe.w != _screen.width || safe.h != _screen.height;
	this->window_width = new_window_width;
	this->window_height = new_window_height;
	this->scale_x = new_scale_x;
	this->scale_y = new_scale_y;
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
	const SDL_DisplayMode *display = SDL_GetDesktopDisplayMode(SDL_GetDisplayForWindow(this->window));
	SDL_Log("IOS_VIDEO LAYOUT window=%dx%d output=%dx%d safe=%d,%d %dx%d display=%dx%d", new_window_width, new_window_height,
			output_width, output_height, safe.x, safe.y, safe.w, safe.h, display != nullptr ? display->w : 0, display != nullptr ? display->h : 0);
	return true;
}

/**
 * Save what a terminated app would lose: the configuration and, unless this is a network client, the running game.
 * The game becomes the next rotating autosave, independent of gui.autosave_on_exit.
 */
void VideoDriver_iOS::SaveForBackground()
{
	const auto start = std::chrono::steady_clock::now();
	std::lock_guard<std::mutex> lock_wait(this->game_thread_wait_mutex);
	std::lock_guard<std::mutex> lock_state(this->game_state_mutex);

	const bool save_game = _game_mode == GameMode::Normal && !HasModalProgress() && (!_networking || _network_server);
	if (save_game) {
		_do_autosave = true;
		SetWindowDirty(WindowClass::Statusbar, 0);
		/* A fresh counter continues after the most recent autosave, like the regular autosave's counter. */
		FiosNumberedSaveName autosave_counter("autosave");
		DoAutoOrNetsave(autosave_counter);
		WaitTillSaved();
		_do_autosave = false;
		SetWindowDirty(WindowClass::Statusbar, 0);
	}

	if (_save_config) {
		SaveToConfig();
		SaveHotkeysToConfig();
		WindowDesc::SaveToConfig();
		SaveToHighScore();
	}

	const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start);
	SDL_Log("IOS_VIDEO LIFECYCLE saved game=%s config=%s ms=%lld", save_game ? "yes" : "no", _save_config ? "yes" : "no",
			static_cast<long long>(elapsed.count()));
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
			/* iOS may terminate a suspended app without notice. Keep running until MainLoop() has saved. */
			if (event_type == SDL_EVENT_DID_ENTER_BACKGROUND && !this->background_save_requested) {
				BeginIOSBackgroundTask();
				this->background_save_requested = true;
			}
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
