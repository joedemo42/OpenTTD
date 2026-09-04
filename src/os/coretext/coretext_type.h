/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file coretext_type.h Common ownership helpers for Apple CoreText objects. */

#ifndef CORETEXT_TYPE_H
#define CORETEXT_TYPE_H

#include <CoreFoundation/CoreFoundation.h>

/** Deleter that calls CFRelease rather than deleting the pointer. */
template <typename T> struct CFDeleter {
	void operator()(T *p)
	{
		if (p) ::CFRelease(p);
	}
};

/** Specialisation of std::unique_ptr for CoreFoundation objects. */
template <typename T>
using CFAutoRelease = std::unique_ptr<typename std::remove_pointer<T>::type, CFDeleter<typename std::remove_pointer<T>::type>>;

#endif /* CORETEXT_TYPE_H */
