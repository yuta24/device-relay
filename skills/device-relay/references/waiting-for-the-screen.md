# Waiting for the screen to settle

`relay wait --stable` waits until the screen stays unchanged for a while: after a transition, an animation, or a swipe. Use it instead of `sleep`.

```sh
relay wait --stable                        # 0.5 s unchanged, up to 10 s
relay wait --stable --for 1 --timeout 5 --require
relay run --step 'tap --id next' --step 'wait --stable --require' --step 'screenshot -o next.png'
```

- It compares small images of the whole screen about every 0.1 seconds, so it also sees drawing that the element tree doesn't show. The images stay on the device.
- `--for` is 0.1–5 seconds (default 0.5), `--timeout` 0–10 (default 10).
- The answer is `{"ok":true,"stable":true,"waitedMs":650}`. When the time runs out it is still exit 0 with `stable:false`; with `--require` it is exit 6, `code` `screen_not_stable` (decided by relay).
- A spinner, a video, a blinking cursor, or a clock on the screen keeps it from settling. Then `--require` fails every time: wait for what you expect with `find <selector> --timeout <s>` or `find <selector> --gone` instead.
- Stable is only a quiet moment, not proof that loading is done: if the screen is still for `--for` before content arrives, it returns first. When you know what should appear, `find --timeout` is the better wait. Very small changes can also be missed.
- `--bundle-id <id>` (or `host`) checks on every sample that this app stays in front; otherwise exit 6. If the runner can't tell the front app, it says so, also as exit 6.
- The command holds the runner while it waits (other commands get busy, exit 5). relay waits up to `--timeout` + 210 seconds for the answer, in case a screen capture hangs.
- An old runner without `/wait` is `runner_bad_response` (exit 8). If you started the runner, `relay stop`, then `relay start --rebuild`.

Checked on an iPhone 18 Pro simulator (iOS 27.2) and an iPhone 14 Pro (iOS 26.7.3) with the host app's stability screen ([test-app](test-app.md)): a still screen settled in about 0.7 seconds, a 1.8-second animation in about 2.3, content shown after 1.5 seconds in about 2.2, and a turning spinner gave `stable:false` (exit 6 with `--require`).
