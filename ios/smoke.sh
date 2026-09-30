#!/usr/bin/env bash
# Non-interactive checks of the OpenTTD iOS port: host tests, Documents payload, app runtime markers.

set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
DERIVED_DATA="$REPO_ROOT/DerivedData"
LOG_DIR="$REPO_ROOT/log"
SOURCE_DIR="$REPO_ROOT/source"
BUILD="$IOS_DIR/build.sh"
BUNDLE_ID="com.example.openttd"
DEFAULT_SIMULATOR="iPad Air 11-inch (M4)"
HOST_TESTS="$DERIVED_DATA/OpenTTD-engine/host-tests"
SEED_DATA="$DERIVED_DATA/DataPackage/SeedData"
TIMGM6MB_SF2_SHA256="c5378b62028c920cb11e4803327983fee2f2cdff5dc89c708e39da417e51c854"
# iOS drivers with the base sets whose runtime markers are asserted.
APP_ARGS=(-s ios -S OpenSFX -M OpenMSX -d driver=1,misc=1)

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
Usage: $(script_name) <command> [options]

host
      Build the native Debug tree and run all upstream and port host tests (ctest).
data
      Stage the Documents payload; native OpenTTD must discover OpenGFX, OpenSFX and OpenMSX in it.
app   [simulator|device] [--simulator <name|UDID> | --device <name|UDID>] [--seconds <1-45>] [--no-build]
      Run the app and assert its engine, Documents, Metal, audio and MIDI markers. Default: simulator, 45 s
      Simulator runs of 15 s or more include a background/foreground cycle.
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

wait_for_text()
{
	local waited=0
	until grep -Fq "$2" "$1" 2>/dev/null; do
		kill -0 "$4" 2>/dev/null || return 1
		(( waited < $3 )) || return 1
		sleep 1
		waited=$((waited + 1))
	done
}

# The native Debug tree also provides the upstream `openttd` executable.
configure_host_tests()
{
	cmake -S "$SOURCE_DIR" -B "$HOST_TESTS" -G Ninja \
		-DCMAKE_BUILD_TYPE=Debug
}

# The script/savegame regressions need a usable base graphics set, as upstream CI provides.
smoke_host()
{
	require_tool cmake ctest ninja unzip
	configure_host_tests
	cmake --build "$HOST_TESTS" --target openttd_test openttd regression_files --parallel
	unzip -oqj "$REPO_ROOT/Data/opengfx-8.0-all.zip" '*.tar' -d "$HOST_TESTS/baseset"
	ctest --test-dir "$HOST_TESTS" --output-on-failure
}

smoke_data()
{
	require_tool cmake ditto ninja shasum
	"$BUILD" documents zip
	[[ ! -e "$SEED_DATA/OpenTTD" ]] || fail "staged data contains a forbidden OpenTTD wrapper directory"
	[[ -d "$SEED_DATA/save/autosave" ]] || fail "staged data is missing save/autosave"
	[[ -d "$SEED_DATA/scenario/heightmap" ]] || fail "staged data is missing scenario/heightmap"
	[[ "$(shasum -a 256 "$SEED_DATA/baseset/timgm6mb/TimGM6mb.sf2" | awk '{print $1}')" == "$TIMGM6MB_SF2_SHA256" ]] || \
		fail "staged TimGM6mb checksum mismatch"

	configure_host_tests
	cmake --build "$HOST_TESTS" --target openttd --parallel
	mkdir -p "$LOG_DIR"
	local temporary
	temporary="$(mktemp -d "$DERIVED_DATA/DataValidation.XXXXXX")"
	local validation_root="$temporary/Documents"
	ditto "$SEED_DATA" "$validation_root"
	"$HOST_TESTS/openttd" -X -x -c "$validation_root/openttd.cfg" -d misc=1 -h \
		> "$LOG_DIR/data-discovery.log" 2>&1
	grep -Fq 'OpenGFX' "$LOG_DIR/data-discovery.log" || fail "OpenGFX was not discovered"
	grep -Fq 'OpenSFX' "$LOG_DIR/data-discovery.log" || fail "OpenSFX was not discovered"
	grep -Fq 'OpenMSX' "$LOG_DIR/data-discovery.log" || fail "OpenMSX was not discovered"
	grep -Fq "$validation_root" "$LOG_DIR/data-discovery.log" || fail "the staged Documents root was not searched"
	rm -rf "$temporary"
	echo "Documents payload discovery passed; details are in log/data-discovery.log"
}

LOGS=()

require_marker()
{
	grep -Fq "$1" "${LOGS[@]}" || fail "runtime marker missing: $1"
}

# Both texts on one line.
require_markers()
{
	grep -hF "$1" "${LOGS[@]}" | grep -F "$2" >/dev/null || fail "runtime marker missing: $1 ... $2"
}

