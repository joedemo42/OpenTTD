#!/usr/bin/env bash
# Builds, installs, runs and packages the OpenTTD iOS app.

set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
DERIVED_DATA="$REPO_ROOT/DerivedData"
LOG_DIR="$REPO_ROOT/log"
# The scripts live in the OpenTTD tree they build.
SOURCE_DIR="$REPO_ROOT"
DEPS_SCRIPT="$REPO_ROOT/ios-deps/build-deps.sh"
DEPS_ARTIFACTS="$REPO_ROOT/ios-deps/artifacts"
ARCHIVE_DIR="$REPO_ROOT/archive"
BUILD_NUMBER_FILE="$IOS_DIR/BUILD_NUMBER"
PROJECT="$IOS_DIR/OpenTTD.xcodeproj"
SCHEME="OpenTTD"
DEFAULT_SIMULATOR="iPad Air 11-inch (M4)"
DEFAULT_DEVICE="OldPad"
IOS_MIN_VERSION="18.0"
ENGINE_ROOT="$DERIVED_DATA/OpenTTD-engine"
ENGINE_XCFRAMEWORK="$ENGINE_ROOT/OpenTTDEngine.xcframework"
# Bump when a CMake cache default changes, so every engine tree is configured afresh.
ENGINE_CONFIG_TAG="documents-root-v1|sdl3-metal-video-v1"
DATA_STAGE="$DERIVED_DATA/DataPackage"
SEED_DATA="$DATA_STAGE/SeedData"
# Vendored third-party code linked into the engine: <directory in src/3rdparty>:<license file>.
VENDORED_LICENSES="fmt:LICENSE.rst monocypher:LICENCE.md nlohmann:LICENSE.MIT openttd_social_integration_api:LICENSE squirrel:COPYRIGHT"
IPA_DIR="$DERIVED_DATA/ipa"
APP_ICON_CATALOG="$DERIVED_DATA/AppIcon.xcassets"
# Local app identity and upload server: APP_NAME, BUNDLE_ID, TEAM_ID, ICON, REPO_SERVER_URL.
BUILD_CONFIG="$REPO_ROOT/build.config"

