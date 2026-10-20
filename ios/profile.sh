#!/usr/bin/env bash
# Profiles the OpenTTD iOS release build on a device: CPU per thread, memory, thermal state, frame statistics.

set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
LOG_DIR="$REPO_ROOT/log"
PROFILE_DIR="$LOG_DIR/profile"
BUILD="$IOS_DIR/build.sh"
BUILD_CONFIG="$REPO_ROOT/build.config"
DEFAULT_DEVICE="OldPad"
DEFAULT_SIMULATOR="iPad Air 11-inch (M4)"
WARM_UP=10

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

run <title|idle|busy> [--device <name|UDID>] [--seconds <5-25>] [--label <name>]
      Profile the installed current release build with an isolated configuration: $WARM_UP s after the first
      frame, xctrace (Time Profiler, Activity Monitor, Thermal State) records --seconds (default 20) while the
      app logs frame statistics. → log/profile/<label>.{trace,txt}; label default: the scenario
      title: title screen; idle: new 256x256 game, seed 1; busy: log/profile/busy.sav. Default device: $DEFAULT_DEVICE
busy-save [--simulator <name|UDID>]
      Create log/profile/busy.sav with the installed current simulator build: 1024x1024 game, seed 1,
      viewport zoomed out 4x. Default simulator: $DEFAULT_SIMULATOR
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

run_app_pid()
{
	sed -nE 's/.*OpenTTD\[([0-9]+):.*/\1/p' "$LOG_DIR/debugger.log" | head -n 1
}

# The isolated configuration and the busy savegame go to Documents/.profile/ (hidden from the game's lists).
# CoreDevice cannot delete files; later runs overwrite them.
STAGE_DIRECTORY=""

cleanup_stage()
{
	if [[ "$STAGE_DIRECTORY" == "$REPO_ROOT/DerivedData/ProfileStage."* ]]; then
		rm -rf -- "$STAGE_DIRECTORY"
	fi
	STAGE_DIRECTORY=""
}

copy_to_device()
{
	local attempt
	for attempt in 1 2 3; do
		xcrun devicectl device copy to --device "$1" --source "$2" --destination "Documents/.profile/${2##*/}" \
			--domain-type appDataContainer --domain-identifier "$BUNDLE_ID" >/dev/null 2>&1 && return 0
		sleep 5
	done
	fail "could not copy ${2##*/} to $1"
}

# Summarizes the trace exports and the frame statistics logged while recording.
summarize()
{
	local trace="$1" started="$2" ended="$3" seconds="$4"
	local exports="$STAGE_DIRECTORY/exports"
	mkdir -p "$exports"
	local schema
	for schema in time-profile activity-monitor-process-live device-thermal-state-intervals; do
		xcrun xctrace export --input "$trace" \
			--xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" > "$exports/$schema.xml" 2>/dev/null || true
	done
	python3 - "$exports" "$seconds" "$LOG_DIR/debugger.log" "$started" "$ended" <<'PYTHON'
import collections, os, re, sys, xml.etree.ElementTree as ET
from datetime import datetime

exports, seconds, debugger, started, ended = sys.argv[1], float(sys.argv[2]), sys.argv[3], int(sys.argv[4]), int(sys.argv[5])

def rows(schema):
    """Rows of an exported table as {mnemonic: (fmt, text)}, resolving xctrace's id/ref sharing."""
    path = os.path.join(exports, schema + '.xml')
    if not os.path.getsize(path):
        return []
    root = ET.parse(path).getroot()
    columns = [c.findtext('mnemonic') for c in root.iter('col')]
    shared, result = {}, []
    def value(element):
        if 'ref' in element.attrib:
            return shared.get(element.attrib['ref'], ('', ''))
        fmt = element.attrib.get('fmt', element.text or '')
        if 'id' in element.attrib:
            shared[element.attrib['id']] = (fmt, element.text or '')
        for child in element:
            value(child)
        return (fmt, element.text or '')
    for row in root.iter('row'):
        result.append({column: value(element) for column, element in zip(columns, list(row))})
    return result

print(f'Recorded {seconds:.0f} s')

threads = collections.Counter()
for row in rows('time-profile'):
    thread = re.sub(r'\s*\(OpenTTD, pid: \d+\)$', '', row.get('thread', ('?', ''))[0]).strip() or '?'
    threads[thread] += int(row.get('weight', ('', '0'))[1] or 0)
total = sum(threads.values())
print(f'CPU (Time Profiler samples): {total / 1e7 / seconds:.1f} % of one core')
for thread, weight in threads.most_common(8):
    print(f'  {weight / 1e7 / seconds:5.1f} %  {thread}')

live = [row for row in rows('activity-monitor-process-live') if 'OpenTTD' in row.get('process', ('', ''))[0]]
if live:
    def numbers(key):
        return [float(row[key][1]) for row in live if key in row and re.fullmatch(r'[0-9.]+', row[key][1] or '')]
    columns = sorted(live[0].keys())
    cpu = next((c for c in columns if 'cpu' in c and 'percent' in c), None)
    footprint = next((c for c in columns if 'footprint' in c), None)
    if cpu and numbers(cpu):
        print(f'Process CPU (Activity Monitor): mean {sum(numbers(cpu)) / len(numbers(cpu)):.1f} %, max {max(numbers(cpu)):.1f} %')
    if footprint and numbers(footprint):
        print(f'Memory footprint: max {max(numbers(footprint)) / 2**20:.0f} MiB')
    if not (cpu and footprint):
        print('Activity Monitor columns: ' + ', '.join(columns))

states = [row.get('thermal-state', row.get('state', ('?', '')))[0] for row in rows('device-thermal-state-intervals')]
print('Thermal state: ' + (', '.join(dict.fromkeys(states)) if states else 'not recorded'))

stats = []
for line in open(debugger, errors='replace'):
    match = re.match(r'\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] dbg: \[driver:2\] iOS video: (.*)', line)
    if match:
        when = datetime.strptime(match.group(1), '%Y-%m-%d %H:%M:%S').timestamp()
        if started + 9 <= when <= ended + 1:
            stats.append(match.group(2).strip())
print('Frame statistics (10 s windows while recording):')
for line in stats or ['  none logged']:
    print('  ' + line)
PYTHON
}