smoke_app()
{
	local platform=""
	local seconds=45
	local no_build=no
	local target_options=()
	local simulator_name="$DEFAULT_SIMULATOR"
	while [[ $# -gt 0 ]]; do
		case "$1" in
			simulator|device)
				[[ -z "$platform" ]] || usage_error "app takes a single target"
				platform="$1"
				target_options+=("$1")
				shift
				;;
			--simulator|--device)
				[[ $# -ge 2 ]] || usage_error "$1 needs a value"
				[[ -z "$platform" || "$platform" == "${1#--}" ]] || usage_error "$1 contradicts target $platform"
				platform="${1#--}"
				[[ "$1" == --device ]] || simulator_name="$2"
				target_options+=("$1" "$2")
				shift 2
				;;
			--seconds)
				[[ $# -ge 2 ]] || usage_error "--seconds needs a value"
				seconds="$2"
				shift 2
				;;
			--no-build) no_build=yes; shift ;;
			*) usage_error "app does not take $1" ;;
		esac
	done
	platform="${platform:-simulator}"
	[[ "$seconds" =~ ^[0-9]+$ ]] && (( 10#$seconds >= 1 && 10#$seconds <= 45 )) || usage_error "--seconds must be 1-45"
	seconds=$((10#$seconds))

	[[ "$no_build" == yes ]] || "$BUILD" install ${target_options[@]+"${target_options[@]}"}
	mkdir -p "$LOG_DIR"
	: > "$LOG_DIR/debugger.log"
	"$BUILD" run ${target_options[@]+"${target_options[@]}"} --seconds "$seconds" --label smoke \
		-- "${APP_ARGS[@]}" &
	local run_pid=$!

	local simulator=""
	if [[ "$platform" == simulator ]]; then
		simulator="$(resolve_simulator "$simulator_name")"
		if (( seconds >= 15 )) && wait_for_text "$LOG_DIR/debugger.log" 'IOS_ENGINE START revision=' 30 "$run_pid"; then
			sleep 10
			xcrun simctl launch "$simulator" com.apple.Preferences >/dev/null
			sleep 3
			xcrun simctl launch "$simulator" "$BUNDLE_ID" >/dev/null
		fi
	fi
	wait "$run_pid" || fail "the app run failed; see log/debugger.log"

	LOGS=("$LOG_DIR/debugger.log")
	[[ "$platform" != simulator ]] || LOGS+=("$LOG_DIR/smoke.log")
	require_marker 'IOS_ENGINE START revision='
	require_marker 'IOS_ENGINE DATA root='
	! grep -hF 'IOS_ENGINE DATA root=' "${LOGS[@]}" | grep -F '/Documents/OpenTTD' >/dev/null || \
		fail "the app used the forbidden Documents/OpenTTD wrapper"
	require_marker 'IOS_VIDEO READY renderer=metal'
	require_marker 'IOS_VIDEO PRESENT first_dirty='
	require_markers 'IOS_AUDIO READY rate=' 'sound_set=OpenSFX'
	require_marker 'IOS_AUDIO CALLBACK active=yes'
	require_markers 'IOS_MUSIC READY synth=midisynth' 'music_set=OpenMSX'
	require_marker 'IOS_MUSIC PLAY '
	require_marker 'IOS_MUSIC PLAYBACK active=yes'

	if [[ "$platform" == simulator ]]; then
		if (( seconds >= 15 )); then
			require_marker 'IOS_MUSIC LIFECYCLE background'
			require_marker 'IOS_MUSIC LIFECYCLE foreground'
		fi
		local documents
		documents="$(xcrun simctl get_app_container "$simulator" "$BUNDLE_ID" data)/Documents"
		[[ ! -e "$documents/OpenTTD" ]] || fail "the simulator contains the forbidden Documents/OpenTTD wrapper"
		local file
		for file in opengfx-8.0.tar opensfx-1.0.3.tar openmsx-0.4.2/openmsx.obm \
			timgm6mb/TimGM6mb.sf2 timgm6mb/LICENSE.txt timgm6mb/COPYING.md; do
			[[ -f "$documents/baseset/$file" ]] || fail "$file was not seeded into Documents/baseset"
		done
	fi
	echo "App smoke test passed on the $platform ($seconds s); evidence is in log/debugger.log and log/smoke.*"
}

command="${1:-}"
case "$command" in
	""|-h|--help)
		usage
		exit 0
		;;
	host|data)
		[[ $# -eq 1 ]] || usage_error "$command takes no arguments"
		"smoke_$command"
		;;
	app)
		shift
		for argument in "$@"; do
			[[ "$argument" != -h && "$argument" != --help ]] || { usage; exit 0; }
		done
		require_tool xcrun
		smoke_app "$@"
		;;
	*)
		usage >&2
		exit 1
		;;
esac
