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
- 座標系は「前面アプリの表示の向き（interface orientation）での、画面左上を原点とするポイント単位」です。横向きなら幅 > 高さの座標で指定します（詳しくは「座標系と画面の向き」）。
- 全エンドポイントで `Authorization: Bearer <token>` が必要です。トークンは `relay start` が起動ごとに生成します（詳しくは「認証」）。
- XCUI の失敗（`record(_:)` に送られる issue）はテストを失敗させずに HTTP 422 として返し、ランナーはそのまま動き続けます。
- ホストからの接続経路は、シミュレータでは `127.0.0.1` です。実機では CoreDevice トンネルのアドレス（`devicectl` の `tunnelIPAddress`）か `<udid>.coredevice.local` を使います。Wi-Fi の IP は `--allow-wifi` を付けたときだけ使います。usbmux は現時点では使いません。
- `relay` CLI（SwiftPM）は、ビルド、ランナーの起動、到達可能なアドレスの探索、Ctrl-C での後片付けをまとめて行います。

```
Package.swift / Sources/relay      ホスト CLI (relay start / relay bench)
Tests/relayTests                   CLI のユニットテスト (Swift Testing)
Runner/RelayRunner.xcodeproj       RelayRunnerHost (空のホストアプリ) + RelayRunnerUITests (常駐ランナー)
.relay/                            DerivedData、ログ、runner.json (git 管理外)
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
# token: /path/to/device-relay/.relay/runner.json
```

ready になると、URL とアクセストークンが `.relay/runner.json`（パーミッション 0600）に書き出されます。別のターミナルから:

```sh
TOKEN=$(jq -r .token .relay/runner.json)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8100/health
xcrun swift run relay bench --url http://127.0.0.1:8100 --count 5 --tap 200,120   # トークンは runner.json から読む
```

Ctrl-C を押すと `relay` が `/shutdown` を送り、`.relay/runner.json` を削除します。ランナーがテストメソッドから抜けて `** TEST EXECUTE SUCCEEDED **` で終了し、`relay` も終了します（10 秒以内に終わらなければ xcodebuild を terminate します）。ランナーが ready になる前に Ctrl-C を押した場合は、`/shutdown` を送る先がないので xcodebuild をすぐに terminate します。

ready の後も、`relay start` は 3 秒ごとに `/health` を送ってランナーの生存を確認します（`200` と `409` は生存扱い）。3 回続けて応答がなければ、ランナーが落ちたとみなしてエラーを表示し、xcodebuild を止めて `.relay/runner.json` を削除し、終了コード 1 で終わります。`.relay/runner.json` を書き出せなかった場合も、ランナーを止めてから終了コード 1 で終わります。

オプション:

| オプション | 説明 |
| --- | --- |
| `--port 8100` | 端末側の待ち受けポート。xcodebuild には `TEST_RUNNER_RELAY_RUNNER_PORT` として渡され、ランナーからは `RELAY_RUNNER_PORT` として見えます |
| `--team-id <TEAM_ID>` | 実機向けの署名チーム。`-allowProvisioningUpdates RELAY_DEVELOPMENT_TEAM=<TEAM_ID>` を付けてビルドします |
| `--rebuild` | `.relay/DerivedData-*` に既存の `.xctestrun` があっても再ビルドします |
| `--verbose` | xcodebuild の出力をそのまま表示します |
| `--allow-wifi` | 実機で、CoreDevice トンネルに加えて Wi-Fi などのアドレスも探索します。トークンが同じネットワークに平文で流れるので、既定では無効です |
| `--ready-timeout 180` | `/health` が応答するまで待つ秒数。xcodebuild の出力に `Failed to initialize for UI testing` やテストの失敗が出た場合は、待たずにエラー内容と対処のヒントを表示して非ゼロで終了します |

手動で起動する場合:

