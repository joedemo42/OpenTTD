/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_input.h Platform-independent input translation used by the iOS video driver. */

#ifndef VIDEO_IOS_INPUT_H
#define VIDEO_IOS_INPUT_H

#include "../core/utf8.hpp"

#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <string_view>

namespace OpenTTDIOSInput {

struct LogicalPoint {
	int x = 0;
	int y = 0;
	bool inside = false;

	bool operator==(const LogicalPoint &) const = default;
};

inline LogicalPoint TranslateWindowPoint(float x, float y, int safe_x, int safe_y, int width, int height)
{
	if (width <= 0 || height <= 0) return {};

	const bool inside = x >= safe_x && y >= safe_y && x < safe_x + width && y < safe_y + height;
	return {
		std::clamp(static_cast<int>(std::floor(x)) - safe_x, 0, width - 1),
		std::clamp(static_cast<int>(std::floor(y)) - safe_y, 0, height - 1),
		inside,
	};
}

inline size_t Utf8ByteOffset(std::string_view text, size_t characters)
{
	Utf8View view{text};
	auto iter = view.begin();
	while (characters-- > 0 && iter != view.end()) ++iter;
	return iter.GetByteOffset();
}

enum class GestureActionType : uint8_t {
	PointerMove,
	Tap,
	DragBegin,
	DragMove,
	DragEnd,
	LongPressBegin,
	LongPressMove,
	LongPressEnd,
	Pan,
};

struct GestureAction {
	GestureActionType type = GestureActionType::PointerMove;
	float x = 0;
	float y = 0;
	float dx = 0;
	float dy = 0;
};

struct GestureActions {
	std::array<GestureAction, 3> items{};
	size_t size = 0;

	void Add(GestureActionType type, float x, float y, float dx = 0, float dy = 0)
	{
		assert(this->size < this->items.size());
		this->items[this->size++] = {type, x, y, dx, dy};
	}
};

class GestureState {
public:
	static constexpr float DRAG_THRESHOLD = 8.0f;
	static constexpr uint64_t LONG_PRESS_DELAY_NS = 500'000'000;

	GestureActions FingerDown(uint64_t id, float x, float y, uint64_t timestamp)
	{
		GestureActions actions;
		if (this->FindFinger(id) != nullptr) return actions;

		Finger *finger = this->AddFinger(id, x, y, timestamp);
		if (finger == nullptr) {
			this->mode = Mode::Blocked;
			return actions;
		}

		switch (this->ActiveCount()) {
			case 1:
				this->mode = Mode::Pending;
				actions.Add(GestureActionType::PointerMove, x, y);
				break;

			case 2: {
				Finger *primary = this->ActiveFinger(0);
				if (this->mode == Mode::Drag) actions.Add(GestureActionType::DragEnd, primary->x, primary->y);
				if (this->mode == Mode::LongPress) actions.Add(GestureActionType::LongPressEnd, primary->x, primary->y);
				this->mode = Mode::TwoFinger;
				this->last_centroid = this->Centroid();
				actions.Add(GestureActionType::PointerMove, this->last_centroid.x, this->last_centroid.y);
				break;
			}

			default:
				this->mode = Mode::Blocked;
				break;
		}
		return actions;
	}

	GestureActions FingerMotion(uint64_t id, float x, float y)
	{
		GestureActions actions;
		Finger *finger = this->FindFinger(id);
		if (finger == nullptr) return actions;
		const float motion_x = x - finger->x;
		const float motion_y = y - finger->y;
		finger->x = x;
		finger->y = y;

		switch (this->mode) {
			case Mode::Pending: {
				Finger *primary = this->ActiveFinger(0);
				const float dx = primary->x - primary->start_x;
				const float dy = primary->y - primary->start_y;
				if (dx * dx + dy * dy >= DRAG_THRESHOLD * DRAG_THRESHOLD) {
					this->mode = Mode::Drag;
					actions.Add(GestureActionType::DragBegin, primary->start_x, primary->start_y);
					actions.Add(GestureActionType::DragMove, primary->x, primary->y);
				} else {
					actions.Add(GestureActionType::PointerMove, primary->x, primary->y);
				}
				break;
			}

			case Mode::Drag:
				actions.Add(GestureActionType::DragMove, finger->x, finger->y, motion_x, motion_y);
				break;

			case Mode::LongPress:
				actions.Add(GestureActionType::LongPressMove, finger->x, finger->y, motion_x, motion_y);
				break;

			case Mode::TwoFinger: {
				const FloatPoint centroid = this->Centroid();
				actions.Add(GestureActionType::Pan, centroid.x, centroid.y,
						centroid.x - this->last_centroid.x, centroid.y - this->last_centroid.y);
				this->last_centroid = centroid;
				break;
			}

			default:
				break;
		}
		return actions;
	}