script_name()
{
	local path="$0"
	[[ "$path" != /* ]] || path="${path#"$PWD"/}"
	[[ "$path" != /* ]] || path="${path#"$REPO_ROOT"/}"
	printf '%s' "$path"
}

usage()
{
	cat <<EOF
Usage: $(script_name) <command> [args] [options]
Target: [simulator|device|both] | --simulator <name|UDID> | --device <name|UDID>
        Default: simulator "$DEFAULT_SIMULATOR"; the default device is "$DEFAULT_DEVICE".
Configuration: --release (optimized, stripped, dSYM) for build, install, run, ipa, upload. Default: debug
        Slice = platform + configuration; both = simulator + device of the selected configuration.
Settings: build.config (app name, bundle ID, team, icon, repo server); template: build.config.sample

build     [simulator|device|both] [--release]
          Missing deps, engine and app; ios/BUILD_NUMBER +1 per invocation. Default: simulator
          Each slice that builds becomes the current build (DerivedData/current-<platform>-<configuration>)
install   [target] [--release]
          Install the current build; none → exit 1. Default: simulator
run       [target] [--release] [--seconds <1-45>] [--label <name>] [-- <app args>]
          Run the installed app → log/debugger.log, log/<label>.{log,png}. Default: simulator, 45 s
          Not installed or installed build ≠ current build → exit 1; run install first
ipa       [--unsigned] [--release]
          Current device build → IPA in DerivedData/ipa; none → exit 1. Default: signed
upload    [--notes <text>|--notes-file <path>] [--release]
          Signed IPA of the current device build → archive/ → repo server + release notes ("What's New")
          Release: dSYM → archive/<IPA name>.dSYM.zip, not uploaded. Debug: notes start with [DEBUG BUILD]
documents zip
          Documents payload of the current build → DerivedData/ipa/Documents.zip; none → exit 1
documents install [target]
          Copy the current build's payload into its installed app's Documents, no reinstall; none → exit 1
          Default: simulator
clean
          Remove app build output (DerivedData)
EOF
}

fail()
{
	echo "error: $*" >&2
	exit 1
}

usage_error()
{
	echo "error: $*" >&2
	echo "Run '$(script_name) --help' for usage." >&2
	exit 1
}

require_tool()
{
	local tool
	for tool in "$@"; do
		command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
	done
}

# Sets the named settings from build.config (KEY=value lines, # comments); a missing one stops with an error.
require_settings()
{
	[[ -f "$BUILD_CONFIG" ]] || fail "build.config not found; copy build.config.sample to build.config and fill it in"
	local key value
	for key in "$@"; do
		value="$(sed -n "s/^$key=//p" "$BUILD_CONFIG" | tail -n 1)"
		[[ -n "$value" ]] || fail "build.config: $key is not set; see build.config.sample"
		printf -v "$key" '%s' "$value"
	done
}

# Command line --------------------------------------------------------------

POSITIONAL=()
APP_ARGS=()
GIVEN=""
UNSIGNED=no
RUN_SECONDS=45
LABEL=""
NOTES_FORM=()
NOTES_TEXT=""
NOTES_FILE=""
CONFIGURATION=Debug
RELEASE_OPTION=""
SIMULATOR_OPTION=""
DEVICE_OPTION=""
PLATFORMS=""
SIMULATOR="$DEFAULT_SIMULATOR"
DEVICE="$DEFAULT_DEVICE"

parse_arguments()
{
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-h|--help)
				usage
				exit 0
				;;
			--simulator|--device|--seconds|--label|--notes|--notes-file)
				[[ $# -ge 2 ]] || usage_error "$1 needs a value"
				case "$1" in
					--simulator) SIMULATOR_OPTION="$2" ;;
					--device) DEVICE_OPTION="$2" ;;
					--seconds) RUN_SECONDS="$2" ;;
					--label) LABEL="$2" ;;
					--notes|--notes-file)
						[[ ${#NOTES_FORM[@]} -eq 0 ]] || usage_error "--notes and --notes-file are mutually exclusive"
						if [[ "$1" == --notes ]]; then
							NOTES_TEXT="$2"
							NOTES_FORM=(--form-string "notes=$2")
						else
							NOTES_FILE="$2"
							NOTES_FORM=(-F "notes=<$2")
						fi
						;;
				esac
				GIVEN="$GIVEN $1"
				shift 2
				;;
			--unsigned) UNSIGNED=yes; GIVEN="$GIVEN $1"; shift ;;
			--release) CONFIGURATION=Release; RELEASE_OPTION=" --release"; GIVEN="$GIVEN $1"; shift ;;
			--)
				shift
				APP_ARGS=("$@")
				GIVEN="$GIVEN --"
				break
				;;
			-*) usage_error "unknown option: $1" ;;
			*) POSITIONAL+=("$1"); shift ;;
		esac
	done
}

# Rejects surplus positional arguments and options the command does not take.
allow()
{
	local maximum="$1"
	shift
	[[ ${#POSITIONAL[@]} -le $maximum ]] || usage_error "too many arguments for $COMMAND"
	local option
	for option in $GIVEN; do
		case " $* " in
			*" $option "*) ;;
			*) usage_error "$COMMAND does not take $option" ;;
		esac
	done
}

# Sets PLATFORMS, SIMULATOR and DEVICE from [simulator|device|both] and the target options.
resolve_targets()
{
	case "${1:-}" in
		"")
			if [[ -n "$SIMULATOR_OPTION" && -n "$DEVICE_OPTION" ]]; then
				PLATFORMS="simulator device"
			elif [[ -n "$DEVICE_OPTION" ]]; then
				PLATFORMS=device
			else
				PLATFORMS=simulator
			fi
			;;
		simulator)
			[[ -z "$DEVICE_OPTION" ]] || usage_error "--device contradicts target simulator"
			PLATFORMS=simulator
			;;
		device)
			[[ -z "$SIMULATOR_OPTION" ]] || usage_error "--simulator contradicts target device"
			PLATFORMS=device
			;;
		both) PLATFORMS="simulator device" ;;
		*) usage_error "unknown target: $1" ;;
	esac
	SIMULATOR="${SIMULATOR_OPTION:-$DEFAULT_SIMULATOR}"
	DEVICE="${DEVICE_OPTION:-$DEFAULT_DEVICE}"
}

# Platforms and SDKs ----------------------------------------------------------

target_word()
{
	case "$*" in
		simulator|iphonesimulator) echo simulator ;;
		device|iphoneos) echo device ;;
		*) echo both ;;
	esac
}

platforms_for()
{
	case "$1" in
		simulator|device) echo "$1" ;;
		both) echo simulator device ;;
		*) return 1 ;;
	esac
}

sdk_for()
{
	case "$1" in
		simulator) echo iphonesimulator ;;
		device) echo iphoneos ;;
	esac
}

slice_id()
{
	case "$1" in
		iphoneos) echo ios-arm64 ;;
		iphonesimulator) echo ios-arm64-simulator ;;
	esac
}

has_slice()
{
	[[ -f "$1/Info.plist" ]] || return 1
	plutil -extract AvailableLibraries xml1 -o - "$1/Info.plist" | grep -Fq "<string>$(slice_id "$2")</string>"
}

app_path()
{
	case "$1" in
		simulator) echo "$DERIVED_DATA/Build/Products/$CONFIGURATION-iphonesimulator/OpenTTD.app" ;;
		device) echo "$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/OpenTTD.app" ;;
	esac
}

# Build ------------------------------------------------------------------------

BUILD_NUMBER=""

# One number per invocation, shared by every app build it performs.
next_build_number()
{
	[[ -z "$BUILD_NUMBER" ]] || return 0
	local previous=0
	if [[ -f "$BUILD_NUMBER_FILE" ]]; then
		previous="$(<"$BUILD_NUMBER_FILE")"
		[[ "$previous" =~ ^[0-9]+$ ]] || fail "$BUILD_NUMBER_FILE does not hold a build number"
	fi
	BUILD_NUMBER=$((10#$previous + 1))
	printf '%s\n' "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"
}

bundle_version()
{
	plutil -extract CFBundleVersion raw -o - "$1/Info.plist" 2>/dev/null || true
}

# `build` deletes a slice's stamp before building it and writes the build number only on success.
# Slice = platform + configuration: current-device-debug, current-device-release, ...
stamp_path()
{
	printf '%s/current-%s-%s\n' "$DERIVED_DATA" "$1" "$(tr '[:upper:]' '[:lower:]' <<< "$CONFIGURATION")"
}

CURRENT_BUILD=""

# Sets CURRENT_BUILD for <platform>: its stamp exists and its app has that CFBundleVersion; none → 1.
find_current_build()
{
	local stamp number=""
	stamp="$(stamp_path "$1")"
	[[ ! -f "$stamp" ]] || number="$(<"$stamp")"
	CURRENT_BUILD=""
	[[ "$number" =~ ^[0-9]+$ && "$(bundle_version "$(app_path "$1")")" == "$number" ]] || return 1
	CURRENT_BUILD="$number"
}

require_current_build()
{
	find_current_build "$1" || fail "no current $1 build; run: $(script_name) build $1$RELEASE_OPTION"
}

# Builds only XCFrameworks, slices or license texts that are missing; existing artifacts are reused.
ensure_deps()
{
	local entry framework sdk
	for entry in sdl3:SDL3 zlib:Zlib xz:LibLZMA libpng:LibPNG lzo:LZO; do
		framework="$DEPS_ARTIFACTS/${entry#*:}.xcframework"
		local missing=()
		for sdk in "$@"; do
			has_slice "$framework" "$sdk" || missing+=("$sdk")
		done
		if [[ ${#missing[@]} -eq 0 && -z "$(ls -A "$DEPS_ARTIFACTS/licenses/${entry%%:*}" 2>/dev/null)" ]]; then
			missing=("$@")
		fi
		if [[ ${#missing[@]} -gt 0 ]]; then
			"$DEPS_SCRIPT" build "${entry%%:*}" "$(target_word "${missing[@]}")"
		fi
	done
	local soundfont="$DEPS_ARTIFACTS/TimGM6mb"
	if [[ ! -f "$soundfont/TimGM6mb.sf2" || ! -f "$soundfont/LICENSE.txt" || ! -f "$soundfont/COPYING.md" ]]; then
		"$DEPS_SCRIPT" build timgm6mb
	fi
}

host_arguments()
{
	printf '%s\n' -DCMAKE_BUILD_TYPE=Release -DOPTION_TOOLS_ONLY=ON
}

engine_arguments()
{
	local sdk="$1"
	local slice
	slice="$(slice_id "$sdk")"
	# Debug apps keep the optimized engine (no debug info). Release uses upstream's release build type without its
	# -g: the static engine reaches the app's dSYM as symbol table only.
	local build_type=Release
	[[ "$CONFIGURATION" == Debug ]] || build_type=RelWithDebInfo
	printf '%s\n' \
		-DCMAKE_SYSTEM_NAME=iOS \
		-DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION" \
		-DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
		-DCMAKE_BUILD_TYPE="$build_type" \
		-DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O2 -DNDEBUG" \
		-DCMAKE_OBJCXX_FLAGS_RELWITHDEBINFO="-O2 -DNDEBUG" \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
		-DHOST_BINARY_DIR="$(cmake_tree host)" \
		-DSDL3_INCLUDE_DIR="$DEPS_ARTIFACTS/SDL3.xcframework/$slice/Headers" \
		-DZLIB_INCLUDE_DIR="$DEPS_ARTIFACTS/Zlib.xcframework/$slice/Headers" \
		-DZLIB_LIBRARY="$DEPS_ARTIFACTS/Zlib.xcframework/$slice/libz.a" \
		-DLIBLZMA_INCLUDE_DIR="$DEPS_ARTIFACTS/LibLZMA.xcframework/$slice/Headers" \
		-DLIBLZMA_LIBRARY="$DEPS_ARTIFACTS/LibLZMA.xcframework/$slice/liblzma.a" \
		-DPNG_PNG_INCLUDE_DIR="$DEPS_ARTIFACTS/LibPNG.xcframework/$slice/Headers" \
		-DPNG_LIBRARY="$DEPS_ARTIFACTS/LibPNG.xcframework/$slice/libpng16.a" \
		-DLZO_INCLUDE_DIR="$DEPS_ARTIFACTS/LZO.xcframework/$slice/Headers" \
		-DLZO_LIBRARY="$DEPS_ARTIFACTS/LZO.xcframework/$slice/liblzo2.a"
}

cmake_arguments()
{
	if [[ "$1" == host ]]; then
		host_arguments
	else
		engine_arguments "$1"
	fi
}

# CMake trees are keyed by their complete configuration (SDK, compiler, dependency
# slices, cache contract), so a changed configuration gets a fresh tree instead of
# reconfiguring or deleting an existing one. Source edits stay incremental.
# ponytail: superseded trees stay on disk until `clean`; prune by key if space matters.
cmake_tree()
{
	local key
	key="$( { printf '%s\n' "$ENGINE_CONFIG_TAG" "$(command -v c++)"; cmake_arguments "$1"; } | shasum -a 256 | cut -c1-12)"
	printf '%s/%s-%s\n' "$ENGINE_ROOT" "$1" "$key"
}

# Configures the tree once, then builds <target> incrementally.
build_tree()
{
	local name="$1"
	local target="$2"
	local tree
	tree="$(cmake_tree "$name")"
	if [[ ! -f "$tree/build.ninja" ]]; then
		local arguments=()
		local argument
		while IFS= read -r argument; do
			arguments+=("$argument")
		done < <(cmake_arguments "$name")
		cmake -S "$SOURCE_DIR" -B "$tree" -G Ninja "${arguments[@]}"
	fi
	cmake --build "$tree" --target "$target" --parallel
}

# Native strgen/settingsgen first, then the arm64 engine archive for <sdk>.
build_engine_slice()
{
	local sdk="$1"
	build_tree host tools
	build_tree "$sdk" openttd_lib
	local archive
	archive="$(cmake_tree "$sdk")/libopenttd_engine.a"
	[[ -f "$archive" ]] || fail "$sdk engine archive was not produced"
	lipo -info "$archive" | grep -q 'arm64' || fail "$sdk engine archive is not arm64"
	local archive_members
	archive_members="$(xcrun ar -t "$archive")"
	grep -Fq 'http_nsurlsession.mm.o' <<< "$archive_members" || fail "$sdk engine does not contain the NSURLSession HTTP backend"
	! grep -Eq 'http_(none|curl)\.cpp\.o' <<< "$archive_members" || fail "$sdk engine contains a non-iOS HTTP backend"
}

# Packages every current engine slice of the selected configuration with the public
# bridge header; unchanged packages are kept so Xcode does not relink.
package_engine()
{
	local arguments=()
	local archives=""
	local current=yes
	local sdk archive
	for sdk in iphoneos iphonesimulator; do
		archive="$(cmake_tree "$sdk")/libopenttd_engine.a"
		[[ -f "$archive" ]] || continue
		arguments+=(-library "$archive" -headers "$SOURCE_DIR/src/os/ios")
		archives="$archives $archive"
		if [[ "$archive" -nt "$ENGINE_XCFRAMEWORK/Info.plist" ]]; then
			current=no
		fi
	done
	local stamp="$ENGINE_ROOT/OpenTTDEngine.stamp"
	if [[ "$current" == yes && -f "$stamp" && "$(<"$stamp")" == "$archives" ]]; then
		echo "Using packaged OpenTTD engine"
		return
	fi

	local staging="$ENGINE_ROOT/OpenTTDEngine.staging.xcframework"
	rm -rf "$staging"
	xcodebuild -create-xcframework "${arguments[@]}" -output "$staging"
	rm -rf "$ENGINE_XCFRAMEWORK"
	mv "$staging" "$ENGINE_XCFRAMEWORK"
	printf '%s\n' "$archives" > "$stamp"
	plutil -lint "$ENGINE_XCFRAMEWORK/Info.plist" >/dev/null
	echo "Created $ENGINE_XCFRAMEWORK"
}

# Stages the read-only Manual bundled next to SeedData: the documents the Help window
# shows and the license texts of everything linked or bundled into the app.
stage_manual()
{
	local manual="$1"
	mkdir -p "$manual/docs" "$manual/licenses/md5" "$manual/licenses/timgm6mb"
	cp "$SOURCE_DIR/README.md" "$SOURCE_DIR/COPYING.md" "$SOURCE_DIR/changelog.md" "$SOURCE_DIR/known-bugs.md" "$manual/"
	cp "$SOURCE_DIR/docs/fonts.md" "$manual/docs/"
	local dependency entry
	for dependency in sdl3 zlib xz libpng lzo; do
		cp -R "$DEPS_ARTIFACTS/licenses/$dependency" "$manual/licenses/"
	done
	cp "$DEPS_ARTIFACTS/TimGM6mb/LICENSE.txt" "$DEPS_ARTIFACTS/TimGM6mb/COPYING.md" "$manual/licenses/timgm6mb/"
	for entry in $VENDORED_LICENSES; do
		mkdir -p "$manual/licenses/${entry%%:*}"
		cp "$SOURCE_DIR/src/3rdparty/${entry%%:*}/${entry#*:}" "$manual/licenses/${entry%%:*}/"
	done
	# md5 states its license only in its source comment.
	sed -n '/Copyright (C) 1999, 2002 Aladdin Enterprises/,/ghost@aladdin.com/p' \
		"$SOURCE_DIR/src/3rdparty/md5/md5.h" > "$manual/licenses/md5/LICENSE.txt"
	[[ -s "$manual/licenses/md5/LICENSE.txt" ]] || fail "could not extract the md5 license"
}

# Stages the Documents payload (bundled as SeedData): pinned base sets as released,
# expanded OpenMSX, TimGM6mb with its licenses, generated languages, built-in media
# and AI/GS compatibility scripts. Content-addressed; never a Documents/OpenTTD wrapper.
# The Manual (stage_manual) is staged with it but stays in the bundle.
prepare_data()
{
	local language_dir
	language_dir="$(cmake_tree "$1")/lang"
	[[ -d "$language_dir" ]] || fail "missing generated languages in $language_dir"

	local vendored_licenses=() entry
	for entry in $VENDORED_LICENSES; do
		vendored_licenses+=("$SOURCE_DIR/src/3rdparty/${entry%%:*}/${entry#*:}")
	done
	local fingerprint
	fingerprint="documents-root-v1|manual-v1:$(shasum -a 256 \
		"$REPO_ROOT"/Data/*.zip \
		"$SOURCE_DIR/README.md" "$SOURCE_DIR/COPYING.md" "$SOURCE_DIR/changelog.md" "$SOURCE_DIR/known-bugs.md" \
		"$SOURCE_DIR/docs/fonts.md" "$SOURCE_DIR/src/3rdparty/md5/md5.h" "${vendored_licenses[@]}" \
		"$DEPS_ARTIFACTS"/licenses/*/* \
		"$DEPS_ARTIFACTS/TimGM6mb/TimGM6mb.sf2" \
		"$DEPS_ARTIFACTS/TimGM6mb/LICENSE.txt" \
		"$DEPS_ARTIFACTS/TimGM6mb/COPYING.md" \
		"$SOURCE_DIR/media/baseset/openttd.grf" \
		"$SOURCE_DIR/media/baseset/opntitle.dat" \
		"$SOURCE_DIR/media/baseset/orig_extra.grf" \
		"$SOURCE_DIR/media/baseset"/*.ttf \
		"$SOURCE_DIR/bin/ai"/*.nut \
		"$SOURCE_DIR/bin/game"/*.nut \
		"$language_dir"/*.lng | sed -E 's#  .*/#  #' | shasum -a 256 | awk '{print $1}')"
	local stamp="$DATA_STAGE/data.stamp"
	if [[ -f "$stamp" && "$(<"$stamp")" == "$fingerprint" ]]; then
		echo "Using staged seed data"
		return
	fi

	local temporary
	temporary="$(mktemp -d "$DERIVED_DATA/DataPackage.XXXXXX")"
	local seed="$temporary/SeedData"
	mkdir -p \
		"$seed/baseset/timgm6mb" \
		"$seed/lang" \
		"$seed/ai/library" \
		"$seed/game/library" \
		"$seed/save/autosave" \
		"$seed/scenario/heightmap" \
		"$seed/newgrf" \
		"$seed/screenshot" \
		"$seed/content_download"
	unzip -p "$REPO_ROOT/Data/opengfx-8.0-all.zip" '*.tar' > "$seed/baseset/opengfx-8.0.tar"
	unzip -p "$REPO_ROOT/Data/opensfx-1.0.3-all.zip" '*.tar' > "$seed/baseset/opensfx-1.0.3.tar"
	unzip -p "$REPO_ROOT/Data/openmsx-0.4.2-all.zip" '*.tar' | tar -xf - -C "$seed/baseset"
	cp \
		"$DEPS_ARTIFACTS/TimGM6mb/TimGM6mb.sf2" \
		"$DEPS_ARTIFACTS/TimGM6mb/LICENSE.txt" \
		"$DEPS_ARTIFACTS/TimGM6mb/COPYING.md" \
		"$seed/baseset/timgm6mb/"
	cp \
		"$SOURCE_DIR/media/baseset/openttd.grf" \
		"$SOURCE_DIR/media/baseset/opntitle.dat" \
		"$SOURCE_DIR/media/baseset/orig_extra.grf" \
		"$SOURCE_DIR/media/baseset"/*.ttf \
		"$seed/baseset/"
	cp "$language_dir"/*.lng "$seed/lang/"
	cp "$SOURCE_DIR/bin/ai"/*.nut "$seed/ai/"
	cp "$SOURCE_DIR/bin/game"/*.nut "$seed/game/"
	stage_manual "$temporary/Manual"
	printf '%s\n' "$fingerprint" > "$temporary/data.stamp"
	rm -rf "$DATA_STAGE"
	mv "$temporary" "$DATA_STAGE"
	echo "Staged $SEED_DATA"
}

# Stages build.config's ICON as the AppIcon catalog; unchanged files are kept so Xcode does not recompile.
# ponytail: the icon is used as given (App Store Connect rejects alpha), never resized or flattened.
stage_icon()
{
	local icon="$ICON"
	[[ "$icon" == /* ]] || icon="$REPO_ROOT/$icon"
	[[ -f "$icon" ]] || fail "build.config: ICON not found: $ICON"
	local properties expected
	properties="$(sips -g format -g pixelWidth -g pixelHeight -g hasAlpha "$icon" 2>/dev/null || true)"
	for expected in 'format: png' 'pixelWidth: 1024' 'pixelHeight: 1024' 'hasAlpha: no'; do
		grep -Fqx "  $expected" <<< "$properties" || fail "build.config: ICON must be a 1024x1024 PNG without alpha: $ICON"
	done
	local icon_set="$APP_ICON_CATALOG/AppIcon.appiconset"
	local contents='{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}'
	mkdir -p "$icon_set"
	[[ "$(cat "$icon_set/Contents.json" 2>/dev/null)" == "$contents" ]] || printf '%s\n' "$contents" > "$icon_set/Contents.json"
	cmp -s "$icon" "$icon_set/AppIcon.png" || cp "$icon" "$icon_set/AppIcon.png"
}

generate_project()
{
	xcodegen --spec "$IOS_DIR/project.yml" --project "$IOS_DIR" \
		--cache-path "$DERIVED_DATA/xcodegen-cache" --use-cache
}

verify_bundled_data()
{
	local app
	app="$(app_path "$1")"
	[[ -d "$app/SeedData" ]] || fail "built app is missing bundled SeedData"
	[[ ! -e "$app/SeedData/OpenTTD" ]] || fail "bundled SeedData contains the forbidden OpenTTD wrapper"
	[[ -f "$app/SeedData/baseset/opengfx-8.0.tar" ]] || fail "built app is missing bundled OpenGFX"
	[[ -f "$app/SeedData/baseset/opensfx-1.0.3.tar" ]] || fail "built app is missing bundled OpenSFX"
	[[ -f "$app/SeedData/baseset/openmsx-0.4.2/openmsx.obm" ]] || fail "built app is missing bundled OpenMSX"
	[[ -f "$app/SeedData/baseset/timgm6mb/TimGM6mb.sf2" ]] || fail "built app is missing bundled TimGM6mb"
	[[ -f "$app/SeedData/baseset/timgm6mb/LICENSE.txt" ]] || fail "built app is missing the TimGM6mb copyright notice"
	[[ -f "$app/SeedData/baseset/timgm6mb/COPYING.md" ]] || fail "built app is missing the TimGM6mb GPL-2 license"
	[[ ! -e "$app/SeedData/README.md" ]] || fail "bundled SeedData contains the Manual"
	local file
	for file in README.md COPYING.md changelog.md known-bugs.md docs/fonts.md \
		licenses/sdl3/LICENSE.txt licenses/zlib/LICENSE licenses/xz/COPYING licenses/xz/COPYING.0BSD \
		licenses/libpng/LICENSE licenses/lzo/COPYING licenses/timgm6mb/LICENSE.txt licenses/timgm6mb/COPYING.md \
		licenses/md5/LICENSE.txt; do
		[[ -s "$app/Manual/$file" ]] || fail "built app is missing Manual/$file"
	done
	local entry
	for entry in $VENDORED_LICENSES; do
		[[ -s "$app/Manual/licenses/${entry%%:*}/${entry#*:}" ]] || fail "built app is missing the ${entry%%:*} license"
	done
}

# Generic destinations: compilation never waits for a particular simulator or device.
xcode_build()
{
	local platform="$1"
	local arguments=(
		-project "$PROJECT"
		-scheme "$SCHEME"
		-configuration "$CONFIGURATION"
		-derivedDataPath "$DERIVED_DATA"
		-allowProvisioningUpdates
		"PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID"
		"APP_DISPLAY_NAME=$APP_NAME"
	)
	if [[ "$platform" == simulator ]]; then
		arguments+=(-destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO)
	else
		arguments+=(-destination 'generic/platform=iOS' "DEVELOPMENT_TEAM=$TEAM_ID")
	fi
	# Release strips the product in place; a build without a relink would run dsymutil on the stripped binary.
	[[ "$CONFIGURATION" == Debug ]] || rm -f "$(app_path "$platform")/OpenTTD"
	xcodebuild "${arguments[@]}" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" build
	verify_bundled_data "$platform"
}

# build_app <simulator|device|both>
build_app()
{
	local target="$1"
	local platforms platform
	platforms="$(platforms_for "$target")"
	require_tool cmake ninja lipo plutil shasum sips tar unzip xcodegen xcodebuild
	require_settings APP_NAME BUNDLE_ID ICON
	[[ " $platforms " != *" device "* ]] || require_settings TEAM_ID
	stage_icon
	next_build_number
	echo "== OpenTTD build $BUILD_NUMBER ($target)"
	mkdir -p "$DERIVED_DATA"
	for platform in $platforms; do
		rm -f "$(stamp_path "$platform")"
	done

	local sdks=()
	for platform in $platforms; do
		sdks+=("$(sdk_for "$platform")")
	done
	ensure_deps "${sdks[@]}"
	local sdk
	for sdk in "${sdks[@]}"; do
		build_engine_slice "$sdk"
	done
	package_engine
	prepare_data "${sdks[0]}"
	generate_project
	for platform in $platforms; do
		xcode_build "$platform"
		printf '%s\n' "$BUILD_NUMBER" > "$(stamp_path "$platform")"
	done
	echo "Built OpenTTD $BUILD_NUMBER ($target)"
}

# Simulators and devices ------------------------------------------------------

is_uuid()
{
	[[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
}

resolve_simulator()
{
	if is_uuid "$1"; then
		printf '%s\n' "$1"
		return
	fi
	local line
	line="$(xcrun simctl list devices available | grep -F "    $1 (" | head -n 1 || true)"
	[[ -n "$line" ]] || fail "available simulator not found: $1"
	printf '%s\n' "$line" | sed -E 's/.*\(([[:xdigit:]-]{36})\).*/\1/'
}

boot_simulator()
{
	if ! xcrun simctl list devices | grep -F "$1" | grep -q '(Booted)'; then
		xcrun simctl boot "$1"
	fi
	xcrun simctl bootstatus "$1" -b >/dev/null
}

# <key> (bundleVersion, url) of the app installed on the device; empty if it is not installed.
device_app()
{
	local json
	json="$(mktemp -t openttd-apps)"
	if xcrun devicectl device info apps --device "$DEVICE" --bundle-id "$BUNDLE_ID" \
		--json-output "$json" >/dev/null 2>&1; then
		plutil -extract "result.apps.0.$1" raw -o - "$json" 2>/dev/null || true
	fi
	rm -f "$json"
}

# CFBundleVersion of the app installed on simulator <UDID>; empty if it is not installed.
simulator_app_version()
{
	local installed
	installed="$(xcrun simctl get_app_container "$1" "$BUNDLE_ID" app 2>/dev/null)" || return 0
	bundle_version "$installed"
}

# require_installed <simulator|device> <installed CFBundleVersion>: the target must run CURRENT_BUILD.
require_installed()
{
	local name="$SIMULATOR"
	[[ "$1" == simulator ]] || name="$DEVICE"
	[[ "$2" == "$CURRENT_BUILD" ]] || fail "OpenTTD on $name: installed build ${2:-none}, current build $CURRENT_BUILD;" \
		"run: $(script_name) install --$1 \"$name\"$RELEASE_OPTION"
}

# PID of the process whose executable URL is <url>; --search ignores case and also lists other apps' openttd.app/openttd.
device_app_pid()
{
	local json found i=0
	json="$(mktemp -t openttd-processes)"
	if xcrun devicectl device info processes --device "$DEVICE" \
		--search "/OpenTTD.app/OpenTTD" --json-output "$json" >/dev/null 2>&1; then
		while found="$(plutil -extract "result.runningProcesses.$i.executable" raw -o - "$json" 2>/dev/null)"; do
			if [[ "$found" == "$1" ]]; then
				plutil -extract "result.runningProcesses.$i.processIdentifier" raw -o - "$json"
				break
			fi
			i=$((i + 1))
		done
	fi
	rm -f "$json"
}

install_platform()
{
	local app
	app="$(app_path "$1")"
	case "$1" in
		simulator)
			local simulator
			simulator="$(resolve_simulator "$SIMULATOR")"
			boot_simulator "$simulator"
			xcrun simctl install "$simulator" "$app"
			echo "Installed on $SIMULATOR"
			;;
		device)
			xcrun devicectl device install app --device "$DEVICE" "$app"
			;;
	esac
}

