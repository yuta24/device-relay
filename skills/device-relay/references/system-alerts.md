# System permission dialogs

Location and notification permission dialogs were checked in Maps on an iPhone 17 Pro simulator (iOS 27.2, relay 0.6.0). While a dialog is open, `relay foreground` returns `com.apple.springboard` with `source: private`. Without `--bundle-id`, `relay find --type alert` finds the dialog and its `label` contains the question, such as `Allow “Maps” to use your location?`. `relay source --format compact --filter interactive` returns only the dialog's buttons.

## Wait, inspect, and dismiss

1. Wait for the dialog with `relay find --type alert --bundle-id com.apple.springboard --timeout 5`. Use a timeout up to 10 seconds; repeat short waits if needed. Confirm that the result has a match (`count` is not zero) and read the question before choosing a response. Without `--require`, no match still exits 0.
2. Read the buttons with `relay source --format compact --filter interactive`, without the underlying app's `--bundle-id`.
3. Copy the chosen button's label exactly and dismiss the dialog with `relay tap --label …`. For example, `relay tap --label "Allow While Using App"` succeeded in about 0.5 seconds and the foreground app returned to Maps.
4. Observe again before continuing in the app.

Labels are exact matches. `Don’t Allow` contains `’` (U+2019); `relay tap --label "Don't Allow"` with ASCII `'` matched nothing. Use the values from `find` / `source` as they are, rather than retyping or normalizing punctuation.

## Targeting pitfalls

- While the dialog is open, don't pass the underlying app's bundle ID to `source`, `find`, or `tap`. With `--bundle-id com.apple.Maps`, `find` and `source` return the elements behind the dialog. An element `tap` / `press` on one sends nothing and exits 6 with `code` `covered_by_other_app`; `alert` in the JSON holds the dialog's question (null for Control Center or Notification Center), and `foreground` is `com.apple.springboard`. Older runners sent the touch: it did nothing, or pressed the dialog's button at the same place, with `ok: true`.
- On `covered_by_other_app`, look with `relay screenshot` or `relay find --type alert --bundle-id com.apple.springboard`, deal with what covers the app, then send the tap again. Taps right after the dialog closes go through (the runner waits up to 0.4 s for the app to come back).
- Without `--bundle-id`, a selector request chooses the foreground app once at the start. It does not choose again while waiting with `--timeout`. If Maps is foreground when `relay find --type alert --timeout 5` starts, a system dialog that appears during the wait will not be found (a `tap` that finds the element behind the dialog gets `covered_by_other_app`). Explicitly target `com.apple.springboard` when waiting for an upcoming dialog, as in step 1.
- `SFSafariViewController` and `ASWebAuthenticationSession` pages are drawn by `com.apple.SafariViewService`: target it (`relay tap --id Close --bundle-id com.apple.SafariViewService`); their elements aren't in the app's tree. Those taps aren't refused, but the "… Wants to Use … to Sign In" prompt before a sign-in page is SpringBoard's and covers like any alert.
- Not caught: coordinate taps and swipes (no target app), a notification banner over the element (the tap hits the banner), and a dialog's button tapped right as it appears (about 0.2 s; the tap is ignored with `ok: true`), so wait a moment after `find` sees the dialog.
- `relay open <url>`: no "Open in “…”?" confirmation appeared on an iPhone 17 simulator (iOS 27.2) for `https://`, custom schemes, `sms:`, or `maps://`, nor on an iPhone 14 Pro (iOS 26.7.1) for `https://`, `App-prefs:`, or `--bundle-id` (other apps' custom schemes untested there). If one appears, it is SpringBoard's: wait for it with `relay find --type alert --bundle-id com.apple.springboard --timeout 5` and tap the button with `relay tap --label … --bundle-id com.apple.springboard`.
- Waits hold the busy gate. Send one command at a time; other commands get busy (exit code 5) until the wait finishes.