```sh
xcodebuild build-for-testing -project Runner/RelayRunner.xcodeproj -scheme RelayRunner \
  -destination 'id=<SIM_UDID>' -derivedDataPath .relay/DerivedData-sim
TEST_RUNNER_RELAY_RUNNER_PORT=8100 xcodebuild test-without-building \
  -xctestrun .relay/DerivedData-sim/Build/Products/*.xctestrun -destination 'id=<SIM_UDID>'
```

xcodebuild の出力に `RELAY_RUNNER_READY port=8100 addresses=en0=…,utun3=…` が出たら待ち受け開始です。`TEST_RUNNER_RELAY_RUNNER_TOKEN_SHA256` を渡さずに起動した場合は、ランナーがトークンを生成して `relay-runner: RELAY_RUNNER_TOKEN_SHA256 is not set; generated token: <token>` と 1 回だけ出力します。認証なしでは待ち受けません。自分で決めたトークンを使う場合は、そのトークンの SHA-256（hex 64 文字、例: `printf %s "$TOKEN" | shasum -a 256`）を渡します。64 文字の hex でない値を渡すと、ランナーは待ち受けずに失敗します。

### 実機

1. 端末で デベロッパモード を有効にします（設定 > プライバシーとセキュリティ > デベロッパモード。有効にすると再起動します）。
2. USB で接続して Mac とペアリングし、`xcrun devicectl list devices` に表示されることを確認します。
3. Xcode の Window > Devices and Simulators で端末を選び、接続済み（準備完了）の状態にします。初回はここで開発用ディスクイメージ（DDI）が端末に適用されるので、完了するまで待ちます。
4. 端末の 設定 > デベロッパ >「UI オートメーションを有効にする」をオンにします。オフのままだと、ランナーが `Failed to initialize for UI testing`（`Timed out while enabling automation mode.`）で起動に失敗します。
5. ランナーをビルドして起動します。

   ```sh
   xcrun swift run relay start --udid <DEVICE_UDID> --team-id <TEAM_ID>
   ```

6. 無料の Personal Team などで署名した場合、初回の起動時に「信頼されていないデベロッパ」と表示されることがあります。端末の 設定 > 一般 > VPNとデバイス管理 で開発元の証明書を信頼してから、もう一度 `relay start` を実行してください。
7. 初回は「ローカルネットワーク上のデバイスの検索および接続」の許可ダイアログが出ることがあります。許可しないと Wi-Fi 経由（`--allow-wifi`）では届きません。

`relay start` は、次の順に `/health` を投げて最初に応答したアドレスを `ready:` として表示します。

1. CoreDevice トンネルアドレス（`xcrun devicectl device info details` の `tunnelIPAddress`。USB 接続だけで使える IPv6 の ULA）
2. `<udid>.coredevice.local`
3. `--allow-wifi` を付けたときだけ: ランナーが `RELAY_RUNNER_READY` で報告したインターフェースのアドレス（Wi-Fi など。`169.254.*` は除外）

既定ではトンネルが見つかるまで 1 と 2 だけを試し、Wi-Fi のアドレスには何も送りません。

| 経路 | 長所 | 短所 |
| --- | --- | --- |
| CoreDevice トンネル | USB だけで動く。同じ LAN にいる必要がない | Xcode/CoreDevice のトンネルが張られている間しか使えない |
| Wi-Fi IP（`--allow-wifi`） | ケーブル不要 | 同じ LAN が必要。ローカルネットワーク許可が必要。トークンと画面が LAN 上を平文で流れる。ネットワークによっては AP 間の通信が遮断される |

## エンドポイント

ベース URL は `http://<host>:8100`（以下の例はシミュレータ）。座標は「座標系と画面の向き」で説明する、表示の向きでのポイント単位です。POST のボディは JSON です。すべてのリクエストに `Authorization: Bearer <token>` が必要です。

