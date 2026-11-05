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
set -euo pipefail

usage() {
	echo "usage: scripts/package.sh <version> <arm64|x86_64>   (the version without v, as in RelayVersion.current)" >&2
	exit 2
}

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

# Xcode's toolchain: another swift first in PATH (swiftly) may not match the Xcode SDK (see the Makefile).
swift=${SWIFT:-xcrun swift}
$swift build -c release --arch "$arch"
binary="$($swift build -c release --arch "$arch" --show-bin-path)/relay"

built=$(lipo -archs "$binary")
if [ "$built" != "$arch" ]; then
	echo "package.sh: $binary is for $built, not $arch" >&2
	exit 1
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
cp "$binary" "$stage/$name/bin/relay"

mkdir -p dist
rm -f "dist/$archive" "dist/$archive.sha256"
# COPYFILE_DISABLE: no AppleDouble (._*) entries. The owner in the archive is not this machine's user.
COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname wheel -czf "dist/$archive" -C "$stage" "$name"
# From inside dist/, so the file names the bare asset: shasum -c works next to the download, and mise, which
# downloads this file from the release, finds the line for the asset it verifies (with another name it would not).
(cd dist && shasum -a 256 "$archive" >"$archive.sha256")

echo "dist/$archive"
echo "dist/$archive.sha256"