install_app()
{
	local platform
	for platform in $PLATFORMS; do
		require_current_build "$platform"
	done
	for platform in $PLATFORMS; do
		install_platform "$platform"
	done
}

# Run ---------------------------------------------------------------------------

# Waits <seconds> while <pid> stays alive; fails as soon as it exits.
hold()
{
	local remaining="$1"
	while (( remaining > 0 )); do
		kill -0 "$2" 2>/dev/null || return 1
		sleep 1
		remaining=$((remaining - 1))
	done
	kill -0 "$2" 2>/dev/null
}

# Ends the local console helper; CoreDevice consoles can ignore SIGINT.
stop_console()
{
	local waited=0
	while kill -0 "$1" 2>/dev/null && (( waited < 10 )); do
		sleep 1
		waited=$((waited + 1))
	done
	kill -KILL "$1" 2>/dev/null || true
	wait "$1" 2>/dev/null || true
}

# Portrait captures are rotated 90° left so evidence is always landscape.
landscape()
{
	local width height
	width="$(sips -g pixelWidth "$1" | awk '/pixelWidth/ {print $2}')"
	height="$(sips -g pixelHeight "$1" | awk '/pixelHeight/ {print $2}')"
	if (( width < height )); then
		sips --rotate -90 "$1" >/dev/null
	fi
}