| メソッド / パス | ボディ / クエリ | 説明 |
| --- | --- | --- |
| `GET /health` | – | 端末情報、表示の向きでの画面サイズ（points / scale）、`orientation`、`touchSynthesis` |
| `GET /screenshot` | `?format=png\|jpeg&quality=0.05–1.0`（既定は png、jpeg の既定 quality は 0.7。範囲外・数値以外の quality と、png への quality の指定は 400） | 画面全体のスクリーンショット（表示の向きに正規化済み） |
| `GET /source` | `?bundleId=`（省略時は最後に `/launch` したアプリ、なければ SpringBoard） | XCUI の要素ツリー（`debugDescription` のテキスト） |
| `POST /tap` | `{"x":200,"y":120}` | タップ |
| `POST /press` | `{"x":200,"y":120,"duration":1.0}` | 長押し |
| `POST /swipe` | `{"from":{"x":200,"y":700},"to":{"x":200,"y":200},"duration":0.3,"hold":0.05}` | スワイプ（ドラッグ） |
| `POST /type` | `{"text":"hello","bundleId":"com.apple.Preferences"}`（bundleId は省略可） | フォーカス中のフィールドへの文字入力 |
| `POST /button` | `{"name":"home"}`（`volumeUp` / `volumeDown` は実機のみ） | ハードウェアボタン。`home` は実機では画面下端からのスワイプで代用します（「既知の制約」を参照） |
| `POST /orientation` | `{"orientation":"portrait\|portraitUpsideDown\|landscapeLeft\|landscapeRight"}` | 端末の向き（`UIDeviceOrientation`）を設定 |
| `POST /launch` | `{"bundleId":"com.apple.Preferences"}` | アプリの起動・前面化（`activate()`） |
| `POST /terminate` | `{"bundleId":"com.apple.Preferences"}` | アプリの終了 |
| `POST /shutdown` | – | ランナーを停止（テストメソッドから抜ける） |

`/tap` `/press` `/swipe` は `"mode": "private" | "xcui"` を受け付けます（省略時は使えれば `private`）。応答の `mode` に実際に使った経路が入り、`/health` の `touchSynthesis` で端末側の既定経路がわかります。詳しくは「タッチ合成の経路」を参照してください。

`/health` の例（横向きの Safari が前面のとき）:

```json
{"coordinateSpace":"points","device":{"model":"iPhone","simulator":true,"systemVersion":"27.0"},"ok":true,
 "orientation":"landscapeLeft","screen":{"height":402,"scale":3,"width":874},"touchSynthesis":"private"}
```

ステータスコード:

| コード | 意味 |
| --- | --- |
| `200` | 成功 |
| `400` | リクエスト不正（JSON、必須フィールド、値の範囲、数値フィールドへの数値以外（真偽値を含む）、負の値・数値以外・矛盾する `Content-Length`） |
| `401` | `Authorization: Bearer <token>` がない、または一致しない（`{"ok":false,"error":"unauthorized"}`）。リクエストヘッダーの形式の判定（`400`・`413`・`431`・`501`）の次、ほかのどの判定よりも先に行います |
| `404` / `405` | 未知のパス / メソッド違い |
| `409` | 別のコマンドを実行中（`{"ok":false,"error":"busy"}`）。待たずにすぐ返ります |
| `422` | XCUI 側で操作に失敗（エラーメッセージを JSON で返し、ランナーは動き続けます） |
| `413` / `431` | ボディが 16 MB を超える / リクエストヘッダーが 64 KB を超える |
| `500` | 内部エラー（JPEG エンコード失敗など） |
| `501` | `Transfer-Encoding` ヘッダーがある（値に関わらず。ボディは `Content-Length` でのみ受け付けます） |

`400`・`401`・`413`・`431`・`501` は、応答した後に接続を閉じます。リクエストは、接続を開いてから（keep-alive の場合は前の応答を返してから）30 秒以内に全体が届かないと、接続を閉じます。実行中のコマンドの時間はこの 30 秒に含めません。

