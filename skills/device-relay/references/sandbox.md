# Using relay from inside a sandbox

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
- The same goes for other agents: use a setting that runs relay outside the sandbox. See "エージェントの sandbox から使う" in docs/sessions.md of device-relay.
