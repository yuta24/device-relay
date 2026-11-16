# Scrolling to an element

To reach an element off the screen, add `--scroll <direction>` to `find`, `tap`, `press`, or `adjust`. The runner looks, swipes, and looks again inside one command, then acts on the element. Use it rather than your own swipe-and-find loop.

```sh
relay tap --id row42 --scroll down
relay tap --label Item3 --type cell --scroll up
relay tap --id tile15 --scroll right --in gallery --timeout 40 --max-swipes 20
relay find --label Total --type staticText --scroll down --require
```

- The direction is where to look in the content (`up` / `down` / `left` / `right`); the finger moves the other way. It is required.
- Found means the whole element fits in the visible part of the container. A partly visible element is scrolled a little more until it fits. `find` then needs it on the screen (reachable with `--hittable`). `tap`, `press`, and `adjust` always need it reachable by a touch, so `--onscreen` with them is exit 2. Where that can't be judged (an iPad window, several displays), it is `hit_test_unavailable` (exit 6).
- The container is the largest visible scroll view, table, or collection view. When the screen has more than one (a horizontal row inside a list), name it with `--in <identifier>`; then the element is looked for only inside it. Swipes keep clear of the keyboard and the navigation, tab, and tool bars.
- `--max-swipes` is 1–30 (default 10). With `--scroll`, `--timeout` is the time for the whole search: 0–60 seconds, default 20. Each swipe takes about 2–3 seconds (it waits for the list to stop), so for far items raise both, as in the `tile15` line above.
- It stops when the element is found, at `--max-swipes`, at `--timeout`, or at the edge (two swipes with nothing changed). The answer adds `swipes` and `scrollStop` (`found`, `edge`, `maxSwipes`, `timeout`). Not found is exit 6, `element_not_found`, even without `--require`: try the other direction, or check the selector with a screenshot.
- The edge is judged by what is shown, so a list of identical rows can look like an edge; rely on `--max-swipes` there.
- `--index`, `--gone`, coordinates, and `--mode xcui` can't be used with `--scroll` (exit 2). It works the same as a step in `relay run`.
- An old runner without it is `runner_bad_response` (exit 8). It may have already tapped what it saw without scrolling: check the screen, and if you started the runner, `relay stop`, then `relay start --rebuild`.

Checked on an iPhone 14 Pro (iOS 26.7.3) with a 100-row table and a 40-tile horizontal list in the host app ([test-app](test-app.md)): row 42 took 5 swipes (about 14 seconds), and a missing element stopped at the edge with exit 6.

## Swiping by hand

For a screen that isn't a scroll view (a map, a canvas) or to move a set distance, swipe yourself:

```sh
relay health                          # check screen.width / height
relay swipe 200 700 200 250           # from bottom to top (moves the content up)
relay find --label "Privacy" --type button
```

An element off the screen is `offscreen`, so repeat swiping and observing until `find` locates it. After a swipe, let the momentum stop before tapping: `relay wait --stable` ([waiting-for-the-screen](waiting-for-the-screen.md)), or a `sleep 2` step in `relay run`. A tap during the scroll only stops it, and the element isn't pressed although `tap` succeeds. Keep swipe start points away from the navigation bar and the home indicator (the top and bottom edges of the screen).
