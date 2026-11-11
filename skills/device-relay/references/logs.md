# Logs and crash reports (relay logs, relay crashes)

When a check fails, read what the app logged and whether it crashed, besides the screen and the element tree. Both commands run on the Mac without the runner (they work while it is busy) and print one JSON object on stdout, failures included. The target is the runner's device, as for the other commands (`--session`, `--runner`), or `--udid <udid>` from `relay devices`, which needs no runner (after `relay stop`, for example). See "ログとクラッシュ記録（relay logs / relay crashes）" in docs/cli.md and `relay logs --help`.

| | Simulator | Physical device |
| --- | --- | --- |
| Past log | Yes | No: collecting needs a Mac administrator; relay does not run sudo (`logs_permission_denied`) |
| `--follow` | Yes | No (`logs_follow_unsupported`) |
| `--bundle-id` | Yes | No (`logs_filter_unsupported`) |
| Crash report list | With process, bundle ID, and crash time | Candidates by file name only; the reports are not opened |
| Saving reports (`-o <dir>`) | Yes | Only the one `--name <relativePath>` chooses (not verified) |

## Getting the log of a test

```sh
date -u +%Y-%m-%dT%H:%M:%SZ                  # note the time before the test, e.g. 2026-11-11T01:40:24Z
relay logs --bundle-id <bundle-id> --since 2026-11-11T01:40:24Z
relay crashes --since 2026-11-11T01:40:24Z
```

- `--since` takes `30s`, `5m`, `2h`, `1d`, or an RFC 3339 time with a time zone. Default: 5 minutes for `logs`, 24 hours for `crashes`. A time without a zone is a usage error (2).
- Read `entries[].message` and `level` (`error` lines first). 0 entries doesn't prove nothing was logged: `--since` is not a retention guarantee.
- The log has Logger, os_log, and NSLog lines. `print()` output (stdout/stderr) is not in it. Debug lines are not kept in the past log; only `--follow` shows them.
- `--bundle-id` keeps the app's main executable as installed now: not its extensions, nor lines from an earlier build. `log_app_unavailable` (1): the app isn't installed on the simulator; check the bundle ID (case-sensitive). `--bundle-id host` is the runner's host app.
- Without `--bundle-id` the whole simulator is logged; more than 64 MiB of JSON fails with `logs_unavailable`: use a later `--since` or `--bundle-id`.
- `-o <file>` writes the JSON to a new file (mode 0600) and prints a summary with its `path`; an existing file is `logs_save_failed`.
- Logs can hold personal data: don't paste long excerpts; quote only the lines that matter.

## Following (simulators)

`relay logs --follow [--bundle-id <id>]` prints NDJSON: `{"type":"start",…}`, one `{"type":"log",…}` per line, and `{"type":"end","reason":"SIGINT",…}` when stopped with SIGINT or SIGTERM (exit 130 / 143). An error after the start is a last `{"type":"error","ok":false,"code":…,"partial":true}` (exit 1). It never ends by itself: run it in the background and stop it, or prefer a past log with `--since`. It takes no `--since` or `--archive` (2).

## Physical devices

- `relay logs` on a device fails with `logs_permission_denied`; `hint` has the command. Don't run sudo yourself: ask the user to run `sudo log collect --device-udid <udid> --start @<time> --output <dir>/device.logarchive`, then read it with `relay logs --archive <dir>/device.logarchive --udid <udid>` (the whole archive unless `--since`; `deviceVerified` is false; no `--bundle-id`). Pass `--udid`: with a session selected (`RELAY_SESSION`) but no runner.json, it is exit 3. Only an administrator account can run that sudo; on a non-admin account (`is not in the sudoers file`) the device log can't be collected at all, so tell the user that instead. `--archive` has not been verified with a real logarchive.
- `relay crashes` on a device lists `.ips` files without opening them: `processHint` comes from the file name, `modifiedAt` is when it was written, `bundleID` is null. `--bundle-id` is `crash_filter_unsupported`. Save one with `--name <relativePath> -o <dir>`; `-o` without `--name` is a usage error (2). Save only what the task needs: reports of other apps hold their data.

| `code` | Exit code | What to do |
| --- | --- | --- |
| `device_unavailable` | 1 | The UDID isn't a simulator or connected device, or the simulator isn't booted (logs): check `relay devices`; relay doesn't boot it |
| `logs_unavailable` | 1 | `log` failed, timed out, printed something unreadable, or too much: read `error`; narrow `--since` |
| `logs_permission_denied` | 1 | Device log: ask the user to run the `hint` command |
| `logs_follow_unsupported` / `logs_filter_unsupported` | 1 | Not on a device (or with `--archive`): drop the option |
| `log_app_unavailable` | 1 | App not installed on the simulator: check the bundle ID |
| `logs_save_failed` / `crashes_save_failed` | 1 | The file exists or the directory is missing: give another path (don't delete the user's files) |
| `crashes_unavailable` | 1 | The list failed, or `--name` isn't in it: list again |
| `crash_filter_unsupported` | 1 | Device: use `processHint` and `--name` |
| `runner_unavailable` | 3 | No runner.json: pass `--udid <udid>` |
