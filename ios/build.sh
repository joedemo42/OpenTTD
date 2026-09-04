#!/usr/bin/env bash

set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
DERIVED_DATA="$REPO_ROOT/DerivedData"
PROJECT="$IOS_DIR/OpenTTD.xcodeproj"
SCHEME="OpenTTD"
BUNDLE_ID="com.example.openttd"
DEFAULT_SIMULATOR="iPad Air 11-inch (M4)"
DEFAULT_DEVICE="OldPad"
LOG_DIR="$REPO_ROOT/log"
DATA_STAGE="$DERIVED_DATA/DataPackage"
SOURCE_DIR="$REPO_ROOT/source"
ENGINE_ROOT="$DERIVED_DATA/OpenTTD-engine"
ENGINE_XCFRAMEWORK="$ENGINE_ROOT/OpenTTDEngine.xcframework"
IOS_MIN_VERSION="26.0"

usage()
{
	cat <<EOF
Usage: $(basename "$0") <command> [arguments]

Commands:
  engine <simulator|device|all>    Build native generators and iOS engine archive(s).
  test-host                        Build and run the upstream host tests.
  generate                         Generate OpenTTD.xcodeproj with XcodeGen.
  build <simulator|device> [name]  Incrementally build for arm64.
  install <simulator|device> [name-or-UUID]
  run <simulator|device> [name-or-UUID]
  test-simulator [name-or-UUID] [seconds]
  test-device [name-or-UUID] [seconds]
  data-zip                         Stage base sets and create a Documents ZIP.
  data-push <simulator|device> [name-or-UUID]
  archive                          Create a signed device archive.
  ipa <signed|unsigned>            Package the device app as an IPA.

Defaults: simulator "$DEFAULT_SIMULATOR", device "$DEFAULT_DEVICE".
All build products stay under $DERIVED_DATA.
EOF
}

fail()
{
	echo "error: $*" >&2
	exit 1
}

require_tool()
{
	command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

require_artifacts()
{
	local artifact
	for artifact in SDL3 Zlib LibLZMA LibPNG LZO; do
		[[ -d "$REPO_ROOT/thirdparty/artifacts/$artifact.xcframework" ]] || \
			fail "missing $artifact.xcframework; run thirdparty/build-deps.sh build all"
	done
}

require_engine_artifact()
{
	[[ -d "$ENGINE_XCFRAMEWORK" ]] || \
		fail "missing OpenTTDEngine.xcframework; run ios/build.sh engine all"
}

build_host_tools()
{
	require_tool cmake
	require_tool ninja
	local build_directory="$ENGINE_ROOT/host"
	local signature="Ninja|Release|tools|$(command -v c++)"
	local stamp="$build_directory/ios-config.stamp"
	if [[ ! -f "$build_directory/build.ninja" || ! -f "$stamp" || "$(<"$stamp")" != "$signature" ]]; then
		cmake -E remove_directory "$build_directory"
		cmake -S "$SOURCE_DIR" -B "$build_directory" -G Ninja \
			-DCMAKE_BUILD_TYPE=Release \
			-DOPTION_TOOLS_ONLY=ON
		printf '%s\n' "$signature" > "$stamp"
	fi
	cmake --build "$build_directory" --target tools --parallel
}

build_engine_slice()
{
	local sdk="$1"
	local artifact_slice
	case "$sdk" in
		iphoneos) artifact_slice="ios-arm64" ;;
		iphonesimulator) artifact_slice="ios-arm64-simulator" ;;
		*) fail "unknown engine SDK: $sdk" ;;
	esac

	local sdk_path compiler dependency_root build_directory
	sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
	compiler="$(xcrun --find clang++)"
	dependency_root="$REPO_ROOT/thirdparty/artifacts"
	build_directory="$ENGINE_ROOT/$sdk"

	local signature="Ninja|Release|$sdk_path|arm64|$IOS_MIN_VERSION|$compiler|$artifact_slice|parent-git"
	local stamp="$build_directory/ios-config.stamp"
	if [[ ! -f "$build_directory/build.ninja" || ! -f "$stamp" || "$(<"$stamp")" != "$signature" ]]; then
		cmake -E remove_directory "$build_directory"
		cmake -S "$SOURCE_DIR" -B "$build_directory" -G Ninja \
			-DCMAKE_SYSTEM_NAME=iOS \
			-DCMAKE_OSX_SYSROOT="$sdk_path" \
			-DCMAKE_OSX_ARCHITECTURES=arm64 \
			-DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION" \
			-DCMAKE_CXX_COMPILER="$compiler" \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
			-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
			-DHOST_BINARY_DIR="$ENGINE_ROOT/host" \
			-DOPTION_USE_PARENT_GIT=ON \
			-DZLIB_INCLUDE_DIR="$dependency_root/Zlib.xcframework/$artifact_slice/Headers" \
			-DZLIB_LIBRARY="$dependency_root/Zlib.xcframework/$artifact_slice/libz.a" \
			-DLIBLZMA_INCLUDE_DIR="$dependency_root/LibLZMA.xcframework/$artifact_slice/Headers" \
			-DLIBLZMA_LIBRARY="$dependency_root/LibLZMA.xcframework/$artifact_slice/liblzma.a" \
			-DPNG_PNG_INCLUDE_DIR="$dependency_root/LibPNG.xcframework/$artifact_slice/Headers" \
			-DPNG_LIBRARY="$dependency_root/LibPNG.xcframework/$artifact_slice/libpng16.a" \
			-DLZO_INCLUDE_DIR="$dependency_root/LZO.xcframework/$artifact_slice/Headers" \
			-DLZO_LIBRARY="$dependency_root/LZO.xcframework/$artifact_slice/liblzo2.a"
		printf '%s\n' "$signature" > "$stamp"
	fi
	cmake --build "$build_directory" --target openttd_lib --parallel

	local archive="$build_directory/libopenttd_engine.a"
	[[ -f "$archive" ]] || fail "$sdk engine archive was not produced"
	lipo -info "$archive" | grep -q 'arm64' || fail "$sdk engine archive is not arm64"
}