```sh
R=http://127.0.0.1:8100
AUTH="Authorization: Bearer $(jq -r .token .relay/runner.json)"
curl -s -H "$AUTH" $R/health
curl -s -H "$AUTH" -o shot.png $R/screenshot
curl -s -H "$AUTH" -o shot.jpg "$R/screenshot?format=jpeg&quality=0.5"
curl -s -H "$AUTH" "$R/source?bundleId=com.apple.Preferences" | head
curl -s -H "$AUTH" -X POST $R/launch      -H 'Content-Type: application/json' -d '{"bundleId":"com.apple.Preferences"}'
curl -s -H "$AUTH" -X POST $R/tap         -H 'Content-Type: application/json' -d '{"x":200,"y":120}'
curl -s -H "$AUTH" -X POST $R/press       -H 'Content-Type: application/json' -d '{"x":200,"y":400,"duration":1.0}'
curl -s -H "$AUTH" -X POST $R/swipe       -H 'Content-Type: application/json' -d '{"from":{"x":200,"y":700},"to":{"x":200,"y":200}}'
curl -s -H "$AUTH" -X POST $R/type        -H 'Content-Type: application/json' -d '{"text":"hello"}'
curl -s -H "$AUTH" -X POST $R/button      -H 'Content-Type: application/json' -d '{"name":"home"}'
curl -s -H "$AUTH" -X POST $R/orientation -H 'Content-Type: application/json' -d '{"orientation":"landscapeLeft"}'
curl -s -H "$AUTH" -X POST $R/terminate   -H 'Content-Type: application/json' -d '{"bundleId":"com.apple.Preferences"}'
curl -s -H "$AUTH" -X POST $R/shutdown
```

## 座標系と画面の向き

- 座標は **前面アプリの表示の向き（interface orientation）での、画面左上を原点とするポイント単位** です。縦向きなら 402×874、横向きなら 874×402 の範囲で指定します（iPhone 17 Pro の場合）。
- `/health` の `screen.width` / `screen.height` はこの向きでの値です。`orientation` は表示の向きを `/orientation` と同じ名前（`portrait` / `portraitUpsideDown` / `landscapeLeft` / `landscapeRight`）で返します。`/orientation landscapeLeft` の後は `"orientation":"landscapeLeft"` になります（UIKit の interface orientation としては `landscapeRight` にあたります。デバイスとインターフェースで左右の名前が逆になるためです）。
- 表示の向きは、端末の向き（`XCUIDevice.orientation`）と一致するとは限りません。横向きの iPhone でもホーム画面は縦のままですし、iPhone のアプリは `portraitUpsideDown` に回転しません。そのため、端末の向きではなく、リクエストのたびに前面アプリの向きを読み直します。`/orientation` を使わずに端末を手で回した場合や、アプリを切り替えた場合にも追従します。
- 向きの取得には非公開の `-[XCUIApplication interfaceOrientation]` を使います（SpringBoard 経由で呼んでも前面アプリの向きが返り、約 1 ms）。使えない場合は、スクリーンショットの `UIImage.imageOrientation` で代用します（約 90 ms）。
- `/screenshot` の画素も表示の向きにそろえます。横向きなら幅 > 高さになり、`width = screen.width × scale`、`height = screen.height × scale` です。ただし iPhone 14 Pro 実機では、XCUI のスクリーンショット自体が 1178×2556 px で、393 pt × 3 = 1179 より短辺が 1 px 足りません（向きの正規化を入れる前から同じです）。XCUI のスクリーンショットは画素が常に縦向きで、回転は向きのメタデータとしてだけ付いているので、縦向き以外では描き直します。そのぶん時間が増えます（p50 で、シミュレータは png +50 ms・jpeg +7 ms、実機は png +30 ms・jpeg はほぼ変わらず）。
- タッチ: `xcui` 経路では、XCTest が SpringBoard 基準の座標を表示の向きで解釈します。`private` 経路の合成イベントは `XCSynthesizedEventRecord` の向きの指定では座標が変換されない（縦向きの画面座標として扱われる）ため、ランナーが表示の向きの座標を縦向きの画面座標に変換し、`portrait` として送ります。どちらの経路でも同じ座標が同じ位置に当たります。

