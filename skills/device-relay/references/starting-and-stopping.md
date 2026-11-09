# Starting, checking, and stopping the runner

relay works from any directory (such as the target app's repository) and creates nothing there: the runner's URL and token go in `~/.relay/runner.json`, screenshots and recordings in `$TMPDIR/relay/`.

| Command | What it does |
| --- | --- |
| `relay status [--json] [--runner <path> \| --session <name> \| --all]` | The runner's URL, device, `relay start` PID, and start time from runner.json, and the `/ping` result. See [start --background / status / stop](start-status-stop.md). `--all` lists every session ([Sessions](sessions.md#sessions)) |
| `relay start --background [options]` | Starts `relay start` detached from the terminal and returns once ready. See [start --background / status / stop](start-status-stop.md) |
| `relay stop [--runner <path> \| --session <name> \| --all]` | Stops the `relay start` in runner.json (the runner, a simulator relay booted, and runner.json are cleaned up). See [start --background / status / stop](start-status-stop.md). `--all` also stops other agents' runners |
| `relay devices [--json] [--os <version>]` | Lists physical devices and simulators (NAME, UDID, KIND, OS, STATE). `--os` keeps only that OS |
| `relay doctor [--udid <UDID> \| --device <name>] [--simulator] [--os <version>] [--project <path>] [--json]` | Checks Xcode, the Runner, signing, and the device (the one `relay start` would use with the same arguments). A device another `relay start` is using appears on an `in use` line and is left out of automatic selection, and is ✗ if you named it. Any ✗ exits 1. `--json` prints only a one-line JSON object, `{"ok":…,"problems":n,"warnings":n,"checks":[{"section","name","status":"ok"\|"warning"\|"problem","detail","fix"}]}` (`fix` is `null` when ok), with the same exit code |
| `relay ping` | `{"ok":true,"busy":<bool>,"busyForMs":<ms or null>,"runner":{"version":…,"sourceHash":…}}`. Answers at once whether it is alive and busy, even during an operation (it doesn't touch the device). `runner` is the relay that built the runner and the hash of its sources (absent on old runners) |
| `relay skill status` | Where this skill comes from and where it is installed (project, global), and a version mismatch with relay (!). To reinstall, `relay skill install [--global \| --dir <skills dir>]` (after asking the user). See `relay skill --help` |
| `relay health` | What you need before operating (409 and exit code 5 during an operation; to check while busy, use `relay ping`). Device information, the screen size in the displayed orientation (`screen.width` / `height` / `scale`), `orientation`, `foreground`, the list of displays `displays` and the foreground app's display `display`, and the runner's version `runner` |

Main options of `relay start` (they can be combined with `--background`):

| Option | Description |
| --- | --- |
| `--udid <UDID>` / `--device <name>` | The device to use; you can't give both. The name matches exactly (ignoring case). With several of that name: the only connected or booted one, else the simulator with the newest iOS. A device and a simulator with the same name is an error listing the candidates |
| `--simulator` | Choose only among simulators (even with a device connected). Without `--device`, the only booted one. With none booted it is an error, so name one with `--device` |
| `--os <version>` | Narrows candidates by OS, as a prefix at each `.` (`27` is 27.x, `26.5` is 26.5.x) |
| `--port 8100` | The port the runner listens on. Use different ones to run alongside another `relay start` on the same Mac (with a session, omitting it picks a free one in `8101`–`8199`) |
| `--session <name>` | The session name (`$RELAY_SESSION` also works). See [Sessions](sessions.md#sessions) |
| `--rebuild` | Rebuilds the runner even if a build exists (when the Runner sources, Xcode's SDK, or the bundle ID prefix change, it rebuilds without this) |
| `--ready-timeout 180` | Seconds to wait until ready |
| `--team-id <TEAM_ID>` | The signing team for a physical device (normally detected automatically) |
| `--project <path>` | Where the Runner project is (normally found from the location of the relay executable) |
| `--verbose` | Shows xcodebuild's output as it is |
| `--allow-wifi` | Also uses a physical device's Wi-Fi addresses. The token and the screen travel over the LAN in plain text, so use it only when the user asks |

With `--background`, it waits up to 30 minutes until the runner is launched (booting a simulator and building), then `--ready-timeout` + 15 seconds. Progress (boot, build, launch) goes to `relay:` lines on stderr; give your own command a timeout that long.

- **Which device without `--udid` / `--device`**: the only connected physical device, else the only booted simulator, otherwise an error listing the candidates. A connected physical device wins over a simulator, so unless the user asked for a physical device, name a simulator from `relay devices` (or add `--simulator` to use the booted one). Of several simulators with the same name, `--device` picks the newest iOS and shows its OS in `relay: using …`; narrow with `--os 26.5` or use `--udid`. A shut-down simulator you name is booted, and `relay stop` shuts it down again.
- **The target app** must already be installed on the device (build and install it the project's way: Xcode, `xcodebuild`, or `xcrun simctl install`). `relay launch` only launches or foregrounds it. Its bundle ID is the project's `PRODUCT_BUNDLE_IDENTIFIER`, or bring the app to the foreground and run `relay foreground`.
- **`status`, `ping`, or `health`**: `relay status` also reads runner.json and the `relay start` process (PID, device, version) and is the check after starting (`--json` for machines). `relay ping` answers at once whether the runner is alive and `busy`, even during an operation. `relay health` gives what you need before operating (screen size and so on) and returns 409 (exit code 5) during an operation.
- **Remember your own runner**: note the `pid:` that `relay start --background` prints, and before `relay stop` check that `pid` in `relay status` is the same.

For preparing a physical device (Developer Mode, pairing, UI Automation, Team ID), see "実機" and "Team ID（実機の署名）" in docs/device.md of device-relay.

## relay doctor and relay skill

- `relay doctor [--udid <UDID> | --device <name>] [--simulator] [--os <version>] [--json]` checks the environment and, given what you would pass to `relay start`, that device. ✗ is a problem (exit code 1) and each line says how to fix it. ! is a warning and does not block starting. A device another session is using is on an `in use` line and left out of automatic selection (✗ if you named it).
- This skill is installed by `relay skill install`: it copies the skill to `.claude/skills/device-relay` at the root of the current git repository (`--global`: `~/.claude/skills/device-relay`). If `relay skill status` shows ! (relay was updated and the skill is out of date), tell the user to run `relay skill install` again. It rewrites files in the repository or the home directory, so don't run it without asking.
