# Build OpenTTD for iOS / iPadOS

You need an Apple silicon Mac with Xcode 26 or later and `brew install cmake ninja xcodegen`.

## 1. Code and base sets

```
git clone --branch openttd-ios https://github.com/joedemo42/OpenTTD
cd OpenTTD
mkdir -p Data
curl -L -o Data/opengfx-8.0-all.zip https://cdn.openttd.org/opengfx-releases/8.0/opengfx-8.0-all.zip
curl -L -o Data/opensfx-1.0.3-all.zip https://cdn.openttd.org/opensfx-releases/1.0.3/opensfx-1.0.3-all.zip
curl -L -o Data/openmsx-0.4.2-all.zip https://cdn.openttd.org/openmsx-releases/0.4.2/openmsx-0.4.2-all.zip
```

## 2. Settings

```
cp build.config.sample build.config
# App icon: 1024x1024 PNG without transparency, here OpenTTD's logo on white.
# The logo has transparent corners, and a direct PNG-to-PNG conversion keeps that transparency, so it goes through JPEG.
sips -s format jpeg media/openttd.1024.png --out /tmp/openttd-icon.jpg
sips -s format png /tmp/openttd-icon.jpg --out AppIcon.png
```

Then fill in `build.config`:

```
APP_NAME=OpenTTD
BUNDLE_ID=com.yourname.openttd
TEAM_ID=
ICON=AppIcon.png
REPO_SERVER_URL=
```

- `BUNDLE_ID`: any reverse-domain ID that is yours.
- `TEAM_ID`: only for device builds. It's your Apple Developer team ID: sign in to Xcode → Settings → Accounts with your Apple ID, then `defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier | grep -E 'teamID|teamName'` shows it. A free personal team works for your own devices (its profiles expire after 7 days).
- `REPO_SERVER_URL`: leave it empty.

## 3. Build and install

Simulator (pick a name from `xcrun simctl list devices available`):

```
./build-ios.sh build
./build-ios.sh install --simulator "iPad Air 11-inch (M4)"
open -a Simulator
```

Device (connected, trusted, with Developer Mode on):

```
./build-ios.sh build device --release
./build-ios.sh install --device "<device name>" --release
```

With a free personal team, trust it once on the device: Settings → General → VPN & Device Management → your Apple ID → Trust. Then start OpenTTD from the home screen.

The first build downloads and builds the dependencies and the engine, so it takes a while. Later builds are incremental. `./build-ios.sh --help` lists every command, and [README.md](README.md) has the details.
