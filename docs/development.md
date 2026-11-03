# 開発者向けの情報

device-relay 自体を開発・検証するときの情報です（リポジトリ内での実行、ランナーの手動起動、検証用のホストアプリ）。全体の入口は [README](../README.md) です。

## リポジトリ内での開発

- 開発中はリポジトリ内で `xcrun swift run relay …` でも動きます。リポジトリ内ではカレントディレクトリのチェックアウトの Runner を使うので、`relay install` 済みでもインストールしたコピーではなく手元の変更がビルドされます。

```sh
xcrun swift build
xcrun swift test
xcrun swift run relay doctor
```

## ランナーを手動で起動する

手動で起動する場合（リポジトリのルートで）:

```sh
xcodebuild build-for-testing -project Runner/RelayRunner.xcodeproj -scheme RelayRunner \
  -destination 'id=<SIM_UDID>' -derivedDataPath /tmp/relay-DerivedData-sim
TEST_RUNNER_RELAY_RUNNER_PORT=8100 xcodebuild test-without-building \
  -xctestrun /tmp/relay-DerivedData-sim/Build/Products/*.xctestrun -destination 'id=<SIM_UDID>' \
  -derivedDataPath /tmp/relay-DerivedData-sim
```

（`test-without-building` にも `-derivedDataPath` を付けると、テストのログと xcresult が `~/Library/Developer/Xcode/DerivedData` ではなくそこに入ります。`relay start` も同じようにしています。）

xcodebuild の出力に `RELAY_RUNNER_READY port=8100 addresses=en0=…,utun3=…` が出たら待ち受け開始です。シミュレータでは `127.0.0.1` だけで待ち受けるので `addresses=lo0=127.0.0.1` になり、`http://127.0.0.1:<port>/` で接続します（Mac の LAN 側のアドレスや `[::1]` では届きません。`localhost` は `127.0.0.1` に落ちて届きます）。`TEST_RUNNER_RELAY_RUNNER_TOKEN_SHA256` を渡さずに起動した場合は、ランナーがトークンを生成して `relay-runner: RELAY_RUNNER_TOKEN_SHA256 is not set; generated token: <token>` と 1 回だけ出力します。認証なしでは待ち受けません。自分で決めたトークンを使う場合は、そのトークンの SHA-256（hex 64 文字、例: `printf %s "$TOKEN" | shasum -a 256`）を渡します。64 文字の hex でない値を渡すと、ランナーは待ち受けずに失敗します。

## 検証用のホストアプリ

実機で他のアプリやデータに触れずに文字入力を試せるよう、RelayRunnerHost（`dev.yuta24.devicerelay.RelayRunnerHost`）に入力欄とラベルを置いています。ランナーの起動時に一緒にインストールされるので、`/launch` で前面に出して使います。

| accessibilityIdentifier | 内容 |
| --- | --- |
| `relay.input` / `relay.input2` | 入力欄 |
| `relay.password` | パスワード欄（`isSecureTextEntry`） |
| `relay.text` | `relay.input` の現在の文字列（`text: …`） |
| `relay.passwordLength` | `relay.password` の文字数だけ（`password: 5 chars`）。文字列そのものは表示しません |
| `relay.submitted` | Return で確定したときの文字列と回数（`submitted #2: …`） |
| `relay.events` | 直近の編集（insert / delete / return）とハードウェアキーの押下（`press Tab` など）。新しい順。パスワード欄の編集は文字数だけ（`insert 3 chars`） |

```sh
curl -s -H "$AUTH" -X POST $R/launch -H 'Content-Type: application/json' -d '{"bundleId":"dev.yuta24.devicerelay.RelayRunnerHost"}'
curl -s -H "$AUTH" -X POST $R/tap -H 'Content-Type: application/json' -d '{"element":{"identifier":"relay.input"}}'
curl -s -H "$AUTH" -X POST $R/type -H 'Content-Type: application/json' -d '{"text":"hello","keys":["return"]}'
curl -s -H "$AUTH" "$R/source" | jq -r '.tree | .. | objects | select(.identifier? == "relay.submitted") | .label'
```

iOS 27 では UIScene のライフサイクルを採用していないアプリが起動時に落ちるので、ホストアプリは `UIWindowSceneDelegate` を使います。また起動画面の設定（`UILaunchScreen`）がないと実機で 320×480 の互換モードになるので、Info.plist に生成させています。
