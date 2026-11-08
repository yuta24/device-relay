#!/bin/bash
# Build unsigned release packages, then check them outside the checkout.
# package.sh archives tracked content from HEAD; commit source changes before testing their packaging.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [ "$#" -eq 0 ]; then
	set -- "$(uname -m)"
fi
for arch in "$@"; do
	case "$arch" in
	arm64 | x86_64) ;;
	*) echo "usage: bash scripts/package-smoke.sh [arm64|x86_64 ...]" >&2; exit 2 ;;
	esac
done

version=$(sed -n 's/^ *static let current = "\(.*\)"$/\1/p' Sources/Relay/Setup/RunnerInstall.swift)
[ -n "$version" ] || { echo "cannot determine RelayVersion.current" >&2; exit 1; }
name="device-relay-v$version"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Require every tracked Runner/skill/document file, not just the top-level directories.
git ls-tree -r --name-only HEAD -- Runner skills LICENSE README.md README.ja.md >"$work/required"
for arch in "$@"; do
	# Clear signing inputs even if invoked from a developer's signing environment.
	env -u RELAY_CODESIGN_IDENTITY -u RELAY_CODESIGN_KEYCHAIN bash scripts/package.sh "$version" "$arch"
	archive="$name-macos-$arch.tar.gz"
	stage="$work/$arch extracted package"
	mkdir -p "$stage"
	cp "dist/$archive" "dist/$archive.sha256" "$stage/"
	(
		cd "$stage"
		shasum -a 256 -c "$archive.sha256"
		# The archive must have one expected top-level directory.
		tar -tzf "$archive" | awk -v prefix="$name/" 'index($0, prefix) != 1 { exit 1 }'
		tar -xzf "$archive"
	)
	package="$stage/$name"
	while IFS= read -r path; do
		[ -f "$package/$path" ] || { echo "$arch: missing $path" >&2; exit 1; }
		git show "HEAD:$path" | cmp - "$package/$path"
	done <"$work/required"

	# Shared sources sit outside Runner/ but must be present for its Xcode project to compile.
	sed -n -E 's/.*path = "?\.\.\/([^";]+)"?;.*/\1/p' \
		"$package/Runner/RelayRunner.xcodeproj/project.pbxproj" | sort -u >"$work/shared"
	[ -s "$work/shared" ] || { echo "$arch: no shared source references" >&2; exit 1; }
	while IFS= read -r path; do
		[ -f "$package/$path" ] || { echo "$arch: missing shared source $path" >&2; exit 1; }
		git show "HEAD:$path" | cmp - "$package/$path"
	done <"$work/shared"
	[ -x "$package/bin/relay" ]
	[ "$(lipo -archs "$package/bin/relay")" = "$arch" ]
	for unwanted in .git .build .relay; do
		[ ! -e "$package/$unwanted" ]
	done
	if [ "$arch" = "$(uname -m)" ]; then
		(
			cd "$stage"
			[ "$("$package/bin/relay" --version)" = "relay $version" ]
			"$package/bin/relay" --help >help.txt
			grep -q 'Usage:' help.txt
		)
		echo "$arch: package contents, checksum, architecture, version and help passed"
	else
		echo "$arch: package contents, checksum and architecture passed (runtime check requires a native host)"
	fi
done