package_engine()
{
	local device_archive="$ENGINE_ROOT/iphoneos/libopenttd_engine.a"
	local simulator_archive="$ENGINE_ROOT/iphonesimulator/libopenttd_engine.a"
	[[ -f "$device_archive" && -f "$simulator_archive" ]] || return

	if [[ -f "$ENGINE_XCFRAMEWORK/Info.plist" && \
		"$ENGINE_XCFRAMEWORK/Info.plist" -nt "$device_archive" && \
		"$ENGINE_XCFRAMEWORK/Info.plist" -nt "$simulator_archive" ]]; then
		echo "Using packaged OpenTTD engine"
		return
	fi

	local staging="$ENGINE_ROOT/OpenTTDEngine.staging.xcframework"
	rm -rf "$staging"
	xcodebuild -create-xcframework \
		-library "$device_archive" \
		-headers "$SOURCE_DIR/src/os/ios" \
		-library "$simulator_archive" \
		-headers "$SOURCE_DIR/src/os/ios" \
		-output "$staging"
	rm -rf "$ENGINE_XCFRAMEWORK"
	mv "$staging" "$ENGINE_XCFRAMEWORK"
	plutil -lint "$ENGINE_XCFRAMEWORK/Info.plist" >/dev/null
	echo "Created $ENGINE_XCFRAMEWORK"
}

build_engine()
{
	local selection="$1"
	require_artifacts
	require_tool cmake
	require_tool lipo
	require_tool ninja
	require_tool plutil
	build_host_tools
	case "$selection" in
		simulator) build_engine_slice iphonesimulator ;;
		device) build_engine_slice iphoneos ;;
		all)
			build_engine_slice iphoneos
			build_engine_slice iphonesimulator
			;;
		*) fail "engine platform must be simulator, device, or all" ;;
	esac
	package_engine
}

