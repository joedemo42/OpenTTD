/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file http_policy.h Platform-independent HTTP request policy shared with native backends. */

#ifndef NETWORK_CORE_HTTP_POLICY_H
#define NETWORK_CORE_HTTP_POLICY_H

#include <string_view>

namespace OpenTTDHTTP {

static constexpr int MAX_REDIRECTS = 5;

inline std::string_view ContentTypeForPayload(std::string_view payload)
{
	if (payload.empty()) return {};
	return payload.starts_with("{") ? "application/json" : "application/x-www-form-urlencoded";
}

inline bool IsErrorStatus(long status_code)
{
	return status_code >= 400;
}

inline bool AllowRedirect(int redirect_count)
{
	return redirect_count <= MAX_REDIRECTS;
}

} // namespace OpenTTDHTTP

#endif /* NETWORK_CORE_HTTP_POLICY_H */
