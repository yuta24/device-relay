# Double taps, sliders, and pickers

`relay tap --count 2` double-taps, and `relay adjust` sets a slider or a picker wheel. The other options of `tap` are in [commands](commands.md).

## Double-tapping

`relay tap (<x> <y> | <selector>) --count 2` taps the same point twice as one gesture: to zoom a map or a photo, or to select a word.

- `--count` is `1` or `2`; anything else is exit 2. Only `tap` takes it, not `press`.
- Two `relay tap` commands in a row are not a double tap. Their gap depends on the round trip: on a physical device, two element taps in a row were two single taps every time.
- With a selector, both taps go to the point the element resolved to once. `--timeout`, `--bundle-id`, `--mode`, and the failures (`covered_by_other_app`, `element_point_covered`, …) are as for one tap.
- The answer adds `"taps":2`. relay waits 0.15 seconds more for it.
- An old runner ignores `--count` and taps once; relay then fails with `runner_bad_response` (exit 8). Don't retry: the screen already got one tap. If you started the runner, `relay stop`, then `relay start --rebuild`.

## Sliders and pickers

```sh
relay adjust --id volume --position 0.5                              # a slider: 0 is the left end, 1 the right
relay adjust --type pickerWheel --value June --picker-value March   # the wheel that shows June now
relay adjust --type pickerWheel --index 2 --picker-value 2030       # the third wheel on the screen
```

- For a slider, use `adjust --position`, not `swipe`. relay drags it on until it is within 0.02 of the target.
- For a picker, set its wheels (`pickerWheel`), not the `picker` / `datePicker` itself. `--picker-value` is the text the wheel shows (`June`, `15`, `2026`), exactly.
- A date picker is one wheel per column (month, day, year), and its wheels have no identifier. Set each column in turn, picking it with `--type pickerWheel --value <what it shows now>` or `--index` (`relay find --type pickerWheel`: `index` counts all the wheels on the screen).
- Check the result in the answer: `{"ok":true,"bundleId":…,"element":{…},"value":"50%","position":0.503}`. `value` (and `position`, for a slider) is read again after setting it; `element` is as it was before.
- The selector, `--timeout`, `--bundle-id`, and `covered_by_other_app` work as for `tap`.

### When it fails (exit 6)

- `element_not_adjustable`: the element isn't a slider (`--position`) or a wheel (`--picker-value`); nothing changed. Check its type with `relay find`, and pick a wheel with `--type pickerWheel`.
- `adjust_failed`: it ended elsewhere, and `value` (and `position`) is what it shows now. It may have moved, so read it before retrying.
  - A slider of steps stops only at its steps: `0.6` on one of 0.25 steps ended at `0.5`. Send a value on a step.
  - A value the wheel doesn't have (`Mango`) fails at once, and `error` lists the wheel's values (`… which is not one of the possible values Apple, Banana, …`). Pick one of them.
  - A day the month doesn't have: `30` in February ended with `value` `28`; `31` in June stopped at `30`, and the date did change to that day. Read `value`, and send a day the month has.
- An old runner doesn't know `adjust`: `not_found` (exit 7). If you started the runner, `relay stop`, then `relay start --rebuild`.

### Time

- A slider took about 2–4 seconds, a wheel under 1. The runner is busy meanwhile (others get exit 5).
- XCUI waits for the app to be idle before and after setting it, and that can't be cut short. On a screen that never goes idle (a repeating animation), it gives up after about 60 seconds each, so an adjust took about 120 seconds: a wheel was still set, but a slider got `adjust_failed` uncorrected (no correction starts 10 seconds after the adjust).
- relay waits 30 seconds + `--timeout` + 140.25 seconds for the answer. Give your own command a longer timeout than that.

### iPad windows

In a window that fills only part of an iPad screen, `adjust` works, but a slider's thumb within about 30 pt of the window's left or right edge (at position 0 or 1) can't be grabbed: the system's window controls take the touch, and it is `adjust_failed` with the `position` unchanged. Move or widen the window so the thumb is away from the edge ([coordinates](coordinates.md)).

Checked on an iPhone 18 Pro simulator (iOS 27.2), an iPad Pro 11-inch (M5) simulator (iPadOS 26.2, windowed), and an iPhone 14 Pro (iOS 26.7.1), on the `relay.gestures` screen of the host app ([test-app](test-app.md)). A screen that never goes idle was checked only on the iPhone simulator.
