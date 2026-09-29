#!/usr/bin/env bash
# Builds, installs, runs and packages the OpenTTD iOS app.

set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
DERIVED_DATA="$REPO_ROOT/DerivedData"
LOG_DIR="$REPO_ROOT/log"
SOURCE_DIR="$REPO_ROOT/source"
DEPS_SCRIPT="$REPO_ROOT/ios-deps/build-deps.sh"
DEPS_ARTIFACTS="$REPO_ROOT/ios-deps/artifacts"
ARCHIVE_DIR="$REPO_ROOT/archive"
BUILD_NUMBER_FILE="$IOS_DIR/BUILD_NUMBER"
PROJECT="$IOS_DIR/OpenTTD.xcodeproj"
SCHEME="OpenTTD"
BUNDLE_ID="com.example.openttd"
DEFAULT_SIMULATOR="iPad Air 11-inch (M4)"
DEFAULT_DEVICE="OldPad"
IOS_MIN_VERSION="26.0"
ENGINE_ROOT="$DERIVED_DATA/OpenTTD-engine"
ENGINE_XCFRAMEWORK="$ENGINE_ROOT/OpenTTDEngine.xcframework"
# Bump when a CMake cache default changes, so every engine tree is configured afresh.
ENGINE_CONFIG_TAG="parent-git|documents-root-v1|sdl3-metal-video-v1"
DATA_STAGE="$DERIVED_DATA/DataPackage"
SEED_DATA="$DATA_STAGE/SeedData"
IPA_DIR="$DERIVED_DATA/ipa"
REPO_SERVER_URL="http://repo-server.invalid/upload/"

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

build     [simulator|device|both]
          Missing deps, engine and app; ios/BUILD_NUMBER +1 per invocation. Default: simulator
install   [target] [--no-build]
          Build and install the app. Default: simulator
run       [target] [--seconds <1-45>] [--label <name>] [--no-build] [--no-install] [-- <app args>]
          Build, install, run non-interactively → log/debugger.log, log/<label>.{log,png}. Default: 45 s
          --no-build: use last build. --no-install: launch installed app (implies --no-build)
ipa       [--unsigned]
          Device build → IPA in DerivedData/ipa. Default: signed
push
          Signed IPA of the current tree → archive/ → repo server
documents zip
          Documents payload → DerivedData/ipa/Documents.zip
documents install [target]
          Copy the payload into the installed app's Documents, no reinstall. Default: simulator
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

# Command line --------------------------------------------------------------

POSITIONAL=()
APP_ARGS=()
GIVEN=""
NO_BUILD=no
NO_INSTALL=no
UNSIGNED=no
RUN_SECONDS=45
LABEL=""
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
			--simulator|--device|--seconds|--label)
				[[ $# -ge 2 ]] || usage_error "$1 needs a value"
				case "$1" in
					--simulator) SIMULATOR_OPTION="$2" ;;
					--device) DEVICE_OPTION="$2" ;;
					--seconds) RUN_SECONDS="$2" ;;
					--label) LABEL="$2" ;;
				esac
				GIVEN="$GIVEN $1"
				shift 2
				;;
			--no-build) NO_BUILD=yes; GIVEN="$GIVEN $1"; shift ;;
			--no-install) NO_INSTALL=yes; GIVEN="$GIVEN $1"; shift ;;
			--unsigned) UNSIGNED=yes; GIVEN="$GIVEN $1"; shift ;;
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
		simulator) echo "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/OpenTTD.app" ;;
		device) echo "$DERIVED_DATA/Build/Products/Debug-iphoneos/OpenTTD.app" ;;
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

# Builds only XCFrameworks or slices that are missing; existing artifacts are reused.
ensure_deps()
{
	local entry framework sdk
	for entry in sdl3:SDL3 zlib:Zlib xz:LibLZMA libpng:LibPNG lzo:LZO; do
		framework="$DEPS_ARTIFACTS/${entry#*:}.xcframework"
		local missing=()
		for sdk in "$@"; do
			has_slice "$framework" "$sdk" || missing+=("$sdk")
		done
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
	printf '%s\n' \
		-DCMAKE_SYSTEM_NAME=iOS \
		-DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION" \
		-DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
		-DHOST_BINARY_DIR="$(cmake_tree host)" \
		-DOPTION_USE_PARENT_GIT=ON \
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
}

