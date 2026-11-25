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

- `relay console status` and `relay console stop` take neither `--session` nor `--runner`: adding one is a usage error (2). SKILL.md's `--session` on every command leaves these two out, since both read `~/.relay/consoles` on the Mac: `status` without an ID reports the captures of every session, and `stop` picks its capture by the captureID you give it. `relay launch --console` does take `--session` (or `--runner`), as the other runner commands do.
- `state` is `starting` (the record exists, before the app's output is captured), `recording`, or `ended` (with a `reason`). A record relay cannot verify shows `state` `ownership_unverified` and a `code` (see `console_ownership_unverified`) instead of these. That is what the list from `status` without an ID shows, and what the failure JSON of `launch --console` shows when it cannot verify the capture or the app (exit 1).
- The app must not be running: exit 1 with `console_requires_restart`. `--restart` terminates it first, then launches it again, so use it only when the user agrees the app may be terminated. A failed launch can leave the app stopped. `--restart` without `--console` is a usage error (2).
- The output must be a new file outside `~/.relay/consoles`, in a directory that exists. An existing file or a symbolic link fails (`console_save_failed`). Relay never overwrites or deletes an existing file, but when a launch fails it may remove the empty file it created, so pick a name of your own.
- The file is mode 0600 and holds the bytes of one PTY: stdout and stderr are mixed and can't be told apart. Control characters and bytes that are not UTF-8 stay in it.
- 16 MiB is the limit (16,777,216 bytes). Past it the rest is dropped (`limitReached: true`) while the app keeps running. Prefer a short session over a long one.
- The capture runs in a process detached from your terminal, so commands after `launch` are fine, and it continues after `launch` returns. Ctrl-C during `launch` leaves the startup and the capture running: the captureID is on stderr, and `relay console status` finds it.
- `launch --console` waits up to about 178 seconds for the capture to be recording before it sends the request; the request then waits up to 150 seconds. Make your own command's timeout longer than that, and don't repeat the launch while it runs.
- `launch --console` checks the capture and the captured app (PID and start time) just before it asks for the app to be brought to the front, and again after the runner reports success. On a launch that exits 0, read `console.state`: `recording` is what relay saw at that moment, and the app can end after it. An empty file or output that stops early does not prove the app printed nothing; check `state` with `relay console status <captureID>` before deciding that.
- If the capture or the app recorded in it has ended, `launch` exits 1 with `console_unavailable` and a `console` object. The app may be in front as a different process, and its output is not captured. The app alone can end while `console.state` stays `recording` with `console.appState` `ended`, so check both. Relay neither launches nor captures again: to capture it, choose a new file name and, if the app is running, pass `--restart` (only when the user agrees, as above).
- When relay cannot verify the capture record or its worker, `launch` also exits 1, with `console.state` `ownership_unverified` and a `code` naming what failed (`console_ownership_unverified`, or `console_not_found` when the record is gone). When it cannot verify the app, `console.appState` is `unknown`. The capture may still be running, so read `relay console status` before launching again.
- If the runner fails to bring the app to the front, `launch` still exits with that error and its JSON carries `console`, so you can stop the capture with its `captureID`. Captures also end with the app's exit, a crash, the runner stopping, or the simulator shutting down.
- `stop` may terminate the app: simctl forwards the signal to it. `appState` says `ended`, `running`, or `unknown`, judged from the captured process's PID and start time (a crash can look like a normal simctl exit). Stopping an already ended capture exits 0 with the same reason.
- A `stop` that times out still leaves the stop request pending: check with `relay console status <captureID>`.
- Captures are recorded under `~/.relay/consoles` and pruned 7 days after they end; the output file is not removed. Check the record's `path`, device, and bundle ID to tell captures apart.
- Console output can hold personal data: don't paste long excerpts, quote only the lines that matter. Delete the output file only when the user agrees.

| `code` | Exit code | What to do |
| --- | --- | --- |
| `console_requires_restart` | 1 | The app is running: add `--restart` (it will be terminated) or `relay terminate` first, then launch |
| `console_unsupported` | 1 | The target is a physical device: relay cannot capture `print()` or stdout/stderr there, so drop `--console` (a simulator captures it). `relay logs` is no substitute for those writes: it reads only Logger, os_log, and NSLog lines |
| `console_unavailable` | 1 | Another console launch is in progress (find and stop it with `relay console status` / `console stop`), the process that owns the runner ended, simctl failed to launch, start/stop timed out, or the capture or the app ended before or during foreground activation. Read `relay console status`: continue with a captureID only when the failure JSON does not show that end and its `state` is `recording`; if it ended, launch again with a new file name (and `--restart` when the app is running and the user agrees). When the app alone ended, stop that `recording` capture before launching again |
| `console_save_failed` | 1 | The new file or the state could not be created, or a write during the capture failed (`saveError`). Choose a new path outside `~/.relay/consoles` in an existing directory |
| `console_not_found` | 1 | No record for that captureID: list the captures with `relay console status` and use the ID it prints |
| `console_ownership_unverified` | 1 | The state is damaged, or the process and the state disagree. Check `path`, device, and bundle ID in `relay console status`, and run status again once the process has ended. It also appears when `stop` runs before the worker has registered itself: wait a moment and run it again |
