#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT="$SCRIPT_DIR/source"
BUILD_ROOT="$SCRIPT_DIR/build"
ARTIFACT_ROOT="$SCRIPT_DIR/artifacts"
PATCH_ROOT="$SCRIPT_DIR/patches"
PROBE_ROOT="$SCRIPT_DIR/probes"
IOS_MIN_VERSION="${IOS_MIN_VERSION:-26.0}"

readonly SDKS=(iphoneos iphonesimulator)
readonly DEPENDENCIES=(sdl3 zlib xz libpng lzo)

SDL3_VERSION="3.4.10"
SDL3_ARCHIVE="SDL3-${SDL3_VERSION}.tar.gz"
SDL3_URL="https://github.com/libsdl-org/SDL/releases/download/release-${SDL3_VERSION}/${SDL3_ARCHIVE}"
SDL3_SHA256="12b34280415ec8418c864408b93d008a20a6530687ee613d60bfbd20411f2785"

ZLIB_VERSION="1.3.2"
ZLIB_ARCHIVE="zlib-${ZLIB_VERSION}.tar.gz"
ZLIB_URL="https://zlib.net/fossils/${ZLIB_ARCHIVE}"
ZLIB_SHA256="bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"

XZ_VERSION="5.8.3"
XZ_ARCHIVE="xz-${XZ_VERSION}.tar.gz"
XZ_URL="https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/${XZ_ARCHIVE}"
XZ_SHA256="3d3a1b973af218114f4f889bbaa2f4c037deaae0c8e815eec381c3d546b974a0"

LIBPNG_VERSION="1.6.58"
LIBPNG_ARCHIVE="libpng-${LIBPNG_VERSION}.tar.gz"
LIBPNG_URL="https://download.sourceforge.net/libpng/${LIBPNG_ARCHIVE}"
LIBPNG_SHA256="8c9b05b675ca7301a458df2c2e46f26e1d41ff36b8863f8c33530bc58c2e6225"

LZO_VERSION="2.10"
LZO_ARCHIVE="lzo-${LZO_VERSION}.tar.gz"
LZO_URL="https://www.oberhumer.com/opensource/lzo/download/${LZO_ARCHIVE}"
LZO_SHA256="c0f892943208266f9b6543b3ae308fab6284c5c90e627931446fb49b4221a072"

