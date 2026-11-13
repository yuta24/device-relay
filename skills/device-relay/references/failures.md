# Exit codes

| Code | Meaning | What to do |
| --- | --- | --- |
| 0 | Success | – |
| 1 | Local failure (runner.json unreadable, device in use, build failure, "already running" from `relay start --background`, `relay install` / `uninstall` failures, and so on; nothing was sent to the runner) | Read the reason in the JSON on stdout or the `relay:` line on stderr, and fix it |
| 2 | Usage error (unknown option, missing or invalid value, incompatible options, invalid session name, and so on). stderr gets only `relay: <error>` and `relay: see relay <command> --help` (no JSON, no stdout) | Fix the command. `relay <command> --help` |
| 3 | Can't reach the runner (no runner.json, can't connect, `no response within <seconds>s`) | For `no response within`, the runner is still working: wait for `busy` in `relay ping` to become `false` (`launch` / `terminate` wait up to 150 seconds, a long `type` 0.1 seconds per character, so give your own command a longer timeout). After a `launch` timeout, busy can last several more minutes, so if you started the runner yourself, `relay stop` and restarting is faster. Otherwise, `relay status`. No runner.json: `relay start --background …`. runner.json exists but doesn't answer (`relay start` was killed, for example): `relay stop` to clean up, then start. `the OS refused the connection`: relay is inside a sandbox ([Using relay from inside a sandbox](sandbox.md)), so neither stop nor start anything |
| 4 | Token rejected (401). runner.json is stale or belongs to another runner | Check the URL, device, and PID with `relay status`, and `--runner` / `--session` / `$RELAY_RUNNER` / `$RELAY_SESSION` / `~/.relay/runner.json`. If you started it yourself, `relay stop` and restart. Otherwise, ask the user without stopping it |
| 5 | Busy (409). Another command is running | Wait about a second, or retry once `relay ping` shows `"busy":false` |
| 6 | Action failed (422): element not found, not unique, disabled, or offscreen; SpringBoard covers the target (`covered_by_other_app`); an element in the share sheet can't be placed (`remote_view_position_unknown`); no keyboard focus; a field `relay type --clear` couldn't empty (`clear_failed`); an element `relay find --gone --require` waited for is still there (`element_still_present`); no app opens the URL of `relay open` (`open_failed`); `relay adjust` got an element that isn't a slider or wheel (`element_not_adjustable`) or ended elsewhere (`adjust_failed`); the app for `relay launch`, `relay open --bundle-id`, or `relay uninstall` isn't installed | Branch on `code` in the JSON on stdout ([List of codes](#list-of-codes) below). For element failures, read `reason` and `candidates`, observe again, and fix the selector |
| 7 | Request rejected (400 and other 4xx) | `point_offscreen`: the coordinates are off the screen (read `screen` in `relay health` again; rotating swaps width and height). `touch_mode_unavailable`: drop `--mode` and send it again. `invalid_request` and others: read the error text and fix it |
| 8 | Runner error (5xx and the like) | Retry once. If it persists, check `relay status` and the logs |

Runner commands always output JSON, exactly one object on stdout whether they succeed or fail (`--json` makes no difference). `relay:` lines on stderr are hints for people, so there is no need to merge them with `2>&1`. The exceptions are `relay screenshot` (one line with the saved path on success; with `-o -` the image is on stdout, so a failure's JSON goes to stderr) and usage errors (exit code 2, no JSON). Options can also be written `--opt=value`, such as `--port=8101`.

Failures on relay's side have the same JSON shape as the runner's: `runner_unavailable` and `runner_timeout` (exit code 3), `runner_info_invalid` and `screenshot_save_failed` (1), `app_not_installed` and `element_still_present` (6), `runner_bad_response` (8 and the like), and so on.

## When an action fails (exit code 6)

JSON goes to stdout (to stderr only for `relay screenshot -o -`).

```json
{"candidates":[…],"code":"element_ambiguous","count":2,"error":"2 elements match the selector; add conditions or an index","ok":false,"reason":"ambiguous"}
```

The `code`s of element failures are `element_not_found` (`notFound`, `indexOutOfRange`), `element_ambiguous` (`ambiguous`), `element_not_hittable` (`emptyFrame`, `offscreen`, `disabled`), `element_point_covered` (`pointCovered`), and `remote_view_position_unknown` (`positionUnknown`), with `reason` giving the detail.

| `reason` | Meaning | What to do |
| --- | --- | --- |
| `notFound` | No match | The screen hasn't changed yet → add `--timeout`. Wrong foreground app → `relay foreground`, `--bundle-id`. Wrong name → check the actual values with `relay find --type …` / `relay source` |
| `ambiguous` | Two or more match and there is no `--index` (returns at once, without waiting) | Look at `candidates` and add a condition such as `--type`, or `--index` |
| `indexOutOfRange` | `--index` is at or beyond the number of matches | Check the count with `relay find` |
| `emptyFrame` | The element's width or height is 0 | It isn't displayed. Observe the screen again |
| `offscreen` | The element is off the screen | Scroll with `relay swipe`, then look again |
| `disabled` | The element is `enabled: false` | A prerequisite input or step is missing. Check the screen |
| `pointCovered` | Hit testing identified an unrelated control in the snapshot at the touch point; nothing was sent. `hit` summarizes its type, label, and frame | Check `relay screenshot` / `relay source`, reveal the target, or use coordinates verified in the screenshot |
| `positionUnknown` | The element is inside the share sheet, and where it is on the screen can't be told; nothing was sent | Find it in `relay screenshot` and tap by coordinates |

If `relay type` / `relay key` report `no_keyboard_focus` (`no element has keyboard focus in <bundleId>`), tap the text field and send it again (the check takes 2–3 seconds).

### List of codes

Failure JSON is `{"ok":false,"code":"…","error":"…"}`. `code` is a string that doesn't change, so branch on it (the wording of `error` may change). A response without `code` is from an old runner.

| `code` | Exit code | What to do |
| --- | --- | --- |
| `invalid_request` | 7 | Read the error text and fix the value |
| `point_offscreen` | 7 | Read `screen` in `relay health` again and fix the coordinates |
| `touch_mode_unavailable` | 7 / 6 | Drop `--mode` and send it again |
| `http_malformed` / `request_too_large` | 7 / 8 | Doesn't happen through relay. Fix the client (curl or the like) |
| `unauthorized` | 4 | Same as exit code 4 above |
| `busy` | 5 | Wait and retry |
| `not_found` / `method_not_allowed` | 7 | Wrong path or method. If a relay command gets it, the runner is old, as for `relay adjust` with a runner from before it (if you started it yourself, `relay stop` and then `relay start --rebuild`) |
| `element_not_found` / `element_ambiguous` / `element_not_hittable` | 6 | The `reason` table above |
| `element_point_covered` | 6 | An unrelated control was confirmed at the touch point; nothing was sent. See `pointCovered` above |
| `no_keyboard_focus` | 6 | Tap the text field and send it again |
| `display_unknown` | 6 | The screen is dark. Check with the user |
| `window_position_unknown` | 6 | The iPad window's position is unknown. Reduce to one window, or use coordinates from a screenshot |
| `remote_view_position_unknown` | 6 | An element tap/press selected an element inside the share sheet whose frame can't be put on the screen; nothing was sent. Find it in `relay screenshot` and use `relay tap <x> <y>` |
| `covered_by_other_app` | 6 | An element tap/press found SpringBoard in front of the target app (a system alert, Control Center, …); nothing was sent. `foreground` and `alert` (the alert's question, or null) tell what covers it. Check with `relay screenshot` or `relay find --type alert --bundle-id com.apple.springboard`, close it, and send it again ([system-alerts](system-alerts.md)) |
| `touch_failed` | 6 / 8 | Retry once. If it persists, `relay status` and the logs |
| `clear_failed` | 6 | `relay type --clear` couldn't empty the field and typed nothing; `remaining` is the number of characters left. Check its `value` with `relay find`. Shorter than before: send `--clear` again (a field without select all loses up to 200 characters a time). Unchanged: the app puts the text back. Not checked on a physical device: there, a cursor in the middle may cause it ([Clearing a field](clear-and-gone.md#clearing-a-field)) |
| `typing_failed` | 6 / 8 | `relay type` / `relay key` did not finish typing in time (the runner gave up and is no longer busy). Some of the text may be in the field, and the rest may still arrive after the answer: check its `value` with `relay find`, clear it if needed, and send it again |
| `element_still_present` | 6 | `relay find --gone --require`: an element still matched when `--timeout` ran out (`count`, `elements`, and `gone:false` come with it). Wait longer (repeat `find --gone --timeout <s>`) or check with `relay screenshot`. After a tap meant to close it, the tap may have been ignored ([Waiting for an element to go](clear-and-gone.md#waiting-for-an-element-to-go)) |
| `open_failed` | 6 | `relay open` could not open the URL: no installed app handles its scheme, or the app named with `--bundle-id` could not open it. Check the scheme and that the app is installed; `--bundle-id <id>` sends the URL to that app whatever its scheme |
| `element_not_adjustable` | 6 | `relay adjust`: not a slider (`--position`) or a wheel (`--picker-value`); nothing changed. Check the type with `relay find`; pick a wheel with `--type pickerWheel`, not the `picker` / `datePicker` ([gestures-and-controls](gestures-and-controls.md)) |
| `adjust_failed` | 6 | `relay adjust` ended elsewhere: `value` (and `position`) is what it shows now, and it may have moved. A slider of steps stops only at steps (`0.6` → `0.5`); a value the wheel doesn't have fails, and `error` lists its values; `30` in February stops at `28`. On an iPad window, a thumb near the edge can't be grabbed ([gestures-and-controls](gestures-and-controls.md#ipad-windows)) |
| `xcui_failed` | 6 | Read the error text (XCUI's message) and observe the foreground app and the screen again |
| `app_not_installed` | 6 | relay decides before sending (the runner doesn't return it). Check the bundle ID (case-sensitive), or install the app with `relay install <path>`. From `relay uninstall`: nothing was removed |
| `app_bundle_invalid` | 1 | `relay install`: no such path, not an `.app` / `.ipa`, or no Info.plist with a bundle ID. Check the path |
| `app_platform_mismatch` | 1 | `relay install`: a simulator build for a device or the reverse; nothing was sent. Use the build for that kind of device |
| `app_install_failed` / `app_uninstall_failed` | 1 | `simctl` / `devicectl` failed or timed out (signing and provisioning errors included). Read `error` (the tool's reason); signing problems are for the user |
| `app_uninstall_refused` | 1 | `relay uninstall` of the runner's own app (`host`, `…RelayRunnerHost…`); nothing was removed. Removing it would stop the runner |
| `runner_bad_response` | 8 and the like | relay got an answer it can't read: not JSON (`status` holds the HTTP status), or no `cleared` / `gone` / `taps` for `type --clear` / `find --gone` / `tap --count 2` from a runner older than relay. For `--clear`, that runner typed after the old text instead of clearing, so don't retry: check the `value` with `relay find`. For `--count 2`, it tapped once, so don't retry either. If you started the runner, `relay stop`, then `relay start --rebuild` |
| `internal_error` | 8 | Retry once. If it persists, `relay status` and the logs |
| `device_unavailable` / `logs_unavailable` / `logs_permission_denied` / `logs_follow_unsupported` / `logs_filter_unsupported` / `log_app_unavailable` / `logs_save_failed` / `crashes_unavailable` / `crash_filter_unsupported` / `crashes_save_failed` | 1 | From `relay logs` / `relay crashes` ([logs](logs.md)). `device_unavailable` also from `relay install` / `uninstall`: the simulator isn't booted, or the device isn't connected |
