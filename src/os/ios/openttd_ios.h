/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file openttd_ios.h Public bridge between the iOS application and engine. */

#ifndef OPENTTD_IOS_H
#define OPENTTD_IOS_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *OpenTTDIOSGetEngineRevision(void);
const char *OpenTTDIOSGetDocumentsPath(void);
bool OpenTTDIOSPrepareDocuments(char *error_message, size_t error_message_size);
bool OpenTTDIOSValidateDocuments(char *error_message, size_t error_message_size);
int OpenTTDIOSMain(int argc, char *argv[]);

#ifdef __cplusplus
}
#endif

#endif /* OPENTTD_IOS_H */
