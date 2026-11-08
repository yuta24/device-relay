[日本語](README.ja.md)

# device-relay

A CLI for driving iOS simulators and physical devices from a Mac — for people, scripts, and coding agents — with nothing embedded in the app under test.

## Overview

- It uses the same "long-running XCTest runner" approach as WebDriverAgent. A runner, running on the device as a UI test, starts an HTTP server and uses the XCUITest APIs to tap, swipe, type, take screenshots, read the element tree, and more. You don't need to modify the target app or add an SDK to it.
- The `relay` CLI on the Mac builds and launches the runner, finds how to reach it, and cleans up afterwards. It also exposes each runner operation as a single command, so people, scripts, and coding agents all use it the same way.
- Connections to the runner require a token. Build products and logs go in `~/.relay`, and nothing is created in the target app's repository.

See [docs/design.md](docs/design.md) for how it works. Detailed documentation in docs/ is currently in Japanese.

## Requirements

- macOS 26 or later with Xcode 26 or later (tested with Xcode 27; CI runs Xcode 26 and 27)
- **iOS 17.0 or later** (relay relies on the CoreDevice tunnel; the deployment target is 17.0)
- For a physical device:
  - An Apple Development certificate (sign in under Xcode > Settings > Accounts to create one). The Team ID is detected from the certificate.
  - Developer Mode and UI Automation turned on on the device
  - The device paired with the Mac and reachable through CoreDevice, over USB or the same network

> **Toolchains (building from source)**: if another Swift toolchain (installed with `swiftly`, for example) comes first in your PATH, it can disagree with the Xcode SDK and fail with errors such as `unknown argument: '-target-arch-variant'`. In that case, build with Xcode's toolchain through `xcrun swift build` / `xcrun swift test` / `xcrun swift run` (the Makefile uses `xcrun swift` too).

> **Private APIs**: the runner uses private XCTest APIs, which can change without notice when Xcode or iOS is updated. They are used only inside the UI test bundle on the device; nothing is added to the target app. See [docs/private-api.md](docs/private-api.md) for what is used and what happens when it is unavailable.

## Install

The `relay` CLI comes prebuilt, so your Xcode version can't break building it. The Runner comes as source, and `relay start` builds it on your Mac with your Xcode.

### mise (recommended)

```sh
mise use -g github:yuta24/device-relay
```

To update: `mise upgrade github:yuta24/device-relay`.

### Manual install

```sh
VERSION=0.6.0      # the latest version on https://github.com/yuta24/device-relay/releases
ARCH=$(uname -m)   # arm64 or x86_64
NAME=device-relay-v$VERSION-macos-$ARCH
BASE=https://github.com/yuta24/device-relay/releases/download/v$VERSION

curl -fLO "$BASE/$NAME.tar.gz"
curl -fLO "$BASE/$NAME.tar.gz.sha256"
shasum -a 256 -c "$NAME.tar.gz.sha256"

mkdir -p ~/.local/share/device-relay ~/.local/bin
tar -xzf "$NAME.tar.gz" -C ~/.local/share/device-relay
ln -sfn ~/.local/share/device-relay/device-relay-v$VERSION/bin/relay ~/.local/bin/relay
```

- Add `~/.local/bin` to your PATH if it isn't there. To update, repeat these steps with the new version, then remove the old directory.
- The binary is signed and notarized, so downloading the tarball with a browser works too. macOS checks the notarization online, so the first run of a browser download needs a network connection.
- Link `bin/relay` rather than copying it: relay finds the Runner from its own location. If you do copy the binary alone somewhere else, run `relay install` once from the extracted directory.

### Build from source

For contributors, or to run `main`:

```sh
git clone https://github.com/yuta24/device-relay
cd device-relay
make install   # xcrun swift build -c release, and link it to ~/.local/bin/relay (change with PREFIX=...)
```

The link points into the checkout, and relay builds the Runner from there. After updating the repository, run `make install` again. `make uninstall` removes the link only if it points into this checkout.