## 認証

- `relay start` は起動ごとに 32 バイトのランダムなトークン（`SecRandomCopyBytes`、hex 64 文字）を生成します。ランナーにはトークンそのものではなく、その SHA-256 だけを xcodebuild の環境変数 `TEST_RUNNER_RELAY_RUNNER_TOKEN_SHA256` で渡します（コマンドライン引数には載せません）。ランナーは提示されたトークンの SHA-256 を、保持しているハッシュと定数時間で比較します。
- ランナーは全エンドポイント（`/health` と `/shutdown` を含む）で `Authorization: Bearer <token>` を要求し、ない場合や一致しない場合は `401` を返します。比較は定数時間で行います。判定は HTTP キュー上で、リクエストヘッダーを読み終えた時点（ボディを読む前）に行い、`409` の busy 判定よりも先です。未認証のリクエストからは busy 状態も処理時間もわからず、ボディを溜め込ませることもできません。
- 認証の前に処理するのはリクエストヘッダーの解析だけで、ヘッダーは 64 KB まで、リクエスト全体が届くまでは 30 秒までに制限しています。
- ready になると `relay start` は `{"url","token","udid"}` を `.relay/runner.json` にパーミッション 0600 で書き出し、stdout には `ready: <url>` とファイルの場所（`token: <path>`）だけを出します。トークンそのものは stdout に出しません（CI のログやターミナルの履歴に残りやすいため）。停止時にファイルを削除します。
- `relay bench` は `--token` を受け付け、省略時は `.relay/runner.json` から読みます。`relay start` 内部の `/health` 探索と `/shutdown` もトークンを付けます。
- ランナーのログ（`relay-runner GET /health -> 200 1ms` など）には、メソッドとパスしか出しません。
- 脅威モデル: 同じネットワーク（Wi-Fi など）にいる第三者が、タップ、アプリの起動、スクリーンショットの取得をできないようにするためのものです。ランナーはすべてのインターフェースで待ち受けますが、トークンがなければ何もできません。通信は平文の HTTP です。既定では、`relay` は CoreDevice トンネル（USB などの Mac と端末の間の経路）にしかトークンを送りません。`--allow-wifi` を付けると、Wi-Fi 上にもトークンと画面が平文で流れ、同じネットワークで盗聴できる相手には守れません。
- xcodebuild は `TEST_RUNNER_` 環境変数を xcresult（`~/Library/Developer/Xcode/DerivedData/RelayRunner-*/Logs/Test/*.xcresult`）に記録します。ここに残るのはトークンの SHA-256 だけで、トークンは 256 ビットのランダム値なので、ハッシュから求めることはできず、ハッシュ自体をトークンとして送っても `401` になります。

## 計測したレイテンシ

iPhone 17 Pro シミュレータ（iOS 27.0、Apple Silicon Mac、`127.0.0.1`）で、Safari を前面にして計測しました。`relay bench --count 10 --tap 196,30 --mode private|xcui` の結果（ms）:

| リクエスト | min | p50 | p90 | max | サイズ |
| --- | ---: | ---: | ---: | ---: | ---: |
| `GET /health` | 1 | 1 | 1 | 8 | 204 B |
| `GET /screenshot` (png、縦) | 86 | 88 | 89 | 107 | 766 KB |
| `GET /screenshot` (jpeg q=0.5、縦) | 108 | 110 | 110 | 114 | 213 KB |
| `GET /screenshot` (png、横・正規化あり) | 136 | 138 | 140 | 173 | 766 KB |
| `GET /screenshot` (jpeg q=0.5、横・正規化あり) | 113 | 117 | 118 | 118 | 151 KB |
| `POST /tap` (private) | 292 | 298 | 304 | 315 | – |
| `POST /tap` (xcui) | 1598 | 1617 | 1634 | 1636 | – |