run_simulator()
{
	local seconds="$1"
	local label="$2"
	local simulator
	simulator="$(resolve_simulator "$SIMULATOR")"
	boot_simulator "$simulator"
	require_installed simulator "$(simulator_app_version "$simulator")"

	local started=$SECONDS
	xcrun simctl launch --terminate-running-process --console "$simulator" "$BUNDLE_ID" \
		${APP_ARGS[@]+"${APP_ARGS[@]}"} > "$LOG_DIR/debugger.log" 2>&1 &
	local console_pid=$!
	local alive=yes
	hold "$seconds" "$console_pid" || alive=no

	if xcrun simctl io "$simulator" screenshot "$LOG_DIR/$label.png" >/dev/null 2>&1; then
		landscape "$LOG_DIR/$label.png"
	else
		echo "warning: simulator screenshot failed" >&2
	fi
	xcrun simctl spawn "$simulator" log show --last "$((SECONDS - started + 5))s" --style compact \
		--predicate 'process == "OpenTTD"' > "$LOG_DIR/$label.log" 2>&1 || \
		echo "warning: simulator log collection failed" >&2
	xcrun simctl terminate "$simulator" "$BUNDLE_ID" >/dev/null 2>&1 || true
	stop_console "$console_pid"
	[[ "$alive" == yes ]] || fail "OpenTTD exited before $seconds s; see log/debugger.log and log/$label.log"
	echo "Ran OpenTTD on $SIMULATOR for $seconds s: log/debugger.log, log/$label.log, log/$label.png"
}

