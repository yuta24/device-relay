#!/bin/bash
# Builds relay for one architecture and packs what a user needs without building relay themselves:
# dist/device-relay-v<version>-macos-<arch>.tar.gz and its .sha256.
#
#   device-relay-v<version>/
#     bin/relay
#     Runner/         built by relay start on the user's Mac
#     Sources/relay/  only the files Runner's project compiles (path = ../Sources/relay/... in its pbxproj)
#     skills/
#     LICENSE README.md README.ja.md
#
# relay finds Runner/ from its own location (RunnerProject), so this layout has to keep bin/ next to it.
# The asset name and layout are what mise's github backend detects with no options (docs/development.md).
#
# Two steps, which the release workflow runs apart so that it can notarize between them:
#   --build-only  builds relay into dist/build/<arch>/relay, signed if RELAY_CODESIGN_IDENTITY is set
#   --pack-only   packs that binary as it is (rebuilding could replace the notarized binary)
#
#   RELAY_CODESIGN_IDENTITY  the identity for codesign, such as a certificate's SHA-1 hash. Unset: unsigned
#   RELAY_CODESIGN_KEYCHAIN  the keychain to find that identity in. Unset: the keychain search list
set -euo pipefail

usage() {
	echo "usage: scripts/package.sh [--build-only|--pack-only] <version> <arm64|x86_64>   (the version without v, as in RelayVersion.current)" >&2
	exit 2
}

mode=all
case "${1:-}" in
--build-only)
	mode=build
	shift
	;;
--pack-only)
	mode=pack
	shift
	;;
esac

[ "$#" -eq 2 ] || usage
version=$1
arch=$2
case "$arch" in
arm64 | x86_64) ;;
*) usage ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

current=$(sed -n 's/^ *static let current = "\(.*\)"$/\1/p' Sources/relay/RunnerInstall.swift)
if [ "$version" != "$current" ]; then
	echo "package.sh: version $version is not RelayVersion.current ($current)" >&2
	exit 1
fi

# The binary comes from the working tree and the rest from HEAD, so a dirty tree would mix the two.
if ! git diff --quiet HEAD --; then
	echo "package.sh: warning: uncommitted changes; relay is built with them, but the other files come from HEAD" >&2
fi

built_binary="dist/build/$arch/relay"

if [ "$mode" != pack ]; then
	# Xcode's toolchain: another swift first in PATH (swiftly) may not match the Xcode SDK (see the Makefile).
	swift=${SWIFT:-xcrun swift}
	$swift build -c release --arch "$arch"
	binary="$($swift build -c release --arch "$arch" --show-bin-path)/relay"

	rm -rf "dist/build/$arch"
	mkdir -p "dist/build/$arch"
	cp "$binary" "$built_binary"

	if [ -n "${RELAY_CODESIGN_IDENTITY:-}" ]; then
		# shellcheck disable=SC2086 # the expansion is either nothing or the option and its quoted value
		codesign --force --options runtime --timestamp --sign "$RELAY_CODESIGN_IDENTITY" \
			${RELAY_CODESIGN_KEYCHAIN:+--keychain "$RELAY_CODESIGN_KEYCHAIN"} "$built_binary"
		codesign --verify --strict --verbose=2 "$built_binary"
		# Only this line: the rest of --display shows the identity's name and the Team ID in a public log.
		code_directory=$(codesign --display --verbose=2 "$built_binary" 2>&1 | grep '^CodeDirectory ')
		echo "$code_directory"
		case "$code_directory" in
		*flags=*runtime*) ;;
		*)
			echo "package.sh: $built_binary is signed without the hardened runtime" >&2
			exit 1
			;;
		esac
	fi
fi

if [ ! -f "$built_binary" ]; then
	echo "package.sh: no $built_binary; run scripts/package.sh --build-only $version $arch first" >&2
	exit 1
fi
built=$(lipo -archs "$built_binary")
if [ "$built" != "$arch" ]; then
	echo "package.sh: $built_binary is for $built, not $arch" >&2
	exit 1
fi

if [ "$mode" = build ]; then
	echo "$built_binary"
	exit 0
fi

# Same reading of the project as CheckoutRunnerSource.referencedFiles.
shared=()
while IFS= read -r path; do
	shared+=("$path")
done < <(git show HEAD:Runner/RelayRunner.xcodeproj/project.pbxproj |
	sed -n -E 's/.*path = "?\.\.\/([^";]+)"?;.*/\1/p' | sort -u)
if [ "${#shared[@]}" -eq 0 ]; then
	echo "package.sh: no shared sources found in Runner's project; it would not build without them" >&2
	exit 1
fi

name="device-relay-v$version"
archive="$name-macos-$arch.tar.gz"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# git archive: tracked files only, so no xcuserdata or build output from this checkout.
git archive --format=tar --prefix="$name/" HEAD Runner skills LICENSE README.md README.ja.md "${shared[@]}" |
	tar -xf - -C "$stage"
mkdir -p "$stage/$name/bin"
cp "$built_binary" "$stage/$name/bin/relay"

mkdir -p dist
rm -f "dist/$archive" "dist/$archive.sha256"
# COPYFILE_DISABLE: no AppleDouble (._*) entries. The owner in the archive is not this machine's user.
COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname wheel -czf "dist/$archive" -C "$stage" "$name"
# From inside dist/, so the file names the bare asset: shasum -c works next to the download, and mise, which
# downloads this file from the release, finds the line for the asset it verifies (with another name it would not).
(cd dist && shasum -a 256 "$archive" >"$archive.sha256")

echo "dist/$archive"
echo "dist/$archive.sha256"
