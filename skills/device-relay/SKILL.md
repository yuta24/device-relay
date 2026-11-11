---
name: device-relay
description: Drive iOS simulators and physical devices with the relay CLI (device-relay) to check how an app really behaves. It can launch apps, take screenshots to see the screen, read the element tree, and tap, long-press, swipe, and type, with nothing embedded in the app. Use when verifying an iOS app change on a simulator or device, when you need to know how a screen looks, when reproducing a UI bug, or when operating an iPhone app by touch or keyboard.
---

# device-relay

`relay` controls iOS simulators and physical devices from the Mac through a long-running XCTest runner; the target app needs no changes.
Details are in topic files under `references/` (index: [reference.md](reference.md)): read the one named here when the case comes up.

## Before you start

- If `command -v relay` finds nothing, ask the user to install it (`mise use -g github:yuta24/device-relay`, or the README). Don't install it yourself.
- Sandbox: if relay prints `Operation not permitted`, or `relay doctor` shows ✗ for `localhost` / `~/.relay`, the runner has not stopped; relay is inside a sandbox. Don't stop or restart anything; ask the user to run relay outside it, and don't edit their settings yourself ([sandbox](references/sandbox.md)). Call relay alone, not with `cd … &&`, `>`, or `$(…)`.
- Sessions: run `echo "$RELAY_SESSION"`. If it is empty and other agents may use relay, pick a name and pass `--session <name>` on every command; `export` doesn't carry over to the next command ([sessions](references/sessions.md#sessions)).

## Flow

```sh
relay status                                 # 0: a runner answers, use it. 3: none. 4: token rejected
relay devices                                # NAME, UDID, KIND, OS, STATE
relay start --background --device "<name>"   # or --udid; --os narrows. Note the pid: it prints
relay launch <bundle-id>                     # the app must already be installed
relay screenshot --scale 1                   # prints a path; read it as an image
relay source --format compact --filter interactive   # operable elements, one per line
relay find --type button                     # elements matching a selector (JSON)
relay tap --id <identifier>
relay find --id <next-screen element> --timeout 5 --require   # wait; exit 6 if it never appears
relay stop                                   # when done, if you started it
```

- The first start builds the runner for minutes: give it a long timeout (up to 30 min).
- `waiting for another relay start's build` is not a failure: wait. If start exits 1 because another start is starting on that port, wait for `relay status` to return 0 and use that runner.
- If start fails, read the log tail it prints before acting ([troubleshooting](references/troubleshooting.md)).

## Rules

- **Use a running runner as it is.** If `relay status` exits 0, someone else started it: don't stop it. `relay stop` also kills another person's foreground `relay start`, so stop only a runner you started, after checking its `pid` in `relay status` matches the one you noted.
- **Exit code 4: investigate, don't stop.** runner.json doesn't belong to the runner answering. Unless you started it, ask the user before stopping or restarting.
- **Name the device.** Without one, a connected physical device wins. Use a simulator from `relay devices` (`--device` / `--udid`) unless the user asked for a device.
- **Stay inside the target app.** Don't open Settings, Safari, Messages, etc. unless the task needs it. If you leave, `relay button home`, then `relay launch <bundle-id>`.
- **Start from a known state:** `relay button home` and `relay launch <bundle-id>` (`relay terminate` first for a fresh launch).
- **No passwords or personal data on your own.** Enter only what the user gave you, and secrets via stdin, never argv: `printf '%s' "$PASSWORD" | relay type --stdin`.
- **Nothing destructive on a physical device** (deleting data or apps, purchases, sending messages, changing settings, signing out) without the user's confirmation. Share its screenshots only as far as the task needs.
- **Clean up when the task is done:** after rotating, `relay orientation portrait`; leave the app on a sensible screen; then `relay stop` the runner you started, even if the user may ask for more (starting again is cheap). Never stop one you didn't start.

## Observe and operate

- `relay screenshot --scale 1`: 1 px = 1 pt, so pixels are tap coordinates. Plain `relay screenshot` (full resolution) only for small text.
- Pick selectors from `relay source --format compact --filter interactive` or `relay find`: a line's `type`, `label`, `id`, `value` are selectors. Use the whole tree only when needed ([formats](references/element-tree.md)).
- Prefer selectors (`--id`, else `--label` + `--type`) over coordinates. On `ambiguous`, add `--type` or `--index`.
- Coordinates are points from the top left (`relay tap x y`; `relay swipe x1 y1 x2 y2` to scroll).
- Text: tap the field, `relay type "text"` (`--key return` submits); `relay key return|delete|space`.
- Wait with `relay find <selector> --timeout <s>` (≤ 10 s, repeat for longer) or `tap --timeout`, never `sleep`, except to let a swipe's scroll stop ([scrolling](references/scrolling.md)).
- After the screen changes, observe again: don't reuse selectors, indexes, or coordinates.
- One command at a time; overlapping ones get busy (5).
- Permission dialogs: wait with `relay find --type alert --bundle-id com.apple.springboard --timeout 5`, tap the exact `label` from `find`/`source` ([system-alerts](references/system-alerts.md)).
- Right after `relay launch`, add `--bundle-id <id>` to `find` / `tap` / `type` / `source`, except for permission dialogs.

## Exit codes

- 0 ok. 1 local failure, nothing sent: read the reason. 2 usage: `relay <command> --help`.
- 3 no runner: for `no response within`, wait for `busy:false` in `relay ping`; for `the OS refused the connection`, see sandbox above.
- 4 token rejected: see Rules. 5 busy: wait a second, retry. 8 runner error: retry once, then `relay status`.
- 6 / 7: branch on `code` in the stdout JSON:
  - `element_not_found`: wait with `--timeout`, check `relay foreground`, check real values with `relay find --type …`
  - `element_ambiguous`: add `--type` or `--index` (waiting won't help)
  - `element_not_hittable`: `offscreen` → scroll; `disabled` → do the prior step; `emptyFrame` → observe again
  - `no_keyboard_focus`: tap the text field, resend
  - `covered_by_other_app`: an alert etc. covers the app: `relay screenshot`, close it, resend
  - `app_not_installed`: check the bundle ID (case-sensitive) or install the app
  - `point_offscreen` (7): re-read `screen` in `relay health`
  - others: [failures](references/failures.md), [list of codes](references/failures.md#list-of-codes)

## When a person is needed

Device asking for its passcode during automation mode (`Failed to initialize for UI testing`), Untrusted Developer, locked device, Local Network permission: tell the user what to do on the device, then start again. Don't work around it ([troubleshooting](references/troubleshooting.md)).

## More

Each file in `references/` stands alone; read only the one you need:

- [starting-and-stopping](references/starting-and-stopping.md): `start` options, which device, the app, doctor, `relay skill`
- [start-status-stop](references/start-status-stop.md): their output and exit codes
- [sessions](references/sessions.md): parallel sessions, runner.json lookup
- [sandbox](references/sandbox.md): `Operation not permitted`
- [commands](references/commands.md): options, timeouts, deep links (`open`)
- [element-tree](references/element-tree.md): `source` formats, selectors
- [failures](references/failures.md): all exit codes, `code`s, `reason`s
- [coordinates](references/coordinates.md): orientation, iPad windows, iPhone Duo
- [scrolling](references/scrolling.md): to an element off the screen
- [recording](references/recording.md): `relay record`
- [relay-run](references/relay-run.md): replaying confirmed steps
- [test-app](references/test-app.md): an app to try things on
- [troubleshooting](references/troubleshooting.md): start failures, prompts, logs
