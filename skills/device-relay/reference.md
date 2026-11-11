# device-relay reference

This supplements [SKILL.md](SKILL.md). For anything not here, see the device-relay README and the documents in docs/, or `relay --help` / `relay <command> --help`. `--help` (also `-h` and `relay help <command>`) exists for every subcommand. The documents in docs/ are in Japanese, so their file and section names are given as they appear there, in quotation marks.

Each file in `references/` stands alone; read only the one you need.

- [starting-and-stopping](references/starting-and-stopping.md): `start` options, which device, the app, status/ping/health, doctor, skill
- [start-status-stop](references/start-status-stop.md): their output and exit codes
- [sessions](references/sessions.md): runner.json lookup, parallel sessions
- [sandbox](references/sandbox.md): `Operation not permitted`
- [commands](references/commands.md): runner commands' options, timeouts, opening URLs and deep links, installing apps (`relay install`)
- [element-tree](references/element-tree.md): `source` formats, `--filter interactive`, selectors
- [system-alerts](references/system-alerts.md): permission dialogs, SpringBoard targeting, exact labels
- [failures](references/failures.md): all exit codes, `code`s, `reason`s
- [coordinates](references/coordinates.md): orientation, iPad windows, iPhone Duo
- [scrolling](references/scrolling.md): to an element off the screen
- [recording](references/recording.md): `relay record`
- [logs](references/logs.md): `relay logs`, `relay crashes`
- [relay-run](references/relay-run.md): replaying confirmed steps
- [test-app](references/test-app.md): RelayRunnerHost, to try things on
- [troubleshooting](references/troubleshooting.md): start failures, prompts, logs