To validate changes, install [mise](https://mise.jdx.dev/) and run these commands from the checkout:

```sh
mise trust
mise install --locked
mise run check
```

`check` lints workflows and shell scripts, runs Swift and Python tests, and enforces coverage floors, using the same task as CI.
`mise.lock` records tool download URLs and checksums for Apple Silicon and Intel Macs.
For individual tasks (`build`, `test:swift`, `test:python`, `coverage`, `lint:workflow`, and `lint:shell`), see [Development](docs/development.md).

## Quick start

```sh
# From any directory (such as the target app's repository). Start with a simulator
relay doctor --simulator   # check Xcode, the Runner, and simulators (signing is only needed for devices)
relay devices              # find a simulator's name ("iPhone 17 Pro" below is an example)
relay start --background --device "iPhone 17 Pro"   # boot it if shut down, launch the runner, and return once ready
relay status               # check the running runner (exit code 0 if it is alive)
relay screenshot           # operate it (the section "CLI から操作する" of docs/cli.md)
relay stop                 # stop the runner (and shut down a simulator relay booted)
```

- When several iOS runtimes have a simulator with the same name, `--device` picks the one with the newest iOS and shows it, with its OS, in `relay: using …`. To try an older iOS, narrow it down with something like `--os 26.5` ("[端末の選択](docs/setup.md#端末の選択relay-devices)").
- To use a simulator that is already booted, `relay start --background --simulator` works too. It chooses among simulators even when a device is connected.
- `relay start` without `--udid` / `--device` / `--simulator` prefers a connected physical device. A device needs signing and UI Automation set up, so follow the steps in "[実機](docs/setup.md#実機)" first.

From agents, CI, and scripts, the basic flow is `relay start --background`, then your operations, then `relay stop` ("[バックグラウンドで動かす](docs/setup.md#バックグラウンドで動かすrelay-start---background--status--stop)"). When you are at the machine and watching, `relay start` in the foreground (stop with Ctrl-C) is fine too.

## First steps

The runner comes with a host app, RelayRunnerHost, for trying things out. Use it in place of a target app to go through launching, observing, operating, and checking.

```sh
relay launch host                                     # host is an alias for RelayRunnerHost's bundle ID
relay source --format compact --filter interactive   # see the elements you can operate, one per line
relay tap --id relay.input --timeout 3                # tap the text field by identifier (wait up to 3 seconds for it)
relay type "hello" --key return                       # type text and press Return
relay find --id relay.submitted                       # check the submitted text (its label)
relay screenshot --scale 1                            # save a screenshot shrunk to 1 px = 1 pt, and print its path
```

- Coordinates are in points, in the displayed orientation of the foreground app ([docs/screen.md](docs/screen.md)).
- You can also skip `relay` and call the HTTP API directly with `curl` or similar. The token is in `~/.relay/runner.json` ([docs/http-api.md](docs/http-api.md)).
- [docs/elements.md](docs/elements.md) covers how to select elements (`--id`, `--label`, `--type`, `--index`) and how to wait for them.

## Preparing a physical device (summary)

A physical device needs the following before `relay start`. For details, see [実機 in docs/setup.md](docs/setup.md#実機) and "[Team ID（実機の署名）](docs/setup.md#team-id実機の署名)".

1. Turn on Developer Mode on the device, connect it with USB, and pair it with the Mac (`relay devices` shows it as `connected`)
2. Get the device ready in Xcode's Devices and Simulators window (the developer disk image is applied the first time)
3. On the device, turn on Settings > Developer > Enable UI Automation
4. Sign in to Xcode and set up an Apple Development certificate (the Team ID is detected from it)
5. Check that `relay doctor` shows no ✗, then run `relay start`. Keep the device at hand while it starts, and enter the passcode if asked

## Common commands

`relay --help` / `relay <command> --help` show how to use each command. See [docs/cli.md](docs/cli.md) for more.

| Command | What it does |
| --- | --- |
| `relay install` / `relay uninstall` | Copy the Runner project to `~/.relay/runner` / remove it (only needed for a `relay` binary copied away from its directory) |
| `relay doctor` | Check the environment: Xcode, the Runner, the device, signing, and so on |
| `relay devices` | List physical devices and simulators |
| `relay start [--background]` | Build and launch the runner (`--background` returns once it is ready) |
| `relay status` / `relay stop` | Check the running runner / stop it (`--all` for every session) |
| `relay screenshot` | Save a screenshot and print its path (`--scale 1` to shrink it) |
| `relay source` | Get the element tree (`--format compact --filter interactive` for only the elements you can operate) |
| `relay find` | Find elements matching a selector (`--timeout` to wait, `--require` to fail if there is none) |
| `relay tap` / `relay press` / `relay swipe` | Touch by coordinates or by element selector (`--id`, `--label`, `--type`) |
| `relay type` / `relay key` | Send text or special keys to the element with keyboard focus |
| `relay launch` / `relay terminate` | Launch an app (or bring it to the foreground) / terminate it |
| `relay button` / `relay orientation` | Press a hardware button / change the device orientation |
| `relay run` (experimental) | Run a scenario of one step per line, in order |
| `relay record start` / `relay record stop` | Record the screen of a simulator or a device connected with USB to an MP4 / stop and print where it was saved (a device needs camera access the first time) |
| `relay skill install` | Install the skill for coding agents, into the target app's repository for example |
| `relay config` | Show or change settings (Team ID, bundle ID prefix) |

To run several agents in parallel, pass `RELAY_SESSION` as an environment variable when launching each agent, and give each one its own device. The shells of the commands the agent runs inherit the value, so state files and ports are kept per session and sessions don't interfere with each other ([docs/setup.md](docs/setup.md#複数のセッションを並列に動かすrelay-start---session)).

```sh
RELAY_SESSION=agent-1 claude   # every relay this agent runs uses agent-1
RELAY_SESSION=agent-2 codex    # in another terminal, as another session
```

If you can't pass the environment variable, add `--session <name>` to each command. With agents that start a new shell for each command, an `export` inside a command does not carry over to the next one.

## Troubleshooting

- Start with `relay doctor` (`relay doctor --simulator` for a simulator) to check the environment. Items marked ✗ and ! come with a one-line fix.
- Logs are in `~/.relay/logs/` (`start-*.log`, `build-*.log`, `runner-*.log`). When `relay start --background` fails, it prints the cause and the end of the log. `relay start` removes logs over 7 days old, keeping the newest 20 of each kind.
- Subcommand exit codes (`2` = usage error, `3` = can't reach the runner, `5` = busy, `6` = XCUI action failed, and so on) are listed in [docs/cli.md](docs/cli.md).
- For problems specific to physical devices (UI Automation, the passcode, the home button, and so on), see [docs/limitations.md](docs/limitations.md).

## Documentation

Detailed documentation in docs/ is currently in Japanese.

| Document | Contents |
| --- | --- |
| [docs/setup.md](docs/setup.md) | Installing and updating, how the Runner is found (`relay install`), choosing a device, Team ID, checking the environment (`relay doctor`), simulators, starting in the background, physical devices |
| [docs/cli.md](docs/cli.md) | CLI subcommands and exit codes, how the runner is found (runner.json, sessions), running scenarios (`relay run`, experimental), recording (`relay record`, for simulators and devices connected with USB), the agent skill |
| [docs/http-api.md](docs/http-api.md) | HTTP API endpoints and status codes, authentication, concurrent requests and liveness checks (`/ping`), the foreground app, text input and special keys |
| [docs/elements.md](docs/elements.md) | The element tree (`/source`, compact, interactive), element selectors, waiting (timeout) |
| [docs/screen.md](docs/screen.md) | The coordinate system and screen orientation, shrinking screenshots |
| [docs/design.md](docs/design.md) | Architecture and file layout, touch synthesis paths, measured latency |
| [docs/limitations.md](docs/limitations.md) | Known limitations |
| [docs/private-api.md](docs/private-api.md) | The private Apple APIs the runner uses, and what happens when they are unavailable |
| [docs/development.md](docs/development.md) | For developers: running from the repository, launching the runner by hand, the host app used for verification, cutting a release |
| [skills/device-relay/](skills/device-relay/) | The skill for coding agents (`SKILL.md`, and `references/` with one file per topic indexed by `reference.md`, in English) |

## License

See [LICENSE](LICENSE) (Apache License 2.0).
