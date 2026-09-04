/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file openttd_ios.h Public bridge between the iOS application and engine. */

#ifndef OPENTTD_IOS_H
#define OPENTTD_IOS_H

#ifdef __cplusplus
extern "C" {
#endif

const char *OpenTTDIOSGetEngineRevision(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENTTD_IOS_H */
