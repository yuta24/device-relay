# Logs and crash reports (relay logs, relay crashes)

When a check fails, read what the app logged and whether it crashed, besides the screen and the element tree. Both commands run on the Mac without the runner (they work while it is busy) and print one JSON object on stdout, failures included. The target is the runner's device, as for the other commands (`--session`, `--runner`), or `--udid <udid>` from `relay devices`, which needs no runner (after `relay stop`, for example). See "ログとクラッシュ記録（relay logs / relay crashes）" in docs/cli.md and `relay logs --help`.

| | Simulator | Physical device |
| --- | --- | --- |
| Past log | Yes | No: collecting needs a Mac administrator; relay does not run sudo (`logs_permission_denied`) |
| `--follow` | Yes | No (`logs_follow_unsupported`) |
| `--bundle-id` | Yes | No (`logs_filter_unsupported`) |
| Filters: `--level`, `--subsystem`, `--category`, `--grep`, `--limit` | Yes | Only with `--archive`, not on the device itself |
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
- The log has Logger, os_log, and NSLog lines. `print()` output (stdout/stderr) is not in it. Debug lines are not kept in the past log; only `--follow` shows them (`--level debug` doesn't bring them back).
- `--bundle-id` keeps the app's main executable as installed now: not its extensions, nor lines from an earlier build. `log_app_unavailable` (1): the app isn't installed on the simulator; check the bundle ID (case-sensitive). `--bundle-id host` is the runner's host app.
- Without `--bundle-id` the whole simulator is logged; when the lines kept for the output exceed about 64 MiB, it fails with `logs_unavailable`: use a later `--since`, `--bundle-id`, a filter such as `--level error`, or `--limit` (a smaller N if it is already given).
- `-o <file>` writes the JSON to a new file (mode 0600) and prints a summary with its `path`; an existing file is `logs_save_failed`.
- Logs can hold personal data: don't paste long excerpts; quote only the lines that matter.

## Narrowing the log

`--level`, `--subsystem`, `--category`, and `--grep` work on every read: the past log, `--follow`, and `--archive`. `--limit` works on the past log and `--archive`, not with `--follow`. Giving several keeps only the lines that match all of them (AND).

| Option | Keeps |
| --- | --- |
| `--level <level>` | That severity and the ones above it: `debug`, `info`, `default`, `error`, `fault` |
| `--subsystem <name>` | The whole subsystem value |
| `--category <name>` | The whole category value |
| `--grep <text>` | A case-sensitive literal substring of the message; not a regular expression |

An empty value is a usage error (2). A text that starts with `--` is written as `--grep=--text`.

`--limit <N>` (N >= 1) keeps the newest N of all the matches, oldest first. `count` is then the number returned, `matchedCount` the number matched, `truncated` whether any match was left out, and `range.firstEntryAt` the first returned line. It cannot be combined with `--follow` (2).

When the log is large, read less:

```sh
relay logs --bundle-id com.example.app --since 10m --level error --limit 20
```

0 entries after narrowing still doesn't prove the app logged nothing.

## Following (simulators)

`relay logs --follow [--bundle-id <id>] [<filters>] [-o <file>] [<target>]` prints NDJSON: `{"type":"start",…}`, one `{"type":"log",…}` per line, and `{"type":"end","reason":"SIGINT",…}` when stopped with SIGINT or SIGTERM (exit 130 / 143). An error after the start is a last `{"type":"error","ok":false,"code":…,"partial":true}` (exit 1). It never ends by itself: run it in the background and stop it, or prefer a past log with `--since`. It takes no `--since`, `--archive`, or `--limit` (2); the filters do work with it.

## Physical devices

- `relay logs` on a device fails with `logs_permission_denied`; `hint` has the command. Don't run sudo yourself: ask the user to run `sudo log collect --device-udid <udid> --start @<time> --output <dir>/device.logarchive`, then read it with `relay logs --archive <dir>/device.logarchive --udid <udid>` (the whole archive unless `--since`; `deviceVerified` is false; no `--bundle-id`). Pass `--udid`: with a session selected (`RELAY_SESSION`) but no runner.json, it is exit 3. Only an administrator account can run that sudo; on a non-admin account (`is not in the sudoers file`) the device log can't be collected at all, so tell the user that instead. The filters and `--limit` work with `--archive`; `--bundle-id` still does not (`logs_filter_unsupported`). Filtering an archive is checked with one collected from a simulator; an archive collected from a device is not checked.
- `relay crashes` on a device lists `.ips` files without opening them: `processHint` comes from the file name, `modifiedAt` is when it was written, `bundleID` is null. `--bundle-id` is `crash_filter_unsupported`. Save one with `--name <relativePath> -o <dir>`; `-o` without `--name` is a usage error (2). Save only what the task needs: reports of other apps hold their data.

| `code` | Exit code | What to do |
| --- | --- | --- |
| `device_unavailable` | 1 | The UDID isn't a simulator or connected device, or the simulator isn't booted (logs): check `relay devices`; relay doesn't boot it |
| `logs_unavailable` | 1 | `log` failed, timed out, printed something unreadable, or too much: read `error`; use a later `--since`, a filter, or `--limit` |
| `logs_permission_denied` | 1 | Device log: ask the user to run the `hint` command |
| `logs_follow_unsupported` / `logs_filter_unsupported` | 1 | `--follow` on a device, or `--bundle-id` on a device or with `--archive`: drop the option |
| `log_app_unavailable` | 1 | App not installed on the simulator: check the bundle ID |
| `logs_save_failed` / `crashes_save_failed` | 1 | The file exists or the directory is missing: give another path (don't delete the user's files) |
| `crashes_unavailable` | 1 | The list failed, or `--name` isn't in it: list again (`--name` ignores `--since` and `--bundle-id`) |
| `crash_filter_unsupported` | 1 | Device: use `processHint` and `--name` |
| `runner_unavailable` | 3 | No runner.json: pass `--udid <udid>` |
