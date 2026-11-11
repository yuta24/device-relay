# Element tree formats

Normally use shrunk screenshots (`--scale 1`) and filtered trees: full-resolution images and whole trees use up context each time you read them. The screenshot is what the user sees; the tree is what you can address. Use the screenshot to understand the screen and the filtered tree or `find` to choose a selector. To check elements the filter leaves out (headings, result text, disabled buttons), use `relay find <selector>` or `relay source --format compact`; narrow JSON with `jq` or `--max-depth <n>`. All of them target the foreground app unless you pass `--bundle-id`.

| Command | Output | Size at the top of Settings |
| --- | --- | --- |
| `relay source --format compact --filter interactive` | Only the elements you can operate, one per line (the usual choice) | 12 lines, about 1 KB |
| `relay source --filter interactive` | The same elements as JSON (an `elements` array) | About 2.3 KB |
| `relay source --format compact` | All elements, one per line, indented for parent and child | 167 lines, about 11 KB |
| `relay source` | A JSON tree of all elements (also `placeholder`, `enabled`, `hasKeyboardFocus`, and so on) | About 37 KB |
| `relay source --format text` | XCUI's `debugDescription` (slow; for people to read) | About 17 KB |

A compact line: `type`, the non-empty `label="…"`, `id="…"` (identifier), `value="…"`, and `placeholder="…"` (JSON strings), `frame=x,y,width,height` (points, rounded to integers), and flags (`selected`, `focused` = keyboard focus, `disabled`, `truncated`).

```
textField id="relay.input" placeholder="Type here" frame=16,86,370,34 focused
button label="General" id="com.apple.settings.general" frame=16,293,370,52
```

What `--filter interactive` keeps and leaves out:

- Kept: buttons, cells, links, home screen icons, tabs, switches, sliders, steppers, pickers, text fields (`textField`, `secureTextField`, `searchField`, `textView`), and the like, that have an identifier, label, or placeholder (text fields are kept even with none). For an unnamed cell, the labeled text inside it is kept instead (tapping the text hits the cell)
- Left out: disabled (`enabled: false`), off the screen, the keyboard and its keys, elements whose tap point is covered by the keyboard or a control in front (a search bar at the bottom, for example), heading and body text, images, containers (`table` and the like)
- Filtering checks a center overlapped by a later control with accessibility hit testing, dropping the candidate only when an unrelated control in the snapshot receives the hit. Unknown results keep it. It remains approximate for other overlays; element touches verify separately.
- Selectors search the whole tree. With a `staticText` of the same label, `--label` alone becomes `ambiguous`, so also add the line's `type`, or use `--id`.

## Element selectors

- Conditions: `--id` (accessibilityIdentifier), `--label`, `--type`, `--value`. An exact match (including case) with the values of the same name in `relay source`, all ANDed. There are no partial matches or regular expressions.
- `--index <n>`: the nth of the matching elements (from 0, in the same order as `relay source`'s JSON). You can use `index` from a `relay find` result as it is.
- `--type` names are the same as `type` in `relay source` (`button`, `staticText`, `textField`, `secureTextField`, `searchField`, `cell`, `switch`, `image`, `navigationBar`, `scrollView`, `table`, `collectionView`, `alert`, and so on). An unknown name is a usage error, exit code 2.
- When a name is ambiguous, get a list with `relay find --type <type>` and use its `identifier` or `index`.
- The tap point is the center of the element's frame (the part overlapping the screen).
- Element taps and presses verify that the center hits the selected element, its ancestors, or its descendants. Only a confirmed hit on an unrelated control in the snapshot refuses the touch: exit 6, `element_point_covered`. Check a screenshot, reveal the target, or use coordinates confirmed in the screenshot ([failures](failures.md)). Missing hit-test APIs, nil/error results, or receivers absent from the snapshot preserve the existing touch. Hits on content such as `staticText`, `other`, `image`, or `group` also go through: label text may activate its associated control. Coordinate touches are unchanged.
- Hit verification is skipped for iPad app windows and devices with multiple displays, where its coordinate space has not been checked. Interactive filtering keeps candidates without this check too.
