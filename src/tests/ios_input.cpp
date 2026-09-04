/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_input.cpp Test the platform-independent iOS input translator. */

#include "../stdafx.h"

#include "../3rdparty/catch2/catch.hpp"

#include "../video/ios_input.h"

#include "../safeguards.h"

using namespace OpenTTDIOSInput;

TEST_CASE("iOS input safe-area coordinates")
{
	CHECK(TranslateWindowPoint(20, 10, 20, 10, 100, 80) == LogicalPoint{0, 0, true});
	CHECK(TranslateWindowPoint(119.9f, 89.9f, 20, 10, 100, 80) == LogicalPoint{99, 79, true});
	CHECK(TranslateWindowPoint(5, 5, 20, 10, 100, 80) == LogicalPoint{0, 0, false});
	CHECK(TranslateWindowPoint(140, 100, 20, 10, 100, 80) == LogicalPoint{99, 79, false});
}

TEST_CASE("iOS input UTF-8 composition offsets")
{
	constexpr std::string_view text = "Aä🚂";
	CHECK(Utf8ByteOffset(text, 0) == 0);
	CHECK(Utf8ByteOffset(text, 1) == 1);
	CHECK(Utf8ByteOffset(text, 2) == 3);
	CHECK(Utf8ByteOffset(text, 3) == 7);
	CHECK(Utf8ByteOffset(text, 20) == text.size());
}

TEST_CASE("iOS input tap and canceled touch")
{
	GestureState gesture;
	auto actions = gesture.FingerDown(1, 10, 20, 0);
	REQUIRE(actions.size == 1);
	CHECK(actions.items[0].type == GestureActionType::PointerMove);

	actions = gesture.FingerUp(1, 12, 21, false);
	REQUIRE(actions.size == 1);
	CHECK(actions.items[0].type == GestureActionType::Tap);
	CHECK(actions.items[0].x == 12);
	CHECK(actions.items[0].y == 21);

	gesture.FingerDown(2, 10, 20, 0);
	CHECK(gesture.FingerUp(2, 10, 20, true).size == 0);
}

TEST_CASE("iOS input thresholded drag")
{
	GestureState gesture;
	gesture.FingerDown(1, 10, 20, 0);
	auto actions = gesture.FingerMotion(1, 14, 23);
	REQUIRE(actions.size == 1);
	CHECK(actions.items[0].type == GestureActionType::PointerMove);

	actions = gesture.FingerMotion(1, 18, 20);
	REQUIRE(actions.size == 2);
	CHECK(actions.items[0].type == GestureActionType::DragBegin);
	CHECK(actions.items[0].x == 10);
	CHECK(actions.items[1].type == GestureActionType::DragMove);
	CHECK(actions.items[1].x == 18);

	actions = gesture.FingerUp(1, 22, 20, false);
	REQUIRE(actions.size == 1);
	CHECK(actions.items[0].type == GestureActionType::DragEnd);
}

TEST_CASE("iOS input stationary long press")
{
	GestureState gesture;
	gesture.FingerDown(1, 10, 20, 1'000);
	CHECK(gesture.Update(1'000 + GestureState::LONG_PRESS_DELAY_NS - 1).size == 0);

	auto actions = gesture.Update(1'000 + GestureState::LONG_PRESS_DELAY_NS);
	REQUIRE(actions.size == 1);
	CHECK(actions.items[0].type == GestureActionType::LongPressBegin);

	actions = gesture.FingerUp(1, 10, 20, false);
	REQUIRE(actions.size == 1);
	CHECK(actions.items[0].type == GestureActionType::LongPressEnd);
}

TEST_CASE("iOS input two-finger pan cancels a one-finger drag")
{
	GestureState gesture;
	gesture.FingerDown(1, 0, 0, 0);
	gesture.FingerMotion(1, 8, 0);

	auto actions = gesture.FingerDown(2, 20, 0, 1);
	REQUIRE(actions.size == 2);
	CHECK(actions.items[0].type == GestureActionType::DragEnd);
	CHECK(actions.items[1].type == GestureActionType::PointerMove);
	CHECK(actions.items[1].x == 14);

	actions = gesture.FingerMotion(1, 18, 0);
	REQUIRE(actions.size == 1);
	CHECK(actions.items[0].type == GestureActionType::Pan);
	CHECK(actions.items[0].dx == 5);
	CHECK(actions.items[0].dy == 0);

	CHECK(gesture.FingerUp(1, 18, 0, false).size == 0);
	CHECK(gesture.FingerUp(2, 20, 0, false).size == 0);
}

TEST_CASE("iOS input accumulated pinch steps")
{
	PinchAccumulator pinch;
	CHECK(pinch.Update(1.05f) == 0);
	CHECK(pinch.Update(1.07f) == -1);
	pinch.Reset();
	CHECK(pinch.Update(0.95f) == 0);
	CHECK(pinch.Update(0.93f) == 1);
}