profile_run()
{
	local scenario="" device="$DEFAULT_DEVICE" seconds=20 label=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			title|idle|busy)
				[[ -z "$scenario" ]] || usage_error "run takes one scenario"
				scenario="$1"
				shift
				;;
			--device|--seconds|--label)
				[[ $# -ge 2 ]] || usage_error "$1 needs a value"
				case "$1" in
					--device) device="$2" ;;
					--seconds) seconds="$2" ;;
					--label) label="$2" ;;
				esac
				shift 2
				;;
			*) usage_error "run does not take $1" ;;
		esac
	done
	[[ -n "$scenario" ]] || usage_error "run needs a scenario: title, idle or busy"
	[[ "$seconds" =~ ^[0-9]+$ ]] && (( 10#$seconds >= 5 && 10#$seconds <= 25 )) || usage_error "--seconds must be 5-25"
	seconds=$((10#$seconds))
	label="${label:-$scenario}"
	[[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || usage_error "--label may only contain letters, digits, '.', '_' and '-'"
	require_tool python3 xcrun
	[[ "$scenario" != busy || -f "$PROFILE_DIR/busy.sav" ]] || fail "log/profile/busy.sav is missing; run: $(script_name) busy-save"

	mkdir -p "$PROFILE_DIR"
	trap cleanup_stage EXIT INT TERM
	STAGE_DIRECTORY="$(mktemp -d "$REPO_ROOT/DerivedData/ProfileStage.XXXXXX")"
	printf '%s\n' '[gui]' 'missing_strings_threshold = 255' '' '[version]' 'ini_version = 8' > "$STAGE_DIRECTORY/profile.cfg"
	copy_to_device "$device" "$STAGE_DIRECTORY/profile.cfg"
	local arguments=(-x -c .profile/profile.cfg -d driver=2)
	case "$scenario" in
		idle) arguments+=(-g -G 1) ;;
		busy)
			cp "$PROFILE_DIR/busy.sav" "$STAGE_DIRECTORY/busy.sav"
			copy_to_device "$device" "$STAGE_DIRECTORY/busy.sav"
			arguments+=(-g .profile/busy.sav)
			;;
	esac

	: > "$LOG_DIR/debugger.log"
	"$BUILD" run --device "$device" --release --seconds 45 --label "profile-$label" -- "${arguments[@]}" \
		> "$PROFILE_DIR/$label-run.out" 2>&1 &
	local run_pid=$!
	wait_for_text "$LOG_DIR/debugger.log" 'IOS_VIDEO PRESENT first_dirty=' 90 "$run_pid" || \
		fail "OpenTTD did not draw on $device; see log/profile/$label-run.out and log/debugger.log"
	sleep "$WARM_UP"

	local trace="$PROFILE_DIR/$label.trace"
	rm -rf "$trace"
	local started ended attempt
	for attempt in 1 2; do
		started="$(date +%s)"
		# By name: attaching by PID started failing with "Cannot find process" for running apps (and ended them).
		xcrun xctrace record --device "$device" --template 'Time Profiler' --instrument 'Activity Monitor' \
			--instrument 'Thermal State' --attach OpenTTD --time-limit "${seconds}s" --output "$trace" \
			> "$PROFILE_DIR/$label-xctrace.out" 2>&1 && break
		[[ "$attempt" == 1 ]] && kill -0 "$run_pid" 2>/dev/null || fail "xctrace failed; see log/profile/$label-xctrace.out"
		rm -rf "$trace"
	done
	ended="$(date +%s)"
	wait "$run_pid" || fail "the profiled run failed; see log/profile/$label-run.out"
	cp "$LOG_DIR/debugger.log" "$PROFILE_DIR/$label-debugger.log"

	{
		echo "Scenario $scenario on $device, $(grep -m 1 -o 'IOS_ENGINE START revision=[^ ]*' "$LOG_DIR/debugger.log" || true)"
		grep -m 1 -o 'IOS_VIDEO LAYOUT .*' "$LOG_DIR/debugger.log" || true
		summarize "$trace" "$started" "$ended" "$seconds"
	} | tee "$PROFILE_DIR/$label.txt"
	cleanup_stage
	trap - EXIT INT TERM
}

# A zoomed-out large map: the configuration sizes it, a temporary game_start.scr zooms out, and the
# background save on entering the background writes it.
busy_save()
{
	local simulator_name="$DEFAULT_SIMULATOR"
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--simulator)
				[[ $# -ge 2 ]] || usage_error "$1 needs a value"
				simulator_name="$2"
				shift 2
				;;
			*) usage_error "busy-save does not take $1" ;;
		esac
	done
	require_tool xcrun
	local simulator container
	simulator="$(xcrun simctl list devices available | grep -F "    $simulator_name (" | head -n 1 | \
		sed -E 's/.*\(([[:xdigit:]-]{36})\).*/\1/' || true)"
	[[ -n "$simulator" ]] || fail "available simulator not found: $simulator_name"
	container="$(xcrun simctl get_app_container "$simulator" "$BUNDLE_ID" data 2>/dev/null)" || \
		fail "OpenTTD is not installed on $simulator_name"
	local documents="$container/Documents"
	[[ ! -e "$documents/scripts/game_start.scr" ]] || fail "$simulator_name already has a scripts/game_start.scr"
	mkdir -p "$documents/.profile" "$documents/scripts" "$PROFILE_DIR"
	printf '%s\n' '[game_creation]' 'map_x = 10' 'map_y = 10' '' '[version]' 'ini_version = 8' > "$documents/.profile/busy.cfg"
	printf '%s\n' 'zoomto 4' > "$documents/scripts/game_start.scr"
	local cleanup="rm -f -- '$documents/scripts/game_start.scr'; rmdir -- '$documents/scripts' 2>/dev/null || true"
	trap "$cleanup" EXIT INT TERM

	: > "$LOG_DIR/debugger.log"
	"$BUILD" run --simulator "$simulator_name" --seconds 45 --label profile-busy-save -- \
		-x -c .profile/busy.cfg -g -G 1 -d sl=2 > "$PROFILE_DIR/busy-save-run.out" 2>&1 &
	local run_pid=$!
	wait_for_text "$LOG_DIR/debugger.log" 'IOS_VIDEO PRESENT first_dirty=' 30 "$run_pid" || fail "OpenTTD did not start"
	# World generation of 1024x1024 tiles takes about 15 s on an M4 simulator.
	sleep 30
	xcrun simctl launch "$simulator" com.apple.Preferences >/dev/null
	wait_for_text "$LOG_DIR/debugger.log" 'IOS_VIDEO LIFECYCLE saved game=yes' 30 "$run_pid" || \
		fail "the game was not saved on entering the background"
	kill -KILL "$(run_app_pid)"
	wait "$run_pid" || true
	local autosave
	autosave="$(sed -nE "s/.*Autosaving to '([^']+)'.*/\1/p" "$LOG_DIR/debugger.log" | tail -n 1)"
	[[ -f "$documents/save/autosave/$autosave" ]] || fail "the background autosave was not written"
	cp "$documents/save/autosave/$autosave" "$PROFILE_DIR/busy.sav"
	eval "$cleanup"
	trap - EXIT INT TERM
	echo "Created log/profile/busy.sav ($(( $(stat -f %z "$PROFILE_DIR/busy.sav") / 1024 )) KiB)"
}

command="${1:-}"
case "$command" in
	""|-h|--help)
		usage
		exit 0
		;;
	run|busy-save)
		shift
		for argument in "$@"; do
			[[ "$argument" != -h && "$argument" != --help ]] || { usage; exit 0; }
		done
		require_settings BUNDLE_ID
		if [[ "$command" == run ]]; then
			profile_run "$@"
		else
			busy_save "$@"
		fi
		;;
	*)
		usage >&2
		exit 1
		;;
esac