実機 iPhone 14 Pro（iOS 26.7.1、USB 接続の CoreDevice トンネル経由）で、計算機を前面にして計測しました。`relay bench --count 10 --tap 150,748 --mode private|xcui`（「0」キー）の結果（ms）:

| リクエスト | min | p50 | p90 | max | サイズ |
| --- | ---: | ---: | ---: | ---: | ---: |
| `GET /health` | 2 | 3 | 5 | 18 | 207 B |
| `GET /screenshot` (png、縦) | 106 | 108 | 109 | 151 | 244 KB |
| `GET /screenshot` (jpeg q=0.5、縦) | 119 | 123 | 124 | 125 | 129 KB |
| `GET /screenshot` (png、横・正規化あり) | 135 | 138 | 139 | 182 | 206 KB |
| `GET /screenshot` (jpeg q=0.5、横・正規化あり) | 119 | 122 | 124 | 125 | 110 KB |
| `POST /tap` (private) | 281 | 293 | 296 | 296 | – |
| `POST /tap` (xcui) | 493 | 1217 | 1228 | 1246 | – |

## タッチ合成の経路

| 経路 | 仕組み | 特徴 |
| --- | --- | --- |
| `private`（既定） | XCTest の非公開 API でタッチを直接合成（WebDriverAgent と同じ方式） | アプリのアイドル待ちをしない。完了 callback を待ってから応答する |
| `xcui` | 公開 API の `XCUICoordinate.tap()` / `press(forDuration:)` / `press(forDuration:thenDragTo:…)` | 前後で quiescence を待つため遅い |

`private` で使う非公開 API（Xcode 27 では `XCUIAutomation.framework` にあります）:

- `XCPointerEventPath`: `-initForTouchAtPoint:offset:`、`-moveToPoint:atOffset:`、`-liftUpAtOffset:`
- `XCSynthesizedEventRecord`: `-initWithName:interfaceOrientation:`、`-addPointerEventPath:`
- `-[XCUIDevice eventSynthesizer]` が返すオブジェクトの `-synthesizeEvent:completion:`（completion は `^(BOOL, NSError *)`）

クラスとセレクタはすべて実行時に `NSClassFromString` / `respondsToSelector:` で確認します（`Runner/RelayRunnerUITests/RelayTouchSynthesizer.m`）。1 つでも欠けていれば自動で `xcui` に落ち、`/health` は `"touchSynthesis":"xcui"` になります。`mode: "private"` を明示して使えない場合は 400 を返します。動作確認用に、ランナーの環境変数 `RELAY_DISABLE_PRIVATE_TOUCH=1`（xcodebuild には `TEST_RUNNER_RELAY_DISABLE_PRIVATE_TOUCH=1`）で `private` を無効にできます。

ジェスチャーの組み立て: tap は 0.05 秒押して離す、press は `duration` 秒後に離す、swipe は `from` で `hold` 秒止まってから `duration` 秒かけて `to` へ移動し、すぐ離します。座標は前面アプリの表示の向きから縦向きの画面座標に変換して送ります（「座標系と画面の向き」を参照）。

ランナー側で測った処理時間（実機）: press 0.5 s → 743 ms / 1.0 s → 1230 ms、swipe（hold 0.05 + 0.3 s）→ 592–606 ms。xcui では同じ操作がそれぞれ 2059 / 2030 ms、1632–2097 ms でした。private でも、指定時間に対して約 0.25 秒の固定オーバーヘッドがあります（合成イベントの完了通知までの時間）。

## 同時リクエスト

