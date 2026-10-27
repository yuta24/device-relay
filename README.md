# device-relay

対象アプリに何も埋め込まずに、iOS の実機・シミュレータを Mac から HTTP で操作するためのプロトタイプです。

## コンセプト / アーキテクチャ

WebDriverAgent と同じ「常駐 XCTest ランナー」方式を使います。

```
 Mac (host)                                   iOS device / simulator
┌──────────────────────┐   HTTP/1.1 (JSON)   ┌──────────────────────────────────────┐
│ relay start / bench  │ ──────────────────▶ │ RelayRunnerUITests-Runner            │
│ curl / 任意のクライアント │ ◀────────────────── │  testRelay() が NWListener で待ち受け │
└──────────────────────┘                     │  └─ XCUIApplication / XCUIDevice で   │
        │ xcodebuild test-without-building   │     SpringBoard や任意アプリを操作    │
        └──────────────────────────────────▶ └──────────────────────────────────────┘
```

- `Runner/RelayRunner.xcodeproj` の UI テストメソッドが端末上で HTTP サーバ（Network.framework）を立ち上げ、`/shutdown` を受けるまで戻りません。
- 操作は XCUITest の公開 API（`XCUICoordinate`、`XCUIScreen`、`XCUIDevice` など）で行います。対象アプリ側の改修や SDK の組み込みは不要です。
- 座標系は SpringBoard の左上を原点とするポイント単位なので、どのアプリが前面にいても同じ座標で操作できます。
- XCUI の失敗（`record(_:)` に送られる issue）はテストを失敗させずに HTTP 422 として返し、ランナーはそのまま動き続けます。
- ホストからの接続経路は、シミュレータでは `127.0.0.1` です。実機では CoreDevice トンネルのアドレス（`devicectl` の `tunnelIPAddress`）か `<udid>.coredevice.local`、または Wi-Fi の IP を使います。usbmux は現時点では使いません。
- `relay` CLI（SwiftPM）は、ビルド、ランナーの起動、到達可能なアドレスの探索、Ctrl-C での後片付けをまとめて行います。

```
Package.swift / Sources/relay      ホスト CLI (relay start / relay bench)
Tests/relayTests                   CLI のユニットテスト (Swift Testing)
Runner/RelayRunner.xcodeproj       RelayRunnerHost (空のホストアプリ) + RelayRunnerUITests (常駐ランナー)
.relay/                            DerivedData とログ (git 管理外)
```

## 要件

- macOS 上の Xcode（Xcode 27 で動作確認）
- **iOS 17.0 以上**（CoreDevice トンネルを前提とします。デプロイメントターゲットは 17.0）
- 実機の場合
  - Apple Developer の Team ID（署名に使います）
  - 端末側で「デベロッパモード」が有効になっていること
  - Mac とペアリング済みで、USB または同じネットワーク経由で CoreDevice 接続できること

> **ツールチェーンに関する注意**: `swiftly` などで入れた別の Swift ツールチェーンが PATH の先頭にあると、Xcode SDK と食い違って `unknown argument: '-target-arch-variant'` のようなエラーになることがあります。その場合は `xcrun swift build` / `xcrun swift test` / `xcrun swift run` を使い、Xcode のツールチェーンでビルドしてください。

## クイックスタート

コマンドはすべてリポジトリのルートで実行します（`relay start` は `Runner/RelayRunner.xcodeproj` を相対パスで探します）。

```sh
xcrun swift build
xcrun swift test
```

### シミュレータ

```sh
xcrun simctl boot <SIM_UDID>   # 起動していなければ
xcrun swift run relay start --udid <SIM_UDID>
# relay: building runner (log: .relay/logs/build-*.log)   ← 初回か --rebuild 指定時だけ
# relay: launching runner on <SIM_UDID> (log: .relay/logs/runner-*.log)
# relay: runner listening; device addresses: ...
# ready: http://127.0.0.1:8100/
```

別のターミナルから:

```sh
curl -s http://127.0.0.1:8100/health
xcrun swift run relay bench --url http://127.0.0.1:8100 --count 5 --tap 200,120
```

Ctrl-C を押すと `relay` が `/shutdown` を送ります。ランナーがテストメソッドから抜けて `** TEST EXECUTE SUCCEEDED **` で終了し、`relay` も終了します（10 秒以内に終わらなければ xcodebuild を terminate します）。

オプション:

