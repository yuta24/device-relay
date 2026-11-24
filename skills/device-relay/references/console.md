# Console output at launch (relay launch --console, relay console)

When the app's `print()` output or its stdout/stderr is what you need, capture it on a simulator with `relay launch <bundle-id> --console <new-file>`, then read the file. It is not in `relay logs` ([logs](logs.md)). Simulators only: a physical device and a step of `relay run` cannot use it. See "起動時のコンソール採取（シミュレータ）" in docs/cli.md and `relay launch --help`.

```sh
relay launch <bundle-id> --console ./app.log   # start, or restart with --restart
# operate, or wait
cat ./app.log                                  # what the app printed from launch
relay console stop <captureID>                 # stop; the app may go with it
```

| Command | Output, exit code |
| --- | --- |
| `relay launch <bundle-id> [--console <new-file> [--restart]]` | The usual JSON, plus `console`: the absolute `path`, `backend` (`simctl-pty`), `stream` (`combined`), `captureID`, `state`, `byteLimit`, `limitReached`, `saveError`. The capture starts before the app is in front, and the captureID and its stop command go to stderr (`relay: console capture <id>; stop with relay console stop <id>`) as soon as the worker starts |
| `relay console status [<captureID>]` | No runner needed. Without an ID it returns a JSON array of every capture (all sessions; `[]` when there is none) and exits 0; with an ID, that one capture. 1 with a `console_*` code, or 2 for a usage error such as a malformed ID |
| `relay console stop <captureID>` | The ID is required. Stops the capture, waiting up to 12 seconds, and prints it with `appState`. 0, 1 with a `console_*` code, or 2 for a missing or malformed ID |

- The app must not be running: exit 1 with `console_requires_restart`. `--restart` terminates it first, then launches it again, so use it only when the user agrees the app may be terminated. A failed launch can leave the app stopped. `--restart` without `--console` is a usage error (2).
- The output must be a new file outside `~/.relay/consoles`, in a directory that exists. An existing file or a symbolic link fails (`console_save_failed`). Relay never overwrites or deletes an existing file, but when a launch fails it may remove the empty file it created, so pick a name of your own.
- The file is mode 0600 and holds the bytes of one PTY: stdout and stderr are mixed and can't be told apart. Control characters and bytes that are not UTF-8 stay in it.
- 16 MiB is the limit (16,777,216 bytes). Past it the rest is dropped (`limitReached: true`) while the app keeps running. Prefer a short session over a long one.
- The capture runs in a process detached from your terminal, so commands after `launch` are fine, and it continues after `launch` returns. Ctrl-C during `launch` leaves the startup and the capture running: the captureID is on stderr, and `relay console status` finds it.
- `launch --console` waits up to about 178 seconds for the capture to be recording before it sends the request; the request then waits up to 150 seconds. Make your own command's timeout longer than that, and don't repeat the launch while it runs.
- If bringing the app to the front fails, `launch` still exits with that error and its JSON carries `console`, so you can stop the capture with its `captureID`. Captures also end with the app's exit, a crash, the runner stopping, or the simulator shutting down.
- `stop` may terminate the app: simctl forwards the signal to it. `appState` says `ended`, `running`, or `unknown`, judged from the captured process's PID and start time (a crash can look like a normal simctl exit). Stopping an already ended capture exits 0 with the same reason.
- A `stop` that times out still leaves the stop request pending: check with `relay console status <captureID>`.
- Captures are recorded under `~/.relay/consoles` and pruned 7 days after they end; the output file is not removed. Check the record's `path`, device, and bundle ID to tell captures apart.
- Console output can hold personal data: don't paste long excerpts, quote only the lines that matter. Delete the output file only when the user agrees.

| `code` | Exit code | What to do |
| --- | --- | --- |
| `console_requires_restart` | 1 | The app is running: add `--restart` (it will be terminated) or `relay terminate` first, then launch |
| `console_unsupported` | 1 | The target is not a simulator: drop `--console`, and read the log with `relay logs` instead |
| `console_unavailable` | 1 | Another console launch is in progress (find and stop it with `relay console status` / `console stop`), the process that owns the runner ended, simctl failed to launch, or start/stop timed out. Read `relay console status`: when it lists the capture, stop it or continue with that captureID; otherwise launch again |
| `console_save_failed` | 1 | The new file or the state could not be created, or a write during the capture failed (`saveError`). Choose a new path outside `~/.relay/consoles` in an existing directory |
| `console_not_found` | 1 | No record for that captureID: list the captures with `relay console status` and use the ID it prints |
| `console_ownership_unverified` | 1 | The state is damaged, or the process and the state disagree. Check `path`, device, and bundle ID in `relay console status`, and run status again once the process has ended. It also appears when `stop` runs before the worker has registered itself: wait a moment and run it again |