test_host()
{
	require_tool cmake
	require_tool ctest
	require_tool ninja
	require_tool unzip
	local build_directory="$ENGINE_ROOT/host-tests"
	cmake -S "$SOURCE_DIR" -B "$build_directory" -G Ninja \
		-DCMAKE_BUILD_TYPE=Debug \
		-DOPTION_USE_PARENT_GIT=ON
	cmake --build "$build_directory" --target openttd_test openttd regression_files --parallel
	unzip -oqj "$REPO_ROOT/Data/opengfx-8.0-all.zip" '*.tar' -d "$build_directory/baseset"
	ctest --test-dir "$build_directory" --output-on-failure
}

generate_project()
{
	require_tool xcodegen
	require_artifacts
	require_engine_artifact
	mkdir -p "$DERIVED_DATA"
	xcodegen --spec "$IOS_DIR/project.yml" --project "$IOS_DIR" \
		--cache-path "$DERIVED_DATA/xcodegen-cache" --use-cache
}

is_uuid()
{
	[[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
}

resolve_simulator()
{
	local selector="$1"
	if is_uuid "$selector"; then
		printf '%s\n' "$selector"
		return
	fi

	local line
	line="$(xcrun simctl list devices available | grep -F "    $selector (" | head -n 1 || true)"
	[[ -n "$line" ]] || fail "available simulator not found: $selector"
	printf '%s\n' "$line" | sed -E 's/.*\(([[:xdigit:]-]{36})\).*/\1/'
}

boot_simulator()
{
	local simulator="$1"
	if ! xcrun simctl list devices | grep -F "$simulator" | grep -q '(Booted)'; then
		xcrun simctl boot "$simulator"
	fi
	xcrun simctl bootstatus "$simulator" -b
}

destination_for()
{
	local platform="$1"
	local selector="${2:-}"
	case "$platform" in
		simulator)
			if [[ -z "$selector" ]]; then
				echo 'generic/platform=iOS Simulator'
			else
				echo "platform=iOS Simulator,id=$(resolve_simulator "$selector")"
			fi
			;;
		device)
			if [[ -z "$selector" ]]; then
				echo 'generic/platform=iOS'
			elif is_uuid "$selector"; then
				echo "platform=iOS,id=$selector"
			else
				echo "platform=iOS,name=$selector"
			fi
			;;
		*) fail "platform must be simulator or device" ;;
	esac
}

build_app()
{
	local platform="$1"
	local selector="${2:-}"
	local signing="${3:-signed}"
	build_engine all
	generate_project
	local arguments=(
		-project "$PROJECT"
		-scheme "$SCHEME"
		-configuration Debug
		-destination "$(destination_for "$platform" "$selector")"
		-derivedDataPath "$DERIVED_DATA"
		-allowProvisioningUpdates
		build
	)
	if [[ "$platform" == simulator ]]; then
		arguments+=(CODE_SIGNING_ALLOWED=NO)
	elif [[ "$signing" == unsigned ]]; then
		arguments+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
	fi
	xcodebuild "${arguments[@]}"
}

app_path()
{
	case "$1" in
		simulator) echo "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/OpenTTD.app" ;;
		device) echo "$DERIVED_DATA/Build/Products/Debug-iphoneos/OpenTTD.app" ;;
		*) fail "platform must be simulator or device" ;;
	esac
}

install_app()
{
	local platform="$1"
	local selector="${2:-}"
	local app
	if [[ "$platform" == device ]]; then
		build_app device
	else
		build_app "$platform" "$selector"
	fi
	app="$(app_path "$platform")"
	case "$platform" in
		simulator)
			local simulator
			simulator="$(resolve_simulator "${selector:-$DEFAULT_SIMULATOR}")"
			boot_simulator "$simulator"
			xcrun simctl install "$simulator" "$app"
			;;
		device)
			xcrun devicectl device install app --device "${selector:-$DEFAULT_DEVICE}" "$app"
			;;
		*) fail "platform must be simulator or device" ;;
	esac
}