run_device()
{
	local seconds="$1"
	local label="$2"
	require_installed device "$(device_app bundleVersion)"

	# --terminate-existing replaces a running instance: the new process has a new PID.
	local executable previous_pid pid=""
	executable="$(device_app url)OpenTTD"
	previous_pid="$(device_app_pid "$executable")"
	xcrun devicectl device process launch --terminate-existing --console --timeout "$((seconds + 120))" \
		--device "$DEVICE" "$BUNDLE_ID" ${APP_ARGS[@]+"${APP_ARGS[@]}"} > "$LOG_DIR/debugger.log" 2>&1 &
	local console_pid=$!
	local waited=0
	while [[ -z "$pid" || "$pid" == "$previous_pid" ]]; do
		if ! kill -0 "$console_pid" 2>/dev/null || (( waited >= 90 )); then
			stop_console "$console_pid"
			fail "OpenTTD did not launch on $DEVICE; see log/debugger.log"
		fi
		sleep 1
		waited=$((waited + 1))
		pid="$(device_app_pid "$executable")"
	done
	local alive=yes
	hold "$seconds" "$console_pid" || alive=no

	if xcrun devicectl device capture screenshot --device "$DEVICE" \
		--destination "$LOG_DIR/$label.png" >/dev/null 2>&1; then
		landscape "$LOG_DIR/$label.png"
	else
		echo "warning: device screenshot failed" >&2
	fi
	if [[ -n "$pid" ]]; then
		xcrun devicectl device process terminate --device "$DEVICE" --pid "$pid" >/dev/null 2>&1 || true
	fi
	stop_console "$console_pid"
	[[ "$alive" == yes ]] || fail "OpenTTD exited before $seconds s; see log/debugger.log"
	echo "Ran OpenTTD on $DEVICE for $seconds s: log/debugger.log, log/$label.png"
}

