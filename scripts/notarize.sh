#!/bin/bash
# Notarizes the signed binaries under a directory (one submission; scripts/package.sh --build-only puts them in
# dist/build/<arch>/relay). Fails unless Apple answers Accepted, and prints Apple's log when it can.
#
# A bare Mach-O can't be stapled, so nothing here changes the binaries: Gatekeeper looks the ticket up online.
#
#   NOTARY_KEY_PATH   the App Store Connect API key (.p8)
#   NOTARY_KEY_ID     its Key ID
#   NOTARY_ISSUER_ID  its Issuer ID
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
	echo "usage: scripts/notarize.sh <directory of signed binaries>" >&2
	exit 2
fi
: "${NOTARY_KEY_PATH:?notarize.sh: set NOTARY_KEY_PATH}"
: "${NOTARY_KEY_ID:?notarize.sh: set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER_ID:?notarize.sh: set NOTARY_ISSUER_ID}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Without the attributes, or the zip gets AppleDouble (._*) entries next to the binaries.
ditto -c -k --norsrc --noextattr --noqtn "$1" "$work/relay.zip"

auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

# With --wait, the exit code alone doesn't say Accepted: read the status as well, and require both.
code=0
xcrun notarytool submit "$work/relay.zip" "${auth[@]}" --wait --timeout 30m --output-format json \
	>"$work/result.json" || code=$?

field() {
	plutil -extract "$1" raw -o - "$work/result.json" 2>/dev/null || true
}
status=$(field status)
id=$(field id)
echo "notarytool: exit code $code, status '$status', submission '$id'"

if [ "$code" -eq 0 ] && [ "$status" = "Accepted" ]; then
	exit 0
fi

echo "notarize.sh: not accepted: $(field message)" >&2
if [ -n "$id" ]; then
	# There is no log yet while the submission is still in progress (a timeout), so this may fail as well.
	xcrun notarytool log "$id" "${auth[@]}" || echo "notarize.sh: no log for $id" >&2
fi
exit 1
