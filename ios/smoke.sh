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
TIMGM6MB_SF2_SHA256="c5378b62028c920cb11e4803327983fee2f2cdff5dc89c708e39da417e51c854"
# iOS drivers with the base sets whose runtime markers are asserted.
APP_ARGS=(-s ios -S OpenSFX -M OpenMSX -d driver=1,misc=1,net=3)

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
      Current build's Documents.zip: native OpenTTD must discover OpenGFX, OpenSFX and OpenMSX in it.
app   [simulator|device] [--simulator <name|UDID> | --device <name|UDID>] [--seconds <1-45>]
      Run the app and assert its engine, Documents, Metal, audio and MIDI markers. Default: simulator, 45 s
      Uses the installed current build; simulator runs ≥ 15 s add a background/foreground cycle.
multiplayer [--simulator <name|UDID>] [--host <address>]
      A simulator client joins a temporary same-revision host server: map transfer and sync for 45 s.
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
	require_tool cmake ninja shasum unzip
	"$BUILD" documents zip
	local temporary
	temporary="$(mktemp -d "$DERIVED_DATA/DataValidation.XXXXXX")"
	local validation_root="$temporary/Documents"
	unzip -q "$DERIVED_DATA/ipa/Documents.zip" -d "$temporary"
	[[ ! -e "$validation_root/OpenTTD" ]] || fail "Documents.zip contains a forbidden OpenTTD wrapper directory"
	[[ -d "$validation_root/save/autosave" ]] || fail "Documents.zip is missing save/autosave"
	[[ -d "$validation_root/scenario/heightmap" ]] || fail "Documents.zip is missing scenario/heightmap"
	[[ "$(shasum -a 256 "$validation_root/baseset/timgm6mb/TimGM6mb.sf2" | awk '{print $1}')" == "$TIMGM6MB_SF2_SHA256" ]] || \
		fail "Documents.zip TimGM6mb checksum mismatch"

	configure_host_tests
	cmake --build "$HOST_TESTS" --target openttd --parallel
	mkdir -p "$LOG_DIR"
	"$HOST_TESTS/openttd" -X -x -c "$validation_root/openttd.cfg" -d misc=1 -h \
		> "$LOG_DIR/data-discovery.log" 2>&1
	grep -Fq 'OpenGFX' "$LOG_DIR/data-discovery.log" || fail "OpenGFX was not discovered"
	grep -Fq 'OpenSFX' "$LOG_DIR/data-discovery.log" || fail "OpenSFX was not discovered"
	grep -Fq 'OpenMSX' "$LOG_DIR/data-discovery.log" || fail "OpenMSX was not discovered"
	grep -Fq "$validation_root" "$LOG_DIR/data-discovery.log" || fail "the Documents.zip root was not searched"
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
			*) usage_error "app does not take $1" ;;
		esac
	done
	platform="${platform:-simulator}"
	[[ "$seconds" =~ ^[0-9]+$ ]] && (( 10#$seconds >= 1 && 10#$seconds <= 45 )) || usage_error "--seconds must be 1-45"
	seconds=$((10#$seconds))

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
	require_marker 'IOS_HTTP READY backend=nsurlsession tls=system'
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

MULTIPLAYER_SERVER_PID=""
MULTIPLAYER_TEST_ROOT=""
MULTIPLAYER_CLIENT_DIRECTORY=""
MULTIPLAYER_PRIVATE_WRITTEN=no

cleanup_multiplayer()
{
	if [[ -n "$MULTIPLAYER_SERVER_PID" ]] && kill -0 "$MULTIPLAYER_SERVER_PID" 2>/dev/null; then
		kill -TERM "$MULTIPLAYER_SERVER_PID" 2>/dev/null || true
		wait "$MULTIPLAYER_SERVER_PID" 2>/dev/null || true
	fi
	if [[ "$MULTIPLAYER_CLIENT_DIRECTORY" == */Documents/.m14-network-test.* ]]; then
		# The user's private.cfg goes back before the directory holding it is removed.
		local private_file="${MULTIPLAYER_CLIENT_DIRECTORY%/*}/private.cfg"
		if [[ -e "$MULTIPLAYER_CLIENT_DIRECTORY/user-private.cfg" ]]; then
			mv -f -- "$MULTIPLAYER_CLIENT_DIRECTORY/user-private.cfg" "$private_file"
		elif [[ "$MULTIPLAYER_PRIVATE_WRITTEN" == yes ]]; then
			rm -f -- "$private_file"
		fi
		rm -rf -- "$MULTIPLAYER_CLIENT_DIRECTORY"
	fi
	if [[ "$MULTIPLAYER_TEST_ROOT" == "$DERIVED_DATA/NetworkTest."* ]]; then
		rm -rf -- "$MULTIPLAYER_TEST_ROOT"
	fi
	MULTIPLAYER_SERVER_PID=""
	MULTIPLAYER_TEST_ROOT=""
	MULTIPLAYER_CLIENT_DIRECTORY=""
	MULTIPLAYER_PRIVATE_WRITTEN=no
}

# A simulator client joins a temporary native server of the same revision.
smoke_multiplayer()
{
	local simulator_name="$DEFAULT_SIMULATOR"
	local host_address=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--simulator|--host)
				[[ $# -ge 2 ]] || usage_error "$1 needs a value"
				if [[ "$1" == --host ]]; then
					host_address="$2"
				else
					simulator_name="$2"
				fi
				shift 2
				;;
			*) usage_error "multiplayer does not take $1" ;;
		esac
	done
	if [[ -z "$host_address" ]]; then
		host_address="$(ifconfig en0 2>/dev/null | awk '$1 == "inet" && $2 !~ /^127\./ { print $2; exit }' || true)"
	fi
	if [[ -z "$host_address" ]]; then
		host_address="$(ifconfig 2>/dev/null | awk '$1 == "inet" && $2 !~ /^(127\.|169\.254\.)/ { print $2; exit }' || true)"
	fi
	[[ "$host_address" =~ ^[[:xdigit:].:]+$ ]] || \
		fail "could not determine a host address reachable from the simulator; pass --host"

	require_tool cmake ninja
	configure_host_tests
	cmake --build "$HOST_TESTS" --target openttd --parallel

	local simulator container
	simulator="$(resolve_simulator "$simulator_name")"
	container="$(xcrun simctl get_app_container "$simulator" "$BUNDLE_ID" data 2>/dev/null)" || \
		fail "OpenTTD is not installed on $simulator_name"
	trap cleanup_multiplayer EXIT INT TERM
	MULTIPLAYER_TEST_ROOT="$(mktemp -d "$DERIVED_DATA/NetworkTest.XXXXXX")"
	MULTIPLAYER_CLIENT_DIRECTORY="$(mktemp -d "$container/Documents/.m14-network-test.XXXXXX")"
	local server_config="$MULTIPLAYER_TEST_ROOT/openttd.cfg"
	local client_config="$MULTIPLAYER_CLIENT_DIRECTORY/openttd.cfg"
	local port=39799

	# These minimal current-version configs isolate the test from the user's settings.
	printf '%s\n' \
		'[network]' \
		'server_name = "OpenTTD iOS M14 Test"' \
		'server_advertise = false' \
		'' \
		'[version]' \
		'ini_version = 8' > "$server_config"
	printf '%s\n' \
		'[gui]' \
		'missing_strings_threshold = 255' \
		'' \
		'[version]' \
		'ini_version = 8' > "$client_config"
	# With -c, OpenTTD still reads private.cfg (the client name) from Documents.
	local private_file="$container/Documents/private.cfg"
	if [[ -e "$private_file" ]]; then
		mv -- "$private_file" "$MULTIPLAYER_CLIENT_DIRECTORY/user-private.cfg"
	fi
	MULTIPLAYER_PRIVATE_WRITTEN=yes
	printf '%s\n' \
		'[network]' \
		'client_name = "iOS M14 Client"' \
		'participate_survey = no' \
		'use_relay_service = never' \
		'' \
		'[version]' \
		'ini_version = 8' > "$private_file"

	mkdir -p "$LOG_DIR"
	"$HOST_TESTS/openttd" -D "0.0.0.0:$port" -g -x -c "$server_config" -d net=9 \
		< /dev/null > "$LOG_DIR/multiplayer-server.log" 2>&1 &
	MULTIPLAYER_SERVER_PID=$!
	wait_for_text "$LOG_DIR/multiplayer-server.log" 'Map generated, starting game' 30 "$MULTIPLAYER_SERVER_PID" || \
		fail "the temporary multiplayer server did not start within 30 seconds"

	"$BUILD" run --simulator "$simulator_name" --seconds 45 --label multiplayer -- \
		-c "$client_config" -n "$host_address:$port" -s ios -S OpenSFX -M OpenMSX -d driver=1,misc=1,net=9 || \
		fail "the multiplayer client run failed; see log/debugger.log"
	cleanup_multiplayer
	trap - EXIT INT TERM

	local client_log="$LOG_DIR/debugger.log"
	local server_log="$LOG_DIR/multiplayer-server.log"
	grep -Fq 'Client::ReceiveServerMapBegin()' "$client_log" || fail "multiplayer map transfer did not begin"
	grep -Fq 'Client::ReceiveServerMapDone()' "$client_log" || fail "multiplayer map transfer did not complete"
	grep -Fq 'Client::status = ACTIVE' "$client_log" || fail "multiplayer client did not become active"
	local sync_count
	sync_count="$(grep -Fc 'Client::ReceiveServerSync()' "$client_log" || true)"
	(( sync_count >= 3 )) || fail "multiplayer client received fewer than three synchronization packets"
	! grep -Fiq 'sync error' "$client_log" || fail "multiplayer client reported a synchronization error"
	grep -Fq 'joined as iOS M14 Client' "$server_log" || fail "temporary server did not register the iOS client"
	echo "Multiplayer smoke test passed: map transfer and $sync_count sync packets in 45 s; evidence is in log/debugger.log and log/multiplayer*"
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
	app|multiplayer)
		shift
		for argument in "$@"; do
			[[ "$argument" != -h && "$argument" != --help ]] || { usage; exit 0; }
		done
		require_tool xcrun
		"smoke_$command" "$@"
		;;
	*)
		usage >&2
		exit 1
		;;
esac
