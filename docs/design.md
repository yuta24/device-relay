# 設計と計測

device-relay のアーキテクチャ、タッチ合成の経路、計測したレイテンシです。全体の入口は [README](../README.ja.md) です。

## コンセプト / アーキテクチャ

WebDriverAgent と同じ「常駐 XCTest ランナー」方式を使います。

```
 Mac (host)                                   iOS device / simulator
┌──────────────────────┐   HTTP/1.1 (JSON)   ┌──────────────────────────────────────┐
│ relay start / tap …  │ ──────────────────▶ │ RelayRunnerUITests-Runner            │
│ curl / 任意のクライアント │ ◀────────────────── │  testRunServer() が NWListener で待機 │
└──────────────────────┘                     │  └─ XCUIApplication / XCUIDevice で   │
        │ xcodebuild test-without-building   │     SpringBoard や任意アプリを操作    │
        └──────────────────────────────────▶ └──────────────────────────────────────┘
```

- `Runner/RelayRunner.xcodeproj` の UI テストメソッドが端末上で HTTP サーバ（Network.framework）を立ち上げ、`/shutdown` を受けるまで戻りません。
- 操作は XCUITest の API（`XCUICoordinate`、`XCUIScreen`、`XCUIDevice` など）で行います。対象アプリ側の改修や SDK の組み込みは不要です。タッチ合成、前面アプリの取得、表示の向きの取得などには XCTest の非公開 API も使います（「[非公開 API の一覧](private-api.md)」）。
- 座標系は「前面アプリの表示の向き（interface orientation）での、画面左上を原点とするポイント単位」です。横向きなら幅 > 高さの座標で指定します（詳しくは「[座標系と画面の向き](screen.md#座標系と画面の向き)」）。
- 全エンドポイントで `Authorization: Bearer <token>` が必要です。トークンは `relay start` が起動ごとに生成します（詳しくは「[認証](http-api.md#認証)」）。
- XCUI の失敗（`record(_:)` に送られる issue）はテストを失敗させずに HTTP 422 として返し、ランナーはそのまま動き続けます。
- シミュレータは Mac とネットワークを共有するので、[シミュレータへの接続](sessions.md#シミュレータへの接続) はループバックに限ります。以前のビルドは Mac の LAN 側のアドレスで待ち受けていました。実機の待ち受けと [接続の経路](device.md#接続の経路) は実機の文書にまとめています。
- `relay` CLI（SwiftPM）は、ビルド、ランナーの起動、到達可能なアドレスの探索、Ctrl-C（または `relay stop`）での後片付けをまとめて行います。

```
Package.swift / Sources/Relay      ホスト CLI (relay start / status / stop / install / devices / doctor / ランナー操作のサブコマンドなど)
  main.swift                       エントリポイント
  Shared/                          Runner のプロジェクトもコンパイルする共有ソース (認証、HTTP の framing、要素の判定、エラーなど)
  CLI/                             引数の解釈、出力、ランナー操作のサブコマンド、シナリオ、ベンチマーク
  Setup/                           relay install / doctor / skill、Runner プロジェクトの場所・ハッシュ・バンドル ID・Team ID
  Start/                           relay start (ビルドとランナーの起動、バックグラウンド起動、ロック、ビルドディレクトリの掃除)
  Client/                          起動中のランナーへの接続 (HTTP クライアント、状態、ランナーの探索、セッション)
  Device/                          端末の一覧、アプリのインストール確認、録画
  Support/                         外部コマンドの実行 (Shell、HostCommands)、ロック付きの値、プロセスの扱い
Tests/RelayTests                   CLI のユニットテスト (Swift Testing)
  <Dir>/<File>Tests.swift          Sources/Relay/<Dir>/<File>.swift のテスト (ソースと同じディレクトリ構成)。複数のファイルが使う補助は Fixtures/
Runner/RelayRunner.xcodeproj       RelayRunnerHost (文字入力を試すためのホストアプリ) + RelayRunnerUITests (常駐ランナー)
Makefile                           make install / make uninstall (relay を ~/.local/bin にリンク)、make dist
scripts/package.sh                 リリースの tarball を作る (.github/workflows/release.yml も使う)
skills/device-relay/               コーディングエージェント向けのスキル (SKILL.md、references/ の話題別ファイルと索引の reference.md)

~/.relay/runner/                   relay install がコピーした Runner プロジェクト、エージェントスキル (skills/device-relay) と install.json
~/.relay/build/                    DerivedData (Runner プロジェクトごと)、テスト実行のログと xcresult (TestData/port-<port>)、使用の記録 (relay-build-dir.json)。古い結果と、元の Runner がないか 30 日使っていないディレクトリは relay start が消す
~/.relay/logs/                     ビルドとランナーのログ、relay start --background の出力 (start-<時刻>-<port>.log、セッションは start-<時刻>-<名前>-<port>.log。古いものは relay start が消す)
~/.relay/runner.json               起動中のランナーの URL・トークン・端末名と、relay start の PID・起動時刻、ビルドディレクトリの名前 (0600)
~/.relay/sessions/<名前>/          セッションの runner.json と session.lock (docs/sessions.md の「複数のセッションを並列に動かす」)
~/.relay/locks/                    relay start が持つロック (ポート、端末、ビルド) と、ロックを持つ起動が使うビルドディレクトリ (start-<port>.build.json)
~/.relay/config.json               relay config の設定 (teamID)
```

ビルド成果物やログは `~/.relay` に置き、`relay` を実行したディレクトリ（対象アプリのリポジトリなど）には何も作りません。

## タッチ合成の経路

| 経路 | 仕組み | 特徴 |
| --- | --- | --- |
| `private`（既定） | XCTest の非公開 API でタッチを直接合成（WebDriverAgent と同じ方式） | アプリのアイドル待ちをしない。完了 callback を待ってから応答する |
| `xcui` | 公開 API の `XCUICoordinate.tap()` / `press(forDuration:)` / `press(forDuration:thenDragTo:…)` | イベントを送る前後に対象アプリがアイドルになる（quiescence）のを待つため遅い |

`private` で使う非公開 API は「[タッチ合成](private-api.md#タッチ合成)」にまとめています。クラスとセレクタはすべて実行時に `NSClassFromString` / `respondsToSelector:` で確認します（`Runner/RelayRunnerUITests/RelayTouchSynthesizer.m`）。1 つでも欠けていれば自動で `xcui` に落ち、`/health` は `"touchSynthesis":"xcui"` になります。`mode: "private"` を明示して使えない場合は 400 を返します。

`xcui` のタップの計測値は「[計測したレイテンシ](#計測したレイテンシ)」を参照してください。

ジェスチャーの組み立て: tap は 0.05 秒押して離す、press は `duration` 秒後に離す、swipe は `from` で `hold` 秒止まってから `duration` 秒かけて `to` へ移動し、すぐ離します。座標は前面アプリの表示の向きから縦向きの画面座標に変換して送ります（「[座標系と画面の向き](screen.md#座標系と画面の向き)」を参照）。

ランナー側で測った処理時間（実機）: press 0.5 s → 743 ms / 1.0 s → 1230 ms、swipe（hold 0.05 + 0.3 s）→ 592–606 ms。xcui では同じ操作がそれぞれ 2059 / 2030 ms、1632–2097 ms でした。private でも、指定時間に対して約 0.25 秒の固定オーバーヘッドがあります（合成イベントの完了通知までの時間）。

### 実機の home

実機では `XCUIDevice.press(.home)` が成功を返すのに何も起きません。
testmanagerd が `Failed to load displays from CADisplay` で画面を取得できず、ボタンのイベントを画面に結びつかないキーボードから送るため、SpringBoard が無視します。
そのため実機の `/button home` はスワイプで代用します（「[ホームと音量ボタン](device.md#ホームと音量ボタン)」）。

| 経路 | ジェスチャーと応答時間 |
| --- | --- |
| `private` | 0.12 秒のスワイプで、約 0.35 秒で応答します。 |
| `private` が使えない場合 | 最初に 0.02 秒押す必要がある XCUI のドラッグで、約 1.8 秒で応答します。 |

シミュレータでは `press(.home)` が効くので、そのまま使います。

確かめた環境: iOS 26.7.1、Xcode 27。

### 文字入力の経路

`/type`・`/key` も、タッチと同じ合成器で文字を直接送り、アプリのアイドル待ちをしません（「[文字入力の合成](private-api.md#文字入力の合成)」）。
以前の `XCUIElement.typeText` は、入力の前後でアプリがアイドルになるのを待ち、アイドルにならないアプリでは長く busy になったためです。

| 経路 | 仕組み | 特徴 |
| --- | --- | --- |
| `private`（既定） | `XCPointerEventPath` のテキスト入力を合成します。`typeText` が中で作るものと同じです | 送る前にフォーカスを確かめ、完了 callback を待ってから応答します。待つ時間には上限があります |
| `xcui` | 公開 API の `typeText` です | 前後でアイドルを待ちます。待ちきれないと 60 秒で諦めて続けます |

`typeText` の待ちは、アプリの中の XCTest が見る 2 つの条件で決まります。
メインのランループが眠る直前の通知（`XCTMainRunLoopIdleNotifier`）と、UIView のアニメーションの数（`XCTAnimationsIdleNotifier`）です。

修正前のランナーで、メインのランループが眠らない画面に `type abcdefghij` を送ると、次のようになりました。

| 段階 | ランナーのログと時間 |
| --- | --- |
| 送る前の待ち | `Wait for <app> to idle` から 60 秒後に `App event loop idle notification not received, will attempt to continue.` |
| 送るまでの間 | 約 5–43 秒の後に `Synthesize event`。この間は spindump の取得と思われますが、確かめていません |
| 送った後の待ち | また 60 秒後に同じ通知が出て、さらに約 16 秒後に `200` で応答 |

6 回の `/type` は、ランナーの計測で 140.9–180.9 秒でした。
この間 `relay ping` は `"busy":true` で、`relay type` は毎回約 32 秒で終了コード `3` でした。文字はすべて入りました。
修正後の `private` では、同じ画面で 5 回とも約 0.40–0.42 秒でした。
UIView の繰り返しのアニメーションと、メインキューを埋め続ける処理だけの画面では、待ちは起きませんでした（`type` は約 0.5 秒）。
ランループのソースが自分を signal し続ける画面で、毎回起きました。

WKWebView の初回の入力で約 121 秒止まった件は、この 60 秒 2 回に当たると考えていますが、その画面での原因は確かめていません。

確かめた環境: iPhone 17 シミュレータ、iOS 27.2、Xcode 27.2。

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

`relay bench` は縮小したスクリーンショット（`png scale=1`、`jpeg 1024px`）も計測します。設定アプリのトップ（縦）で `relay bench --count 10` の p50 は、png 70 ms（289 KB）、jpeg q=0.5 87 ms（152 KB）、png scale=1 92 ms（69 KB）、jpeg 1024px 90 ms（55 KB）でした（縮小の計測は「[スクリーンショットの縮小](screen.md#スクリーンショットの縮小)」）。

要素指定のタップ（同じシミュレータ、RelayRunnerHost の縦向き・キーボード表示中、`relay.input2` を `curl` で 10 回。ms）:

| リクエスト | min | p50 | p90 | max |
| --- | ---: | ---: | ---: | ---: |
| `POST /tap` `{"x":201,"y":149}` (private) | 295 | 300 | 304 | 304 |
| `POST /tap` `{"element":{"identifier":"relay.input2"}}` (private) | 334 | 347 | 351 | 353 |
| `POST /tap` `{"x":201,"y":149}` (xcui) | 598 | 749 | 773 | 776 |
| `POST /tap` `{"element":{"identifier":"relay.input2"}}` (xcui) | 593 | 739 | 770 | 773 |
| `POST /find` `{"element":{"identifier":"relay.input2"}}` | 25 | 26 | 31 | 56 |

要素指定は、スナップショットとツリーの組み立てのぶん（`/find` 単体とほぼ同じ約 25–50 ms）遅くなります。設定アプリのトップのように要素が多い画面では、`/find` が約 130–150 ms でした。

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

`xcui` のタップ 1 回は、シミュレータの Safari で約 1.6 秒、実機の計算機で約 1.2 秒でした。実機の以前の計測では約 1.9 秒でした。

`/health` は前面アプリの取得のぶん遅くなりました。実機の p50 は約 3 ms → 約 16 ms です。
