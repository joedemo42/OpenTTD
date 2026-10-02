/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_http.cpp Test platform-independent iOS HTTP request policy. */

#include "../stdafx.h"

#include "../3rdparty/catch2/catch.hpp"

#include "../network/core/http_policy.h"

#include "../safeguards.h"

using namespace OpenTTDHTTP;

TEST_CASE("iOS HTTP payload policy")
{
	CHECK(ContentTypeForPayload("").empty());
	CHECK(ContentTypeForPayload("{\"reason\":\"exit\"}") == "application/json");
	CHECK(ContentTypeForPayload("42\n") == "application/x-www-form-urlencoded");
}

TEST_CASE("iOS HTTP response policy")
{
	CHECK_FALSE(IsErrorStatus(200));
	CHECK_FALSE(IsErrorStatus(399));
	CHECK(IsErrorStatus(400));
	CHECK(IsErrorStatus(429));
	CHECK(AllowRedirect(5));
	CHECK_FALSE(AllowRedirect(6));
}