| オプション | 説明 |
| --- | --- |
| `--port 8100` | 端末側の待ち受けポート。xcodebuild には `TEST_RUNNER_RELAY_RUNNER_PORT` として渡され、ランナーからは `RELAY_RUNNER_PORT` として見えます |
| `--team-id <TEAM_ID>` | 実機向けの署名チーム。`-allowProvisioningUpdates RELAY_DEVELOPMENT_TEAM=<TEAM_ID>` を付けてビルドします |
| `--rebuild` | `.relay/DerivedData-*` に既存の `.xctestrun` があっても再ビルドします |
| `--verbose` | xcodebuild の出力をそのまま表示します |
| `--ready-timeout 180` | `/health` が応答するまで待つ秒数 |

手動で起動する場合:

```sh
xcodebuild build-for-testing -project Runner/RelayRunner.xcodeproj -scheme RelayRunner \
  -destination 'id=<SIM_UDID>' -derivedDataPath .relay/DerivedData-sim
TEST_RUNNER_RELAY_RUNNER_PORT=8100 xcodebuild test-without-building \
  -xctestrun .relay/DerivedData-sim/Build/Products/*.xctestrun -destination 'id=<SIM_UDID>'
```

xcodebuild の出力に `RELAY_RUNNER_READY port=8100 addresses=en0=…,utun3=…` が出たら待ち受け開始です。

### 実機

1. 端末で デベロッパモード を有効にします（設定 > プライバシーとセキュリティ > デベロッパモード。有効にすると再起動します）。
2. USB で接続して Mac とペアリングし、`xcrun devicectl list devices` に表示されることを確認します。
3. ランナーをビルドして起動します。

   ```sh
   xcrun swift run relay start --udid <DEVICE_UDID> --team-id <TEAM_ID>
   ```

4. 無料の Personal Team などで署名した場合、初回の起動時に「信頼されていないデベロッパ」と表示されることがあります。端末の 設定 > 一般 > VPNとデバイス管理 で開発元の証明書を信頼してから、もう一度 `relay start` を実行してください。
5. 初回は「ローカルネットワーク上のデバイスの検索および接続」の許可ダイアログが出ることがあります。許可しないと Wi-Fi 経由では届きません。

`relay start` は、次の順に `/health` を投げて最初に応答したアドレスを `ready:` として表示します。

1. CoreDevice トンネルアドレス（`xcrun devicectl device info details` の `tunnelIPAddress`。USB 接続だけで使える IPv6 の ULA）
2. `<udid>.coredevice.local`
3. ランナーが `RELAY_RUNNER_READY` で報告したインターフェースのアドレス（Wi-Fi など。`169.254.*` は除外）

| 経路 | 長所 | 短所 |
| --- | --- | --- |
| CoreDevice トンネル | USB だけで動く。同じ LAN にいる必要がない | Xcode/CoreDevice のトンネルが張られている間しか使えない |
| Wi-Fi IP | ケーブル不要 | 同じ LAN が必要。ローカルネットワーク許可が必要。ネットワークによっては AP 間の通信が遮断される |

## エンドポイント

ベース URL は `http://<host>:8100`（以下の例はシミュレータ）。座標はすべて SpringBoard 左上を原点とするポイント単位です。POST のボディは JSON です。

| メソッド / パス | ボディ / クエリ | 説明 |
| --- | --- | --- |
| `GET /health` | – | 端末情報と画面サイズ（points / scale） |
| `GET /screenshot` | `?format=png\|jpeg&quality=0.05–1.0`（既定は png、jpeg の既定 quality は 0.7） | 画面全体のスクリーンショット |
| `GET /source` | `?bundleId=`（省略時は最後に `/launch` したアプリ、なければ SpringBoard） | XCUI の要素ツリー（`debugDescription` のテキスト） |
| `POST /tap` | `{"x":200,"y":120}` | タップ |
| `POST /press` | `{"x":200,"y":120,"duration":1.0}` | 長押し |
| `POST /swipe` | `{"from":{"x":200,"y":700},"to":{"x":200,"y":200},"duration":0.3,"hold":0.05}` | スワイプ（ドラッグ） |
| `POST /type` | `{"text":"hello","bundleId":"com.apple.Preferences"}`（bundleId は省略可） | フォーカス中のフィールドへの文字入力 |
| `POST /button` | `{"name":"home"}`（`volumeUp` / `volumeDown` は実機のみ） | ハードウェアボタン |
| `POST /orientation` | `{"orientation":"portrait\|portraitUpsideDown\|landscapeLeft\|landscapeRight"}` | 画面の向き |
| `POST /launch` | `{"bundleId":"com.apple.Preferences"}` | アプリの起動・前面化（`activate()`） |
| `POST /terminate` | `{"bundleId":"com.apple.Preferences"}` | アプリの終了 |
| `POST /shutdown` | – | ランナーを停止（テストメソッドから抜ける） |

