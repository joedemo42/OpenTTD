#!/usr/bin/env bash
# Entry point for the iOS port: dispatches to ios-deps/build-deps.sh and ios/build.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS="$ROOT/ios-deps/build-deps.sh"
APP="$ROOT/ios/build.sh"

usage()
{
	local name="$0"
	[[ "$name" != /* ]] || name="${name#"$PWD"/}"
	[[ "$name" != /* ]] || name="$(basename "$name")"
	cat <<EOF
Usage: $name <command> [args] [options]

deps <command> [args]                        → ios-deps/build-deps.sh (same syntax)
  download   <all|dep>                        (re-)download source → ios-deps/source
  build      <all|dep> [simulator|device|both]  XCFrameworks → ios-deps/artifacts. Default: both
  clean      <all|dep>                        remove ios-deps/build/<dep> + artifacts
  dist-clean <all|dep>                        clean + remove ios-deps/source/<dep>
build|install|run|ipa|upload|documents       → ios/build.sh (same syntax)
  build      [simulator|device|both]          deps, engine, app; build number +1. Default: simulator
  install    [target]                         install the current build
  run        [target] [--seconds <1-45>] [--label <name>] [-- <app args>]
                                              run the installed build (45 s); logs + screenshot → log/
  ipa        [--unsigned]                     current device build → IPA in DerivedData/ipa
  upload     [--notes <text>|--notes-file <path>]
                                              signed IPA + release notes → archive/ → repo server
  documents  zip | install [target]           Documents payload → ZIP | installed app
clean [app|deps|all]                         app: DerivedData, deps: every dependency. Default: app

Target: [simulator|device|both] | --simulator <name|UDID> | --device <name|UDID>. Default: simulator
Configuration: --release (optimized, stripped, dSYM) for build, install, run, ipa, upload. Default: debug
Details: $name deps --help, $name build --help
EOF
}

case "${1:-}" in
	""|-h|--help)
		usage
		exit 0
		;;
	deps)
		shift
		exec "$DEPS" "$@"
		;;
	build|install|run|ipa|upload|documents)
		exec "$APP" "$@"
		;;
	clean)
		[[ $# -le 2 ]] || { usage >&2; exit 1; }
		case "${2:-app}" in
			app) exec "$APP" clean ;;
			deps) exec "$DEPS" clean all ;;
			all)
				"$APP" clean
				exec "$DEPS" clean all
				;;
			*)
				usage >&2
				exit 1
				;;
		esac
		;;
	*)
		usage >&2
		exit 1
		;;
esac