run_app()
{
	[[ "$PLATFORMS" == simulator || "$PLATFORMS" == device ]] || usage_error "run takes a single target"
	[[ "$RUN_SECONDS" =~ ^[0-9]+$ ]] && (( 10#$RUN_SECONDS >= 1 && 10#$RUN_SECONDS <= 45 )) || \
		usage_error "--seconds must be 1-45"
	RUN_SECONDS=$((10#$RUN_SECONDS))
	local label="${LABEL:-$PLATFORMS}"
	[[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || usage_error "--label may only contain letters, digits, '.', '_' and '-'"
	require_current_build "$PLATFORMS"
	require_tool sips
	require_settings BUNDLE_ID
	mkdir -p "$LOG_DIR"
	"run_$PLATFORMS" "$RUN_SECONDS" "$label"
}

# Documents payload ---------------------------------------------------------------

# The payload is the SeedData bundled in the current build; both platforms bundle the same one.
documents_zip()
{
	require_tool ditto zip
	local platform payload=""
	for platform in device simulator; do
		if find_current_build "$platform"; then
			payload="$(app_path "$platform")/SeedData"
			break
		fi
	done
	[[ -n "$payload" ]] || fail "no current build; run: $(script_name) build"
	mkdir -p "$IPA_DIR"
	local output="$IPA_DIR/Documents.zip"
	local temporary
	temporary="$(mktemp -d "$DERIVED_DATA/DocumentsZip.XXXXXX")"
	ditto "$payload" "$temporary/Documents"
	rm -f "$output"
	(cd "$temporary" && zip -qry "$output" Documents)
	rm -rf "$temporary"
	local entries
	entries="$(unzip -Z1 "$output")"
	[[ "$entries" != *"Documents/OpenTTD/"* ]] || fail "Documents ZIP contains the forbidden OpenTTD wrapper"
	[[ "$entries" == *"Documents/baseset/opengfx-8.0.tar"* ]] || fail "Documents ZIP is missing OpenGFX"
	[[ "$entries" == *"Documents/baseset/opensfx-1.0.3.tar"* ]] || fail "Documents ZIP is missing OpenSFX"
	[[ "$entries" == *"Documents/baseset/openmsx-0.4.2/openmsx.obm"* ]] || fail "Documents ZIP is missing OpenMSX"
	[[ "$entries" == *"Documents/baseset/timgm6mb/TimGM6mb.sf2"* ]] || fail "Documents ZIP is missing TimGM6mb"
	[[ "$entries" == *"Documents/baseset/timgm6mb/LICENSE.txt"* ]] || fail "Documents ZIP is missing the TimGM6mb copyright notice"
	[[ "$entries" == *"Documents/baseset/timgm6mb/COPYING.md"* ]] || fail "Documents ZIP is missing the TimGM6mb GPL-2 license"
	echo "Created $output"
}

# Existing Documents files are kept on the simulator; CoreDevice merges directories.
documents_install()
{
	require_settings BUNDLE_ID
	local platform simulator=""
	for platform in $PLATFORMS; do
		require_current_build "$platform"
		if [[ "$platform" == simulator ]]; then
			simulator="$(resolve_simulator "$SIMULATOR")"
			boot_simulator "$simulator"
			require_installed simulator "$(simulator_app_version "$simulator")"
		else
			require_installed device "$(device_app bundleVersion)"
		fi
	done
	for platform in $PLATFORMS; do
		local payload
		payload="$(app_path "$platform")/SeedData"
		case "$platform" in
			simulator)
				require_tool rsync
				local container
				container="$(xcrun simctl get_app_container "$simulator" "$BUNDLE_ID" data)"
				mkdir -p "$container/Documents"
				rsync -a --ignore-existing "$payload/" "$container/Documents/"
				echo "Installed the Documents payload on $SIMULATOR"
				;;
			device)
				local item
				for item in "$payload"/*; do
					xcrun devicectl device copy to --device "$DEVICE" \
						--source "$item" \
						--destination Documents \
						--domain-type appDataContainer \
						--domain-identifier "$BUNDLE_ID"
				done
				echo "Installed the Documents payload on $DEVICE"
				;;
		esac
	done
}

# Packaging ---------------------------------------------------------------------

IPA_PATH=""
IPA_NAME=""

create_ipa()
{
	local signing="$1"
	require_tool codesign ditto zip
	require_current_build device
	local app
	app="$(app_path device)"
	local version
	version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Info.plist")"

	IPA_NAME="OpenTTD-$version-$CURRENT_BUILD.ipa"
	IPA_PATH="$IPA_DIR/OpenTTD.ipa"
	[[ "$signing" == signed ]] || IPA_PATH="$IPA_DIR/OpenTTD-unsigned.ipa"
	mkdir -p "$IPA_DIR"
	local temporary
	temporary="$(mktemp -d "$DERIVED_DATA/IPA.XXXXXX")"
	mkdir -p "$temporary/Payload"
	local bundle="$temporary/Payload/OpenTTD.app"
	ditto "$app" "$bundle"
	# The device build is always signed; the unsigned IPA strips every signature from its copy.
	if [[ "$signing" == unsigned ]]; then
		rm -rf "$bundle/_CodeSignature" "$bundle/embedded.mobileprovision"
		find "$bundle" -maxdepth 1 -type f \( -name OpenTTD -o -name '*.dylib' \) \
			-exec codesign --remove-signature {} +
	fi
	rm -f "$IPA_PATH"
	(cd "$temporary" && zip -qry "$IPA_PATH" Payload)
	rm -rf "$temporary"
	echo "Created $IPA_PATH ($IPA_NAME)"
}

upload_ipa()
{
	require_tool curl
	require_settings REPO_SERVER_URL
	[[ -z "$NOTES_FILE" || ( -f "$NOTES_FILE" && -r "$NOTES_FILE" ) ]] || fail "notes file not found or unreadable: $NOTES_FILE"
	create_ipa signed
	local archived="$ARCHIVE_DIR/$IPA_NAME"
	[[ ! -e "$archived" ]] || fail "$archived already exists"
	# Release keeps the matching dSYM next to the IPA; it is not uploaded.
	local dsym binary dsym_zip="$ARCHIVE_DIR/${IPA_NAME%.ipa}.dSYM.zip"
	if [[ "$CONFIGURATION" == Release ]]; then
		binary="$(app_path device)/OpenTTD"
		dsym="$(app_path device).dSYM"
		[[ "$(xcrun dwarfdump --uuid "$dsym" 2>/dev/null | awk '{print $2}')" == "$(xcrun dwarfdump --uuid "$binary" | awk '{print $2}')" ]] || \
			fail "$dsym is missing or does not match $binary"
		[[ ! -e "$dsym_zip" ]] || fail "$dsym_zip already exists"
	else
		# The repo server cannot tell debug from release builds, so debug notes say it first.
		local notes="[DEBUG BUILD]"
		[[ -z "$NOTES_FILE" ]] || NOTES_TEXT="$(<"$NOTES_FILE")"
		[[ ${#NOTES_FORM[@]} -eq 0 ]] || notes+=$'\n'"$NOTES_TEXT"
		NOTES_FORM=(--form-string "notes=$notes")
	fi
	mkdir -p "$ARCHIVE_DIR"
	cp "$IPA_PATH" "$archived"
	# No AppleDouble (._*) entries: they break dwarfdump on the unpacked dSYM.
	[[ "$CONFIGURATION" == Debug ]] || ditto -c -k --norsrc --noextattr --noacl --keepParent "$dsym" "$dsym_zip"
	curl --fail --silent --show-error -F "file=@$archived" ${NOTES_FORM[@]+"${NOTES_FORM[@]}"} "$REPO_SERVER_URL"
	echo
	echo "Uploaded archive/$IPA_NAME"
	[[ "$CONFIGURATION" == Debug ]] || echo "Kept archive/${dsym_zip##*/}"
}

# Main ---------------------------------------------------------------------------

COMMAND="${1:-}"
case "$COMMAND" in
	""|-h|--help)
		usage
		exit 0
		;;
	build|install|run|ipa|upload|documents|clean) shift ;;
	*)
		usage >&2
		exit 1
		;;