ステータスコード: `200` 成功、`400` リクエスト不正（JSON、必須フィールド、値の範囲）、`404` 未知のパス、`405` メソッド違い、`500` 内部エラー（JPEG エンコード失敗など）、`422` XCUI 側で操作に失敗（エラーメッセージを JSON で返し、ランナーは動き続けます）。

```sh
R=http://127.0.0.1:8100
curl -s $R/health
curl -s -o shot.png $R/screenshot
curl -s -o shot.jpg "$R/screenshot?format=jpeg&quality=0.5"
curl -s "$R/source?bundleId=com.apple.Preferences" | head
curl -s -X POST $R/launch      -H 'Content-Type: application/json' -d '{"bundleId":"com.apple.Preferences"}'
curl -s -X POST $R/tap         -H 'Content-Type: application/json' -d '{"x":200,"y":120}'
curl -s -X POST $R/press       -H 'Content-Type: application/json' -d '{"x":200,"y":400,"duration":1.0}'
curl -s -X POST $R/swipe       -H 'Content-Type: application/json' -d '{"from":{"x":200,"y":700},"to":{"x":200,"y":200}}'
curl -s -X POST $R/type        -H 'Content-Type: application/json' -d '{"text":"hello"}'
curl -s -X POST $R/button      -H 'Content-Type: application/json' -d '{"name":"home"}'
curl -s -X POST $R/orientation -H 'Content-Type: application/json' -d '{"orientation":"landscapeLeft"}'
curl -s -X POST $R/terminate   -H 'Content-Type: application/json' -d '{"bundleId":"com.apple.Preferences"}'
curl -s -X POST $R/shutdown
```

## 計測したレイテンシ

iPhone 17 Pro シミュレータ（iOS 27.0、Apple Silicon Mac、`127.0.0.1`）で計測しました。`relay bench --count 5 --tap 200,120` の結果（ms）:

| リクエスト | min | p50 | p90 | max | サイズ |
| --- | ---: | ---: | ---: | ---: | ---: |
| `GET /health` | 0 | 0 | 51 | 51 | 152 B |
| `GET /screenshot` (png) | 127 | 129 | 250 | 250 | 2.87 MB |
| `GET /screenshot` (jpeg q=0.5) | 162 | 163 | 243 | 243 | 329 KB |
| `POST /tap` | 475 | 484 | 1042 | 1042 | – |

n=5 なので p90 は max と同じ値です。散発的に 1 回だけ遅いサンプルがあり、それが p90/max に出ています。手動で計測したほかの操作: swipe 約 0.7 s、launch 約 5.9 s、tap は 370–630 ms 程度でした。実機の値はまだ計測していません。

## 既知の制約

- **タップが遅い**: XCUI はイベントを送る前後に対象アプリがアイドルになる（quiescence）のを待つため、タップ 1 回に 0.4–0.6 秒かかります。将来は、非公開 API の `XCSynthesizedEventRecord` などでイベントを直接合成する高速パスを検討します。
- **`/type`**: キーボードのフォーカスがあるフィールドが必要です。対象アプリは `bundleId` で指定し、省略すると最後に `/launch` した bundleId（なければ SpringBoard）を使います。`/launch` を経由せずに前面に出たアプリには、`bundleId` を明示してください。
- **映像ストリームはまだない**: 画面はスクリーンショットのポーリングで取得します（png 約 130 ms / jpeg 約 165 ms）。
- **ローカルネットワーク許可**: 実機では初回にローカルネットワークの許可ダイアログが出ることがあります。
- **座標系**: SpringBoard の原点からのポイント単位です（ピクセルではありません）。`/health` の `screen.scale` を掛けるとスクリーンショットのピクセル座標になります。回転時の座標の扱いはまだ検証していません。
- **音量ボタン**: `volumeUp` / `volumeDown` は実機でのみ使えます（シミュレータでは 400）。
- **usbmux 非対応**: 実機への接続には CoreDevice トンネルか Wi-Fi のどちらかが必要です。
- **同時に 1 クライアント**: XCUI の操作は直列に処理されます。複数クライアントからの同時操作は想定していません。
