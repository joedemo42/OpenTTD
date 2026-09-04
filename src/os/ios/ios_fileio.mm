/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_fileio.mm iOS search-path integration. */

#include "../../stdafx.h"
#include "../../fileio_func.h"

#include "ios_filesystem.h"

#include "../../safeguards.h"

void DetermineBasePaths(std::string_view)
{
	extern EnumIndexArray<std::string, Searchpath, Searchpath::End> _searchpaths;

	for (std::string &path : _searchpaths) path.clear();
	std::string documents = GetIOSDocumentsDirectory();
	AppendPathSeparator(documents);
	_searchpaths[Searchpath::PersonalDir] = documents;
	_searchpaths[Searchpath::WorkingDir] = documents;
	_searchpaths[Searchpath::AutodownloadPersonalDir] = documents + "content_download" PATHSEP;
}