# Packages every current engine slice with the public bridge header; unchanged
# packages are kept so Xcode does not relink.
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

# Stages the Documents payload (bundled as SeedData): pinned base sets as released,
# expanded OpenMSX, TimGM6mb with its licenses, generated languages, built-in media
# and AI/GS compatibility scripts. Content-addressed; never a Documents/OpenTTD wrapper.
prepare_data()
{
	local language_dir
	language_dir="$(cmake_tree "$1")/lang"
	[[ -d "$language_dir" ]] || fail "missing generated languages in $language_dir"

	local fingerprint
	fingerprint="documents-root-v1:$(shasum -a 256 \
		"$REPO_ROOT"/Data/*.zip \
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
	printf '%s\n' "$fingerprint" > "$temporary/data.stamp"
	rm -rf "$DATA_STAGE"
	mv "$temporary" "$DATA_STAGE"
	echo "Staged $SEED_DATA"
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
}

# Generic destinations: compilation never waits for a particular simulator or device.
xcode_build()
{
	local platform="$1"
	local signing="$2"
	local arguments=(
		-project "$PROJECT"
		-scheme "$SCHEME"
		-configuration Debug
		-derivedDataPath "$DERIVED_DATA"
		-allowProvisioningUpdates
	)
	if [[ "$platform" == simulator ]]; then
		arguments+=(-destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO)
	else
		arguments+=(-destination 'generic/platform=iOS')
		if [[ "$signing" == unsigned ]]; then
			arguments+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
		fi
	fi
	xcodebuild "${arguments[@]}" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" build
	verify_bundled_data "$platform"
}

