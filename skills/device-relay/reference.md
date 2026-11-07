# device-relay reference

This supplements [SKILL.md](SKILL.md). For anything not here, see the device-relay README and the documents in docs/, or `relay --help` / `relay <command> --help`. `--help` (also `-h` and `relay help <command>`) exists for every subcommand. The documents in docs/ are in Japanese, so their file and section names are given below as they appear there, in quotation marks.

## Starting, checking, and stopping the runner

| Command | What it does |
| --- | --- |
| `relay status [--json] [--runner <path> \| --session <name> \| --all]` | The runner's URL, device, `relay start` PID, and start time from runner.json, and the `/ping` result. See "start --background / status / stop" below. `--all` lists every session ("Sessions" below) |
| `relay start --background [options]` | Starts `relay start` detached from the terminal and returns once ready. Same section |
| `relay stop [--runner <path> \| --session <name> \| --all]` | Stops the `relay start` in runner.json (the runner, a simulator relay booted, and runner.json are cleaned up). Same section. `--all` also stops other agents' runners |
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
| `--session <name>` | The session name (`$RELAY_SESSION` also works). See "Sessions" below |
| `--rebuild` | Rebuilds the runner even if a build exists (when the Runner sources, Xcode's SDK, or the bundle ID prefix change, it rebuilds without this) |
| `--ready-timeout 180` | Seconds to wait until ready |
| `--team-id <TEAM_ID>` | The signing team for a physical device (normally detected automatically) |
| `--project <path>` | Where the Runner project is (normally found from the location of the relay executable) |
| `--verbose` | Shows xcodebuild's output as it is |
| `--allow-wifi` | Also uses a physical device's Wi-Fi addresses. The token and the screen travel over the LAN in plain text, so use it only when the user asks |

With `--background`, it waits up to 30 minutes until the runner is launched (booting a simulator and building), then `--ready-timeout` + 15 seconds.

### start --background / status / stop

See "バックグラウンドで動かす" in docs/setup.md of device-relay for details.

**`relay start --background`**: starts `relay start` with the same options as a new session (it survives closing the terminal; stdin is `/dev/null`, output goes to `~/.relay/logs/start-<time>-<port>.log`), then reads that log and waits.

```
relay: started relay start in the background (pid <PID>, log: /Users/<you>/.relay/logs/start-<time>-<port>.log)   ← stderr (progress relay: lines)
relay: building runner (log: ...)
relay: launching runner on <UDID> (log: ...)
ready: http://127.0.0.1:8100/                                                                   ← stdout from here
device: <device name> (<UDID>)
pid: <PID>
log: /Users/<you>/.relay/logs/start-<time>-<port>.log
token: /Users/<you>/.relay/runner.json
```

Paths are absolute, including the home directory (`/Users/<you>` is the user's home).

| Exit code | When |
| --- | --- |
| 0 | Ready |
| 1 | The child `relay start` exited before ready (build failure, device not found, `Failed to initialize for UI testing`, and so on). The runner in `~/.relay/runner.json` already answers on the same port. Interrupted while waiting |
| 3 | Timed out (30 minutes until launch, then `--ready-timeout` + 15 seconds) |

On failure it stops the child (including an xcodebuild in progress, and a simulator relay booted is shut down), and prints the last 20 lines of the log, the cause, and the log's path (`(log: …)`) to stderr. If the end of the log isn't enough, read the whole file.

**`relay status [--json]`**: shows the contents of runner.json (found in the same order as "Where the runner is found (runner.json)"; `--runner <path>` also works) and the `/ping` result.

```
url:         http://127.0.0.1:8100/
device:      <device name> (<UDID>)
pid:         <PID> (relay start running)
started:     <date and time>
host app:    <bundle ID of RelayRunnerHost>
ping:        ok (idle)
runner:      0.5.0 (sources <12 characters>)
runner.json: /Users/<you>/.relay/runner.json
```

`runner.json:` is an absolute path too. With a session, a `session:` line comes first.

`--json` is one object: `alive` (whether `/ping` returned 200), `url`, `udid`, `name`, `pid`, `processRunning` (whether that `relay start` is still running), `startedAt` (ISO 8601), `hostBundleID`, `session`, `ping` (`{"status":200,"busy":…,"busyForMs":…}`, `{"status":401}`, and so on; `{"error":"…"}` if there is no answer), `runner` (the runner version `/ping` returned, `{"version":…,"sourceHash":…}`; `null` for old runners or no answer), `expectedRunner` (the expected value `relay start` saved in runner.json), and `runnerInfo` (the path of runner.json). Missing values are `null`. Without runner.json it prints only `{"alive":false,"code":"runner_unavailable","error":"…","ok":false}`.

| Exit code | When |
| --- | --- |
| 0 | `/ping` answered |
| 3 | No runner.json, or no answer (stderr says `relay stop cleans up, relay start --background starts a new one`; with `--json`, `{"alive":false,"ok":false,"code":"runner_unavailable",…}` also goes to stdout) |
| 4 | Token rejected (401). runner.json doesn't belong to the runner at that address (another `relay start`, a stale file, or `--runner` / `$RELAY_RUNNER` / `~/.relay/runner.json`; `.relay/runner.json` in the current directory is not read). Unless you started it yourself, ask the user |
| Others | `/ping` returned another HTTP status (same as the runner commands: 7 for 404 and the like, 8 for 5xx) |

**`relay stop`**: sends SIGTERM to the `relay start` in runner.json and waits for it to exit (the same path as Ctrl-C: the runner's `/shutdown`, shutting down a simulator relay booted, removing runner.json). It also stops a foreground `relay start`, so use it only on what you started yourself.

| Output, exit code | When |
| --- | --- |
| `stopped`, 0 | Stopped. If `relay start` was no longer running, it sent `/shutdown` to the runner and removed runner.json |
| `not running`, 0 | Nothing is running (no runner.json, or it removed a stale runner.json that didn't answer) |
| 1 | `relay start` didn't exit within 60 seconds. Look at `~/.relay/logs/start-*.log` and tell the user |

For preparing a physical device (Developer Mode, pairing, UI Automation, Team ID), see "実機" and "Team ID（実機の署名）" in docs/setup.md of device-relay.

## Recording (relay record)

To keep evidence of behavior, use `relay record start`, then your operations, then `relay record stop`. It works on simulators (the host's `simctl io recordVideo`) and on physical devices connected with USB (as a capture device on the Mac, the same mechanism as QuickTime). A physical device needs macOS camera access for the app running relay (the terminal, for example), which the first `record start` requests with a dialog. See "録画（relay record）" in docs/cli.md and `relay record --help`.

| Command | Output, exit code |
| --- | --- |
| `relay record start [-o <file>] [--force] [--max-duration 600] [--runner <path> \| --session <name>]` | Once recording has started, prints the absolute path of the video on stdout and exits 0. Default `$TMPDIR/relay/relay-recording-<time>.mp4`; a relative path is under the current directory. 1: the simulator isn't booted, the device isn't connected with USB (Wi-Fi only, or not connected), no camera access (ask the user to allow it in System Settings > Privacy & Security > Camera), the device's screen doesn't appear as a capture device (ask the user to check the USB connection, unlock it, and "Trust"), several devices with the same name are connected, the directory doesn't exist, the file already exists (`--force` overwrites; if it is the user's file, ask first), already recording, or recording fails to start (stderr has the output of simctl or the recording process). 3: no runner, or it doesn't answer. 4: token rejected (401) |
| `relay record stop [--runner <path> \| --session <name> \| --port <n>]` | Waits for the video to be written (up to 30 seconds), prints the absolute path of the non-empty MP4 on stdout, and exits 0. `not recording` and 0 if nothing is recording. A recording that stopped by itself (`--max-duration`) is retrieved here too. 1: writing didn't finish (you can stop again), the video is empty, or there is no runner.json and several recordings exist (choose with `--port <n>` from the list by port) |
| `relay record status [--json] [--runner <path> \| --session <name> \| --port <n>]` | Whether it is recording (`yes` / `ended`), the video's location, and the elapsed time. If a physical device has sent no frame for 5 seconds or more, a `frames:` line (`stall` with `--json`). Always 0 |

- A recording continues detached from the terminal, so you can run other commands after `record start`. `relay stop` also writes the recording first (the path goes to stderr).
- If the simulator shuts down or the device is unplugged during a recording, `record stop` returns the video up to that point.
- `record stop` on a physical device takes about 4 seconds (it waits so that a `record start` right after can find the screen). A `record start` right after another recording stopped tries once more with a new process, so it can take about 20 seconds.
- If frames stop because the device was locked during a recording, for example, the recording continues (the video holds the last frame). If `record status` shows `frames: no frame for 5s …`, ask the user to unlock it.
- A physical device's video is a QuickTime movie only when `-o` ends in `.mov`, otherwise an MP4 (both H.264, no audio).

## Using relay from inside a sandbox

When Claude Code or a similar tool runs shell commands in a sandbox (Seatbelt on macOS), relay behaves as follows.

| Symptom | Meaning |
| --- | --- |
| `relay start` can't create `~/.relay/locks`, can't write to DerivedData, can't connect to testmanagerd's socket, or can't create a pseudo-terminal | `relay start` doesn't work inside a sandbox. Start it outside the sandbox |
| `cannot reach the runner at http://127.0.0.1:8100/: the OS refused the connection (Operation not permitted); relay may be running inside a sandbox …` (exit code 3) | The runner may well be running. The OS refused relay's connection. Don't redo `relay stop` or `relay start` (in this case `relay stop` also exits 3 without removing runner.json) |
| `✗ localhost` / `✗ ~/.relay` in `relay doctor` (`Operation not permitted`) | Connecting to 127.0.0.1 or writing to `~/.relay` was refused. It seems to be running inside a sandbox |
| `relay stop` says `cannot signal relay start (pid …): Operation not permitted; relay may be running inside a sandbox …` (exit code 1) | From inside a sandbox, it can't signal a `relay start` running outside. Ask the user to run `relay stop` outside the sandbox (the arguments aren't wrong) |

The recommendation is to run relay outside the sandbox. Ask the user to add the following to Claude Code's settings (`~/.claude/settings.json`, or the project's `.claude/settings.json` / `.claude/settings.local.json`); the agent must not rewrite them without asking.

```json
{
  "sandbox": {
    "excludedCommands": ["relay *"]
  }
}
```

- The exclusion applies only when every command in one Bash call matches. `cd … && relay …`, `relay … > file`, `$(relay …)`, and inside `for` / `if` go back into the sandbox, so call relay on its own (give the output location with `-o <file>`).
- If an administrator requires the sandbox, `excludedCommands` in the repository's settings is ignored (it works in `~/.claude/settings.json`).
- To let only the operating commands through from inside the sandbox, use `"network": {"allowLocalBinding": true}` (macOS; every localhost port becomes reachable, and commands listening on other than localhost may also accept connections from other machines; if an administrator requires the sandbox, `true` in the repository's settings is ignored, but it works in `~/.claude/settings.json`). `relay start` still has to be started outside, so normally use `excludedCommands`.
- A physical device's runner is at a CoreDevice tunnel address rather than localhost, so it also has to run outside the sandbox.
- The same goes for other agents: use a setting that runs relay outside the sandbox. See "エージェントの sandbox から使う" in docs/setup.md of device-relay.

## Where the runner is found (runner.json)

Runner commands read the URL and token from a runner.json found in this order (the token can't be passed on the command line).

1. `--runner <path>` or `--session <name>` (not both)
2. The environment variable `RELAY_RUNNER` or `RELAY_SESSION` (both is a usage error, exit code 2)
3. `~/.relay/runner.json` (where `relay start` without a session writes it)

If the file or session named in 1 or 2 doesn't exist, the exit code is 3, without looking at 3. `.relay/runner.json` in the current directory or its parents is not read (to prevent 401s from stale files left by earlier versions). If 3 is missing and such a file exists, the error says `.relay/runner.json in <dir> is no longer read; pass --runner <path> to use it`. Use a file you placed by hand with `--runner <path>`. If exit code 4 persists, check that `--runner` / `$RELAY_RUNNER` doesn't point to a stale file.

### Sessions

When several agents work in parallel, keep them in separate sessions (names start with a letter or digit, with up to 64 letters, digits, `.`, `_`, and `-`). If `$RELAY_SESSION` isn't set, add `--session <name>` to every command. In environments that start a new shell for each command, `export` doesn't carry over to the next one.

| What is separate | Details |
| --- | --- |
| runner.json | `~/.relay/sessions/<name>/runner.json`. Nothing is written to `~/.relay/runner.json`, and it doesn't fall back to other files |
| Port | Without `--port`, a free one in `8101`–`8199`, shown on the `ready:` line. Only `relay start`s reserve ports among themselves, so if another process takes it first, launching the runner fails (`Address already in use` in the log). Start again and it picks the next free one |
| Device | One runner per device (also without a session). Naming a device in use exits 1 with an error that names its owner. Omitting the device leaves those in use out of the candidates. With a session, of several free booted simulators it picks the first (newest iOS, then name; if another start takes it at the same moment, the next one; several physical devices is an error listing the candidates) |
| Build | Shared. Builds to the same DerivedData go one at a time, and during another start's build and while launching from the same build (until ready), relay prints `waiting for another relay start's build` and waits. It can take minutes but isn't a failure |
| Logs | `~/.relay/logs/start-<time>-<name>-<port>.log` and so on |

If a command without a session uses the file from 3, and other sessions are running, stderr gets `relay: warning: no session selected; using <path>, while sessions <names> are running; pass --session or set RELAY_SESSION`. The exit code doesn't change.

`relay status --all [--json]` lists every session and the runner in `~/.relay/runner.json` (`(default)`; `session` is `null` in JSON), with SESSION, STATE, DEVICE, URL, and PID. STATE is `starting`, `running`, `busy`, `no answer`, `rejected`, or `unknown`. The exit code is always 0. `relay stop --session <name>` also stops a session that is still building. See "複数のセッションを並列に動かす" in docs/setup.md of device-relay.

## Commands and options

| Command | Usage |
| --- | --- |
| `screenshot` | `relay screenshot [-o <file>\|-] [--format png\|jpeg] [--quality 0.05-1.0] [--max-size <px>] [--scale <px/pt>]`. Prints the saved file's absolute path as one line (default `$TMPDIR/relay/screenshot-<time>.png`). A `.jpg` / `.jpeg` extension or `--quality` selects JPEG (default quality 0.7). `--max-size` is the pixel count of the longer edge and `--scale` the upper limit of pixels per point; the device shrinks the image (with both, the smaller wins; it never enlarges). When shrunk, stderr gets the image size, the screen size, and px/pt ("Coordinates and orientation" below) |
| `source` | `relay source [--format json\|text\|compact] [--filter interactive] [--max-depth <n>] [--bundle-id <id>]`. `--max-depth 0` is the root only. `compact` is one element per line, and `--filter interactive` keeps only the elements you can operate ("Element tree formats" below) |
| `find` | `relay find <selector> [--limit 20] [--timeout <s>] [--require] [--bundle-id <id>]`. `--limit` is 1–100 and `--timeout` up to 10 seconds. No match is exit code 0 (`"count":0`), or 6 with `--require` |
| `tap` | `relay tap (<x> <y> \| <selector>) [--mode private\|xcui] [--timeout <s>] [--bundle-id <id>]`. `--timeout` and `--bundle-id` apply to selectors only |
| `press` | `relay press (<x> <y> \| <selector>) [--duration 1.0] [--mode private\|xcui] [--timeout <s>] [--bundle-id <id>]` |
| `swipe` | `relay swipe <x1> <y1> <x2> <y2> [--duration 0.3] [--hold 0.05] [--mode private\|xcui]`. Holds at the start for `--hold` seconds, then moves to the end over `--duration` seconds |
| `type` | `relay type [<text> \| --stdin] [--key return\|delete\|space]... [--bundle-id <id>]`. `--key` can repeat and is sent in order after the text. It doesn't return until typing finishes (about 15 ms per character on a simulator), and waits for the response up to 30 seconds + 0.1 seconds per character + 1 second per key |
| `key` | `relay key return\|delete\|space [--bundle-id <id>]` |
| `button` | `relay button home\|volumeUp\|volumeDown` (volume buttons on physical devices only) |
| `orientation` | `relay orientation portrait\|portraitUpsideDown\|landscapeLeft\|landscapeRight\|landscape` (`landscape` is an alias for `landscapeLeft`) |
| `launch` / `terminate` | `relay launch <bundle-id>` / `relay terminate <bundle-id>`. They don't return until the app has launched or terminated, and wait for the response up to 150 seconds (30 + 120). For an app that isn't installed, `launch` sends nothing to the runner and exits 6 at once (`app_not_installed`). When it can't tell, it prints `cannot tell whether …` and sends it |
| `foreground` | The foreground app's `bundleId` and `pid` |

- `relay shutdown` isn't in the list. Normally use `relay stop`. `shutdown` only sends `/shutdown` to the runner and returns at once with `{"ok":true}`; removing runner.json and shutting down the simulator is done a few seconds later by `relay start` when it sees the runner end (you can't tell when that is finished). If `relay start` is no longer running, runner.json stays behind. `relay stop` waits until the end and prints `stopped`.
- The wait for a response is 30 seconds plus how long that operation may wait (`--timeout`, `--duration`, `--hold`, `type` / `launch` / `terminate` above, 1 second for `key`). Make your own command's timeout longer than that. Even after a timeout (`no response within <seconds>s`, exit code 3) the runner keeps working on the operation, and other commands get 409 (exit code 5) until it finishes, so wait for `busy` in `relay ping` to become `false` before continuing. A `launch` timeout can last several minutes. `relay stop` works while busy, so if you started the runner yourself, stopping and restarting recovers faster.
- `--type` names, key names, button names, orientations, and numeric ranges are checked before sending; a wrong one is a usage error, exit code 2, and nothing is sent (for example `relay key tab` → `unsupported key 'tab'`).
- Don't normally give `--mode` (the default `private` is fast; `xcui` waits for the app to go idle, so each takes 1–2 seconds).

## Running scenarios (relay run, experimental)

This is an experimental feature. How steps are written and the output may change. Use it to replay fixed or already-confirmed steps in one call.

```sh
relay run steps.relay        # a file (one step per line; blank lines and lines starting with # are ignored)
relay run - < steps.relay    # standard input
relay run --step "launch <bundle-id>" --step "tap --id login.button --timeout 5" --step "find --id home.title --timeout 5 --require"
relay run steps.relay --check   # validate only (no runner needed, runs nothing; 0 if there are no problems)
```

- Steps are runner commands without `relay` (`tap`, `press`, `swipe`, `type`, `key`, `button`, `orientation`, `launch`, `terminate`, `find`, `source`, `screenshot`, `health`, `foreground`, `ping`) and `sleep <seconds>` (up to 60). `start` / `stop` / `shutdown` and the like can't be written.
- Words split as in a shell (spaces, `'...'`, `"..."`, `\`). `--runner` and `--session` go on `relay run` and can't be in a step. `type --stdin` can't be used either. `screenshot` requires `--output <file>`.
- For a scenario you save, write `# relay-run: 1` (the format version) on the first line. For an unsupported version, that line is an error and nothing runs.
- All lines are checked before running. For an invalid line it prints `relay: line <N>: <reason>`, runs nothing, and exits 2 (stderr only). You can check a scenario you wrote with `--check` before running it.
- While running, it stops at the first step that fails, prints that step's error and `relay: step i/n (line N) failed: <step>`, and exits with that step's exit code (1, 3–8; 1 when a screenshot couldn't be saved).
- A step means the same as the command alone. To confirm an element, wait with `find <selector> --timeout <seconds> --require`, which stops there if it doesn't appear (exit code 6). `find` without `--require` continues even with no match. A fixed `sleep` is the last resort.
- Each step's stdout (including a failed step's `{"ok":false,"code":…}`) goes to stdout as it is, and per-step progress (`relay: [i/n] … ok (… ms)`) and the total go to stderr (`--quiet` removes them). Progress and failure lines mask `type` text as `***`, but the scenario file keeps what is written in it. Don't write passwords the user gave you in a scenario (use `relay type --stdin`, one command at a time).

## Element tree formats

| Command | Output | Size at the top of Settings |
| --- | --- | --- |
| `relay source --format compact --filter interactive` | Only the elements you can operate, one per line (the usual choice) | 12 lines, about 1 KB |
| `relay source --filter interactive` | The same elements as JSON (an `elements` array) | About 2.3 KB |
| `relay source --format compact` | All elements, one per line, indented for parent and child | 167 lines, about 11 KB |
| `relay source` | A JSON tree of all elements (also `placeholder`, `enabled`, `hasKeyboardFocus`, and so on) | About 37 KB |
| `relay source --format text` | XCUI's `debugDescription` (slow; for people to read) | About 17 KB |

A compact line: `type`, the non-empty `label="…"`, `id="…"` (identifier), `value="…"`, and `placeholder="…"` (JSON strings), `frame=x,y,width,height` (points, rounded to integers), and flags (`selected`, `focused` = keyboard focus, `disabled`, `truncated`).

```
textField id="relay.input" placeholder="Type here" frame=16,86,370,34 focused
button label="General" id="com.apple.settings.general" frame=16,293,370,52
```

What `--filter interactive` keeps and leaves out:

- Kept: buttons, cells, links, home screen icons, tabs, switches, sliders, steppers, pickers, text fields (`textField`, `secureTextField`, `searchField`, `textView`), and the like, that have an identifier, label, or placeholder (text fields are kept even with none). For an unnamed cell, the labeled text inside it is kept instead (tapping the text hits the cell)
- Left out: disabled (`enabled: false`), off the screen, the keyboard and its keys, elements whose tap point is covered by the keyboard or a control in front (a search bar at the bottom, for example), heading and body text, images, containers (`table` and the like)
- The check for being covered is approximate. Elements under a sheet that isn't a control are kept, so confirm with a screenshot that they are visible.
- Selectors search the whole tree. With a `staticText` of the same label, `--label` alone becomes `ambiguous`, so also add the line's `type`, or use `--id`.

## Element selectors

- Conditions: `--id` (accessibilityIdentifier), `--label`, `--type`, `--value`. An exact match (including case) with the values of the same name in `relay source`, all ANDed. There are no partial matches or regular expressions.
- `--index <n>`: the nth of the matching elements (from 0, in the same order as `relay source`'s JSON). You can use `index` from a `relay find` result as it is.
- `--type` names are the same as `type` in `relay source` (`button`, `staticText`, `textField`, `secureTextField`, `searchField`, `cell`, `switch`, `image`, `navigationBar`, `scrollView`, `table`, `collectionView`, `alert`, and so on). An unknown name is a usage error, exit code 2.
- When a name is ambiguous, get a list with `relay find --type <type>` and use its `identifier` or `index`.
- The tap point is the center of the element's frame (the part overlapping the screen).
- For an element covered by the keyboard or a sheet, if its frame is on the screen, the tap hits whatever is covering it. Before tapping, confirm with a screenshot that it is visible, and if it is covered, close the keyboard (in some apps `relay key return` closes it) or scroll.

## When an action fails (exit code 6)

JSON goes to stdout (to stderr only for `relay screenshot -o -`).

```json
{"candidates":[…],"code":"element_ambiguous","count":2,"error":"2 elements match the selector; add conditions or an index","ok":false,"reason":"ambiguous"}
```

The `code`s of element failures are `element_not_found` (`notFound`, `indexOutOfRange`), `element_ambiguous` (`ambiguous`), and `element_not_hittable` (`emptyFrame`, `offscreen`, `disabled`), with `reason` giving the detail.

| `reason` | Meaning | What to do |
| --- | --- | --- |
| `notFound` | No match | The screen hasn't changed yet → add `--timeout`. Wrong foreground app → `relay foreground`, `--bundle-id`. Wrong name → check the actual values with `relay find --type …` / `relay source` |
| `ambiguous` | Two or more match and there is no `--index` (returns at once, without waiting) | Look at `candidates` and add a condition such as `--type`, or `--index` |
| `indexOutOfRange` | `--index` is at or beyond the number of matches | Check the count with `relay find` |
| `emptyFrame` | The element's width or height is 0 | It isn't displayed. Observe the screen again |
| `offscreen` | The element is off the screen | Scroll with `relay swipe`, then look again |
| `disabled` | The element is `enabled: false` | A prerequisite input or step is missing. Check the screen |

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
| `not_found` / `method_not_allowed` | 7 | Wrong path or method. If a relay command gets it, the runner is old (if you started it yourself, `relay stop` and then `relay start --rebuild`) |
| `element_not_found` / `element_ambiguous` / `element_not_hittable` | 6 | The `reason` table above |
| `no_keyboard_focus` | 6 | Tap the text field and send it again |
| `display_unknown` | 6 | The screen is dark. Check with the user |
| `window_position_unknown` | 6 | The iPad window's position is unknown. Reduce to one window, or use coordinates from a screenshot |
| `touch_failed` | 6 / 8 | Retry once. If it persists, `relay status` and the logs |
| `xcui_failed` | 6 | Read the error text (XCUI's message) and observe the foreground app and the screen again |
| `app_not_installed` | 6 | relay decides before sending (the runner doesn't return it). Check the bundle ID, or install the app |
| `internal_error` | 8 | Retry once. If it persists, `relay status` and the logs |

## Coordinates and orientation

- Coordinates are in points, with the origin at the top left of the screen in the foreground app's displayed orientation. `screen` in `relay health` is 402×874 in portrait, for example, and 874×402 in landscape.
- A full-resolution screenshot's pixels are `screen.width × scale` × `screen.height × scale`. To get coordinates from a position on the image, divide by scale.
- In a `--scale 1` image, pixels = points (402×874 on an iPhone 17 Pro in portrait). For an image shrunk with `--max-size` or the like, divide by the px/pt in stderr's `relay: image 471x1024 px, screen 402x874 pt, 1.172 px/pt (tap in points: px / 1.172)` (for example (120, 375) px → (102, 320) pt). With curl, response headers such as `X-Relay-Image-Scale` give the same values.
- Tap and swipe coordinates are always points, whichever image you use.
- Coordinates must be within `0 ≤ x < screen.width` and `0 ≤ y < screen.height` (displayed orientation). Outside, nothing is sent and you get 400 (exit code 7), with the screen size and orientation in a message like `invalid field: x, y: (500, 100) is outside the screen, which is 402x874 points in portrait (...)`. `swipe` checks both the start (`from:`) and the end (`to:`). Use points a few points inside the edge rather than right at it.
- After `relay orientation`, read `orientation` and `screen` in `relay health` again. Most iPhone apps don't rotate to `portraitUpsideDown`.
- In iPad windowed mode (windowed apps, Stage Manager, Slide Over), coordinates are still for the whole screen. The frames from `find` and `source` (except `--format text`) and the `point` of an element tap are converted to screen coordinates too, and `window` in the response (`x`, `y`, `width`, `height`, `scale`) gives the window's position and scale. Full-screen apps don't have it. If the position can't be determined, a tap sends nothing and exits 6 (`window_position_unknown`), while `find` and `source` keep frames in window coordinates, with `window: null` and a `warning` (a leading `warning …` line with `--format compact`).
- On devices with several displays (iPhone Duo; Xcode 27.1 or later, iOS 27.1 or later), `displays` in `relay health` lists the displays (the outer is ID 1 at 466×678, the inner ID 3 at 669×951, in portrait points) and `display` is the ID of the foreground app's display. `screen`, screenshots (response header `X-Relay-Display`), coordinates, and element frames are for that display. The inner one is normally landscape, with a `screen` of 951×669. After a fold change, read `relay health` again (the simulator can restart and stop the runner, so `relay status` first, and `relay start` again if it stopped). On a Duo, `relay orientation` doesn't rotate the screen (the outer stays portrait, the inner landscapeRight). If the foreground app's display can't be determined (`display` is `null`, and touches and screenshots exit 6 with `cannot tell which display`), both displays are dark, so check with the user. On the inner display, when SpringBoard or an app that doesn't rotate is in front, `--mode xcui` coordinate touches are refused with `xcui touches can't reach`, so drop `--mode` and send it again.
- See "座標系と画面の向き", "iPad のウィンドウ表示", and "表示が複数ある端末（iPhone Duo）" in docs/screen.md of device-relay.

## Scrolling example

```sh
relay health                          # check screen.width / height
relay swipe 200 700 200 250           # from bottom to top (moves the content up)
relay find --label "Privacy" --type button
```

An element off the screen is `offscreen`, so repeat swiping and observing until `find` locates it. Keep swipe start points away from the navigation bar and the home indicator (the top and bottom edges of the screen).

## The app for trying things out

RelayRunnerHost is installed with the runner. Its bundle ID differs per user (`<prefix>.RelayRunnerHost`), so in relay commands write `host` in place of the bundle ID (`relay launch host`, `--bundle-id host`). The actual ID appears as `host app` in `relay status`. You can try operations on it in place of a target app. Identifiers: `relay.input` / `relay.input2` (text fields), `relay.password` (password field; `secureTextField`), `relay.text`, `relay.passwordLength`, `relay.submitted`, `relay.events` ("検証用のホストアプリ" in docs/development.md of device-relay).

```sh
relay launch host
relay tap --id relay.input --timeout 3
relay type "hello" --key return
relay find --id relay.submitted       # its label is "submitted #1: hello"
```

## Troubleshooting

| Symptom | Cause and fix | device-relay document |
| --- | --- | --- |
| `Failed to initialize for UI testing` (`Timed out while enabling automation mode.`) when starting | On a physical device, this is usually the device asking for its passcode while enabling automation mode, and timing out without it (UI Automation being off gives the same error). Ask the user to enter the passcode if the device shows that screen, then `relay start` again (the permission lasts a while, so starting right after tends to work). If `relay start` said `run relay install again`, confirm with the user and redo `relay install` first (relay rebuilds old builds by itself). If it still continues, ask them to check that Settings > Developer > Enable UI Automation is on. On a simulator it is usually temporary, so start again just once | docs/setup.md, "実機" |
| `... timed out after 30 s` from `simctl`, `devicectl`, `xcrun`, or `security` | The tool did not answer in time and relay stopped it. Check that the command answers in a terminal, then try again | docs/limitations.md |
| "Untrusted Developer" on a physical device | Certificates such as a Personal Team's. Ask the user to trust it in Settings > General > VPN & Device Management, then start again | docs/setup.md, "実機" |
| `relay doctor` shows locked (`passcodeRequired`), or operations have no effect | Ask the user to unlock the physical device | docs/setup.md, "環境の確認（relay doctor）" |
| `--allow-wifi` doesn't reach it | Ask the user to allow it in the "Local Network" permission dialog on the device | docs/setup.md, "実機"; docs/limitations.md |
| A physical device doesn't become `connected`, or the DDI isn't mounted | Ask the user to connect with USB and get it ready in Xcode's Devices and Simulators window | docs/setup.md, "実機" |
| Signing or Team ID errors (physical device) | Ask the user to sign in to Xcode and create an Apple Development certificate. With several teams, `--team-id` | docs/setup.md, "Team ID（実機の署名）" |
| `run relay install again to update the runner` appears | relay was updated after `relay install`. Ask the user to run `relay install` (it doesn't stop anything from working) | docs/setup.md, "Runner の用意（relay install）" |
| `unknown argument: '-target-arch-variant'` (building relay) | Another Swift comes first in PATH. `make install` uses `xcrun swift`, so use that | README, "Requirements" |
| One operation doesn't return for minutes, and busy continues meanwhile | A sheet from another process (Apple Account sign-in, for example) is up, and snapshots are stuck. Wait, or ask the user to close it | docs/limitations.md |
| After an Xcode or iOS update, `touchSynthesis` in `relay health` became `xcui` and `foreground.source` became `fallback`, or elements' `hasKeyboardFocus` is `null` | Private APIs the runner uses became unavailable. It mostly keeps working through alternatives, so expect slower touches and name the target with `--bundle-id` | docs/private-api.md |
| `relay button home` has no effect on a physical device | On devices with a home button, the substitute swipe opens Control Center | docs/limitations.md |
| `the OS refused the connection (Operation not permitted)` (exit code 3) | relay is inside the agent's sandbox and can't connect to localhost. The runner hasn't stopped. Ask the user for the settings in "Using relay from inside a sandbox" above | docs/setup.md, "エージェントの sandbox から使う" |
| Exit code 3, but runner.json exists | `relay start` was killed and only the file remains (`relay status` shows `relay start not running` for the pid and no answer for ping). Clean up with `relay stop` (`not running`), then start | docs/setup.md, "バックグラウンドで動かす"; docs/limitations.md |
| `relay start --background` exits 1 with "a runner is already running" | The runner in `~/.relay/runner.json` answers on the same port. Check with `relay status` and use it as it is. Unless you started it yourself, don't stop it | docs/setup.md, "バックグラウンドで動かす" |

Logs from a failed start are in `~/.relay/logs/` (`start-*.log`, `build-*.log`, `runner-*.log`). When `relay start --background` fails, it prints the cause, the end of the log, and the `start-*.log` path to stderr, so read that first, and if it isn't enough, read that file and the `build-*.log` / `runner-*.log` it mentions. `relay start` removes logs over 7 days old (keeping the newest 20 of each kind) and all but the newest 3 `.xcresult` per port, so copy what you need to keep out of `~/.relay`. What a running runner writes is never removed, and neither are your screenshots and recordings.
