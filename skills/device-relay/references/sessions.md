# Where the runner is found (runner.json)

Runner commands read the URL and token from a runner.json found in this order (the token can't be passed on the command line).

1. `--runner <path>` or `--session <name>` (not both)
2. The environment variable `RELAY_RUNNER` or `RELAY_SESSION` (both is a usage error, exit code 2)
3. `~/.relay/runner.json` (where `relay start` without a session writes it)

If the file or session named in 1 or 2 doesn't exist, the exit code is 3, without looking at 3. `.relay/runner.json` in the current directory or its parents is not read (to prevent 401s from stale files left by earlier versions). If 3 is missing and such a file exists, the error says `.relay/runner.json in <dir> is no longer read; pass --runner <path> to use it`. Use a file you placed by hand with `--runner <path>`. If exit code 4 persists, check that `--runner` / `$RELAY_RUNNER` doesn't point to a stale file.

## Sessions

When several agents work in parallel, keep them in separate sessions (names start with a letter or digit, with up to 64 letters, digits, `.`, `_`, and `-`). Check `echo "$RELAY_SESSION"` first: if the user set it when launching the agent (`RELAY_SESSION=agent-1 claude`, for example), every command already uses that session. If it isn't set, add `--session <name>` to every command. In environments that start a new shell for each command, `export` doesn't carry over to the next one, and a command without the session either exits 3 or operates someone else's runner.

```sh
relay status --all                                                     # every session (which devices are in use)
relay start --background --session agent-1 --device "<name>" --os 27.0  # one device per session; the port is automatic
relay tap --session agent-1 --id <id>                                  # reaches only your runner
relay stop --session agent-1                                           # stops only your session
```

Don't stop other sessions' runners, and don't use `relay stop --all`.

| What is separate | Details |
| --- | --- |
| runner.json | `~/.relay/sessions/<name>/runner.json`. Nothing is written to `~/.relay/runner.json`, and it doesn't fall back to other files |
| Port | Without `--port`, a free one in `8101`–`8199`, shown on the `ready:` line. Only `relay start`s reserve ports among themselves, so if another process takes it first, launching the runner fails (`Address already in use` in the log). Start again and it picks the next free one |
| Device | One runner per device (also without a session). Naming a device in use exits 1 with an error that names its owner. Omitting the device leaves those in use out of the candidates. With a session, of several free booted simulators it picks the first (newest iOS, then name; if another start takes it at the same moment, the next one; several physical devices is an error listing the candidates) |
| Build | Shared. Builds to the same DerivedData go one at a time, and during another start's build and while launching from the same build (until ready), relay prints `waiting for another relay start's build` and waits. It can take minutes but isn't a failure |
| Logs | `~/.relay/logs/start-<time>-<name>-<port>.log` and so on |

If a command without a session uses the file from 3, and other sessions are running, stderr gets `relay: warning: no session selected; using <path>, while sessions <names> are running; pass --session or set RELAY_SESSION`. The exit code doesn't change. If you meant your own runner, add `--session` and check which device that operation reached.

`relay status --all [--json]` lists every session and the runner in `~/.relay/runner.json` (`(default)`; `session` is `null` in JSON), with SESSION, STATE, DEVICE, URL, and PID. STATE is `starting`, `running`, `busy`, `no answer`, `rejected`, or `unknown`. The exit code is always 0. `relay stop --session <name>` also stops a session that is still building. See "複数のセッションを並列に動かす" in docs/setup.md of device-relay.
