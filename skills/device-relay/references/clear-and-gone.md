# Clearing a field and waiting for an element to go

`relay type --clear` empties a text field before typing, and `relay find --gone` waits for an element to go away. The other options of `type` and `find` are in [commands](commands.md).

## Clearing a field

`relay type --clear "new text"` empties the field with keyboard focus, then types. Use it to replace a field's text, not repeated `delete`.

- It sends select all (Cmd-A) and delete. Where select all doesn't work, it moves to the end (Cmd-↓) and deletes what is left, one visible character per delete (emoji included), wherever the cursor is.
- It reads the field's `value` again. Empty means `null`, `""`, or the same as its `placeholder`. A field already empty gets no keys.
- Not empty: nothing is typed, and it exits 6 with `code` `clear_failed`. `remaining` is the number of characters left, never the text ([List of codes](failures.md#list-of-codes)).
- The second way deletes up to 200 characters a time: a longer field without select all gets `clear_failed`, and sending `--clear` again deletes the rest.
- With no keyboard focus, it is `no_keyboard_focus` and nothing is sent, as for plain `type`.
- relay waits 33 seconds more for the answer (23 for clearing, 10 for the runner to give up). Past its own limit the runner answers `typing_failed`.
- Not checked on a physical device. If Cmd-A and Cmd-↓ don't arrive there, a field with the cursor in the middle may get `clear_failed`.
- An old runner ignores `--clear` and types after the old text, then relay fails with `runner_bad_response` (exit 8). Don't retry: check the `value` with `relay find`, and if you started the runner, `relay stop`, then `relay start --rebuild`.

Checked on an iPhone 18 Pro simulator (iOS 27.2) with a hardware keyboard connected: both ways emptied single-line, password, and multi-line fields in about 0.7–2.1 seconds.

## Waiting for an element to go

`relay find <selector> --gone --timeout <s> --require` waits for no element to match: a loading indicator, a sheet, or an alert going away. Use it instead of `sleep`.

- Gone means no matching element in the element tree, the same test as `"count":0`. An element off the screen or with an empty frame still counts as there; the frame isn't looked at.
- The answer adds `gone` (`true` / `false`). When the time runs out, it is still exit 0 with `gone:false` and the elements left; with `--require` it is exit 6, `code` `element_still_present` (decided by relay).
- An element that never matched is `gone:true` at once, so a wrong selector also succeeds. Check the selector with a plain `relay find` first.
- `--index` can't be used with `--gone` (exit 2). `--limit` applies to the list of elements left.
- The app is chosen once at the start, as for `--timeout`. For a system dialog, add `--bundle-id com.apple.springboard`.
- If the app's tree can't be read during the wait (the app ended, for example), it fails at the end with `xcui_failed` (exit 6).
- An old runner ignores `--gone` and waits for the element to appear; relay then fails with `runner_bad_response` (exit 8). If you started the runner, `relay stop`, then `relay start --rebuild`.
- Right after an alert closes with `gone:true`, the foreground app can take about 230 ms to come back. An element `tap` waits for that by itself.

Checked on an iPhone 18 Pro simulator (iOS 27.2): `relay.toast` in the host app ([test-app](test-app.md)) was gone about 1.4 seconds after the tap, and an element that stayed gave exit 6 after `--timeout 2`. Not checked on a physical device.
