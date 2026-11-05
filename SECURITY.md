# Security

device-relay is a development tool that gives whoever holds its token control of an iOS device's UI. This page describes what its authentication protects, what it does not, and how to report a vulnerability.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability reporting: open the [Security tab](https://github.com/yuta24/device-relay/security) of this repository and choose **Report a vulnerability**. Please don't open a public issue for them.

## Supported versions

Only the latest release gets security fixes. device-relay is at 0.x, and fixes are not backported to older versions.

## How it works

The runner is an HTTP server running on the device or simulator as an XCTest UI test. With the token, a client can tap, type, launch and terminate any installed app (not only the one you are testing), read the element tree, and take screenshots.

### Authentication

- `relay start` generates a random token for each launch (32 bytes from `SecRandomCopyBytes`).
- It saves the token to `~/.relay/runner.json` (or `~/.relay/sessions/<name>/runner.json` for a session) with mode 0600, and removes the file when it stops. The token is not printed to stdout, only the path of the file.
- The runner receives only the token's SHA-256, through an environment variable rather than a command-line argument. xcodebuild records that variable in the xcresult, so only the hash ends up there; sending the hash as a token is rejected with `401`.
- Every endpoint, including `/ping`, `/health`, and `/shutdown`, requires `Authorization: Bearer <token>`. The runner compares in constant time, after reading the request headers and before reading the body or answering anything else, so an unauthenticated client learns nothing about whether the runner is busy.
- Before authentication the runner only parses request headers, limited to 64 KB, with 30 seconds for the whole request to arrive.
- The runner's log contains only each request's method and path, with its status and duration, not its headers or body.

### Network exposure

Traffic is **plain HTTP, with no TLS**. The token and screenshots are not encrypted by device-relay.

| Target | Runner listens on | How relay reaches it |
| --- | --- | --- |
| Simulator | `127.0.0.1` only | `127.0.0.1`. Other machines cannot connect. |
| Physical device | All interfaces | The CoreDevice tunnel (between the Mac and the device, such as over USB). relay sends nothing to the device's Wi-Fi addresses by default. |
| Physical device with `--allow-wifi` | All interfaces | The CoreDevice tunnel, and also the device's Wi-Fi addresses. **The token and the screen travel over the network in plain text.** |

## Threat model

The token is meant to stop a third party on the same network (Wi-Fi, for example) from tapping, launching apps, or taking screenshots.

It does **not** protect against:

- **Eavesdroppers when using `--allow-wifi`.** Anyone who can read traffic on that network can capture the token and the screen, and then control the device. Use this option only on a network you trust.
- **Code running as your macOS user.** It can read `runner.json` and use the token. This includes coding agents you give access to relay.
- **Anyone you give the token to.** It grants full control of the device's UI until the runner stops.

Connections to a physical device's runner from its network are not blocked: the runner listens on all interfaces, and anything that reaches it can get as far as the header parsing above.

## Things to keep in mind

- **Stale state.** If `relay start` is killed (with `kill -9`, for example), `runner.json` stays behind and the runner may keep running with its token still valid. `relay stop` cleans this up.
- **Screen contents.** Screenshots and recordings can show personal information. By default they are saved under `$TMPDIR/relay/`.
- **Secrets on the command line.** Text passed to `relay type` shows up in `ps` and the shell history, so pass passwords with `relay type --stdin`. `relay run` hides typed text in its progress lines, but a scenario file keeps what is written in it. `relay bench --token` also puts a token on the command line; without it, `relay bench` reads the token from `runner.json`.
- **Physical device setup.** A device needs Developer Mode and UI Automation turned on, and the runner is signed with your own Apple Development certificate. These settings are meant for development; consider what else on the device the runner can reach.

## Private APIs

The runner uses private XCTest APIs for parts of touch synthesis, finding the foreground app, reading the orientation, and more. They are used only inside the UI test bundle on the device, and nothing is added to the app under test. Don't reuse this code in an app you ship. Xcode and iOS updates can change these APIs without notice; see [docs/private-api.md](docs/private-api.md) (in Japanese).

## More detail

These documents are in Japanese:

- [Authentication, in docs/http-api.md](docs/http-api.md#認証)
- [Known limitations, in docs/limitations.md](docs/limitations.md)
