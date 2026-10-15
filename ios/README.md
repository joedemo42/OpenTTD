# OpenTTD for iOS and iPadOS

A native arm64 port for iOS/iPadOS 18 or later: SDL3 with its Metal renderer, CoreText, an SDL3 sound driver, a native MIDI synthesizer and an NSURLSession HTTP backend. All dependencies are static; the app links only system frameworks.

## Prerequisites

- Apple silicon Mac with Xcode 26 or later (iOS 26 SDK) and its command line tools.
- Host tools: CMake, Ninja, XcodeGen, curl, git (e.g. from Homebrew; nothing is linked against them).
- A device build signs with automatic signing for team `XXXXXXXXXX`; change `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml` for another team.

## Sources and data

Neither is tracked in this repository:

- `source/`: an OpenTTD clone on the port's `openttd-ios` branch, checked out at the commit in `SOURCES.lock` (the branch is based on the upstream commit recorded there).
- `Data/`: the base sets as released by openttd.org, unmodified:

  | File | SHA-256 |
  | --- | --- |
  | `opengfx-8.0-all.zip` | `43a0c1dabf39cb865394f3a6cc36d4da5c10ecfaaf55652043104806810903be` |
  | `opensfx-1.0.3-all.zip` | `e0a218b7dd9438e701503b0f84c25a97c1c11b7c2f025323fb19d6db16ef3759` |
  | `openmsx-0.4.2-all.zip` | `5a4277a2e62d87f2952ea5020dc20fb2f6ffafdccf9913fbf35ad45ee30ec762` |

The pinned dependency sources (SDL3, zlib, xz, libpng, LZO, TimGM6mb) are downloaded and verified by `ios-deps/build-deps.sh` on first use.

## Build, run, package

`./build-ios.sh --help` lists every command. Typical use:

```
./build-ios.sh build both                     # dependencies, engine and app (debug), simulator + device
./build-ios.sh install && ./build-ios.sh run  # iPad Air 11-inch (M4) simulator, 45 s, logs in log/
./build-ios.sh build device --release
./build-ios.sh install --device OldPad --release
./build-ios.sh ipa --release                  # DerivedData/ipa/OpenTTD.ipa
./build-ios.sh upload --release --notes "…"   # archive/ + repo server, dSYM kept in archive/
./build-ios.sh documents zip                  # Documents payload for manual transfer
```

## TestFlight

`ios/testflight.sh upload` re-signs the current release device build (`./build-ios.sh build device --release`) for App Store distribution and uploads it with its dSYM through the Apple ID signed in to Xcode. The app declares its encryption exempt (`ITSAppUsesNonExemptEncryption = NO`). The App Store Connect app record, TestFlight test information, external groups and public links are set up on the App Store Connect website.

Builds are incremental; `ios/BUILD_NUMBER` counts every build and is never reset.

## Checks

`ios/smoke.sh` runs the non-interactive checks: `host` (upstream and port host tests), `data` (base sets are found in the Documents payload), `app` (runtime markers of every subsystem), `multiplayer` (a simulator client joins a local server), `lifecycle` (background save, crash files) and `archive` (IPA, dSYM and Documents.zip audit).

## On the device

- Documents is visible in the Files app and in Finder: saves, screenshots, configuration, downloaded content and crash files (`crash*.json.log`, `crash*.sav`, `crash*.png`).
- Entering the background saves the configuration and the running game (next rotating autosave), because iOS may end a suspended app without notice.
- Crash reports from iOS (`.ips`) are symbolicated with the release build's `archive/OpenTTD-<version>-<build>.dSYM.zip`.