usage()
{
	cat <<EOF
Usage: $(basename "$0") <command> [dependency]

Commands:
  build <name|all>  Incrementally build and package a dependency.
  verify <name|all> Re-run compile/link probes against installed slices.
  clean <name>      Remove only the named dependency's generated build/artifact data.
  list              List supported dependencies and pinned versions.

Environment:
  IOS_MIN_VERSION   Deployment target (default: 26.0).
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

sha256_file()
{
	shasum -a 256 "$1" | awk '{print $1}'
}

validate_dependency()
{
	local dependency="$1"
	local candidate
	for candidate in "${DEPENDENCIES[@]}"; do
		[[ "$candidate" == "$dependency" ]] && return 0
	done
	fail "unsupported dependency: $dependency"
}

download_archive()
{
	local filename="$1"
	local url="$2"
	local expected_sha="$3"
	local destination="$SOURCE_ROOT/$filename"

	mkdir -p "$SOURCE_ROOT"
	if [[ -f "$destination" ]] && [[ "$(sha256_file "$destination")" == "$expected_sha" ]]; then
		echo "Using verified $filename"
		return
	fi

	local partial="$destination.partial"
	rm -f "$partial"
	echo "Downloading $url"
	curl --fail --location --retry 3 --silent --show-error --output "$partial" "$url"
	[[ "$(sha256_file "$partial")" == "$expected_sha" ]] || fail "SHA-256 mismatch for $filename"
	mv "$partial" "$destination"
}

patch_fingerprint()
{
	local dependency="$1"
	local directory="$PATCH_ROOT/$dependency"
	if [[ ! -d "$directory" ]]; then
		echo none
		return
	fi

	local files=()
	while IFS= read -r file; do
		files+=("$file")
	done < <(find "$directory" -type f \( -name '*.patch' -o -name '*.diff' \) -print | sort)

	if [[ ${#files[@]} -eq 0 ]]; then
		echo none
		return
	fi

	shasum -a 256 "${files[@]}" | shasum -a 256 | awk '{print $1}'
}

prepare_source()
{
	local dependency="$1"
	local archive="$2"
	local archive_sha="$3"
	local top_directory="$4"
	local dependency_root="$BUILD_ROOT/$dependency"
	local source_directory="$dependency_root/src"
	local fingerprint="${archive_sha}:$(patch_fingerprint "$dependency")"
	local stamp="$dependency_root/source.stamp"

	if [[ -d "$source_directory" && -f "$stamp" && "$(<"$stamp")" == "$fingerprint" ]]; then
		echo "Using prepared $dependency source"
		return
	fi

	mkdir -p "$dependency_root"
	rm -rf "$source_directory"
	local extract_directory
	extract_directory="$(mktemp -d "$dependency_root/extract.XXXXXX")"
	tar -xf "$SOURCE_ROOT/$archive" -C "$extract_directory"
	[[ -d "$extract_directory/$top_directory" ]] || fail "archive layout changed for $dependency"
	mv "$extract_directory/$top_directory" "$source_directory"
	rmdir "$extract_directory"

	local patch_directory="$PATCH_ROOT/$dependency"
	if [[ -d "$patch_directory" ]]; then
		local patch_file
		while IFS= read -r patch_file; do
			echo "Applying $(basename "$patch_file")"
			patch --directory="$source_directory" --strip=1 --forward --input="$patch_file"
		done < <(find "$patch_directory" -type f \( -name '*.patch' -o -name '*.diff' \) -print | sort)
	fi

	printf '%s\n' "$fingerprint" > "$stamp"
}

cmake_ios_arguments()
{
	local sdk="$1"
	local install_prefix="$2"
	local sdk_path
	sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

	printf '%s\n' \
		-G Ninja \
		-DCMAKE_SYSTEM_NAME=iOS \
		-DCMAKE_OSX_SYSROOT="$sdk_path" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION" \
		-DCMAKE_C_COMPILER="$(xcrun --find clang)" \
		-DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$install_prefix" \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON
}

create_xcframework()
{
	local dependency="$1"
	local library_name="$2"
	local output_name="$3"
	local dependency_root="$BUILD_ROOT/$dependency"
	local output="$ARTIFACT_ROOT/$output_name.xcframework"
	local staging="$dependency_root/$output_name.xcframework"

	rm -rf "$staging"
	mkdir -p "$ARTIFACT_ROOT"
	xcodebuild -create-xcframework \
		-library "$dependency_root/install/iphoneos/lib/$library_name" \
		-headers "$dependency_root/install/iphoneos/include" \
		-library "$dependency_root/install/iphonesimulator/lib/$library_name" \
		-headers "$dependency_root/install/iphonesimulator/include" \
		-output "$staging"
	rm -rf "$output"
	mv "$staging" "$output"
	plutil -lint "$output/Info.plist" >/dev/null
	echo "Created $output"
}

probe_cmake_package()
{
	local dependency="$1"
	local package_directory_suffix="$2"
	local probe_directory_name="$3"
	local dependency_root="$BUILD_ROOT/$dependency"
	local sdk

	for sdk in "${SDKS[@]}"; do
		local install_prefix="$dependency_root/install/$sdk"
		local probe_build="$dependency_root/probe/$sdk"
		local arguments=()
		while IFS= read -r argument; do
			arguments+=("$argument")
		done < <(cmake_ios_arguments "$sdk" "$install_prefix")

		cmake -S "$PROBE_ROOT/$probe_directory_name" -B "$probe_build" \
			"${arguments[@]}" \
			-DCMAKE_PREFIX_PATH="$install_prefix" \
			-DDEPENDENCY_PACKAGE_DIR="$install_prefix/$package_directory_suffix"
		cmake --build "$probe_build" --parallel
		local probe_binary="$probe_build/dependency-probe.app/dependency-probe"
		[[ -f "$probe_binary" ]] || fail "$dependency $sdk probe binary was not produced"
		file "$probe_binary" | grep -q 'arm64' || fail "$dependency $sdk probe is not arm64"
	done
}

build_sdl3()
{
	download_archive "$SDL3_ARCHIVE" "$SDL3_URL" "$SDL3_SHA256"
	prepare_source sdl3 "$SDL3_ARCHIVE" "$SDL3_SHA256" "SDL3-$SDL3_VERSION"

	local sdk
	for sdk in "${SDKS[@]}"; do
		local dependency_root="$BUILD_ROOT/sdl3"
		local install_prefix="$dependency_root/install/$sdk"
		local build_directory="$dependency_root/$sdk"
		local arguments=()
		while IFS= read -r argument; do
			arguments+=("$argument")
		done < <(cmake_ios_arguments "$sdk" "$install_prefix")

		cmake -S "$dependency_root/src" -B "$build_directory" \
			"${arguments[@]}" \
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
		cmake --build "$build_directory" --target install --parallel
		lipo -info "$install_prefix/lib/libSDL3.a" | grep -q 'arm64' || fail "SDL3 $sdk archive is not arm64"
	done

	create_xcframework sdl3 libSDL3.a SDL3
	probe_sdl3
}

probe_sdl3()
{
	probe_cmake_package sdl3 lib/cmake/SDL3 sdl3
}

build_zlib()
{
	download_archive "$ZLIB_ARCHIVE" "$ZLIB_URL" "$ZLIB_SHA256"
	prepare_source zlib "$ZLIB_ARCHIVE" "$ZLIB_SHA256" "zlib-$ZLIB_VERSION"

	local sdk
	for sdk in "${SDKS[@]}"; do
		local dependency_root="$BUILD_ROOT/zlib"
		local install_prefix="$dependency_root/install/$sdk"
		local build_directory="$dependency_root/$sdk"
		local arguments=()
		while IFS= read -r argument; do
			arguments+=("$argument")
		done < <(cmake_ios_arguments "$sdk" "$install_prefix")

		cmake -S "$dependency_root/src" -B "$build_directory" \
			"${arguments[@]}" \
			-DZLIB_BUILD_SHARED=OFF \
			-DZLIB_BUILD_STATIC=ON \
			-DZLIB_BUILD_TESTING=OFF
		cmake --build "$build_directory" --target install --parallel
		lipo -info "$install_prefix/lib/libz.a" | grep -q 'arm64' || fail "zlib $sdk archive is not arm64"
	done

	create_xcframework zlib libz.a Zlib
	probe_zlib
}

probe_zlib()
{
	probe_cmake_package zlib lib/cmake/zlib zlib
}

build_xz()
{
	download_archive "$XZ_ARCHIVE" "$XZ_URL" "$XZ_SHA256"
	prepare_source xz "$XZ_ARCHIVE" "$XZ_SHA256" "xz-$XZ_VERSION"

	local sdk
	for sdk in "${SDKS[@]}"; do
		local dependency_root="$BUILD_ROOT/xz"
		local install_prefix="$dependency_root/install/$sdk"
		local build_directory="$dependency_root/$sdk"
		local arguments=()
		while IFS= read -r argument; do
			arguments+=("$argument")
		done < <(cmake_ios_arguments "$sdk" "$install_prefix")

		cmake -S "$dependency_root/src" -B "$build_directory" \
			"${arguments[@]}" \
			-DBUILD_SHARED_LIBS=OFF \
			-DBUILD_TESTING=OFF \
			-DXZ_DOC=OFF \
			-DXZ_NLS=OFF \
			-DXZ_TOOL_LZMADEC=OFF \
			-DXZ_TOOL_LZMAINFO=OFF \
			-DXZ_TOOL_XZ=OFF \
			-DXZ_TOOL_XZDEC=OFF
		cmake --build "$build_directory" --target install --parallel
		lipo -info "$install_prefix/lib/liblzma.a" | grep -q 'arm64' || fail "liblzma $sdk archive is not arm64"
	done

	create_xcframework xz liblzma.a LibLZMA
	probe_xz
}

probe_xz()
{
	probe_cmake_package xz lib/cmake/liblzma xz
}

build_libpng()
{
	[[ -f "$BUILD_ROOT/zlib/install/iphoneos/lib/libz.a" && \
		-f "$BUILD_ROOT/zlib/install/iphonesimulator/lib/libz.a" ]] || build_zlib
	download_archive "$LIBPNG_ARCHIVE" "$LIBPNG_URL" "$LIBPNG_SHA256"
	prepare_source libpng "$LIBPNG_ARCHIVE" "$LIBPNG_SHA256" "libpng-$LIBPNG_VERSION"

	local sdk
	for sdk in "${SDKS[@]}"; do
		local dependency_root="$BUILD_ROOT/libpng"
		local install_prefix="$dependency_root/install/$sdk"
		local build_directory="$dependency_root/$sdk"
		local zlib_prefix="$BUILD_ROOT/zlib/install/$sdk"
		local arguments=()
		while IFS= read -r argument; do
			arguments+=("$argument")
		done < <(cmake_ios_arguments "$sdk" "$install_prefix")

		cmake -S "$dependency_root/src" -B "$build_directory" \
			"${arguments[@]}" \
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
		cmake --build "$build_directory" --target install --parallel
		lipo -info "$install_prefix/lib/libpng16.a" | grep -q 'arm64' || fail "libpng $sdk archive is not arm64"
		grep -Fq "$zlib_prefix/lib/libz.a" "$build_directory/CMakeCache.txt" || fail "libpng $sdk did not bind to the matching zlib slice"
	done

	create_xcframework libpng libpng16.a LibPNG
	probe_libpng
}

probe_libpng()
{
	local sdk
	for sdk in "${SDKS[@]}"; do
		local dependency_root="$BUILD_ROOT/libpng"
		local install_prefix="$dependency_root/install/$sdk"
		local zlib_prefix="$BUILD_ROOT/zlib/install/$sdk"
		local probe_build="$dependency_root/probe/$sdk"
		local arguments=()
		while IFS= read -r argument; do
			arguments+=("$argument")
		done < <(cmake_ios_arguments "$sdk" "$install_prefix")

		cmake -S "$PROBE_ROOT/libpng" -B "$probe_build" \
			"${arguments[@]}" \
			-DLIBPNG_PREFIX="$install_prefix" \
			-DZLIB_PREFIX="$zlib_prefix"
		cmake --build "$probe_build" --parallel
		local probe_binary="$probe_build/dependency-probe.app/dependency-probe"
		[[ -f "$probe_binary" ]] || fail "libpng $sdk probe binary was not produced"
		file "$probe_binary" | grep -q 'arm64' || fail "libpng $sdk probe is not arm64"
	done
}

build_lzo()
{
	download_archive "$LZO_ARCHIVE" "$LZO_URL" "$LZO_SHA256"
	prepare_source lzo "$LZO_ARCHIVE" "$LZO_SHA256" "lzo-$LZO_VERSION"

	local sdk
	for sdk in "${SDKS[@]}"; do
		local dependency_root="$BUILD_ROOT/lzo"
		local install_prefix="$dependency_root/install/$sdk"
		local build_directory="$dependency_root/$sdk"
		local arguments=()
		while IFS= read -r argument; do
			arguments+=("$argument")
		done < <(cmake_ios_arguments "$sdk" "$install_prefix")

		cmake -S "$dependency_root/src" -B "$build_directory" \
			"${arguments[@]}" \
			-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
			-DENABLE_SHARED=OFF \
			-DENABLE_STATIC=ON
		cmake --build "$build_directory" --target lzo_static_lib --parallel
		mkdir -p "$install_prefix/lib" "$install_prefix/include"
		cmake -E copy_if_different "$build_directory/liblzo2.a" "$install_prefix/lib/liblzo2.a"
		cmake -E copy_directory "$dependency_root/src/include/lzo" "$install_prefix/include/lzo"
		lipo -info "$install_prefix/lib/liblzo2.a" | grep -q 'arm64' || fail "LZO $sdk archive is not arm64"
	done

	create_xcframework lzo liblzo2.a LZO
	probe_lzo
}

probe_lzo()
{
	local sdk
	for sdk in "${SDKS[@]}"; do
		local dependency_root="$BUILD_ROOT/lzo"
		local install_prefix="$dependency_root/install/$sdk"
		local probe_build="$dependency_root/probe/$sdk"
		local arguments=()
		while IFS= read -r argument; do
			arguments+=("$argument")
		done < <(cmake_ios_arguments "$sdk" "$install_prefix")

		cmake -S "$PROBE_ROOT/lzo" -B "$probe_build" \
			"${arguments[@]}" \
			-DLZO_PREFIX="$install_prefix"
		cmake --build "$probe_build" --parallel
		local probe_binary="$probe_build/dependency-probe.app/dependency-probe"
		[[ -f "$probe_binary" ]] || fail "LZO $sdk probe binary was not produced"
		file "$probe_binary" | grep -q 'arm64' || fail "LZO $sdk probe is not arm64"
	done
}

build_dependency()
{
	case "$1" in
		sdl3) build_sdl3 ;;
		zlib) build_zlib ;;
		xz) build_xz ;;
		libpng) build_libpng ;;
		lzo) build_lzo ;;
		*) fail "no builder for dependency: $1" ;;
	esac
}

