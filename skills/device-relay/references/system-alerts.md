# System permission dialogs

Location and notification permission dialogs were checked in Maps on an iPhone 17 Pro simulator (iOS 27.2, relay 0.6.0). While a dialog is open, `relay foreground` returns `com.apple.springboard` with `source: private`. Without `--bundle-id`, `relay find --type alert` finds the dialog and its `label` contains the question, such as `Allow “Maps” to use your location?`. `relay source --format compact --filter interactive` returns only the dialog's buttons.

## Wait, inspect, and dismiss

1. Wait for the dialog with `relay find --type alert --bundle-id com.apple.springboard --timeout 5`. Use a timeout up to 10 seconds; repeat short waits if needed. Confirm that the result has a match (`count` is not zero) and read the question before choosing a response. Without `--require`, no match still exits 0.
2. Read the buttons with `relay source --format compact --filter interactive`, without the underlying app's `--bundle-id`.
3. Copy the chosen button's label exactly and dismiss the dialog with `relay tap --label …`. For example, `relay tap --label "Allow While Using App"` succeeded in about 0.5 seconds and the foreground app returned to Maps.
4. Observe again before continuing in the app.

Labels are exact matches. `Don’t Allow` contains `’` (U+2019); `relay tap --label "Don't Allow"` with ASCII `'` matched nothing. Use the values from `find` / `source` as they are, rather than retyping or normalizing punctuation.

## Targeting pitfalls

- While the dialog is open, don't pass the underlying app's bundle ID to `source`, `find`, or `tap`. With `--bundle-id com.apple.Maps`, the filtered tree returned buttons behind the dialog; tapping one returned `ok: true` and exit code 0 but did nothing, and the dialog remained open.
- Without `--bundle-id`, a selector request chooses the foreground app once at the start. It does not choose again while waiting with `--timeout`. If Maps is foreground when `relay find --type alert --timeout 5` starts, a system dialog that appears during the wait will not be found. Explicitly target `com.apple.springboard` when waiting for an upcoming dialog, as in step 1.
- Waits hold the busy gate. Send one command at a time; other commands get busy (exit code 5) until the wait finishes.