コマンドは 1 つずつ実行します。実行中（タッチの完了待ちなどを含む）に別のリクエストが来ると、ランナーは HTTP キュー上で即座に `409 {"ok":false,"error":"busy"}` を返し、メインスレッドには入れません（実行中のコマンドの後ろに並ばせることはしません）。`/shutdown` だけは実行中でも受け付けてすぐ `200` を返し、実行中のコマンドが終わった時点でランナーが止まります。シミュレータで 3 秒の `/swipe` 中に `/health`・`/screenshot`・`/tap` を送ると、それぞれ 1–5 ms で 409 が返り、swipe 自体は 200 で完了しました。

## 既知の制約

- **タッチ合成は非公開 API 依存**: `private` 経路は Xcode / iOS の更新でセレクタやシグネチャが変わると使えなくなります。消えた場合は自動で `xcui` に落ちますが、シグネチャだけ変わった場合は検出できません。表示の向きの取得（`interfaceOrientation`）も非公開 API で、使えない場合はスクリーンショットから求めるので遅くなります。
- **`xcui` 経路は遅い**: XCUI はイベントを送る前後に対象アプリがアイドルになる（quiescence）のを待つため、タップ 1 回にシミュレータの Safari で約 1.6 秒、実機の計算機で約 1.2 秒（以前の計測では約 1.9 秒）かかります。
- **`/type`**: キーボードのフォーカスがあるフィールドが必要です。対象アプリは `bundleId` で指定し、省略すると最後に `/launch` した bundleId（なければ SpringBoard）を使います。`/launch` を経由せずに前面に出たアプリには、`bundleId` を明示してください。
- **映像ストリームはまだない**: 画面はスクリーンショットのポーリングで取得します（シミュレータの縦向きで png 約 90 ms / jpeg 約 110 ms、横向きは正規化のぶん遅くなります）。
- **ローカルネットワーク許可**: 実機では初回にローカルネットワークの許可ダイアログが出ることがあります。
- **`/health` の画面サイズ**: xctrunner には起動画面の設定がないため、実機ではランナー内の `UIScreen` が 320×480 の互換モードになります。そのため `/health` は SpringBoard の frame から縦向きの画面サイズを、スクリーンショットのピクセル数から scale を求めます（初回だけ計測してキャッシュします）。向きはリクエストのたびに読み直して幅と高さに反映します。
- **`portraitUpsideDown`**: iPhone のアプリの多くは上下逆さに回転しないので、`/orientation portraitUpsideDown` の後も `/health` の `orientation` は直前の向きのままになることがあります。表示が逆さになった場合の座標変換は実装していますが、検証していません。
- **音量ボタン**: `volumeUp` / `volumeDown` は実機でのみ使えます（シミュレータでは 400）。
- **実機の `home`**: 実機では `XCUIDevice.press(.home)` が成功を返すのに何も起きません（iOS 26.7.1 + Xcode 27 で確認）。testmanagerd が `Failed to load displays from CADisplay` で画面を取得できず、ボタンのイベントを画面に結びつかないキーボードから送るため、SpringBoard が無視します。そのため実機の `/button home` は、ホームインジケーターのジェスチャー（画面下端から上への素早いスワイプ）で代用します。`private` 経路では 0.12 秒のスワイプ（約 0.35 秒で応答）、`private` が使えない場合は XCUI のドラッグ（最初に 0.02 秒押す必要があります。約 1.8 秒）です。ホームボタンのない端末が前提で、ホームボタンのある端末では同じジェスチャーでコントロールセンターが開きます。シミュレータでは `press(.home)` が効くので、そのまま使います。
- **usbmux 非対応**: 実機への接続には CoreDevice トンネル（または `--allow-wifi` で Wi-Fi）が必要です。
- **通信は平文**: 認証はトークンだけで、TLS はありません（「認証」の脅威モデルを参照）。`relay` を `kill -9` などで強制終了した場合は `.relay/runner.json` が残ります。
