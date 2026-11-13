# The app for trying things out

RelayRunnerHost is installed with the runner. Its bundle ID differs per user (`<prefix>.RelayRunnerHost`), so in relay commands write `host` in place of the bundle ID (`relay launch host`, `--bundle-id host`). The actual ID appears as `host app` in `relay status`. You can try operations on it in place of a target app. Identifiers: `relay.input` / `relay.input2` (text fields; `relay.input2` doesn't take select all, Cmd-A, to try the second way of `relay type --clear`), `relay.password` (password field; `secureTextField`), `relay.notes` (multi-line field; return adds a line), `relay.text`, `relay.passwordLength`, `relay.submitted`, `relay.events`, `relay.showToast` (shows the label `relay.toast` and removes it after 1.5 seconds, to try `relay find --gone`), `relay.gestures` (opens the screen below) ("検証用のホストアプリ" in docs/development.md of device-relay).

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

`relay.gestures` opens a screen for double taps, sliders, and pickers ([gestures-and-controls](gestures-and-controls.md)). Identifiers: `relay.gestures.close` (back to the first screen), `relay.tapTarget` (a view that tells a double tap from two taps), `relay.tapCounts` (how often each fired: `single: 2, double: 1`), `relay.tapReset` (counts back to 0), `relay.animate` (starts or stops an animation that keeps the app from going idle, to try XCUI's idle waits; label `Animate: on` / `Animate: off`), `relay.slider` (continuous, 0.3 at first) and `relay.steppedSlider` (0.25 steps, 0.5 at first), `relay.sliderValue` (`slider: 0.30, stepped: 0.50`), `relay.datePicker` (wheels for month, day, and year, without identifiers; en_US, UTC, 2026-06-15 at first), `relay.dateValue` (`date: 2026-06-15`), `relay.picker` (two wheels: 8 fruits and 1–20; `Banana`, `3` at first), `relay.pickerValue` (`picker: Banana, 3`).

```sh
relay tap --id relay.gestures --timeout 3
relay tap --id relay.tapTarget --count 2       # adds 1 to double in relay.tapCounts
relay adjust --id relay.steppedSlider --position 0.75
relay adjust --type pickerWheel --value June --picker-value March   # the date picker's month
relay find --id relay.dateValue                # its label is "date: 2026-03-15"
```