# build_app <simulator|device|both> [signed|unsigned]
build_app()
{
	local target="$1"
	local signing="${2:-signed}"
	local platforms platform
	platforms="$(platforms_for "$target")"
	require_tool cmake ninja lipo plutil shasum tar unzip xcodegen xcodebuild
	next_build_number
	echo "== OpenTTD build $BUILD_NUMBER ($target)"
	mkdir -p "$DERIVED_DATA"

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
		xcode_build "$platform" "$signing"
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

device_has_app()
{
	local json
	json="$(mktemp -t openttd-apps)"
	local found=no
	if xcrun devicectl device info apps --device "$DEVICE" --json-output "$json" >/dev/null 2>&1 && \
		grep -Fq "\"$BUNDLE_ID\"" "$json"; then
		found=yes
	fi
	rm -f "$json"
	[[ "$found" == yes ]]
}

device_app_pid()
{
	local json
	json="$(mktemp -t openttd-processes)"
	if xcrun devicectl device info processes --device "$DEVICE" \
		--search "/OpenTTD.app/OpenTTD" --json-output "$json" >/dev/null 2>&1; then
		plutil -extract result.runningProcesses.0.processIdentifier raw -o - "$json" 2>/dev/null || true
	fi
	rm -f "$json"
}

install_platform()
{
	local app
	app="$(app_path "$1")"
	[[ -d "$app" ]] || fail "no $1 build to install; run: $(script_name) build $1"
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
	[[ "$NO_BUILD" == yes ]] || build_app "$(target_word $PLATFORMS)"
	local platform
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
	if [[ "$NO_INSTALL" == yes ]]; then
		xcrun simctl get_app_container "$simulator" "$BUNDLE_ID" >/dev/null 2>&1 || \
			fail "OpenTTD is not installed on $SIMULATOR"
	fi

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
	if [[ "$NO_INSTALL" == yes ]]; then
		device_has_app || fail "OpenTTD is not installed on $DEVICE"
	fi

	# --terminate-existing replaces a running instance: the new process has a new PID.
	local previous_pid pid=""
	previous_pid="$(device_app_pid)"
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
		pid="$(device_app_pid)"
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
	[[ "$NO_INSTALL" == yes ]] || install_app
	require_tool sips
	mkdir -p "$LOG_DIR"
	"run_$PLATFORMS" "$RUN_SECONDS" "$label"
}

# Documents payload ---------------------------------------------------------------

# The payload needs generated languages: the simulator engine slice is built as needed.
ensure_payload()
{
	require_tool cmake ninja lipo plutil shasum tar unzip
	mkdir -p "$DERIVED_DATA"
	ensure_deps iphonesimulator
	build_engine_slice iphonesimulator
	prepare_data iphonesimulator
}

documents_zip()
{
	require_tool ditto zip
	ensure_payload
	mkdir -p "$IPA_DIR"
	local output="$IPA_DIR/Documents.zip"
	local temporary
	temporary="$(mktemp -d "$DERIVED_DATA/DocumentsZip.XXXXXX")"
	ditto "$SEED_DATA" "$temporary/Documents"
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
	ensure_payload
	local platform
	for platform in $PLATFORMS; do
		case "$platform" in
			simulator)
				require_tool rsync
				local simulator container
				simulator="$(resolve_simulator "$SIMULATOR")"
				boot_simulator "$simulator"
				container="$(xcrun simctl get_app_container "$simulator" "$BUNDLE_ID" data 2>/dev/null)" || \
					fail "OpenTTD is not installed on $SIMULATOR"
				mkdir -p "$container/Documents"
				rsync -a --ignore-existing "$SEED_DATA/" "$container/Documents/"
				echo "Installed the Documents payload on $SIMULATOR"
				;;
			device)
				device_has_app || fail "OpenTTD is not installed on $DEVICE"
				local item
				for item in "$SEED_DATA"/*; do
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
	require_tool ditto zip
	build_app device "$signing"
	local app
	app="$(app_path device)"
	local version build
	version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Info.plist")"
	build="$(plutil -extract CFBundleVersion raw -o - "$app/Info.plist")"
	[[ "$build" == "$BUILD_NUMBER" ]] || fail "app reports build $build instead of $BUILD_NUMBER"

	IPA_NAME="OpenTTD-$version-$build.ipa"
	IPA_PATH="$IPA_DIR/OpenTTD.ipa"
	[[ "$signing" == signed ]] || IPA_PATH="$IPA_DIR/OpenTTD-unsigned.ipa"
	mkdir -p "$IPA_DIR"
	local temporary
	temporary="$(mktemp -d "$DERIVED_DATA/IPA.XXXXXX")"
	mkdir -p "$temporary/Payload"
	ditto "$app" "$temporary/Payload/OpenTTD.app"
	rm -f "$IPA_PATH"
	(cd "$temporary" && zip -qry "$IPA_PATH" Payload)
	rm -rf "$temporary"
	echo "Created $IPA_PATH ($IPA_NAME)"
}

push_ipa()
{
	require_tool curl
	create_ipa signed
	local archived="$ARCHIVE_DIR/$IPA_NAME"
	[[ ! -e "$archived" ]] || fail "$archived already exists"
	mkdir -p "$ARCHIVE_DIR"
	cp "$IPA_PATH" "$archived"
	curl --fail --silent --show-error -F "file=@$archived" "$REPO_SERVER_URL"
	echo
	echo "Pushed archive/$IPA_NAME"
}

# Main ---------------------------------------------------------------------------

COMMAND="${1:-}"
case "$COMMAND" in
	""|-h|--help)
		usage
		exit 0
		;;
	build|install|run|ipa|push|documents|clean) shift ;;
	*)
		usage >&2
		exit 1
		;;
esac
parse_arguments "$@"
require_tool xcrun

case "$COMMAND" in
	build)
		allow 1
		platforms_for "${POSITIONAL[0]:-simulator}" >/dev/null || usage_error "unknown target: ${POSITIONAL[0]}"
		build_app "${POSITIONAL[0]:-simulator}"
		;;
	install)
		allow 1 --simulator --device --no-build
		resolve_targets "${POSITIONAL[0]:-}"
		install_app
		;;
	run)
		allow 1 --simulator --device --seconds --label --no-build --no-install --
		resolve_targets "${POSITIONAL[0]:-}"
		[[ "$NO_INSTALL" == no ]] || NO_BUILD=yes
		run_app
		;;
	ipa)
		allow 0 --unsigned
		if [[ "$UNSIGNED" == yes ]]; then
			create_ipa unsigned
		else
			create_ipa signed
		fi
		;;
	push)
		allow 0
		push_ipa
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
