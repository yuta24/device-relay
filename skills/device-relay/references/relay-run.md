# Running scenarios (relay run, experimental)

This is an experimental feature. How steps are written and the output may change. Use it to replay fixed or already-confirmed steps in one call. Go through an unfamiliar screen one command at a time while observing first.

1. Write the confirmed steps to `<name>.relay` (ask the user whether to keep it in the repository). Where the screen changes, wait with `find <selector> --timeout 5 --require` or `tap … --timeout 5`.
2. Validate it with `relay run <file> --check`, then replay it with `relay run <file>`.
3. If it fails, observe the screen where it stopped (screenshot, `relay source --format compact --filter interactive`), fix the selector or wait on line N, and go back to step 2.

```sh
relay run steps.relay        # a file (one step per line; blank lines and lines starting with # are ignored)
relay run - < steps.relay    # standard input
relay run --step "launch <bundle-id>" --step "tap --id login.button --timeout 5" --step "find --id home.title --timeout 5 --require"
relay run steps.relay --check   # validate only (no runner needed, runs nothing; 0 if there are no problems)
```

- Steps are runner commands without `relay` (`tap`, `press`, `swipe`, `type`, `key`, `button`, `orientation`, `launch`, `open`, `terminate`, `find`, `source`, `screenshot`, `health`, `foreground`, `ping`) and `sleep <seconds>` (up to 60). `start` / `stop` / `shutdown` and the like can't be written.
- Words split as in a shell (spaces, `'...'`, `"..."`, `\`). `--runner` and `--session` go on `relay run` and can't be in a step. `type --stdin` can't be used either. `screenshot` requires `--output <file>`.
- For a scenario you save, write `# relay-run: 1` (the format version) on the first line. For an unsupported version, that line is an error and nothing runs.
- All lines are checked before running. For an invalid line it prints `relay: line <N>: <reason>`, runs nothing, and exits 2 (stderr only). You can check a scenario you wrote with `--check` before running it.
- While running, it stops at the first step that fails, prints that step's error and `relay: step i/n (line N) failed: <step>`, and exits with that step's exit code (1, 3–8; 1 when a screenshot couldn't be saved).
- A step means the same as the command alone. To confirm an element, wait with `find <selector> --timeout <seconds> --require`, which stops there if it doesn't appear (exit code 6). `find` without `--require` continues even with no match. A fixed `sleep` is the last resort.
- Each step's stdout (including a failed step's `{"ok":false,"code":…}`) goes to stdout as it is, and per-step progress (`relay: [i/n] … ok (… ms)`) and the total go to stderr (`--quiet` removes them). Progress and failure lines mask `type` text as `***`, but the scenario file keeps what is written in it. Don't write passwords the user gave you in a scenario (use `relay type --stdin`, one command at a time).