	GestureActions FingerUp(uint64_t id, float x, float y, bool canceled)
	{
		GestureActions actions;
		Finger *finger = this->FindFinger(id);
		if (finger == nullptr) return actions;
		finger->x = x;
		finger->y = y;

		if (this->ActiveCount() == 1) {
			switch (this->mode) {
				case Mode::Pending:
					if (!canceled) actions.Add(GestureActionType::Tap, finger->x, finger->y);
					break;

				case Mode::Drag:
					actions.Add(GestureActionType::DragEnd, finger->x, finger->y);
					break;

				case Mode::LongPress:
					actions.Add(GestureActionType::LongPressEnd, finger->x, finger->y);
					break;

				default:
					break;
			}
		}

		finger->active = false;
		if (this->ActiveCount() == 0) {
			this->mode = Mode::Idle;
		} else {
			this->mode = Mode::Blocked;
		}
		return actions;
	}

	GestureActions Update(uint64_t timestamp)
	{
		GestureActions actions;
		if (this->mode != Mode::Pending) return actions;

		Finger *primary = this->ActiveFinger(0);
		if (primary != nullptr && timestamp >= primary->timestamp + LONG_PRESS_DELAY_NS) {
			this->mode = Mode::LongPress;
			actions.Add(GestureActionType::LongPressBegin, primary->x, primary->y);
		}
		return actions;
	}

	GestureActions CancelAll()
	{
		GestureActions actions;
		Finger *primary = this->ActiveFinger(0);
		if (primary != nullptr) {
			if (this->mode == Mode::Drag) actions.Add(GestureActionType::DragEnd, primary->x, primary->y);
			if (this->mode == Mode::LongPress) actions.Add(GestureActionType::LongPressEnd, primary->x, primary->y);
		}
		for (Finger &finger : this->fingers) finger.active = false;
		this->mode = Mode::Idle;
		return actions;
	}

	size_t ActiveCount() const
	{
		return std::ranges::count_if(this->fingers, [](const Finger &finger) { return finger.active; });
	}

private:
	enum class Mode : uint8_t { Idle, Pending, Drag, LongPress, TwoFinger, Blocked };

	struct FloatPoint {
		float x = 0;
		float y = 0;
	};

	struct Finger {
		uint64_t id = 0;
		float x = 0;
		float y = 0;
		float start_x = 0;
		float start_y = 0;
		uint64_t timestamp = 0;
		bool active = false;
	};

	Finger *FindFinger(uint64_t id)
	{
		auto iter = std::ranges::find_if(this->fingers, [id](const Finger &finger) { return finger.active && finger.id == id; });
		return iter == this->fingers.end() ? nullptr : &*iter;
	}

	Finger *AddFinger(uint64_t id, float x, float y, uint64_t timestamp)
	{
		auto iter = std::ranges::find_if(this->fingers, [](const Finger &finger) { return !finger.active; });
		if (iter == this->fingers.end()) return nullptr;
		*iter = {id, x, y, x, y, timestamp, true};
		return &*iter;
	}

	Finger *ActiveFinger(size_t index)
	{
		for (Finger &finger : this->fingers) {
			if (!finger.active) continue;
			if (index-- == 0) return &finger;
		}
		return nullptr;
	}

	FloatPoint Centroid()
	{
		Finger *first = this->ActiveFinger(0);
		Finger *second = this->ActiveFinger(1);
		assert(first != nullptr && second != nullptr);
		return {(first->x + second->x) * 0.5f, (first->y + second->y) * 0.5f};
	}

	std::array<Finger, 5> fingers{};
	Mode mode = Mode::Idle;
	FloatPoint last_centroid{};
};

class PinchAccumulator {
public:
	static constexpr float STEP_SCALE = 1.12f;

	void Reset() { this->scale = 1.0f; }

	int Update(float change)
	{
		if (!std::isfinite(change) || change <= 0) return 0;
		this->scale *= change;

		int steps = 0;
		while (this->scale >= STEP_SCALE && steps > -8) {
			this->scale /= STEP_SCALE;
			--steps;
		}
		while (this->scale <= 1.0f / STEP_SCALE && steps < 8) {
			this->scale *= STEP_SCALE;
			++steps;
		}
		return steps;
	}

private:
	float scale = 1.0f;
};

} // namespace OpenTTDIOSInput

#endif /* VIDEO_IOS_INPUT_H */
