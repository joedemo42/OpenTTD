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

usage()
{
	cat <<EOF
Usage: $(basename "$0") <command> [arguments]

Commands:
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

generate_project()
{
	require_tool xcodegen
	require_artifacts
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
	grep -Fq 'IOS_PROBE READY renderer=metal' "$LOG_DIR/device-debugger.log" || \
		fail "Metal readiness marker missing from device console"
	echo "Device probe passed for $seconds seconds; console output is in $LOG_DIR/device-debugger.log"
}

archive_app()
{
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
	generate)
		[[ $# -eq 1 ]] || { usage; exit 2; }
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