run_app()
{
	local platform="$1"
	local selector="${2:-}"
	install_app "$platform" "$selector"
	case "$platform" in
		simulator)
			local simulator
			simulator="$(resolve_simulator "${selector:-$DEFAULT_SIMULATOR}")"
			xcrun simctl launch --terminate-running-process "$simulator" "$BUNDLE_ID"
			;;
		device)
			xcrun devicectl device process launch --terminate-existing \
				--device "${selector:-$DEFAULT_DEVICE}" "$BUNDLE_ID"
			;;
		*) fail "platform must be simulator or device" ;;
	esac
}

prepare_data()
{
	require_tool unzip
	require_tool shasum
	local fingerprint
	fingerprint="$(shasum -a 256 "$REPO_ROOT"/Data/*.zip | shasum -a 256 | awk '{print $1}')"
	local stamp="$DATA_STAGE/data.stamp"
	if [[ -f "$stamp" && "$(<"$stamp")" == "$fingerprint" ]]; then
		echo "Using staged Documents data"
		return
	fi

	local temporary
	temporary="$(mktemp -d "$DERIVED_DATA/DataPackage.XXXXXX")"
	mkdir -p "$temporary/Documents/OpenTTD/baseset"
	unzip -p "$REPO_ROOT/Data/opengfx-8.0-all.zip" '*.tar' > \
		"$temporary/Documents/OpenTTD/baseset/opengfx-8.0.tar"
	unzip -p "$REPO_ROOT/Data/opensfx-1.0.3-all.zip" '*.tar' > \
		"$temporary/Documents/OpenTTD/baseset/opensfx-1.0.3.tar"
	unzip -p "$REPO_ROOT/Data/openmsx-0.4.2-all.zip" '*.tar' | \
		tar -xf - -C "$temporary/Documents/OpenTTD/baseset"
	printf '%s\n' "$fingerprint" > "$temporary/data.stamp"
	rm -rf "$DATA_STAGE"
	mv "$temporary" "$DATA_STAGE"
	echo "Staged $DATA_STAGE/Documents"
}

create_data_zip()
{
	require_tool zip
	prepare_data
	local output="$DERIVED_DATA/OpenTTD-Documents.zip"
	rm -f "$output"
	(cd "$DATA_STAGE" && zip -qry "$output" Documents)
	echo "Created $output"
}

push_data()
{
	local platform="$1"
	local selector="${2:-}"
	prepare_data
	case "$platform" in
		simulator)
			require_tool rsync
			local simulator container
			simulator="$(resolve_simulator "${selector:-$DEFAULT_SIMULATOR}")"
			container="$(xcrun simctl get_app_container "$simulator" "$BUNDLE_ID" data)"
			mkdir -p "$container/Documents/OpenTTD"
			rsync -a --ignore-existing "$DATA_STAGE/Documents/OpenTTD/" "$container/Documents/OpenTTD/"
			;;
		device)
			xcrun devicectl device copy to --device "${selector:-$DEFAULT_DEVICE}" \
				--source "$DATA_STAGE/Documents/OpenTTD" \
				--destination Documents \
				--domain-type appDataContainer \
				--domain-identifier "$BUNDLE_ID"
			;;
		*) fail "platform must be simulator or device" ;;
	esac
}

test_simulator()
{
	require_tool sips
	local selector="${1:-$DEFAULT_SIMULATOR}"
	local seconds="${2:-45}"
	[[ "$seconds" =~ ^[0-9]+$ ]] || fail "test duration must be a whole number of seconds"
	local simulator
	simulator="$(resolve_simulator "$selector")"
	install_app simulator "$simulator"
	mkdir -p "$LOG_DIR"
	xcrun simctl launch --terminate-running-process --console "$simulator" "$BUNDLE_ID" \
		> "$LOG_DIR/debugger.log" 2>&1 &
	local console_pid=$!
	sleep "$seconds"
	xcrun simctl io "$simulator" screenshot "$LOG_DIR/skeleton.png"
	xcrun simctl spawn "$simulator" log show --last 2m --style compact \
		--predicate 'process == "OpenTTD"' > "$LOG_DIR/simulator.log"
	xcrun simctl terminate "$simulator" "$BUNDLE_ID" || true
	wait "$console_pid" || true

	local width height
	width="$(sips -g pixelWidth "$LOG_DIR/skeleton.png" | awk '/pixelWidth/ {print $2}')"
	height="$(sips -g pixelHeight "$LOG_DIR/skeleton.png" | awk '/pixelHeight/ {print $2}')"
	if (( width < height )); then
		sips --rotate -90 "$LOG_DIR/skeleton.png" >/dev/null
	fi
	grep -Fq 'IOS_PROBE ENGINE revision=' "$LOG_DIR/simulator.log" || \
		fail "OpenTTD engine marker missing from simulator log"
	grep -Fq 'IOS_PROBE READY renderer=metal' "$LOG_DIR/simulator.log" || \
		fail "Metal readiness marker missing from simulator log"
	echo "Simulator probe passed; logs and screenshot are in $LOG_DIR"
}

