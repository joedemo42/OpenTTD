/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_stdafx.h iOS-specific compiler setup. */

#ifndef IOS_STDAFX_H
#define IOS_STDAFX_H

#define __STDC_LIMIT_MACROS
#include <stdint.h>

#if (defined(__LP64__) && !defined(POINTER_IS_64BIT)) || (!defined(__LP64__) && defined(POINTER_IS_64BIT))
#	error "Compiling 64 bits without POINTER_IS_64BIT set! (or vice versa)"
#endif

#endif /* IOS_STDAFX_H */