verify_dependency()
{
	case "$1" in
		sdl3) probe_sdl3 ;;
		zlib) probe_zlib ;;
		xz) probe_xz ;;
		libpng) probe_libpng ;;
		lzo) probe_lzo ;;
		*) fail "no verifier for dependency: $1" ;;
	esac
}

run_for_selection()
{
	local action="$1"
	local selection="$2"
	if [[ "$selection" == all ]]; then
		local dependency
		for dependency in "${DEPENDENCIES[@]}"; do
			"${action}_dependency" "$dependency"
		done
	else
		validate_dependency "$selection"
		"${action}_dependency" "$selection"
	fi
}

require_tool awk
require_tool cmake
require_tool curl
require_tool file
require_tool lipo
require_tool ninja
require_tool patch
require_tool plutil
require_tool shasum
require_tool tar
require_tool xcodebuild
require_tool xcrun

mkdir -p "$SOURCE_ROOT" "$BUILD_ROOT" "$ARTIFACT_ROOT" "$PATCH_ROOT"

command="${1:-}"
case "$command" in
	build|verify)
		[[ $# -eq 2 ]] || { usage; exit 2; }
		run_for_selection "$command" "$2"
		;;
	clean)
		[[ $# -eq 2 ]] || { usage; exit 2; }
		validate_dependency "$2"
		rm -rf "$BUILD_ROOT/$2"
		case "$2" in
			sdl3) rm -rf "$ARTIFACT_ROOT/SDL3.xcframework" ;;
			zlib) rm -rf "$ARTIFACT_ROOT/Zlib.xcframework" ;;
			xz) rm -rf "$ARTIFACT_ROOT/LibLZMA.xcframework" ;;
			libpng) rm -rf "$ARTIFACT_ROOT/LibPNG.xcframework" ;;
			lzo) rm -rf "$ARTIFACT_ROOT/LZO.xcframework" ;;
		esac
		;;
	list)
		[[ $# -eq 1 ]] || { usage; exit 2; }
		echo "sdl3 $SDL3_VERSION"
		echo "zlib $ZLIB_VERSION"
		echo "xz $XZ_VERSION"
		echo "libpng $LIBPNG_VERSION"
		echo "lzo $LZO_VERSION"
		;;
	*)
		usage
		exit 2
		;;
esac