test_device()
{
	local selector="${1:-$DEFAULT_DEVICE}"
	local seconds="${2:-45}"
	[[ "$seconds" =~ ^[0-9]+$ ]] || fail "test duration must be a whole number of seconds"
	install_app device "$selector"
	mkdir -p "$LOG_DIR"
	xcrun devicectl device process launch --terminate-existing --console \
		--device "$selector" "$BUNDLE_ID" > "$LOG_DIR/device-debugger.log" 2>&1 &
	local console_pid=$!
	sleep "$seconds"
	kill -INT "$console_pid" 2>/dev/null || true
	wait "$console_pid" || true
	grep -Fq 'IOS_PROBE ENGINE revision=' "$LOG_DIR/device-debugger.log" || \
		fail "OpenTTD engine marker missing from device console"
	grep -Fq 'IOS_PROBE READY renderer=metal' "$LOG_DIR/device-debugger.log" || \
		fail "Metal readiness marker missing from device console"
	echo "Device probe passed for $seconds seconds; console output is in $LOG_DIR/device-debugger.log"
}

archive_app()
{
	build_engine all
	generate_project
	xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath "$DERIVED_DATA" \
		-archivePath "$DERIVED_DATA/OpenTTD.xcarchive" -allowProvisioningUpdates archive
}

create_ipa()
{
	require_tool ditto
	require_tool zip
	local signing="$1"
	[[ "$signing" == signed || "$signing" == unsigned ]] || fail "IPA mode must be signed or unsigned"
	build_app device "" "$signing"
	local app
	app="$(app_path device)"
	local temporary
	temporary="$(mktemp -d "$DERIVED_DATA/IPA.XXXXXX")"
	mkdir -p "$temporary/Payload"
	ditto "$app" "$temporary/Payload/OpenTTD.app"
	local output="$DERIVED_DATA/OpenTTD-$signing.ipa"
	rm -f "$output"
	(cd "$temporary" && zip -qry "$output" Payload)
	rm -rf "$temporary"
	echo "Created $output"
}

require_tool xcodebuild
require_tool xcrun
mkdir -p "$DERIVED_DATA"

command="${1:-}"
case "$command" in
	engine)
		[[ $# -eq 2 ]] || { usage; exit 2; }
		build_engine "$2"
		;;
	test-host)
		[[ $# -eq 1 ]] || { usage; exit 2; }
		test_host
		;;
	generate)
		[[ $# -eq 1 ]] || { usage; exit 2; }
		build_engine all
		generate_project
		;;
	build|install|run)
		[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
		"${command//-/_}_app" "$2" "${3:-}"
		;;
	data-push)
		[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
		push_data "$2" "${3:-}"
		;;
	test-simulator)
		[[ $# -le 3 ]] || { usage; exit 2; }
		test_simulator "${2:-}" "${3:-45}"
		;;
	test-device)
		[[ $# -le 3 ]] || { usage; exit 2; }
		test_device "${2:-}" "${3:-45}"
		;;
	data-zip)
		[[ $# -eq 1 ]] || { usage; exit 2; }
		create_data_zip
		;;
	archive)
		[[ $# -eq 1 ]] || { usage; exit 2; }
		archive_app
		;;
	ipa)
		[[ $# -eq 2 ]] || { usage; exit 2; }
		create_ipa "$2"
		;;
	*)
		usage
		exit 2
		;;
esac