esac
parse_arguments "$@"
require_tool xcrun

case "$COMMAND" in
	build)
		allow 1 --release
		platforms_for "${POSITIONAL[0]:-simulator}" >/dev/null || usage_error "unknown target: ${POSITIONAL[0]}"
		build_app "${POSITIONAL[0]:-simulator}"
		;;
	install)
		allow 1 --simulator --device --release
		resolve_targets "${POSITIONAL[0]:-}"
		install_app
		;;
	run)
		allow 1 --simulator --device --seconds --label --release --
		resolve_targets "${POSITIONAL[0]:-}"
		run_app
		;;
	ipa)
		allow 0 --unsigned --release
		if [[ "$UNSIGNED" == yes ]]; then
			create_ipa unsigned
		else
			create_ipa signed
		fi
		;;
	upload)
		allow 0 --notes --notes-file --release
		upload_ipa
		;;
	documents)
		case "${POSITIONAL[0]:-}" in
			zip)
				allow 1
				documents_zip
				;;
			install)
				allow 2 --simulator --device
				resolve_targets "${POSITIONAL[1]:-}"
				documents_install
				;;
			*) usage_error "documents takes zip or install" ;;
		esac
		;;
	clean)
		allow 0
		rm -rf "$DERIVED_DATA"
		echo "Removed $DERIVED_DATA"
		;;
esac
