/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file coretext_font.h CoreText font handling shared by Apple platforms. */

#ifndef CORETEXT_FONT_H
#define CORETEXT_FONT_H

#include "coretext_type.h"

#include <CoreText/CoreText.h>

#include "../../fontcache/truetypefontcache.h"

class CoreTextFontCache : public TrueTypeFontCache {
	CFAutoRelease<CTFontDescriptorRef> font_desc; ///< Font descriptor excluding font size.
	CFAutoRelease<CTFontRef> font;                ///< CoreText font handle.

	std::string font_name;                        ///< Cached font name.

	void SetFontSize(int pixels);
	const Sprite *InternalGetGlyph(GlyphID key, bool use_aa) override;
public:
	CoreTextFontCache(FontSize fs, CFAutoRelease<CTFontDescriptorRef> &&font, int pixels);

	void ClearFontCache() override;
	GlyphID MapCharToGlyph(char32_t key, bool allow_fallback = true) override;
	std::string GetFontName() override { return font_name; }
	bool IsBuiltInFont() override { return false; }
	const void *GetOSHandle() override { return font.get(); }
};

#endif /* CORETEXT_FONT_H */
