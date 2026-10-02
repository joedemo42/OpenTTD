#!/usr/bin/env bash
# Builds the pinned iOS dependencies as static arm64 XCFrameworks in ios-deps/artifacts.

set -euo pipefail

DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DEPS_DIR/.." && pwd)"
SOURCE_ROOT="$DEPS_DIR/source"
BUILD_ROOT="$DEPS_DIR/build"
ARTIFACT_ROOT="$DEPS_DIR/artifacts"
PATCH_ROOT="$DEPS_DIR/patches"
PROBE_ROOT="$DEPS_DIR/probes"
IOS_MIN_VERSION="26.0"

# Build order: prerequisites first.
DEPENDENCIES="sdl3 zlib xz libpng lzo timgm6mb"
TIMGM6MB_SF2_SHA256="c5378b62028c920cb11e4803327983fee2f2cdff5dc89c708e39da417e51c854"

script_name()
{
	local path="$0"
	[[ "$path" != /* ]] || path="${path#"$PWD"/}"
	[[ "$path" != /* ]] || path="${path#"$REPO_ROOT"/}"
	printf '%s' "$path"
}

dependency_list()
{
	local dependency separator=" "
	for dependency in $DEPENDENCIES; do
		load_dependency "$dependency"
		printf '%s%s %s' "$separator" "$dependency" "$VERSION"
		separator=", "
	done
}

usage()
{
	cat <<EOF
Usage: $(script_name) <command> [args]

download   <all|dep>
           (Re-)download the pinned source archive into ios-deps/source/<dep>.
build      <all|dep> [simulator|device|both]
           Build static arm64 XCFrameworks and license texts into ios-deps/artifacts. Default: both
           Missing source is downloaded; a missing build dir is extracted and patched.
clean      <all|dep>
           Remove ios-deps/build/<dep> and the dependency's artifacts.
dist-clean <all|dep>
           clean, then remove ios-deps/source/<dep>.

Dependencies:$(dependency_list)
libpng links zlib; timgm6mb is SoundFont data (no slices).
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

# Sets VERSION, ARCHIVE, URL, SHA256, TOP_DIRECTORY, FRAMEWORK, LIBRARY and LICENSES for one dependency.
load_dependency()
{
	case "$1" in
		sdl3)
			VERSION="3.4.10"
			ARCHIVE="SDL3-$VERSION.tar.gz"
			URL="https://github.com/libsdl-org/SDL/releases/download/release-$VERSION/$ARCHIVE"
			SHA256="12b34280415ec8418c864408b93d008a20a6530687ee613d60bfbd20411f2785"
			TOP_DIRECTORY="SDL3-$VERSION"
			FRAMEWORK="SDL3"
			LIBRARY="libSDL3.a"
			LICENSES="LICENSE.txt"
			;;
		zlib)
			VERSION="1.3.2"
			ARCHIVE="zlib-$VERSION.tar.gz"
			URL="https://zlib.net/fossils/$ARCHIVE"
			SHA256="bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"
			TOP_DIRECTORY="zlib-$VERSION"
			FRAMEWORK="Zlib"
			LIBRARY="libz.a"
			LICENSES="LICENSE"
			;;
		xz)
			VERSION="5.8.3"
			ARCHIVE="xz-$VERSION.tar.gz"
			URL="https://github.com/tukaani-project/xz/releases/download/v$VERSION/$ARCHIVE"
			SHA256="3d3a1b973af218114f4f889bbaa2f4c037deaae0c8e815eec381c3d546b974a0"
			TOP_DIRECTORY="xz-$VERSION"
			FRAMEWORK="LibLZMA"
			LIBRARY="liblzma.a"
			LICENSES="COPYING COPYING.0BSD"
			;;
		libpng)
			VERSION="1.6.58"
			ARCHIVE="libpng-$VERSION.tar.gz"
			URL="https://download.sourceforge.net/libpng/$ARCHIVE"
			SHA256="8c9b05b675ca7301a458df2c2e46f26e1d41ff36b8863f8c33530bc58c2e6225"
			TOP_DIRECTORY="libpng-$VERSION"
			FRAMEWORK="LibPNG"
			LIBRARY="libpng16.a"
			LICENSES="LICENSE"
			;;
		lzo)
			VERSION="2.10"
			ARCHIVE="lzo-$VERSION.tar.gz"
			URL="https://www.oberhumer.com/opensource/lzo/download/$ARCHIVE"
			SHA256="c0f892943208266f9b6543b3ae308fab6284c5c90e627931446fb49b4221a072"
			TOP_DIRECTORY="lzo-$VERSION"
			FRAMEWORK="LZO"
			LIBRARY="liblzo2.a"
			LICENSES="COPYING"
			;;
		timgm6mb)
			VERSION="1.3"
			ARCHIVE="timgm6mb-soundfont_$VERSION.orig.tar.gz"
			URL="https://deb.debian.org/debian/pool/main/t/timgm6mb-soundfont/$ARCHIVE"
			SHA256="af8f3a00e416dfb262bcaa904a1c84df04a51b72bbc1313aed012bc754bdf99b"
			TOP_DIRECTORY="timgm6mb-soundfont_$VERSION"
			FRAMEWORK=""
			LIBRARY=""
			LICENSES=""
			;;
		*) return 1 ;;
	esac
}

sdks_for()
{
	case "$1" in
		simulator) echo iphonesimulator ;;
		device) echo iphoneos ;;
		both) echo iphoneos iphonesimulator ;;
		*) return 1 ;;
	esac
}

target_for()
{
	case "$*" in
		iphonesimulator) echo simulator ;;
		iphoneos) echo device ;;
		*) echo both ;;
	esac
}

slice_id()
{
	case "$1" in
		iphoneos) echo ios-arm64 ;;
		iphonesimulator) echo ios-arm64-simulator ;;
	esac
}

sha256_file()
{
	shasum -a 256 "$1" | awk '{print $1}'
}

artifact_path()
{
	if [[ "$1" == timgm6mb ]]; then
		echo "$ARTIFACT_ROOT/TimGM6mb"
	else
		echo "$ARTIFACT_ROOT/$FRAMEWORK.xcframework"
	fi
}

# Downloads the pinned archive unless a verified copy exists; "force" always downloads.
download_source()
{
	local dependency="$1"
	local mode="${2:-}"
	local directory="$SOURCE_ROOT/$dependency"
	local destination="$directory/$ARCHIVE"

	if [[ "$mode" != force && -f "$destination" && "$(sha256_file "$destination")" == "$SHA256" ]]; then
		echo "Using verified $ARCHIVE"
		return
	fi

	mkdir -p "$directory"
	local partial="$destination.partial"
	rm -f "$partial"
	echo "Downloading $URL"
	curl --fail --location --retry 3 --silent --show-error --output "$partial" "$URL"
	[[ "$(sha256_file "$partial")" == "$SHA256" ]] || fail "SHA-256 mismatch for $ARCHIVE"
	mv "$partial" "$destination"
	echo "Downloaded $destination"
}

patch_files()
{
	[[ -d "$PATCH_ROOT/$1" ]] || return 0
	find "$PATCH_ROOT/$1" -type f \( -name '*.patch' -o -name '*.diff' \) -print | sort
}

patch_fingerprint()
{
	local files=()
	local file
	while IFS= read -r file; do
		files+=("$file")
	done < <(patch_files "$1")
	if [[ ${#files[@]} -eq 0 ]]; then
		echo none
	else
		shasum -a 256 "${files[@]}" | awk '{print $1}' | shasum -a 256 | awk '{print $1}'
	fi
}

# Extracts and patches the source once. A build dir prepared from another archive or
# patch set is never reused or silently replaced.
prepare_source()
{
	local dependency="$1"
	local root="$BUILD_ROOT/$dependency"
	local source_directory="$root/src"
	local stamp="$root/source.stamp"
	local fingerprint
	fingerprint="$SHA256:$(patch_fingerprint "$dependency")"

	if [[ -d "$source_directory" ]]; then
		[[ -f "$stamp" && "$(<"$stamp")" == "$fingerprint" ]] || \
			fail "${root#"$REPO_ROOT"/} was prepared from another source or patch set; run: $(script_name) clean $dependency"
		echo "Using prepared $dependency source"
		return
	fi

	mkdir -p "$root"
	local extract_directory
	extract_directory="$(mktemp -d "$root/extract.XXXXXX")"
	tar -xf "$SOURCE_ROOT/$dependency/$ARCHIVE" -C "$extract_directory"
	[[ -d "$extract_directory/$TOP_DIRECTORY" ]] || fail "archive layout changed for $dependency"
	mv "$extract_directory/$TOP_DIRECTORY" "$source_directory"
	rmdir "$extract_directory"

	local patch_file
	while IFS= read -r patch_file; do
		echo "Applying $(basename "$patch_file")"
		patch --directory="$source_directory" --strip=1 --forward --input="$patch_file"
	done < <(patch_files "$dependency")

	printf '%s\n' "$fingerprint" > "$stamp"
}

cmake_ios_arguments()
{
	local sdk="$1"
	local install_prefix="$2"
	printf '%s\n' \
		-G Ninja \
		-DCMAKE_SYSTEM_NAME=iOS \
		-DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION" \
		-DCMAKE_C_COMPILER="$(xcrun --find clang)" \
		-DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$install_prefix" \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON
}

# Configures <dependency>'s <sdk> tree with the common iOS arguments plus the extra ones.
configure_sdk()
{
	local dependency="$1"
	local sdk="$2"
	shift 2
	local root="$BUILD_ROOT/$dependency"
	local arguments=()
	local argument
	while IFS= read -r argument; do
		arguments+=("$argument")
	done < <(cmake_ios_arguments "$sdk" "$root/install/$sdk")
	cmake -S "$root/src" -B "$root/$sdk" "${arguments[@]}" "$@"
}

build_sdl3_sdk()
{
	configure_sdk sdl3 "$1" \
		-DSDL_SHARED=OFF \
		-DSDL_STATIC=ON \
		-DSDL_CAMERA=OFF \
		-DSDL_DIALOG=OFF \
		-DSDL_GPU=OFF \
		-DSDL_HAPTIC=OFF \
		-DSDL_HIDAPI=OFF \
		-DSDL_JOYSTICK=OFF \
		-DSDL_OPENGL=OFF \
		-DSDL_OPENGLES=OFF \
		-DSDL_POWER=OFF \
		-DSDL_RENDER_GPU=OFF \
		-DSDL_RENDER_VULKAN=OFF \
		-DSDL_SENSOR=OFF \
		-DSDL_TEST_LIBRARY=OFF \
		-DSDL_TESTS=OFF \
		-DSDL_TRAY=OFF \
		-DSDL_VULKAN=OFF \
		-DSDL_EXAMPLES=OFF \
		-DSDL_INSTALL=ON \
		-DSDL_DISABLE_INSTALL_DOCS=ON
	cmake --build "$BUILD_ROOT/sdl3/$1" --target install --parallel
}

build_zlib_sdk()
{
	configure_sdk zlib "$1" \
		-DZLIB_BUILD_SHARED=OFF \
		-DZLIB_BUILD_STATIC=ON \
		-DZLIB_BUILD_TESTING=OFF
	cmake --build "$BUILD_ROOT/zlib/$1" --target install --parallel
}

build_xz_sdk()
{
	configure_sdk xz "$1" \
		-DBUILD_SHARED_LIBS=OFF \
		-DBUILD_TESTING=OFF \
		-DXZ_DOC=OFF \
		-DXZ_NLS=OFF \
		-DXZ_TOOL_LZMADEC=OFF \
		-DXZ_TOOL_LZMAINFO=OFF \
		-DXZ_TOOL_XZ=OFF \
		-DXZ_TOOL_XZDEC=OFF
	cmake --build "$BUILD_ROOT/xz/$1" --target install --parallel
}

# libpng must bind to the zlib slice built here, never to an SDK or host copy.
build_libpng_sdk()
{
	local zlib_prefix="$BUILD_ROOT/zlib/install/$1"
	configure_sdk libpng "$1" \
		-UPNG_EXECUTABLES \
		-DPNG_FRAMEWORK=OFF \
		-DPNG_SHARED=OFF \
		-DPNG_STATIC=ON \
		-DPNG_TESTS=OFF \
		-DPNG_TOOLS=OFF \
		-DZLIB_INCLUDE_DIR="$zlib_prefix/include" \
		-DZLIB_LIBRARY="$zlib_prefix/lib/libz.a" \
		-DZLIB_LIBRARY_RELEASE="$zlib_prefix/lib/libz.a" \
		-DZLIB_ROOT="$zlib_prefix" \
		-DZLIB_USE_STATIC_LIBS=ON
	cmake --build "$BUILD_ROOT/libpng/$1" --target install --parallel
	grep -Fq "$zlib_prefix/lib/libz.a" "$BUILD_ROOT/libpng/$1/CMakeCache.txt" || \
		fail "libpng $1 did not bind to the matching zlib slice"
}

# LZO 2.10 predates CMake 4: raise only its policy floor, build the static library
# target alone and stage the library plus public headers by hand.
build_lzo_sdk()
{
	local root="$BUILD_ROOT/lzo"
	local install_prefix="$root/install/$1"
	configure_sdk lzo "$1" \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		-DENABLE_SHARED=OFF \
		-DENABLE_STATIC=ON
	cmake --build "$root/$1" --target lzo_static_lib --parallel
	mkdir -p "$install_prefix/lib" "$install_prefix/include"
	cmake -E copy_if_different "$root/$1/liblzo2.a" "$install_prefix/lib/liblzo2.a"
	cmake -E copy_directory "$root/src/include/lzo" "$install_prefix/include/lzo"
}

# Compile/link probe against the installed slice; iOS find-root remapping is disabled
# for the explicit package paths inside each probe.
probe_sdk()
{
	local dependency="$1"
	local sdk="$2"
	local root="$BUILD_ROOT/$dependency"
	local install_prefix="$root/install/$sdk"
	local probe_build="$root/probe/$sdk"
	local extra=()
	case "$dependency" in
		sdl3) extra=(-DCMAKE_PREFIX_PATH="$install_prefix" -DDEPENDENCY_PACKAGE_DIR="$install_prefix/lib/cmake/SDL3") ;;
		zlib) extra=(-DCMAKE_PREFIX_PATH="$install_prefix" -DDEPENDENCY_PACKAGE_DIR="$install_prefix/lib/cmake/zlib") ;;
		xz) extra=(-DCMAKE_PREFIX_PATH="$install_prefix" -DDEPENDENCY_PACKAGE_DIR="$install_prefix/lib/cmake/liblzma") ;;
		libpng) extra=(-DLIBPNG_PREFIX="$install_prefix" -DZLIB_PREFIX="$BUILD_ROOT/zlib/install/$sdk") ;;
		lzo) extra=(-DLZO_PREFIX="$install_prefix") ;;
	esac
	local arguments=()
	local argument
	while IFS= read -r argument; do
		arguments+=("$argument")
	done < <(cmake_ios_arguments "$sdk" "$install_prefix")
	cmake -S "$PROBE_ROOT/$dependency" -B "$probe_build" "${arguments[@]}" "${extra[@]}"
	cmake --build "$probe_build" --parallel
	local probe_binary="$probe_build/dependency-probe.app/dependency-probe"
	[[ -f "$probe_binary" ]] || fail "$dependency $sdk probe binary was not produced"
	file "$probe_binary" | grep -q 'arm64' || fail "$dependency $sdk probe is not arm64"
}

has_slice()
{
	[[ -f "$1/Info.plist" ]] || return 1
	plutil -extract AvailableLibraries xml1 -o - "$1/Info.plist" | grep -Fq "<string>$(slice_id "$2")</string>"
}

# Packages every installed slice; an unchanged package is kept.
package_xcframework()
{
	local dependency="$1"
	local root="$BUILD_ROOT/$dependency"
	local output
	output="$(artifact_path "$dependency")"
	local arguments=()
	local current=yes
	local sdk
	for sdk in iphoneos iphonesimulator; do
		local library="$root/install/$sdk/lib/$LIBRARY"
		[[ -f "$library" ]] || continue
		arguments+=(-library "$library" -headers "$root/install/$sdk/include")
		# Compare the build-tree library: CMake's Apple install re-runs ranlib on every install.
		if ! has_slice "$output" "$sdk" || [[ "$root/$sdk/$LIBRARY" -nt "$output/Info.plist" ]]; then
			current=no
		fi
	done
	if [[ "$current" == yes ]]; then
		echo "Using packaged $(basename "$output")"
		return
	fi

	local staging="$root/$FRAMEWORK.xcframework"
	rm -rf "$staging"
	mkdir -p "$ARTIFACT_ROOT"
	xcodebuild -create-xcframework "${arguments[@]}" -output "$staging"
	rm -rf "$output"
	mv "$staging" "$output"
	plutil -lint "$output/Info.plist" >/dev/null
	echo "Created $output"
}

# The license texts the app bundle carries: ios-deps/artifacts/licenses/<dep>/.
stage_licenses()
{
	local dependency="$1"
	local output="$ARTIFACT_ROOT/licenses/$dependency"
	local file
	mkdir -p "$output"
	for file in $LICENSES; do
		[[ -s "$BUILD_ROOT/$dependency/src/$file" ]] || fail "$dependency license file $file is missing"
		cmake -E copy_if_different "$BUILD_ROOT/$dependency/src/$file" "$output/$file"
	done
}

build_library()
{
	local dependency="$1"
	shift
	local root="$BUILD_ROOT/$dependency"
	local sdk

	# Prerequisites first; loading them replaces the current dependency's settings.
	if [[ "$dependency" == libpng ]]; then
		local missing=()
		for sdk in "$@"; do
			[[ -f "$BUILD_ROOT/zlib/install/$sdk/lib/libz.a" ]] || missing+=("$sdk")
		done
		[[ ${#missing[@]} -eq 0 ]] || build_dependency zlib "${missing[@]}"
	fi

	load_dependency "$dependency"
	download_source "$dependency"
	prepare_source "$dependency"
	for sdk in "$@"; do
		"build_${dependency}_sdk" "$sdk"
		lipo -info "$root/install/$sdk/lib/$LIBRARY" | grep -q 'arm64' || \
			fail "$dependency $sdk archive is not arm64"
	done
	package_xcframework "$dependency"
	stage_licenses "$dependency"
	for sdk in "$@"; do
		probe_sdk "$dependency" "$sdk"
	done

	local output
	output="$(artifact_path "$dependency")"
	for sdk in "$@"; do
		has_slice "$output" "$sdk" || fail "$output lacks the $(slice_id "$sdk") slice"
	done
}

verify_timgm6mb()
{
	local output="$ARTIFACT_ROOT/TimGM6mb"
	[[ -f "$output/TimGM6mb.sf2" ]] || fail "TimGM6mb SoundFont was not staged"
	[[ "$(sha256_file "$output/TimGM6mb.sf2")" == "$TIMGM6MB_SF2_SHA256" ]] || fail "TimGM6mb SoundFont SHA-256 mismatch"
	[[ -s "$output/LICENSE.txt" ]] || fail "TimGM6mb copyright notice was not staged"
	[[ -s "$output/COPYING.md" ]] || fail "TimGM6mb GPL-2 license was not staged"
}

# The SoundFont is platform-neutral data: staged with its notice and the GPL-2 text.
build_timgm6mb()
{
	load_dependency timgm6mb
	download_source timgm6mb
	prepare_source timgm6mb

	local root="$BUILD_ROOT/timgm6mb"
	local output="$ARTIFACT_ROOT/TimGM6mb"
	local license_notice="$DEPS_DIR/licenses/TimGM6mb.txt"
	local gpl_text="$REPO_ROOT/source/COPYING.md"
	local fingerprint
	fingerprint="$SHA256:$TIMGM6MB_SF2_SHA256:$(sha256_file "$license_notice"):$(sha256_file "$gpl_text")"
	if [[ -f "$output/artifact.stamp" && "$(<"$output/artifact.stamp")" == "$fingerprint" ]]; then
		verify_timgm6mb
		echo "Using staged TimGM6mb SoundFont"
		return
	fi

	local staging="$root/TimGM6mb.staging"
	rm -rf "$staging"
	mkdir -p "$staging" "$ARTIFACT_ROOT"
	cp "$root/src/TimGM6mb.sf2" "$staging/"
	cp "$license_notice" "$staging/LICENSE.txt"
	cp "$gpl_text" "$staging/COPYING.md"
	printf '%s\n' "$fingerprint" > "$staging/artifact.stamp"
	rm -rf "$output"
	mv "$staging" "$output"
	verify_timgm6mb
	echo "Created $output"
}

build_dependency()
{
	local dependency="$1"
	shift
	echo "== $dependency ($(target_for "$@"))"
	if [[ "$dependency" == timgm6mb ]]; then
		build_timgm6mb
	else
		build_library "$dependency" "$@"
	fi
}

clean_dependency()
{
	load_dependency "$1"
	rm -rf "$BUILD_ROOT/$1" "$(artifact_path "$1")" "$ARTIFACT_ROOT/licenses/$1"
	echo "Cleaned $1"
}

selected_dependencies()
{
	if [[ "$1" == all ]]; then
		echo "$DEPENDENCIES"
	elif load_dependency "$1"; then
		echo "$1"
	else
		usage_error "unknown dependency: $1"
	fi
}

command="${1:-}"
case "$command" in
	""|-h|--help)
		usage
		exit 0
		;;
	download)
		[[ $# -eq 2 ]] || usage_error "download takes <all|dep>"
		dependencies="$(selected_dependencies "$2")"
		require_tool curl shasum
		for dependency in $dependencies; do
			load_dependency "$dependency"
			download_source "$dependency" force
		done
		;;
	build)
		[[ $# -eq 2 || $# -eq 3 ]] || usage_error "build takes <all|dep> [simulator|device|both]"
		sdks="$(sdks_for "${3:-both}")" || usage_error "unknown target: $3"
		dependencies="$(selected_dependencies "$2")"
		require_tool cmake ninja curl shasum tar patch lipo file plutil xcodebuild xcrun
		for dependency in $dependencies; do
			build_dependency "$dependency" $sdks
		done
		;;
	clean|dist-clean)
		[[ $# -eq 2 ]] || usage_error "$command takes <all|dep>"
		dependencies="$(selected_dependencies "$2")"
		for dependency in $dependencies; do
			clean_dependency "$dependency"
			if [[ "$command" == dist-clean ]]; then
				rm -rf "${SOURCE_ROOT:?}/$dependency"
				echo "Removed downloaded $dependency source"
			fi
		done
		;;
	*)
		usage >&2
		exit 1
		;;
esac
