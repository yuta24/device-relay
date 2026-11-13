# The app for trying things out

RelayRunnerHost is installed with the runner. Its bundle ID differs per user (`<prefix>.RelayRunnerHost`), so in relay commands write `host` in place of the bundle ID (`relay launch host`, `--bundle-id host`). The actual ID appears as `host app` in `relay status`. You can try operations on it in place of a target app. Identifiers: `relay.input` / `relay.input2` (text fields; `relay.input2` doesn't take select all, Cmd-A, to try the second way of `relay type --clear`), `relay.password` (password field; `secureTextField`), `relay.notes` (multi-line field; return adds a line), `relay.text`, `relay.passwordLength`, `relay.submitted`, `relay.events`, `relay.showToast` (shows the label `relay.toast` and removes it after 1.5 seconds, to try `relay find --gone`) ("検証用のホストアプリ" in docs/development.md of device-relay).

```sh
relay launch host
relay tap --id relay.input --timeout 3
relay type "hello" --key return
relay find --id relay.submitted       # its label is "submitted #1: hello"
```

```sh
relay tap --id relay.input --timeout 3
relay type --clear "replaced"         # relay.text becomes "text: replaced"
relay tap --id relay.showToast
relay find --id relay.toast --gone --timeout 5 --require
```
