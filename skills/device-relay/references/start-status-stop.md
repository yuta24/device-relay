# start --background / status / stop

See "バックグラウンドで動かす" in docs/sessions.md of device-relay for details.

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
| 1 | The child `relay start` exited before ready (build failure, device not found, `Failed to initialize for UI testing`, and so on). The runner in `~/.relay/runner.json` already answers on the same port (it points to `relay stop`; use that runner instead, and stop it only if you started it). Another `relay start` on the same port is still booting or building (`another relay start ... is starting or running a runner on port ...`; wait for `relay status` to return 0 and use that runner). Interrupted while waiting |
| 3 | Timed out (30 minutes until launch, then `--ready-timeout` + 15 seconds) |

On failure it stops the child (including an xcodebuild in progress, and a simulator relay booted is shut down), and prints the last 20 lines of the log, the cause, and the log's path (`(log: …)`) to stderr. If the end of the log isn't enough, read the whole file.

**`relay status [--json]`**: shows the contents of runner.json (found in the same order as [Where the runner is found (runner.json)](sessions.md#where-the-runner-is-found-runnerjson); `--runner <path>` also works) and the `/ping` result.

```
url:         http://127.0.0.1:8100/
device:      <device name> (<UDID>)
pid:         <PID> (relay start running)
started:     <date and time>
host app:    <bundle ID of RelayRunnerHost>
ping:        ok (idle)
runner:      0.6.0 (sources <12 characters>)
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
| 1 | `relay start` didn't exit within 180 seconds (including shutdown of a simulator it booted). Look at `~/.relay/logs/start-*.log` and tell the user |
