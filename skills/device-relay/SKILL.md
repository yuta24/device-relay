---
name: device-relay
description: Drive iOS simulators and physical devices with the relay CLI (device-relay) to check how an app really behaves. It can launch apps, take screenshots to see the screen, read the element tree, and tap, long-press, swipe, and type, with nothing embedded in the app. Use when verifying an iOS app change on a simulator or device, when you need to know how a screen looks, when reproducing a UI bug, or when operating an iPhone app by touch or keyboard.
---

# device-relay

`relay` is a CLI that controls iOS simulators and physical devices from a Mac through a long-running XCTest runner. The target app needs no changes. It works from any directory (such as the target app's repository) and creates nothing there (the runner's URL and token go in `~/.relay/runner.json`, screenshots in `$TMPDIR/relay/`).

Option details, the element tree, what to do for each failure reason, and troubleshooting are in [reference.md](reference.md). For the full picture, see the device-relay README and the documents in docs/ (docs/ is in Japanese).

## Setup (first time only)

1. Check with `command -v relay`. If it is missing, ask the user to install it: `mise use -g github:yuta24/device-relay`, or the manual steps in the device-relay README. These write to the user's home directory, so don't run them without asking.
2. Check the environment with `relay doctor [--udid <UDID> | --device <name>] [--simulator] [--os <version>] [--json]` (given what you would pass to `relay start`, it checks that device). Any ✗ means exit code 1 (local failure), and each line says how to fix it. ! is a warning and does not block starting. A device another session is using appears on an `in use` line and is left out of automatic selection (✗ if you named it).
3. This skill itself is installed by `relay skill install` (copies it to `.claude/skills/device-relay` in the target app's repository; `--global` uses `~/.claude/skills`). If `relay skill status` shows ! (relay was updated and the skill is out of date), tell the user to update it with `relay skill install`. This rewrites files in the repository or home directory, so don't run it without asking.

### When running inside a sandbox

If the agent's shell runs inside a sandbox (Claude Code's sandbox, for example), `relay start` does not work (it can't write to `~/.relay` or DerivedData, can't connect to testmanagerd, and so on), and the runner commands can't connect to localhost either. If relay prints `the OS refused the connection (Operation not permitted)`, or `localhost` / `~/.relay` is ✗ in `relay doctor`, the runner has not stopped: relay is inside a sandbox. Don't `relay stop` or restart anything. Ask the user to configure relay to run outside the sandbox (in Claude Code, `"relay *"` in `sandbox.excludedCommands`; see [reference.md](reference.md#using-relay-from-inside-a-sandbox)). Don't rewrite settings files without asking. For the exclusion to take effect, call relay with one command at a time, not combined with `cd … &&`, redirection (`>`), or `$(…)`.

## Basic flow

```sh
relay status                                    # 0: answered (use it). 3: no runner, or no answer. 4: token rejected
relay devices                                   # list devices (NAME, UDID, KIND, OS, STATE)
relay start --background --device "<name>"      # or --udid <UDID> (--os <version> narrows it). Waits until ready, prints ready:/device:/pid:/log:/token: on stdout, exits 0
relay launch <bundle-id>                        # launch the target app or bring it to the foreground
relay screenshot --scale 1                      # prints the saved file's absolute path → read that file as an image (1 px = 1 pt)
relay source --format compact --filter interactive   # the elements you can operate, one per line
relay find --type button                        # the elements matching a selector (JSON)
relay tap --id <identifier>                     # operate by element
relay find --id <element on the next screen> --timeout 5 --require   # wait for it to appear (exit code 6 if it doesn't), then observe again
relay stop                                      # only if you started it yourself. stopped or not running, exit 0
```

- **Use a running runner as it is.** If `relay status` exits 0, the user or someone else has already started one. Use it, and don't stop it. If the runner in `~/.relay/runner.json` answers on the same port (`--port`, default 8100), `relay start --background` does not start anything and exits 1, pointing to `relay stop`; but `relay stop` also stops a foreground `relay start`, so stop only what you started yourself. If another `relay start` on the same port is still starting (booting or building), you also get exit code 1 with `another relay start ... is starting or running a runner on port ...`. In that case, wait for `relay status` to return 0 and use that runner.
- **If `relay status` returns 4, investigate before stopping anything.** The token in the runner.json it found doesn't belong to the runner answering at that address (another `relay start`'s runner is on the same port, runner.json is stale, or `--runner` / `$RELAY_RUNNER` / `~/.relay/runner.json` points elsewhere; `.relay/runner.json` in the current directory is not read). Unless you started it yourself, ask the user before running `relay stop` or restarting.
- **Choose between `status`, `ping`, and `health` by purpose.** `relay status` also looks at runner.json and `relay start` (PID, device, version), and is the check to run after starting (`--json` for machines). `relay ping` answers at once whether it is alive and `busy`, even during an operation. `relay health` gives what you need before operating (screen size and so on), and returns 409 (exit code 5) during an operation.
- **Remember your own runner.** Note the `pid:` that `relay start --background` prints, and when finishing, check that `pid` in `relay status` is the same before running `relay stop`.
- **Name the device explicitly.** Without `--udid` / `--device`, `relay start` picks the only connected physical device, else the only booted simulator, and otherwise fails with a list of candidates. A connected physical device is picked over a simulator, so unless the user asked for a physical device, pass a simulator chosen from `relay devices` with `--device` / `--udid` (to use a booted simulator, `--simulator` also leaves physical devices out). If several simulators share a name (different runtimes), `--device` picks the one with the newest iOS and shows its OS in `relay: using …`. If you need a specific iOS, narrow it with something like `--os 26.5`, or use `--udid`. A shut-down simulator you name is booted, and shut down again by `relay stop`.
- Progress of `relay start --background` (boot, build, launch) goes to `relay:` lines on stderr. The first run takes minutes to build the runner, so give the command a long timeout (it waits up to 30 minutes until launch, then `--ready-timeout` (default 180 seconds) + 15 seconds).
- If starting fails, it stops the child `relay start`, prints the end of the log and the cause (with the log's path) to stderr, and exits non-zero. The exit code is 1 if the child exited before ready (build failure, device not found, `Failed to initialize for UI testing`, and so on), 3 on timeout, and 1 if a runner already answers on the same port. Read the end of the log and, if needed, the log file (`~/.relay/logs/start-<time>-<port>.log`) before acting ([Troubleshooting](reference.md#troubleshooting)).
- The target app must already be installed on the device (build and install it the project's way: Xcode, `xcodebuild`, or `xcrun simctl install`). `relay launch` only launches or foregrounds; if the app isn't installed it sends nothing to the runner and exits 6 at once (`app_not_installed`).
- Find the bundle ID in the project's `PRODUCT_BUNDLE_IDENTIFIER`, or bring the app to the foreground and check with `relay foreground`.

### Using it in parallel

When other agents are using (or might use) relay, use sessions.

**First check with `echo "$RELAY_SESSION"`.** If the user passed it when launching the agent (`RELAY_SESSION=agent-1 claude`, for example), a value appears and every command uses that session, so just carry on. If it is empty, choose your own session name and add `--session <name>` to every relay command.

**Don't rely on `export`.** In environments that start a new shell for each command it does not carry over, and the next command runs without a session, so it either fails with exit code 3 or operates someone else's runner.

```sh
relay status --all                                                     # list every session (which devices are in use)
relay start --background --session agent-1 --device "<name>" --os 27.0  # one device per session. The port is automatic
relay tap --session agent-1 --id <id>                                  # reaches only your runner
relay stop --session agent-1                                           # stops only your session
```

- If you see `relay: warning: no session selected; using <path>, while sessions <names> are running`, that command ran without a session (it does not fail). If you meant to use your own runner, add `--session` and check which device that operation reached.
- Once a session is specified, relay never falls back to another runner.json. If it hasn't started yet, the exit code is 3. Having both `RELAY_SESSION` and `RELAY_RUNNER` set is a usage error, exit code 2.
- A device can run one runner. Naming a device in use fails with an error that names its owner, so choose another device. A session that names no device takes one free booted simulator, newest iOS first and then by name, and if another start takes it at the same moment, it picks the next. Don't stop other sessions' runners (don't use `relay stop --all` either).
- Builds of the same sources are shared. While another `relay start` is building, or launching a runner from the same build, relay prints `waiting for another relay start's build` and waits. That can take minutes until the earlier one is ready, but it isn't a failure, so wait rather than stopping or restarting.
- A session's port does not collide with other `relay start`s, but if another process takes it first, `relay start` fails to launch the runner (`Address already in use` in the log). Run `relay start` again and it picks the next free port.

## Observing

- **Normally use shrunk screenshots and filtered trees.** Full-resolution images and whole trees are large (image 1206×2622 px, tree 37 KB at the top of Settings) and use up context each time you read them.
- `relay screenshot --scale 1` saves a PNG shrunk on the device to 1 pixel per point and prints its absolute path as one line (about 400×870 px on an iPhone). Read that file to see the screen. The image's pixels are the points you tap. You can confirm it from `relay: image … px, screen … pt, … px/pt` on stderr. On large screens such as an iPad, also add `--max-size 1024` (then divide pixels by the px/pt on stderr to get points).
- Use full-resolution `relay screenshot` (no options) only when you need to check small text or fine details. Its pixels are points × scale (3 on an iPhone).
- `relay source --format compact --filter interactive` lists only the visible, enabled elements you can operate (buttons, cells, text fields, switches, and so on), one per line (12 lines, about 1 KB at the top of Settings). A line's `type`, `label`, `id`, and `value` work directly as selectors: `button label="General" id="com.apple.settings.general" frame=16,293,370,52` → `relay tap --id com.apple.settings.general` or `relay tap --type button --label General`. Keyboard keys are not listed (use `relay type` / `relay key`). For JSON, drop `--format compact`.
- To check elements that aren't listed (headings or result text, disabled buttons), use `relay find <selector>` or the whole tree with `relay source --format compact` (one element per line, indentation for parent and child). `relay source` (JSON) and `--format text` are large, so use them only when needed (narrow JSON with `jq` or `--max-depth <n>`). All of them target the foreground app unless you pass `--bundle-id`.
- `relay find <selector>` returns the matching elements' `type`, `identifier`, `label`, `value`, `frame`, `enabled`, and `index`. It is the fastest way to look for a known element, and no match is still exit code 0 (`"count":0`). With `--require`, no match is exit code 6 (for checking an element that should be there).
- The screenshot is what the user sees; the tree is what you can address. Use both: the screenshot to understand the screen, and the filtered tree or `find` to decide on a selector.

## Operating

**Prefer element selectors over coordinates.** A selector is one or more of `--id`, `--label`, `--type`, and `--value` (all exact, case-sensitive matches, ANDed together), plus an optional `--index <n>`.

```sh
relay tap --id login.button
relay tap --label "Sign In" --type button
relay tap --type textField --index 1
relay press --label "Photo" --type cell --duration 1.0
```

- Use `--id` if the app sets an accessibilityIdentifier, otherwise `--label` and `--type` (a cell often appears as both a `button` and a `staticText` with the same label, so add `--type`).
- If it fails with `ambiguous`, read the candidates and add a condition or `--index`.
- Coordinates (`relay tap <x> <y>`, `relay swipe <x1> <y1> <x2> <y2>`) are in points, with the origin at the top left of the screen in the displayed orientation. Outside the screen (outside `0 ≤ x < screen.width`, `0 ≤ y < screen.height`), nothing is sent and the exit code is 7. Get them from an element's `frame` or from `screen.width` / `screen.height` in `relay health`. When working from a screenshot, the pixels of a `--scale 1` image are points; otherwise divide pixels by the px/pt on stderr (the scale, at full resolution). Use coordinates only for what elements can't express, such as scrolling (for example `relay swipe 200 700 200 200`, from bottom to top).
- Text input: tap the text field, then `relay type "text"`. Add `--key return` to submit. To delete one character, `relay key delete`. The only keys are `return`, `delete`, and `space`. For text starting with `-`, put `--` first: `relay type -- -text`.
- **Wait without sleeping.** After an operation that changes the screen, wait for an element on the next screen with `relay find <selector> --timeout <seconds>` (up to 10 seconds; check `count`), or add `--timeout` to `tap` / `press` so they wait for the element to appear. For longer waits, repeat a short timeout.
- In iPad windowed mode too, element frames and `point` are in screen coordinates. `window` in `relay find --type window` gives the window's position and scale. If the position can't be determined (several windows of the same app, for example), element taps exit 6 with `window_position_unknown` (nothing is sent), and `find` and `source` include a `warning`. In that case, use coordinates from a screenshot.
- On devices with several displays (iPhone Duo: outer and inner), `display` and `screen` in `relay health`, screenshots, coordinates, and element frames all refer to the display the foreground app is on. After a fold change (which only the user can do), read `relay status` and `relay health` again (the switch can stop the runner). If you get exit code 6 with `display_unknown` (`cannot tell which display`), the screen is dark, so check with the user; with `touch_mode_unavailable` (`xcui touches can't reach`), drop `--mode` (or use `--mode private`) and send it again. See "Coordinates and orientation" in reference.md.
- **Observe again after the screen changes.** Frames, indexes, and the foreground app change. Don't reuse selectors or coordinates from the previous screen without checking.
- Send commands one at a time, waiting for the previous result. The runner runs one command at a time, and overlapping ones get busy (exit code 5).
- Right after `relay launch`, the foreground app may still be reported as the previous one. To be sure of the target, add `--bundle-id <id>` to `find` / `tap` / `type` / `source`.
- If `foreground.source` in `relay health` is `fallback`, apps switched by hand can't be tracked, so add `--bundle-id <id>`. If `touchSynthesis` is `xcui`, each touch takes 1–2 seconds. Both mean the private APIs are unavailable (see docs/private-api.md in device-relay).

## Replaying steps (relay run, experimental)

This is an experimental feature, and the format may change. Go through an unfamiliar screen one command at a time while observing, and replay only steps you have already confirmed.

1. Write the confirmed steps to `<name>.relay`, one per line without `relay` (start with `# relay-run: 1`; ask the user whether to keep it in the repository). Where the screen changes, wait with `find <selector> --timeout 5 --require` or `tap … --timeout 5` to confirm you arrived.
2. Before running it, validate it with `relay run <file> --check` (runs nothing).
3. From then on, replay it with `relay run <file>`. It stops at the first step that fails, printing `relay: step i/n (line N) failed: …` and exiting with that step's exit code (table below).
4. If it fails, observe the screen as it stopped (screenshot, `relay source --format compact --filter interactive`), fix the selector or wait on line N, and start again from step 2.

See [reference.md](reference.md#running-scenarios-relay-run-experimental) for how to write them.

## Recording

To keep evidence of behavior (a video for a pull request, for example), use `relay record start`, then your operations, then `relay record stop`. It works on simulators and on physical devices connected with USB (a device on Wi-Fi only gets exit code 1).

- On a physical device, the app running relay (the terminal, for example) needs macOS camera access. The first `record start` shows a macOS dialog and waits for the answer, so ask the user to press Allow. If it exits 1 because access was denied earlier or the like, ask them to allow it in System Settings > Privacy & Security > Camera. The agent must not change the setting itself or use `tccutil`.

- `relay record start` prints the absolute path of the video and returns (default `$TMPDIR/relay/`; set it with `-o <file>`, whose directory must exist). `relay record stop` waits for the video to be written and prints the same path. Tell the user about that file.
- If you forget to stop it, it stops after `--max-duration` (default 600 seconds), and `record stop` still retrieves it. When you stop your own runner with `relay stop`, the recording is written first too.
- Another `record start` during a recording exits 1. Check with `relay record status`. See [reference.md](reference.md#recording-relay-record).

## Exit codes

| Code | Meaning | What to do |
| --- | --- | --- |
| 0 | Success | – |
| 1 | Local failure (runner.json unreadable, device in use, build failure, "already running" from `relay start --background`, and so on; nothing was sent) | Read the reason in the JSON on stdout or the `relay:` line on stderr, and fix it |
| 2 | Usage error (unknown option, missing or invalid value, incompatible options, invalid session name, and so on). stderr gets only two lines, `relay: <error>` and `relay: see relay <command> --help` (no JSON, no stdout) | Fix the command. `relay <command> --help` |
| 3 | Can't reach the runner (no runner.json, can't connect, `no response within <seconds>s`) | For `no response within`, the runner is still working, so wait for `busy` in `relay ping` to become `false` (`launch` / `terminate` wait up to 150 seconds, and a long `type` waits 0.1 seconds per character, so give your own command a longer timeout). After a `launch` timeout, busy can continue for several more minutes, so if you started the runner yourself, `relay stop` and restarting is faster. Otherwise, `relay status`. If there is no runner.json, `relay start --background …`. If runner.json exists but doesn't answer (`relay start` was killed, for example), clean up with `relay stop`, then start. For `the OS refused the connection`, relay is inside a sandbox (see "When running inside a sandbox" above), so neither stop nor start anything |
| 4 | Token rejected (401). runner.json is stale or belongs to another runner | Check the URL, device, and PID with `relay status`, and also `--runner` / `--session` / `$RELAY_RUNNER` / `$RELAY_SESSION` / `~/.relay/runner.json`. If you started it yourself, `relay stop` and restart. Otherwise, ask the user without stopping it |
| 5 | Busy (409). Another command is running | Wait about a second, or retry once `relay ping` shows `"busy":false` |
| 6 | Action failed (422): element not found, not unique, disabled, or offscreen; no keyboard focus; the app for `relay launch` isn't installed | Branch on `code` in the JSON on stdout (table below). For element failures, read `reason` and `candidates`, observe again, and fix the selector |
| 7 | Request rejected (400 and other 4xx) | If `code` is `point_offscreen`, the coordinates are off the screen (read `screen` in `relay health` again; rotating swaps width and height). For `touch_mode_unavailable`, drop `--mode` and send it again. For `invalid_request` and others, read the error text and fix it |
| 8 | Runner error (5xx and the like) | Retry once. If it persists, check `relay status` and the logs |

Runner commands always output JSON, exactly one object on stdout whether they succeed or fail (`--json` makes no difference). `relay:` lines on stderr are hints for people, so there is no need to merge them with `2>&1`. The exceptions are `relay screenshot` (one line with the saved path on success; with `-o -` the image is on stdout, so a failure's JSON goes to stderr) and usage errors (exit code 2, no JSON). Options can also be written `--opt=value`, such as `--port=8101`.

Failure JSON (`{"ok":false,"code":"…","error":"…"}`) has the same shape for runner responses and for failures on relay's side (`runner_unavailable` and `runner_timeout` = exit code 3, `runner_info_invalid` and `screenshot_save_failed` = 1, `app_not_installed` = 6, and so on). `code` is a stable string, so branch on `code`, not on the English `error`. Common ones with exit code 6:

| `code` | What to do |
| --- | --- |
| `element_not_found` | Wait with `--timeout`, check the foreground app with `relay foreground`, check the actual values with `relay find --type …` |
| `element_ambiguous` | Look at `candidates` and add a condition such as `--type`, or `--index` (waiting won't help) |
| `element_not_hittable` | If `reason` is `offscreen`, scroll; if `disabled`, do the prerequisite step; if `emptyFrame`, observe again |
| `no_keyboard_focus` | Tap the text field and send it again |
| `touch_mode_unavailable` | Drop `--mode` and send it again |
| `display_unknown` | The screen is dark. Check with the user |
| `window_position_unknown` | The iPad window's position is unknown. Reduce to one window, or use coordinates from a screenshot |
| `touch_failed` / `xcui_failed` | Retry once. If it persists, observe again |
| `app_not_installed` | Check the bundle ID (it is case-sensitive) or install the app and send it again. Waiting won't help |

No `code` means an old runner (judge by the exit code and error text). The list of codes is in [reference.md](reference.md#when-an-action-fails-exit-code-6), as is what to do for each `reason`.

## Staying safe

- **Stay inside the target app.** Unless the task requires it, don't open or operate apps other than the target, such as Settings, Safari, or Messages. If you end up in another app, go back with `relay button home` and then `relay launch <bundle-id>`.
- **Start from a known state.** To avoid the effects of earlier operations, `relay button home` and then `relay launch <bundle-id>` (for a fresh launch, `relay terminate <bundle-id>` first).
- **Don't enter passwords or personal information on your own.** Enter only what the user gave you. Don't put passwords on the command line (they stay in `ps` and the shell history); pass them on standard input from an environment variable or file the user prepared: `printf '%s' "$PASSWORD" | relay type --stdin`.
- **Don't do anything destructive on a physical device.** Deleting data or apps, purchases, sending messages or email, changing system settings, signing out, and the like need the user's confirmation first. Screenshots of a physical device can show personal information, so don't share them beyond what the task needs.
- **Clean up.** If you rotated the device (`relay orientation landscape` is the same as `landscapeLeft`), go back with `relay orientation portrait`, return the app to a reasonable screen, and stop only runners you started, with `relay stop`.

## Common failures

- `Failed to initialize for UI testing` (`Timed out while enabling automation mode.`): on a physical device, the device may be asking for its passcode during enablement. Ask the user to enter the passcode if the device shows that screen, then start again (if `relay start` said to run `relay install` again, confirm with the user and do that first). If it continues, ask them to turn on Settings > Developer > Enable UI Automation. On a simulator, start again just once.
- "Untrusted Developer" on a physical device: ask the user to trust the developer in Settings > General > VPN & Device Management, then start again.
- The physical device is locked: ask the user to unlock it.
- Local network permission (physical device with `--allow-wifi`): ask the user to allow it in the dialog on the device.

All of these require someone to operate the device by hand, so don't try to work around them; tell the user what you need them to do. See [reference.md](reference.md#troubleshooting).
