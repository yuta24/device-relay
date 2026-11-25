#!/bin/bash
# Builds the release tarballs of RelayVersion.current for arm64 and then x86_64 into dist/, the same way the
# release workflow does but not notarized, and unsigned unless RELAY_CODESIGN_IDENTITY is set (see scripts/package.sh).
#
#   SWIFT  the swift command to build with. Unset: xcrun swift, Xcode's toolchain (scripts/package.sh)
set -euo pipefail

# Any directory: the version comes from the checkout, and package.sh works from its own root.
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

version=$(sed -n 's/^ *static let current = "\(.*\)"$/\1/p' Sources/Relay/Setup/RunnerInstall.swift)
if [ -z "$version" ]; then
	echo "dist.sh: cannot read RelayVersion.current from Sources/Relay/Setup/RunnerInstall.swift" >&2
	exit 1
fi

scripts/package.sh "$version" arm64
scripts/package.sh "$version" x86_64
