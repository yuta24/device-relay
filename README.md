# device-relay

対象アプリに何も埋め込まずに、iOS の実機・シミュレータを Mac から HTTP で操作するためのプロトタイプです。

## コンセプト / アーキテクチャ

WebDriverAgent と同じ「常駐 XCTest ランナー」方式を使います。

```
 Mac (host)                                   iOS device / simulator
┌──────────────────────┐   HTTP/1.1 (JSON)   ┌──────────────────────────────────────┐
│ relay start / tap …  │ ──────────────────▶ │ RelayRunnerUITests-Runner            │
│ curl / 任意のクライアント │ ◀────────────────── │  testRelay() が NWListener で待ち受け │
└──────────────────────┘                     │  └─ XCUIApplication / XCUIDevice で   │
        │ xcodebuild test-without-building   │     SpringBoard や任意アプリを操作    │
        └──────────────────────────────────▶ └──────────────────────────────────────┘
```

- `Runner/RelayRunner.xcodeproj` の UI テストメソッドが端末上で HTTP サーバ（Network.framework）を立ち上げ、`/shutdown` を受けるまで戻りません。
- 操作は XCUITest の API（`XCUICoordinate`、`XCUIScreen`、`XCUIDevice` など）で行います。対象アプリ側の改修や SDK の組み込みは不要です。タッチ合成、表示の向き、前面アプリの取得には XCTest の非公開 API も使い、使えない場合は公開 API に落ちます。
- 座標系は「前面アプリの表示の向き（interface orientation）での、画面左上を原点とするポイント単位」です。横向きなら幅 > 高さの座標で指定します（詳しくは「座標系と画面の向き」）。
- 全エンドポイントで `Authorization: Bearer <token>` が必要です。トークンは `relay start` が起動ごとに生成します（詳しくは「認証」）。
- XCUI の失敗（`record(_:)` に送られる issue）はテストを失敗させずに HTTP 422 として返し、ランナーはそのまま動き続けます。
- ホストからの接続経路は、シミュレータでは `127.0.0.1` です。実機では CoreDevice トンネルのアドレス（`devicectl` の `tunnelIPAddress`）か `<udid>.coredevice.local` を使います。Wi-Fi の IP は `--allow-wifi` を付けたときだけ使います。usbmux は現時点では使いません。
- `relay` CLI（SwiftPM）は、ビルド、ランナーの起動、到達可能なアドレスの探索、Ctrl-C（または `relay stop`）での後片付けをまとめて行います。

```
Package.swift / Sources/relay      ホスト CLI (relay start / status / stop / install / devices / doctor / ランナー操作のサブコマンドなど)
Tests/relayTests                   CLI のユニットテスト (Swift Testing)
Runner/RelayRunner.xcodeproj       RelayRunnerHost (文字入力を試すためのホストアプリ) + RelayRunnerUITests (常駐ランナー)
Makefile                           make install / make uninstall (relay を ~/.local/bin にリンク)
skills/device-relay/               コーディングエージェント向けのスキル (SKILL.md と reference.md)

~/.relay/runner/                   relay install がコピーした Runner プロジェクト、エージェントスキル (skills/device-relay) と install.json
~/.relay/build/                    DerivedData (Runner プロジェクトごと)
~/.relay/logs/                     ビルドとランナーのログ、relay start --background の出力 (start-<時刻>-<port>.log)
~/.relay/runner.json               起動中のランナーの URL・トークン・端末名と、relay start の PID・起動時刻 (0600)
~/.relay/config.json               relay config の設定 (teamID)
```

ビルド成果物やログは `~/.relay` に置き、`relay` を実行したディレクトリ（対象アプリのリポジトリなど）には何も作りません。

## 要件

- macOS 上の Xcode（Xcode 27 で動作確認。`devicectl` を使うので Xcode 15 以上）
- **iOS 17.0 以上**（CoreDevice トンネルを前提とします。デプロイメントターゲットは 17.0）
- 実機の場合
  - Apple Development 証明書（Xcode > Settings > Accounts でサインインして作成）。Team ID は証明書から自動で検出します
  - 端末側で「デベロッパモード」と「UI オートメーション」が有効になっていること
  - Mac とペアリング済みで、USB または同じネットワーク経由で CoreDevice 接続できること

> **ツールチェーンに関する注意**: `swiftly` などで入れた別の Swift ツールチェーンが PATH の先頭にあると、Xcode SDK と食い違って `unknown argument: '-target-arch-variant'` のようなエラーになることがあります。その場合は `xcrun swift build` / `xcrun swift test` / `xcrun swift run` を使い、Xcode のツールチェーンでビルドしてください（Makefile も `xcrun swift` を使います）。

## クイックスタート

```sh
# device-relay のリポジトリで（1 回だけ）
make install          # xcrun swift build -c release して ~/.local/bin/relay にリンク（PREFIX=... で変更可）
relay install         # Runner プロジェクトを ~/.relay/runner にコピー（--build でシミュレータ用に事前ビルド）

# 以降はどのディレクトリからでも（対象アプリのリポジトリなど）。まずはシミュレータで試します
relay doctor --simulator   # Xcode・Runner・シミュレータを確認（署名は実機でだけ必要）
relay devices              # シミュレータの名前を確かめる（下の "iPhone 17 Pro" は例）
relay start --background --device "iPhone 17 Pro"   # 停止中なら boot してランナーを起動し、ready になったらプロンプトに戻る
relay status               # 動いているランナーの確認（生きていれば終了コード 0）
relay screenshot           # 操作（「CLI から操作する」）
relay stop                 # ランナーを止める（relay が boot したシミュレータも shutdown）
```

- 同じ名前のシミュレータが iOS のランタイムごとにあっても、`--device` は最も新しい iOS のものを選び、`relay: using …` に OS つきで表示します。古い iOS で試すときは `--os 26.5` のように絞ります（「端末の選択」）。
- すでに起動しているシミュレータを使うなら `relay start --background --simulator` でも構いません。実機が接続されていても、シミュレータの中から選びます。
- `--udid` / `--device` / `--simulator` を付けずに `relay start` すると、接続中の実機があればそれを優先します。実機は署名や UI オートメーションの準備が要るので、「実機」の手順を済ませてから使ってください。

エージェントや CI、スクリプトからは、`relay start --background` → 操作 → `relay stop` が基本の流れです（「バックグラウンドで動かす」）。人が手元で見ながら使うときは、`relay start`（フォアグラウンド。Ctrl-C で停止）でもかまいません。

- `make install` は `.build/release/relay` へのシンボリックリンクを `$(PREFIX)/bin/relay`（既定 `~/.local/bin/relay`）に作ります。`~/.local/bin` が PATH になければ追加してください。`make uninstall` はそのリンクがこのチェックアウトを指している場合だけ削除します。リポジトリを更新したら `make install` と `relay install` をやり直します。
- 開発中はリポジトリ内で `xcrun swift run relay …` でも動きます。リポジトリ内ではカレントディレクトリのチェックアウトの Runner を使うので、`relay install` 済みでもインストールしたコピーではなく手元の変更がビルドされます。

```sh
xcrun swift build
xcrun swift test
xcrun swift run relay doctor
```

### Runner の用意（relay install）

`relay` 本体（CLI）と、端末で動かす Runner（Xcode プロジェクト）は別に用意します。`relay install` は Runner プロジェクトを `~/.relay/runner/` にコピーし、relay のバージョンと元リポジトリのコミットを `~/.relay/runner/install.json` に記録します。

- コピー元は `--project <path>` > `$RELAY_HOME` > カレントディレクトリとその親 > `relay` の実行ファイルの場所（シンボリックリンクを解決）とその親、の順に探した device-relay のチェックアウトです。`make install` したリンクからは元のチェックアウトが見つかります。（取り出し元は差し替えられるようにしてあり、将来 GitHub Release からのダウンロードにする予定です。）
- コピーするのは `Runner/` と、プロジェクトが参照している CLI 側の共有ソース（`Sources/relay/RunnerAuth.swift` など、`project.pbxproj` の `../Sources/...` の参照）、それにエージェントスキル（`skills/device-relay`。「エージェントスキル」を参照）です。リポジトリと同じ配置（`~/.relay/runner/Runner/RelayRunner.xcodeproj`、`~/.relay/runner/skills/device-relay`）にします。
- 再実行すると上書き更新します。一時ディレクトリにコピーしてから入れ替えるので、途中で失敗しても前の Runner は残ります。入れ替えたときは、古いソースのビルド成果物（`~/.relay/build/installed`）を削除します。
- `relay install --build` は、コピーの後にシミュレータ用の `build-for-testing`（`generic/platform=iOS Simulator`）を行い、初回の `relay start` でビルドを省きます。ビルドログは `relay start` と同じく `~/.relay/logs/` の `build-<時刻>.log`（ポートはないので付けません）に保存し、失敗したときはそのパスを示します（コピーした Runner は残ります）。`--verbose` を付けると xcodebuild の出力をそのまま表示します。
- `relay uninstall`（= `relay install --remove`）は `~/.relay/runner` とそのビルド成果物を削除します。`config.json`、`runner.json`、ログは残します。
- `relay start` / `relay doctor` は、記録したバージョンが `relay` のバージョンと違う場合や、元のチェックアウトのコミットが記録と違う場合（`git pull` の後など）に「relay install を再実行して」と知らせます。止めはしません。

`relay start` が使う Runner プロジェクトは、次の順に探します。

1. `--project <path>`（チェックアウトのルート、`Runner/`、`.xcodeproj` のどれでも可）
2. `$RELAY_HOME`（同上）
3. カレントディレクトリとその親にある device-relay のチェックアウト（開発時用）
4. `~/.relay/runner`（`relay install` したもの）
5. `relay` の実行ファイルの場所（シンボリックリンクを解決したもの）とその親にあるチェックアウト

対象アプリのリポジトリなど、チェックアウトの外から実行すると 4 の `~/.relay/runner` を使います。device-relay のリポジトリ内で実行すると 3 のチェックアウトを使うので、`relay install` 済みでも、編集中（未コミットを含む）の Runner がそのままビルドされます。

1 と 2 で指定した場所にプロジェクトがなければ、ほかを探さずにエラーにします。どこにも見つからなければ、`relay install` などの設定方法を示して終了します。DerivedData は Runner プロジェクトごとに `~/.relay/build/installed`（インストールしたもの）か `~/.relay/build/<ディレクトリ名>-<パスのハッシュ>` に分けるので、別のソースでビルドした `.xctestrun` を使い回すことはありません。

### 端末の選択（relay devices）

`relay devices` は、`xcrun devicectl list devices` の実機と `xcrun simctl list devices` の iOS シミュレータを一覧表示します（名前、UDID、種類、OS、状態）。`--json` で JSON の配列を出します。`--os <version>` を付けると、その OS のものだけを表示します（下の `--os` と同じ一致の仕方）。

```
NAME           UDID                                  KIND       OS          STATE
Test Phone     00000000-0000000000000000             device     iOS 26.7.1  connected
iPhone 17 Pro  11111111-1111-1111-1111-111111111111  simulator  iOS 27.0    booted
iPhone 17      22222222-2222-2222-2222-222222222222  simulator  iOS 27.0    shutdown
```

`relay start` と `relay doctor` は、端末を次のように決めます。どれを使うかは必ず `relay: using …` として、OS と選んだ理由つきで表示します。

1. `--udid <UDID>`
2. `--device <名前>`: 名前の完全一致（大文字小文字は無視）。同じ名前が複数ある（ランタイム違いのシミュレータなど）ときは、次の順に決めます
   1. そのうち接続中・起動中のものが 1 つだけならそれ
   2. 候補（起動中のものがあればその中、なければすべて）がすべてシミュレータなら、最も新しい iOS のもの（`26.10` は `26.5` より新しい、のように数値で比べます）。`relay: using iPhone 17 Pro (iPhone 17 Pro, iOS 27.0, simulator, shutdown) <SIM_UDID> (--device; the newest iOS of 3 simulators named "iPhone 17 Pro")` のように表示します
   3. 実機とシミュレータが同じ名前の場合、同じ名前の実機が複数ある場合、最も新しい iOS のシミュレータが複数ある場合は、候補つきでエラーにします（実機は OS で推測しません。`--simulator` か `--udid` で選びます）
3. どちらもなければ、接続中の実機が 1 台だけならそれ、実機がなく起動中のシミュレータが 1 台だけならそれ。複数・0 台なら候補一覧つきでエラーにします

次の 2 つで、上の選択の前に候補を絞れます。`--udid` / `--device` とも、自動選択とも組み合わせられます。

- `--simulator`: シミュレータだけから選びます。実機が接続されていても、`--device` で同じ名前の実機があっても、シミュレータを選びます。`--device` なしでは、起動中のシミュレータが 1 台ならそれ、複数ならエラー（候補つき）です。0 台のときもエラーにし、新しい iOS のものから順に候補を示して、`--device <名前>` で選ぶよう案内します。どのシミュレータ（iPhone か iPad か、画面の大きさ）を使うかはスクリーンショットや座標に関わるので、勝手に選んで boot はしません
- `--os <version>`: OS のバージョンが前方一致するもの（区切りの `.` ごとに比べます）だけから選びます。`--os 27` は iOS 27.0 や 27.1、`--os 26.5` は 26.5 や 26.5.1 に一致し、26.6 や 26.50 には一致しません（足りない桁は 0 とみなすので、`--os 27.0` は iOS 27 にも一致します）。「以上」の比較にしないのは、`--os 26.5` で 27.0 が選ばれると意図と違うためです

停止中のシミュレータを `--udid` / `--device` で指定した場合は、`relay start` が `simctl boot` して起動を待ちます。relay が boot したシミュレータは、`relay start` の終了時（Ctrl-C を含む）に shutdown します。boot やビルドの途中（ランナーの起動前）に Ctrl-C（または SIGTERM）した場合も、実行中の simctl や xcodebuild を止めてから shutdown します。もともと起動していたシミュレータはそのままにします。

### Team ID（実機の署名）

実機では、署名に使う Team ID を次の順に決めます。シミュレータでは不要です。

1. `--team-id <TEAM_ID>`
2. `~/.relay/config.json` の `teamID`
3. キーチェーンの Apple Development 証明書（`security find-identity -v -p codesigning` の有効な ID と、その証明書のサブジェクトの OU）。証明書の名前の括弧内の ID は個人の ID で、Team ID ではありません。チームが 1 つならそれを使い、複数ならエラーで候補を示します

1 か 3 で決めた Team ID は、ランナーが起動できた（`ready:` が出た）ところで `~/.relay/config.json` に保存し、次回からはそれを使います。ビルドや起動に失敗した Team ID は保存しないので、打ち間違えた `--team-id` が残ることはありません。変えるときは `--team-id` を付けて起動するか（保存し直します）、`relay config` を使います。

```sh
relay config                      # 設定の一覧
relay config get teamID           # 未設定なら終了コード 1（標準エラーに relay: teamID is not set）
relay config set teamID <TEAM_ID>
relay config unset teamID         # 忘れて、次回はキーチェーンから検出し直す
```

### 環境の確認（relay doctor）

`relay doctor [--udid <UDID> | --device <名前>] [--simulator] [--os <version>] [--project <path>]` は、ビルドや起動をせずに次を確認し、各項目を ✓（問題なし）/ ✗（このままでは動かない）/ !（注意）で表示します。✗ と ! には直し方を 1 行添えます。✗ があれば終了コード 1（ローカルの失敗）、なければ 0 です。

- relay のバージョン、Xcode（`xcodebuild -version` と `xcode-select -p`）、xcrun、devicectl
- Runner プロジェクトの解決結果と、`relay install` の状態（記録したバージョン・コミット・コピー元、ずれていれば !）
- 端末一覧と、同じオプションの `relay start` が使う端末（`--udid` / `--device` がなければ自動選択の結果）。自動選択で実機になる場合は、シミュレータで試すなら `--simulator` か `--device <シミュレータ名>` を付けるよう ! で知らせます
- 実機: OS のバージョン（17 以上）、接続状態、ペアリング、デベロッパモード（`devicectl list devices`）、DDI のマウント状態（`ddiServicesAvailable`）、ロック状態（`devicectl device info lockState` の `passcodeRequired`）。UI オートメーションの有効状態は Mac から読めないので、常に ! で確認を促します
- シミュレータ: ランタイムが入っているか、起動状態
- 署名: 証明書と Team ID（実機なら見つからなければ ✗、シミュレータなら !）
- エージェントスキル: カレントディレクトリの git のルートの `.claude/skills/device-relay` と `~/.claude/skills/device-relay` の状態（`relay skill status` と同じ判定。古い・relay が入れたものでなければ !。入っていなくても問題にはしません）

`relay start` も、ビルドの前に同じ端末のチェックを行い、✗（接続されていない、ペアリングされていない、デベロッパモードが無効、iOS 17 未満、シミュレータのランタイムがない）があればビルドせずに終了します。! の項目（ロック中、DDI 未マウント）は表示だけして続けます。

### シミュレータ

```sh
relay start --device "iPhone 17 Pro"   # 停止中なら boot し、終了時に shutdown
# relay: runner project: ~/.relay/runner (from relay install)
# relay: using iPhone 17 Pro (iPhone 17 Pro, iOS 27.0, simulator, shutdown) <SIM_UDID> (--device; the newest iOS of 3 simulators named "iPhone 17 Pro")
# relay: booting simulator iPhone 17 Pro (<SIM_UDID>); it is shut down when relay exits
# relay: building runner (log: ~/.relay/logs/build-<時刻>-8100.log)   ← 初回か --rebuild 指定時だけ
# relay: launching runner on <SIM_UDID> (log: ~/.relay/logs/runner-<時刻>-8100.log)
# relay: runner listening; device addresses: ...
# ready: http://127.0.0.1:8100/
# token: ~/.relay/runner.json
```

ready になると、URL とアクセストークンが `~/.relay/runner.json`（パーミッション 0600）に書き出されます。別のターミナルから（`relay health` などのサブコマンドは「CLI から操作する」を参照）:

```sh
TOKEN=$(jq -r .token ~/.relay/runner.json)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8100/health
relay bench --url http://127.0.0.1:8100 --count 5 --tap 200,120   # トークンは runner.json から読む
```

Ctrl-C を押す（または別のターミナルで `relay stop` を実行する）と `relay` が `/shutdown` を送り、`runner.json` を削除します。ランナーがテストメソッドから抜けて `** TEST EXECUTE SUCCEEDED **` で終了し、`relay` も終了します（10 秒以内に終わらなければ xcodebuild を terminate します）。ランナーが ready になる前に Ctrl-C を押した場合は、`/shutdown` を送る先がないので xcodebuild をすぐに terminate します。ランナーの起動前（シミュレータの boot やビルドの途中）なら、そのビルドの xcodebuild を止め、relay が boot したシミュレータを shutdown して、`relay: stopped before launching the runner` と表示して終了コード 1 で終わります。

ready の後も、`relay start` は 3 秒ごとに `/ping` を送ってランナーの生存を確認します（`200` だけが生存扱い）。`/ping` はコマンドの実行中でも busy ゲートを通らずに即答するので、生存確認が利用者のリクエストと重なって `409` を起こすことはありません。ready の判定（起動直後の探索）には、XCUI が動くことを確かめるため `/health` を使います。3 回続けて応答がなければ（`200` 以外が 3 回続けば）、ランナーが落ちたとみなしてエラーを表示し、xcodebuild を止めて `runner.json` を削除し、終了コード 1 で終わります。`--rebuild` なしで `/ping` のない古いランナーを使った場合は、`/ping` が `404` になるので警告を出し、以後は `/health` で確認します（このときは `409` も生存扱いで、利用者のリクエストが `409` になることがあります）。`runner.json` を書き出せなかった場合も、ランナーを止めてから終了コード 1 で終わります。

オプション:

| オプション | 説明 |
| --- | --- |
| `--udid <UDID>` / `--device <名前>` | 使う端末（「端末の選択」）。省略すると自動で選びます。同時には指定できません |
| `--simulator` | シミュレータだけから選びます（「端末の選択」）。実機が接続されていてもシミュレータを使えます |
| `--os <version>` | OS のバージョン（`27`、`27.0`、`26.5` など）で候補を絞ります（「端末の選択」） |
| `--project <path>` | Runner プロジェクトの場所（「Runner の用意」）。`$RELAY_HOME` より優先します |
| `--port 8100` | 端末側の待ち受けポート。xcodebuild には `TEST_RUNNER_RELAY_RUNNER_PORT` として渡され、ランナーからは `RELAY_RUNNER_PORT` として見えます |
| `--team-id <TEAM_ID>` | 実機向けの署名チーム（「Team ID」。省略時は自動検出）。`-allowProvisioningUpdates RELAY_DEVELOPMENT_TEAM=<TEAM_ID>` を付けてビルドし、ランナーが起動できたら `~/.relay/config.json` に保存します |
| `--rebuild` | `~/.relay/build/…/DerivedData-*` に既存の `.xctestrun` があっても再ビルドします |
| `--verbose` | xcodebuild の出力をそのまま表示します |
| `--allow-wifi` | 実機で、CoreDevice トンネルに加えて Wi-Fi などのアドレスも探索します。トークンが同じネットワークに平文で流れるので、既定では無効です |
| `--ready-timeout 180` | `/health` が応答するまで待つ秒数。xcodebuild の出力に `Failed to initialize for UI testing` やテストの失敗が出た場合は、待たずにエラー内容と対処のヒントを表示して非ゼロで終了します |
| `--background` | 端末から切り離して起動し、ready になったら終了します（「バックグラウンドで動かす」） |

### バックグラウンドで動かす（relay start --background / status / stop）

`relay start` はフォアグラウンドで動き続けてターミナルを占有します。エージェントや CI、スクリプトからは `--background` を付けて起動し、終わったら `relay stop` で止めます。

```sh
relay start --background --device "iPhone 17 Pro"
# relay: started relay start in the background (pid 12345, log: ~/.relay/logs/start-<時刻>-8100.log)
# relay: using iPhone 17 Pro (...) <SIM_UDID> (--device; the newest iOS of ...)
# relay: building runner (log: ...)            ← 進行状況（ログの relay: の行）は標準エラーに出ます
# relay: launching runner on <SIM_UDID> (log: ...)
# ready: http://127.0.0.1:8100/                ← ここから標準出力
# device: iPhone 17 Pro (<SIM_UDID>)
# pid: 12345
# log: ~/.relay/logs/start-<時刻>-8100.log
# token: ~/.relay/runner.json
relay status          # URL・端末・PID・起動時刻・/ping の結果
relay tap --id relay.input
relay stop            # stopped
```

- `relay start --background [start の他のオプション]` は、同じオプションの `relay start`（`--background` なし）を新しいセッションとして起動します（端末を閉じても止まりません）。その stdin は `/dev/null`、stdout と stderr は `~/.relay/logs/start-<時刻>-<port>.log` です。ログは親（実行したコマンド）が新しく作ってから子に渡すので、同じ秒に別のポートで起動しても、同じポートですぐに起動し直しても、ほかの `relay start` のログと混ざりません（同じ名前があれば `-2`、`-3` … を付けます。`build-`・`runner-` のログも同じ名前の付け方です）。親はそのログを読み、`ready:` が出たら上のように URL・端末・PID・ログのパスを表示して終了コード 0 で終わります。
- ready にならなかった場合は、子の `relay start` を止め（SIGTERM。ビルド中なら xcodebuild を止め、relay が boot したシミュレータは shutdown します。60 秒以内に終わらなければ子と、子が起動したプロセスを強制終了します）、ログの末尾と原因を表示して終了します。終了コードは、子が ready の前に終了した場合（ビルドの失敗、端末が見つからない、`Failed to initialize for UI testing` など）は `1`、時間切れは `3`（ランナーに届かない）です。時間切れは、ランナーの起動（ビルドの完了）から `--ready-timeout` + 15 秒、起動まで（シミュレータの boot とビルド）は 30 分です。待っている間に Ctrl-C を押した場合も子を止めて `1` で終わります。
- 同じポートで動かせる `relay start` は 1 つだけです。`relay start`（フォアグラウンドのものと、`--background` が起動したもの）は、端末を選ぶ前から終了するまで（ランナーが動いている間も）`~/.relay/locks/start-<port>.lock` をロック（`flock`）します。そのポートでほかの `relay start` が起動中か実行中なら、boot もビルドもせずにエラー（終了コード `1`）にします。`--background` はロックを取ってから下の runner.json の確認を行い、起動した `relay start` にロックを引き継ぐので、ほぼ同時に 2 つ起動しても進むのは片方だけです。ロックはプロセスが終われば（強制終了でも）外れるので、ロックファイルが残っていても次の起動を妨げません。
- 起動の前に `~/.relay/runner.json` を確認します。その URL のポートが新しく使うポート（`--port`、既定は `8100`）と違えば、衝突しないのでそのまま起動し、runner.json は後から起動したランナーで上書きされます（フォアグラウンドで複数起動するときと同じです）。ポートが同じ（または URL からポートが取れない）ときは、その URL へ `/ping` を送り、何かが HTTP で応答したら、新しいランナーはそのポートで待ち受けられないので起動せずにエラー（終了コード `1`）にします。`200` なら、ランナーが動いているので `relay stop` で止めるか、そのまま使うか、`--port` で別のポートに起動するように案内します。`401` なら、runner.json に書かれたものとは別のランナー（別のトークン）がその URL で動いている可能性があり、`404` などそれ以外の応答なら別の何かがそのポートで待ち受けています。どちらの場合も、それを止める（`relay stop`、またはそのランナーを起動した `relay start`）か、`--port` で別のポートを使うように案内します。ポートが同じでも、応答がない（接続できない・タイムアウトした）ときと、runner.json がないときは起動に進みます。
- `relay status [--json]` は、runner.json（「接続先（runner.json）の探し方」と同じ順に探します。`--runner <path>` も可）の URL・端末名と UDID・`relay start` の PID とそれがまだ動いているか・起動時刻・`/ping` の結果（`busy` を含む）を表示します。`--json` では 1 つの JSON オブジェクト（`alive`、`url`、`udid`、`name`、`pid`、`processRunning`、`startedAt`、`ping`、`runnerInfo`）を出します。ランナーが `/ping` に応答すれば `0`、runner.json がないか応答しなければ `3`、トークンが拒否されたら（`401`）`4` です。
- `relay stop` は、runner.json の `relay start` に SIGTERM を送り、終了を待ちます。フォアグラウンドの Ctrl-C と同じ経路で、ランナーの `/shutdown`、relay が boot したシミュレータの shutdown、runner.json の削除を行います。`stopped` と表示して `0` で終わります（60 秒以内に終わらなければ `1`）。`relay start` がもう動いていない場合（強制終了された場合など）は、runner.json の URL とトークンで `POST /shutdown` を送り、runner.json を削除します。何も動いていなければ `not running` と表示して `0` です。フォアグラウンドの `relay start` も同じように止められます。
- runner.json には `relay start` の PID と起動時刻（秒単位）を記録します。`relay stop` は、その PID のプロセスの起動時刻が一致し、実行ファイルが `relay` で最初の引数が `start` の場合だけシグナルを送ります。`relay start` の終了後にその PID が別のプロセスに再利用されても、そのプロセスには何も送りません。

手動で起動する場合（リポジトリのルートで）:

```sh
xcodebuild build-for-testing -project Runner/RelayRunner.xcodeproj -scheme RelayRunner \
  -destination 'id=<SIM_UDID>' -derivedDataPath /tmp/relay-DerivedData-sim
TEST_RUNNER_RELAY_RUNNER_PORT=8100 xcodebuild test-without-building \
  -xctestrun /tmp/relay-DerivedData-sim/Build/Products/*.xctestrun -destination 'id=<SIM_UDID>'
```

xcodebuild の出力に `RELAY_RUNNER_READY port=8100 addresses=en0=…,utun3=…` が出たら待ち受け開始です。`TEST_RUNNER_RELAY_RUNNER_TOKEN_SHA256` を渡さずに起動した場合は、ランナーがトークンを生成して `relay-runner: RELAY_RUNNER_TOKEN_SHA256 is not set; generated token: <token>` と 1 回だけ出力します。認証なしでは待ち受けません。自分で決めたトークンを使う場合は、そのトークンの SHA-256（hex 64 文字、例: `printf %s "$TOKEN" | shasum -a 256`）を渡します。64 文字の hex でない値を渡すと、ランナーは待ち受けずに失敗します。

### 実機

1. 端末で デベロッパモード を有効にします（設定 > プライバシーとセキュリティ > デベロッパモード。有効にすると再起動します）。
2. USB で接続して Mac とペアリングし（端末で「このコンピュータを信頼」）、`relay devices` に `connected` で表示されることを確認します。
3. Xcode の Window > Devices and Simulators で端末を選び、接続済み（準備完了）の状態にします。初回はここで開発用ディスクイメージ（DDI）が端末に適用されるので、完了するまで待ちます。
4. 端末の 設定 > デベロッパ >「UI オートメーションを有効にする」をオンにします。オフのままだと、ランナーが `Failed to initialize for UI testing`（`Timed out while enabling automation mode.`）で起動に失敗します（Mac からは状態を読めないので、`relay doctor` は確認を促すだけです）。オンでも、automation mode の有効化のときに端末がパスコードの入力を求めることがあります。起動中は端末を手元に置き、パスコード入力画面が出たら入力してください（「既知の制約」の「automation mode の有効化でパスコードを求められる」）。
5. `relay doctor` で ✗ がないことを確認します（ペアリング、デベロッパモード、DDI、ロック、署名の Team ID）。
6. ランナーをビルドして起動します。接続中の実機が 1 台だけなら `--udid` も `--team-id` も要りません（Team ID はキーチェーンから検出し、起動できたら保存します）。意図した端末を確実に使うには `--device "<端末名>"` か `--udid` で指定します。

   ```sh
   relay start
   # relay: using <端末名> (iPhone 14 Pro, iOS 26.7.1, device, connected) <DEVICE_UDID> (selected automatically; the only connected device)
   # relay: signing team: <TEAM_ID> (from keychain)
   # ...
   # relay: saved the team to ~/.relay/config.json; relay config unset teamID forgets it   ← ランナーが起動できたとき
   # ready: http://<アドレス>:8100/
   ```

7. 無料の Personal Team などで署名した場合、初回の起動時に「信頼されていないデベロッパ」と表示されることがあります。端末の 設定 > 一般 > VPNとデバイス管理 で開発元の証明書を信頼してから、もう一度 `relay start` を実行してください。
8. 初回は「ローカルネットワーク上のデバイスの検索および接続」の許可ダイアログが出ることがあります。許可しないと Wi-Fi 経由（`--allow-wifi`）では届きません。

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
| `GET /ping` | – | 生存確認。busy ゲートもメインスレッドも通らずに即答します（`{"ok":true,"busy":<bool>,"busyForMs":<ms or null>}`）。詳しくは「生存確認（/ping）」 |
| `GET /health` | – | 端末情報、表示の向きでの画面サイズ（points / scale）、`orientation`、`touchSynthesis`、`foreground` |
| `GET /foreground` | – | 前面アプリの `bundleId` と `pid`、取得経路 `source`（`private` / `fallback`）。詳しくは「前面アプリ」 |
| `GET /screenshot` | `?format=png\|jpeg&quality=0.05–1.0&maxSize=<px>&scale=<px/pt>`（既定は png、jpeg の既定 quality は 0.7。範囲外・数値以外の quality と、png への quality の指定は 400。`maxSize`・`scale` は省略時は縮小なし） | 画面全体のスクリーンショット（表示の向きに正規化済み）。`maxSize`・`scale` で端末側で縮小します。画像と座標の関係を `X-Relay-*` ヘッダーで返します。詳しくは「スクリーンショットの縮小」 |
| `GET /source` | `?format=json\|text\|compact&filter=interactive&maxDepth=<n>&bundleId=`（既定は json、bundleId の既定は前面アプリ） | XCUI の要素ツリー。json は要素ごとの属性と frame、text は `debugDescription`、compact は 1 行 1 要素。`filter=interactive` で操作できる要素だけに絞ります。詳しくは「要素ツリー（/source）」 |
| `POST /tap` | `{"x":200,"y":120}`、または `{"element":{"identifier":"relay.input"}}` | タップ。`element` で要素を指定すると、その frame の中心をタップします（「要素セレクタ」） |
| `POST /press` | `{"x":200,"y":120,"duration":1.0}`、または `{"element":{…},"duration":1.0}` | 長押し |
| `POST /find` | `{"element":{"type":"button"},"limit":20,"bundleId":"…","timeout":0}`（`limit`・`bundleId`・`timeout` は省略可） | セレクタに一致する要素の一覧（type / identifier / label / value / frame / enabled）。ツリー全体を読まずに要素を探せます（「要素セレクタ」） |
| `POST /swipe` | `{"from":{"x":200,"y":700},"to":{"x":200,"y":200},"duration":0.3,"hold":0.05}` | スワイプ（ドラッグ） |
| `POST /type` | `{"text":"hello","keys":["return"],"bundleId":"com.apple.Preferences"}`（`keys` と `bundleId` は省略可。`keys` があれば `text` は省略・空文字でも可。`text` が文字列以外なら `keys` があっても 400） | キーボードのフォーカスがある要素への文字入力。`text` の後に `keys` を順に送ります。対象の既定は前面アプリ |
| `POST /key` | `{"key":"return","bundleId":"…"}`（bundleId は省略可） | 特殊キー（`return` / `delete` / `space`）を 1 つ送ります。それ以外のキー名は 400。詳しくは「文字入力と特殊キー」 |
| `POST /button` | `{"name":"home"}`（`volumeUp` / `volumeDown` は実機のみ） | ハードウェアボタン。`home` は実機では画面下端からのスワイプで代用します（「既知の制約」を参照） |
| `POST /orientation` | `{"orientation":"portrait\|portraitUpsideDown\|landscapeLeft\|landscapeRight"}` | 端末の向き（`UIDeviceOrientation`）を設定 |
| `POST /launch` | `{"bundleId":"com.apple.Preferences"}` | アプリの起動・前面化（`activate()`） |
| `POST /terminate` | `{"bundleId":"com.apple.Preferences"}` | アプリの終了 |
| `POST /shutdown` | – | ランナーを停止（テストメソッドから抜ける） |

`/tap` `/press` `/swipe` は `"mode": "private" | "xcui"` を受け付けます（省略時は使えれば `private`）。応答の `mode` に実際に使った経路が入り、`/health` の `touchSynthesis` で端末側の既定経路がわかります。詳しくは「タッチ合成の経路」を参照してください。

`/health` の例（横向きの Safari が前面のとき）:

```json
{"coordinateSpace":"points","device":{"model":"iPhone","simulator":true,"systemVersion":"27.0"},
 "foreground":{"bundleId":"com.apple.mobilesafari","pid":42390,"source":"private"},"ok":true,
 "orientation":"landscapeLeft","screen":{"height":402,"scale":3,"width":874},"touchSynthesis":"private"}
```

ステータスコード:

| コード | 意味 |
| --- | --- |
| `200` | 成功 |
| `400` | リクエスト不正（JSON、必須フィールド、値の範囲、数値フィールドへの数値以外（真偽値を含む）、負の値・数値以外・矛盾する `Content-Length`） |
| `401` | `Authorization: Bearer <token>` がない、または一致しない（`{"ok":false,"error":"unauthorized"}`）。リクエストヘッダーの形式の判定（`400`・`413`・`431`・`501`）の次、ほかのどの判定よりも先に行います |
| `404` / `405` | 未知のパス / メソッド違い |
| `409` | 別のコマンドを実行中（`{"ok":false,"error":"busy"}`）。待たずにすぐ返ります。`/ping` と `/shutdown` 以外のすべてのエンドポイント（`/health` を含む）で起こります。詳しくは「同時リクエスト」 |
| `422` | XCUI 側で操作に失敗（エラーメッセージを JSON で返し、ランナーは動き続けます）。`/type`・`/key` でキーボードのフォーカスがない場合は `no element has keyboard focus in <bundleId>`。`/tap`・`/press` の `element` で触れる要素が 1 つに決まらない場合は `reason`・`count`・`candidates` 付き（「要素セレクタ」） |
| `413` / `431` | ボディが 16 MB を超える / リクエストヘッダーが 64 KB を超える |
| `500` | 内部エラー（JPEG エンコード失敗など） |
| `501` | `Transfer-Encoding` ヘッダーがある（値に関わらず。ボディは `Content-Length` でのみ受け付けます） |

`400`・`401`・`413`・`431`・`501` は、応答した後に接続を閉じます。リクエストは、接続を開いてから（keep-alive の場合は前の応答を返してから）30 秒以内に全体が届かないと、接続を閉じます。実行中のコマンドの時間はこの 30 秒に含めません。

```sh
R=http://127.0.0.1:8100
AUTH="Authorization: Bearer $(jq -r .token ~/.relay/runner.json)"
curl -s -H "$AUTH" $R/ping
curl -s -H "$AUTH" $R/health
curl -s -H "$AUTH" -o shot.png $R/screenshot
curl -s -H "$AUTH" -o shot.jpg "$R/screenshot?format=jpeg&quality=0.5"
curl -s -H "$AUTH" -D - -o small.png "$R/screenshot?scale=1"   # 402x874 px（1 px = 1 pt）。ヘッダーに X-Relay-*
curl -s -H "$AUTH" $R/foreground
curl -s -H "$AUTH" "$R/source?maxDepth=3" | jq .tree
curl -s -H "$AUTH" "$R/source?format=text&bundleId=com.apple.Preferences" | head
curl -s -H "$AUTH" "$R/source?format=compact&filter=interactive"
curl -s -H "$AUTH" -X POST $R/launch      -H 'Content-Type: application/json' -d '{"bundleId":"com.apple.Preferences"}'
curl -s -H "$AUTH" -X POST $R/tap         -H 'Content-Type: application/json' -d '{"x":200,"y":120}'
curl -s -H "$AUTH" -X POST $R/press       -H 'Content-Type: application/json' -d '{"x":200,"y":400,"duration":1.0}'
curl -s -H "$AUTH" -X POST $R/tap         -H 'Content-Type: application/json' -d '{"element":{"label":"General","type":"button"}}'
curl -s -H "$AUTH" -X POST $R/find        -H 'Content-Type: application/json' -d '{"element":{"type":"cell"},"limit":5}'
curl -s -H "$AUTH" -X POST $R/swipe       -H 'Content-Type: application/json' -d '{"from":{"x":200,"y":700},"to":{"x":200,"y":200}}'
curl -s -H "$AUTH" -X POST $R/type        -H 'Content-Type: application/json' -d '{"text":"hello"}'
curl -s -H "$AUTH" -X POST $R/type        -H 'Content-Type: application/json' -d '{"text":"example.com","keys":["return"]}'
curl -s -H "$AUTH" -X POST $R/key         -H 'Content-Type: application/json' -d '{"key":"delete"}'
curl -s -H "$AUTH" -X POST $R/button      -H 'Content-Type: application/json' -d '{"name":"home"}'
curl -s -H "$AUTH" -X POST $R/orientation -H 'Content-Type: application/json' -d '{"orientation":"landscapeLeft"}'
curl -s -H "$AUTH" -X POST $R/terminate   -H 'Content-Type: application/json' -d '{"bundleId":"com.apple.Preferences"}'
curl -s -H "$AUTH" -X POST $R/shutdown
```

## CLI から操作する

`relay` には、エンドポイントを 1 つずつ呼ぶサブコマンドがあります。ランナーは `relay start --background`（または別のターミナルの `relay start`）で起動しておき、使い終わったら `relay stop` で止めます。トークンを自分で扱わずに、人もスクリプトもエージェントも同じ形で操作できます。`relay <command> --help` で各コマンドの使い方を表示します。

```sh
relay start --background                       # ready: <URL> が出たら戻る（「バックグラウンドで動かす」）
relay status                                   # 生きていれば終了コード 0、いなければ 3
relay health                                   # curl -s -H "$AUTH" $R/health
relay launch dev.yuta24.devicerelay.RelayRunnerHost
relay find --type textField                    # POST /find {"element":{"type":"textField"}}
relay tap --id relay.input                     # POST /tap {"element":{"identifier":"relay.input"}}
relay tap 200 120 --mode xcui                  # POST /tap {"x":200,"y":120,"mode":"xcui"}
relay press --label General --type button --duration 1.0
relay swipe 200 700 200 200 --duration 0.3
relay type "hello" --key return                # POST /type {"text":"hello","keys":["return"]}
printf '%s' "$PASSWORD" | relay type --stdin   # 文字列を標準入力から読む（ps やシェルの履歴に残さない）
relay key delete
relay screenshot                               # 保存先の絶対パスを出力（既定は $TMPDIR/relay/screenshot-<時刻>.png）
relay screenshot -o shot.jpg --quality 0.5     # 拡張子 .jpg / --quality で jpeg
relay screenshot --scale 1                     # 端末側で 1 px = 1 pt に縮小（stderr に画像と画面の大きさ）
relay screenshot --max-size 1024 --format jpeg # 長辺 1024 px に縮小
relay source --max-depth 3 | jq .tree
relay source --format text --bundle-id com.apple.Preferences
relay source --format compact --filter interactive   # 操作できる要素だけを 1 行 1 要素で
relay button home
relay orientation landscapeLeft
relay terminate com.apple.Preferences
relay shutdown                                 # ランナーだけを止める（relay start はそれを見て終了）
relay stop                                     # relay start ごと止める（boot したシミュレータの shutdown も）
```

（`make install` した `relay` をどのディレクトリからでも使えます。リポジトリ内では `xcrun swift run relay …` でも動きます。）

| コマンド | エンドポイント | 主なオプション |
| --- | --- | --- |
| `ping` / `health` / `foreground` | `GET /ping` / `/health` / `/foreground` | – |
| `screenshot` | `GET /screenshot` | `-o <file>`（`-` で stdout）、`--format png\|jpeg`、`--quality 0.05–1.0`、`--max-size <px>`、`--scale <px/pt>` |
| `source` | `GET /source` | `--format json\|text\|compact`、`--filter interactive`、`--max-depth <n>`、`--bundle-id <id>` |
| `find` | `POST /find` | セレクタ、`--limit <n>`、`--timeout <s>`、`--bundle-id <id>` |
| `tap` / `press` | `POST /tap` / `/press` | `<x> <y>` かセレクタ、`--mode private\|xcui`、`--timeout`・`--bundle-id`（セレクタのみ）、`--duration`（press のみ） |
| `swipe` | `POST /swipe` | `<x1> <y1> <x2> <y2>`、`--duration`、`--hold`、`--mode` |
| `type` | `POST /type` | `<text>` か `--stdin`、`--key <name>`（複数可、順に送る）、`--bundle-id` |
| `key` / `button` / `orientation` | `POST /key` / `/button` / `/orientation` | 名前（`key` は `--bundle-id` も可） |
| `launch` / `terminate` | `POST /launch` / `/terminate` | `<bundle-id>` |
| `shutdown` | `POST /shutdown` | – |
| `status` | `GET /ping` と runner.json | `--json`。終了コードは「バックグラウンドで動かす」 |
| `stop` | `relay start` への SIGTERM（なければ `POST /shutdown`） | – |

- セレクタは `--id`（= `identifier`）・`--label`・`--type`・`--value` を 1 つ以上と、任意の `--index <n>` です（「要素セレクタ」と同じ完全一致・AND）。`--type` の名前、キー名、ボタン名、向きの名前、数値の範囲は送る前に確認し、間違っていれば終了コード 1 で何も送りません。
- `-` で始まる文字列を入力するときは `relay type -- --text` のように `--` を挟みます。
- パスワードなど、`ps` やシェルの履歴に残したくない文字列は `relay type --stdin` で標準入力から渡します。末尾の改行 1 つ（`\n` か `\r\n`。`echo` が付けるもの）だけを除き、それ以外はそのまま入力します。`--key` と併用でき、`<text>` と同時に指定すると終了コード 1 で何も送りません。標準入力が空でも `--key` があればキーだけを送ります。
- 成功時はランナーの JSON をそのまま stdout に出します（`source --format text` / `compact` はテキスト）。`screenshot` だけは画像をファイルに保存し、その絶対パスを 1 行出します。既定の保存先を `$TMPDIR` にしたのは、操作する側（対象アプリのリポジトリ）の作業ツリーを汚さないためです。`--max-size` / `--scale` で縮小したときは、stdout は同じくパス 1 行のままで、stderr に `relay: image 471x1024 px, screen 402x874 pt, 1.172 px/pt (tap in points: px / 1.172)` のように画像と画面の大きさを出します（「スクリーンショットの縮小」）。
- 失敗時はランナーの JSON を stderr に出し、ステータスごとに次の終了コードで終わります。`relay:` で始まる行は人向けのヒントです。

| 終了コード | 意味 |
| --- | --- |
| `0` | 成功（2xx） |
| `1` | 引数の誤り、runner.json が読めない、スクリーンショットを保存できないなど、ローカルの失敗 |
| `3` | ランナーに届かない（runner.json がない、接続できない・タイムアウト）。`relay status` で確認し、動いていなければ `relay start --background` で起動してください |
| `4` | `401`。runner.json のトークンが動いているランナーのものではない（古いファイル、別のランナー） |
| `5` | `409`（busy）。再試行してよい |
| `6` | `422`。XCUI で失敗（フォーカスがない、要素が見つからない・1 つに決まらないなど） |
| `7` | `400` とその他の 4xx |
| `8` | 5xx などそれ以外 |

### 接続先（runner.json）の探し方

URL とトークンは `runner.json` から読みます。トークンはコマンドライン引数では受け取りません（`ps` やシェルの履歴に残るため）。次の順に探し、最初に見つかったものを使います。

1. `--runner <path>`
2. 環境変数 `RELAY_RUNNER`（runner.json のパス）
3. カレントディレクトリから親へ順に `.relay/runner.json`
4. `~/.relay/runner.json`

1 と 2 で指定したファイルがなければ、3・4 に進まずに終了コード 3 で終わります（意図しない別の端末を操作しないため）。

`relay start` は、どのディレクトリで実行しても `~/.relay/runner.json`（パーミッション 0600）だけに書き出します。カレントディレクトリ（対象アプリのリポジトリなど）には `.relay/` を作らないので、3 で見つかるのは、自分で置いた `.relay/runner.json` か、以前の版の `relay start` が書いたものだけです。停止時には、まだ自分のトークンが書かれている場合だけ削除します（`relay stop` が片付けるときも同じです）。複数の `relay start` を同時に動かすこと（`--port` を分けて）はできますが、`~/.relay/runner.json` は最後に起動したものになり、前のランナーには `relay health` などのコマンドが届かなくなります（前のランナーのトークンはファイルに残りません）。

## エージェントスキル

`skills/device-relay/` は、コーディングエージェント（Claude Code など）が対象アプリのリポジトリで作業しながら relay でアプリの動作を確かめるためのスキルです。`SKILL.md` に基本の流れ（`relay status` → `relay start --background` → `relay launch` → スクリーンショットと要素の観察 → 操作 → 確認 → `relay stop`）、要素セレクタを優先する操作のコツ、終了コードごとの対処、安全上の注意をまとめ、オプションやトラブルシューティングの詳細は `reference.md` に分けています。

使う前に、このリポジトリで `make install` と `relay install` を済ませ、`relay doctor` で確認しておきます（「クイックスタート」）。`relay install` は Runner と一緒にスキルも `~/.relay/runner/skills/device-relay` にコピーし、`relay skill install` はそこから対象アプリのリポジトリなどへ入れます。

```sh
cd /path/to/app
relay skill install            # <git のルート>/.claude/skills/device-relay にコピー（チームでコミットできる）
relay skill install --global   # ~/.claude/skills/device-relay（どのリポジトリでも使う）
relay skill install --dir <skills dir>   # <skills dir>/device-relay
relay skill status             # 取り出し元と、プロジェクト・グローバルのインストール先、バージョンのずれ（!）
relay skill uninstall          # relay が入れたものだけを削除（--global / --dir も同じ）
```

- 既定の入れ先は、カレントディレクトリの git のルート（git の外ならカレントディレクトリ）の `.claude/skills/device-relay` です。コピーなので、そのままコミットしてチームで共有できます。どのコマンドも入れ先（削除先）のパスを必ず表示します。relay が表示・比較するパスは、存在する部分のシンボリックリンクを解決した形にそろえます（macOS では `/private/tmp/...` も `/tmp/...` になります）。
- 取り出し元は `~/.relay/runner/skills/device-relay`（`relay install` したもの）、なければ `relay install` と同じ探し方で見つけた device-relay のチェックアウト（`$RELAY_HOME`、カレントディレクトリとその親、`relay` の実行ファイルのチェックアウト）の `skills/device-relay` です。
- コピーには、SKILL.md を変えずに隠しファイル `.relay-skill.json` を置き、relay のバージョン、コミット、取り出し元、日時を記録します。この記録があるもの（または relay のスキルを指すリンク）は relay が入れたものとみなし、再実行で上書き更新します。それ以外のものが入れ先にあれば、`--force` なしでは上書きしません。`uninstall` は relay が入れたものだけを削除し、それ以外は残してエラーにします。
- `--link` はコピーの代わりにシンボリックリンクを作ります。スキルを編集する開発用で、取り出し元はチェックアウトを優先します（チェックアウトの変更がそのまま反映されます）。リンクはこの Mac の絶対パスを指すので、コミットして共有するには向きません。
- `relay skill status` は、記録したバージョンが `relay` のバージョンと違う場合や、取り出し元より古い（バージョンかコミットが違う）場合に ! を付けます。relay を更新したら `relay install` の後に `relay skill install`（`--global` などで入れたなら同じオプション）をやり直してください。
- スキルは、ランナーが動いていれば（`relay status` が 0）それを使い、止めません。自分で `relay start --background` したときだけ、終わりに `relay stop` します。端末は、実機を指定されない限り `relay devices` で選んだシミュレータを `--device` / `--udid` で明示します。

## 前面アプリ

`/type`・`/key`・`/source` は、`bundleId` を省略すると前面アプリを対象にします。`/launch` を経由せずに手で切り替えたアプリ（ホーム画面のアイコン、ステータスバーの「◀ 戻る」、他アプリからの起動など）にも追従します。`GET /foreground` と `/health` の `foreground` で確認できます。

```json
{"bundleId":"com.apple.springboard","ok":true,"pid":35,"source":"private"}
```

| `source` | 仕組み |
| --- | --- |
| `private` | XCTest の非公開 API で、アクセシビリティ上アクティブなアプリを取得します（WebDriverAgent の `fb_activeApplication` と同じ方式）。ホーム画面では SpringBoard（`com.apple.springboard`）になります |
| `fallback` | 非公開 API が使えない場合。最後に `/launch` したアプリが公開 API の `XCUIApplication.state` でまだ `runningForeground` ならそのアプリ、そうでなければ SpringBoard です。`pid` は `null` です。手で切り替えたアプリは判別できません |

`private` で使う非公開 API（`Runner/RelayRunnerUITests/RelayActiveApplication.m`）:

- `-[XCUIDevice accessibilityInterface]`（`XCAXClient_iOS`）の `-activeApplications` → `XCAccessibilityElement` の配列。各要素の `-processIdentifier` で PID を得ます
- `-[XCUIDevice applicationMonitor]` の `-monitoredApplicationWithProcessIdentifier:` → `XCUIApplication`。その `-bundleID` でバンドル ID を得ます

クラスとセレクタは実行時に確認し、欠けていれば `fallback` になります。動作確認用に、ランナーの環境変数 `RELAY_DISABLE_PRIVATE_FOREGROUND=1`（xcodebuild には `TEST_RUNNER_RELAY_DISABLE_PRIVATE_FOREGROUND=1`）で `private` を無効にできます。

`activeApplications` が返すのは通常 1 つです。アプリの切り替えの途中だけ 2 つ返ることがあり（実機で計算機 → RelayRunnerHost の切り替え直後に、切り替え先が先頭でした）、先頭のアプリを前面とみなします。ホーム画面に戻るジェスチャーの直後など、切り替えのアニメーション中は直前のアプリが返ることがあります。

確認した結果（シミュレータ iOS 27.0 と実機 iPhone 14 Pro iOS 26.7.1。いずれも `private`）:

| 状態 | シミュレータ | 実機 |
| --- | --- | --- |
| ホーム画面 | `com.apple.springboard` | `com.apple.springboard` |
| `/launch` したアプリ | RelayRunnerHost、設定（シミュレータには計算機がありません） | `com.apple.calculator`、`dev.yuta24.devicerelay.RelayRunnerHost` |
| relay を通さずに起動（`simctl launch` / `devicectl device process launch`） | `com.apple.mobilesafari`、`com.apple.Preferences`、RelayRunnerHost | `com.apple.calculator`、RelayRunnerHost |
| タッチで切り替え（ステータスバーの「◀ Calculator」をタップ） | – | `com.apple.calculator` |

`/health` は前面アプリの取得のぶん遅くなりました（実機の p50 で約 3 ms → 約 16 ms）。

## 文字入力と特殊キー

- `/type {"text":"..."}` は前面アプリ（または `bundleId`）で、キーボードのフォーカスがある要素に `XCUIElement.typeText` で入力します。入力欄をタップしてフォーカスを当ててから送ってください。
- 特殊キーは `POST /key {"key":"return"}`、または `/type` の `keys` 配列（`{"text":"abc","keys":["delete","return"]}`。`text` の後に順に送ります）で送ります。キー名は大文字小文字を区別せず、別名 `enter`（= return）、`backspace`（= delete）も使えます。
- 対応するキーは `return`・`delete`・`space` だけです。`tab` と `escape` は iPhone のソフトウェアキーボードにキーがなく、tab は `\t` の文字として入力され、escape は何も起きなかったため、外しました。対応していないキー名は、`/key` でも `keys` でも `400 {"ok":false,"error":"invalid field: key: unsupported key 'tab' (expected return, delete, space)"}` を返し、何も入力しません。
- キーは `XCUIKeyboardKey` の文字（return は `\r`、delete は U+007F、space は ` `）として `typeText` で送ります。`typeKey(_:modifierFlags:)`（ハードウェアキーのイベント）も試しましたが、iPhone ではシミュレータ・実機とも space と tab しか届かず、return・delete・escape は何も起きませんでした。
- フォーカスがない場合は、XCUI の長いエラー文の代わりに `422 {"ok":false,"error":"no element has keyboard focus in <bundleId>"}` を返します（XCUI が待つため約 2–3 秒かかります）。

RelayRunnerHost の入力欄（`relay.input`）で確認した結果（シミュレータ・実機とも同じ。`tab`・`escape` は外す前の結果）:

| キー | 結果 |
| --- | --- |
| `text` | 入力されます（`hello world`） |
| `return` | `textFieldShouldReturn` が呼ばれ、入力が確定します。シミュレータの Safari のアドレスバーでもページが開きます |
| `delete` | 1 文字削除されます |
| `space` | 空白が入力されます |
| `tab`（対応外、400） | 1 行の入力欄に `\t` の文字として入力されました（次の入力欄にフォーカスは移らない。ソフトウェアキーボードに Tab キーがないため） |
| `escape`（対応外、400） | 何も起きませんでした（ソフトウェアキーボードに Esc キーがなく、キーイベントとしても届かない） |

1 回の `/key` は、シミュレータで約 0.26 秒、実機で約 0.66 秒でした。

### 検証用のホストアプリ

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

## 要素ツリー（/source）

`GET /source` は既定で JSON を返します（`format=json`）。`XCUIElement.snapshot()` で取得したツリーで、各要素は次のキーをすべて持ちます。

| キー | 内容 |
| --- | --- |
| `type` | `XCUIElement.ElementType` のケース名（`application`、`button`、`textField`、`staticText` など） |
| `identifier` / `label` | accessibilityIdentifier / ラベル（なければ空文字列） |
| `value` / `placeholder` | 値 / プレースホルダ（なければ `null`。値は文字列に変換） |
| `frame` | `{"x","y","width","height"}`。`/tap` と同じ、表示の向きでのポイント単位（小数点以下 3 桁） |
| `enabled` / `selected` | 有効か / 選択されているか |
| `hasFocus` | 公開 API の `hasFocus`。フォーカスエンジン（iPad のキーボード操作や tvOS）のフォーカスで、iPhone で入力中の欄でも `false` です |
| `hasKeyboardFocus` | キーボードのフォーカスがあるか（非公開の `-[XCElementSnapshot hasKeyboardFocus]`。使えなければ `null`） |
| `children` | 子要素の配列 |
| `truncated` | `maxDepth` で子要素を省いた要素にだけ付きます（`true`） |

実機の計算機での出力の抜粋（`children` の中身を省略。キーはソート順です）:

```json
{"bundleId":"com.apple.calculator","ok":true,"tree":{"children":[…],"enabled":true,
 "frame":{"height":852,"width":393,"x":0,"y":0},"hasFocus":false,"hasKeyboardFocus":false,"identifier":"",
 "label":"Calculator","placeholder":null,"selected":false,"type":"application","value":null}}
```

ツリーの中のボタン 1 つ:

```json
{"children":[],"enabled":true,"frame":{"height":36,"width":36,"x":20,"y":63},"hasFocus":false,
 "hasKeyboardFocus":false,"identifier":"SidebarButton","label":"History","placeholder":null,"selected":false,
 "type":"button","value":null}
```

- `maxDepth=<n>` で深さを制限します（`0` はルートだけ）。ただし XCTest は常にツリー全体を取得するので、短くなるのは応答の大きさだけで、時間はほとんど変わりません。`format=compact` と `filter` にも効きます（深さで切ったツリーを絞ります）。
- `format=text` は従来の `debugDescription` のテキストです。`filter` とは組み合わせられません（`400`）。
- 既定を JSON にしたのは、プログラムから扱う用途が主で、計測ではテキストより速かったためです（`debugDescription` はツリーの取得に加えて文字列の整形に時間がかかります）。テキストは人が読むとき用に残しています。
- 横向きでも `frame` は表示の向きの座標です（シミュレータの landscapeLeft / landscapeRight と実機の landscapeLeft で、`relay.input2` の frame の中心を `/tap` するとその欄にフォーカスが移ることを確認しました）。

### 1 行 1 要素の形式（format=compact）

`format=compact` は、要素を 1 行ずつ、深さに応じて 2 文字ずつ字下げしたテキストで返します。`debugDescription`（`format=text`）と違って JSON と同じスナップショットから作るので、JSON と同じくらい速く、大きさは JSON の 3 分の 1 ほどです。

```
application label="Settings" frame=0,0,402,874
  window frame=0,0,402,874
    ...
                  button label="General" id="com.apple.settings.general" frame=16,293,370,52
```

- 1 行は、`type`、空でない `label`・`id`（identifier）・`value`・`placeholder`（値は JSON の文字列。改行や `"` を含んでも 1 行に収まります）、`frame=x,y,width,height`（表示の向きのポイントを整数に丸めたもの）、立っているフラグ（`selected`、`focused`＝キーボードのフォーカス、`disabled`、`truncated`）の順です。名前はセレクタのオプション（`--type`・`--label`・`--id`・`--value`）に合わせています。

### 操作できる要素だけに絞る（filter=interactive）

`filter=interactive` は、ツリー全体の代わりに、エージェントが操作に使える要素だけを文書順の平らな一覧で返します。`format=json` なら `elements` の配列、`format=compact` なら 1 行 1 要素（字下げなし）です。

```json
{"bundleId":"com.apple.Preferences","count":12,"elements":[
 {"frame":{"height":52,"width":370,"x":16,"y":293.333},"identifier":"com.apple.settings.general","label":"General",
  "placeholder":null,"selected":false,"type":"button","value":null}, …],"filter":"interactive","ok":true}
```

```
button label="General" id="com.apple.settings.general" frame=16,293,370,52
searchField label="Search" placeholder="Search" frame=28,808,346,28
```

残す要素:

- 型が操作の対象になるもの: `button`、`cell`、`link`、`icon`（ホーム画面）、`tab`、`switch`、`toggle`、`slider`、`stepper`、`pickerWheel`、`textField`、`secureTextField`、`searchField`、`textView` など。`table` や `segmentedControl` などの入れ物は、中のボタンやセルが残るので外します。キーボードとそのキーは外します（文字入力は `/type`・`/key` で行います）
- identifier・label・placeholder のどれかを持つもの（セレクタで指定できるもの）。テキスト入力欄は何もなくても残します（`--type textField --index <n>` で指定できるため）
- 有効（`enabled`）で、frame が画面と重なり、タップ位置（`/tap` の要素指定と同じ、画面と重なる部分の中心）がキーボードの下にも、後に続くコントロールの下にもないもの
- 名前のないコントロール（label のないセルなど）は、その中のラベル付きの `staticText` を代わりに残します（中に名前付きのコントロールがあればそちらを残します）。テキストをタップするとそのコントロールに当たります

各要素は、セレクタに使う `type`・`identifier`・`label`・`value` と、`placeholder`、`frame`、`selected` を持ちます（子要素はありません）。`relay tap --type button --label General` や `--id` のように、そのままセレクタに使えます。

- 絞り込みはランナー（端末側）で行います。スナップショットの取得はどちらでも同じ時間がかかりますが、ランナーで絞れば JSON に変換して送るのが短い一覧だけで済み、curl などほかのクライアントからも使えます。判定は SwiftPM のテストで確かめられるよう、CLI と共有するソース（`Sources/relay/RunnerElementTree.swift`）に置いています。
- XCUI のスナップショットはヒット可能か（`isHittable`）を持たず、要素ごとに問い合わせると遅いので、重なりは近似で判定します。後に続く（＝手前に描かれる）コントロールがタップ位置を覆っていれば外します（iOS 27 の設定アプリでは、下部の検索バーに中心が隠れた最後のセルと、検索欄の中で重なった 2 つの Dictate ボタンの片方が外れます）。コントロールでないシートや覆いの下にある要素は外れません。
- 一覧から外れても、セレクタは全体のツリーから探します。`--label General` だけでは同じラベルの `staticText` にも一致して `ambiguous` になることがあるので、一覧の `type` も付けるか `--id` を使います。

取得時間（`curl` で 7 回の p50。シミュレータは iPhone 17 Pro / iOS 27.0、実機は iPhone 14 Pro / iOS 26.7.1。括弧内は応答の大きさ）:

| 対象 | json | text | json `maxDepth=3` |
| --- | ---: | ---: | ---: |
| シミュレータ: 設定（トップ） | 50 ms（37 KB） | 198 ms（17 KB） | 46 ms（0.9 KB） |
| シミュレータ: RelayRunnerHost（キーボードなし） | 10 ms（2.5 KB） | 22 ms（1.3 KB） | 10 ms（0.9 KB） |
| シミュレータ: RelayRunnerHost（キーボード表示中） | 25 ms（16 KB） | 86 ms（6 KB） | 24 ms（2.5 KB） |
| シミュレータ: ホーム画面（SpringBoard） | 43 ms（36 KB） | 161 ms（13 KB） | – |
| 実機: RelayRunnerHost（キーボード表示中） | 140 ms（16 KB） | 238 ms（6 KB） | 132 ms（2.7 KB） |
| 実機: 計算機 | 89 ms（10 KB） | 187 ms（4 KB） | 122 ms（1.6 KB） |
| 実機: ホーム画面（SpringBoard） | 194 ms（70 KB） | 589 ms（25 KB） | 182 ms（9 KB） |

`format=compact` と `filter=interactive`（同じシミュレータ。curl で 7–9 回の p50。括弧内は要素数と応答の大きさ）:

| 対象 | json | text | compact | json `filter=interactive` | compact `filter=interactive` |
| --- | ---: | ---: | ---: | ---: | ---: |
| 設定（トップ） | 50 ms（167 要素、37 KB） | 210 ms（17 KB） | 50 ms（167 行、11 KB） | 48 ms（12 要素、2.3 KB） | 48 ms（12 行、1.0 KB） |
| ホーム画面（SpringBoard） | 87 ms（80 KB） | 412 ms（28 KB） | 83 ms（17 KB） | 83 ms（27 要素、4.6 KB） | 83 ms（1.6 KB） |
| RelayRunnerHost（入力欄にフォーカス） | 24 ms（14 KB） | 93 ms（5.6 KB） | 22 ms（3.3 KB） | 24 ms（3 要素、0.6 KB） | 25 ms（0.2 KB） |

時間はほぼスナップショットの取得で決まり、絞り込みや形式では変わりません（text だけは `debugDescription` の整形のぶん遅くなります）。

## 要素セレクタ

`/tap` と `/press` は、`x`・`y` の代わりに `element` で要素を指定できます。`/find` は同じセレクタで一致した要素の一覧を返します。

```json
{"element":{"identifier":"relay.input"}}
{"element":{"label":"History","type":"button"}}
{"element":{"type":"textField","index":1},"bundleId":"dev.yuta24.devicerelay.RelayRunnerHost","timeout":3}
```

| キー | 内容 |
| --- | --- |
| `element.identifier` / `element.label` / `element.value` | `/source` の同名の値との完全一致（大文字小文字も区別） |
| `element.type` | `/source` の `type` と同じケース名（`button`、`textField`、`cell` など）。知らない名前は `400` |
| `element.index` | 一致した要素のうち何番目を使うか（0 から。順序は `/source` の JSON と同じ文書順＝親が先の深さ優先） |
| `bundleId` | 対象アプリ。省略時は前面アプリ（`/source` と同じ） |
| `timeout` | 要素が現れるまで待つ秒数（0–10、既定 0 = 1 回だけ探す）。0.25 秒ごとにスナップショットを取り直します |
| `limit`（`/find` のみ） | 返す要素の上限（1–100、既定 20）。`count` は常に一致した総数で、上限で切った場合は `truncated: true` |

- 条件（`identifier`・`label`・`type`・`value`）は AND で組み合わせ、少なくとも 1 つ必要です。空文字列・文字列以外・未知のキー（`id` など）は `400` です。打ち間違いで条件が黙って消え、意図より広く一致するのを防ぐためです。
- 部分一致・正規表現は入れていません。完全一致なら同じセレクタが常に同じ要素を指し、一致の理由が説明しやすいためです。部分一致は複数一致が増え、`index` の意味が画面の内容で変わりやすくなります。曖昧な名前で探したいときは、`/find` を `type` などで絞って一覧から選び、その `identifier` や `index` を使ってください。
- 解決には `/source` と同じ `snapshot()` を使い、frame は表示の向きのポイント（`/tap` と同じ座標系）なので、横向きでもそのまま使えます。タップ位置は「frame と画面の重なる部分」の中心です（画面端で一部が切れたセルも、見えている部分の中心を押します）。タッチは座標指定と同じ経路（`private`、だめなら `xcui`。`mode` も同じ）で送ります。
- `x`・`y` と `element` を両方指定すると `400` です。

応答（`/tap`）には、実際に使った要素とタップ座標が入ります:

```json
{"bundleId":"dev.yuta24.devicerelay.RelayRunnerHost","element":{"enabled":true,
 "frame":{"height":34,"width":370,"x":16,"y":132},"identifier":"relay.input2","index":0,"label":"",
 "type":"textField","value":null},"mode":"private","ok":true,"point":{"x":201,"y":149}}
```

要素が 1 つに決まらない・触れない場合は `422` で、`reason`、一致した総数 `count`、候補（最大 5 件）`candidates` を返します。

| `reason` | 条件 | `candidates` |
| --- | --- | --- |
| `notFound` | 一致なし | 空 |
| `ambiguous` | 2 件以上一致して `index` がない | 一致した要素（先頭 5 件） |
| `indexOutOfRange` | `index` が一致件数以上 | 一致した要素（先頭 5 件） |
| `emptyFrame` | 選んだ要素の frame の幅か高さが 0 | 選んだ要素 |
| `offscreen` | 選んだ要素の frame が画面と重ならない | 選んだ要素 |
| `disabled` | 選んだ要素が `enabled: false` | 選んだ要素 |

```json
{"candidates":[{"enabled":true,"frame":{"height":52,"width":370,"x":16,"y":380.333},
  "identifier":"com.apple.settings.general","index":0,"label":"General","type":"button","value":null},
 {"enabled":true,"frame":{"height":29,"width":101.667,"x":29.667,"y":392},"identifier":"","index":1,
  "label":"General","type":"staticText","value":null}],
 "count":2,"error":"2 elements match the selector; add conditions or an index","ok":false,"reason":"ambiguous"}
```

（設定アプリのトップでは「一般」のセルが `button` と、その中の `staticText` の 2 つとして見えるので、`{"label":"General","type":"button"}` のように型も指定します。）

`/find` の例（`{"element":{"type":"textField"}}`、RelayRunnerHost）:

```json
{"bundleId":"dev.yuta24.devicerelay.RelayRunnerHost","count":2,"elements":[
 {"enabled":true,"frame":{"height":34,"width":370,"x":16,"y":86},"identifier":"relay.input","index":0,"label":"","type":"textField","value":null},
 {"enabled":true,"frame":{"height":34,"width":370,"x":16,"y":132},"identifier":"relay.input2","index":1,"label":"","type":"textField","value":null}],
 "ok":true,"truncated":false}
```

`/find` は一致がなくても `200`（`count: 0`）です。`elements[].index` はそのまま `/tap` の `index` に使えます。`/find` に `index` を付けると、その 1 件だけ（範囲外なら空）を返します（`count` は一致した総数のままです）。

### 待機（timeout）

- `timeout` を付けると、`/tap`・`/press` は要素が触れる状態（`notFound`・`indexOutOfRange`・`emptyFrame`・`offscreen`・`disabled` 以外）になるまで、`/find` は 1 件以上一致するまで待ちます。期限を過ぎると最後の結果を返します（`/tap` は `422`、`/find` は `count: 0`）。`ambiguous` は待っても解消しにくいので、待たずにすぐ `422` を返します。
- 待っている間もスナップショットの失敗（アプリがまだ起動していないなど）は再試行します。
- 上限は 10 秒です。待っている間はコマンドが busy ゲートを持ち続けるので、ほかのリクエスト（`/health` を含む）は `409` になります（`/ping` は `busy: true` を返します）。長く待つ必要がある場合は、短い `timeout` で繰り返してください。
- `timeout` は「次のスナップショットを取るかどうか」の期限で、1 回のスナップショット自体は中断できません（「既知の制約」を参照）。

シミュレータで、RelayRunnerHost を終了した状態から `{"element":{"identifier":"relay.input2"},"bundleId":"…RelayRunnerHost","timeout":5}` を送り、1.5 秒後に `simctl launch` で起動すると、約 3.8 秒で 200 が返って `relay.input2` にフォーカスが移りました。待機中の `/ping` は `{"busy":true,"busyForMs":719}`、`/health` は `409` でした。

確認した結果（シミュレータ iPhone 17 Pro）:

- RelayRunnerHost: `relay.input` / `relay.input2` を identifier 指定・`{"type":"textField","index":1}` でタップすると、`/source` の `hasKeyboardFocus` がその欄に移りました（`private`・`xcui`、`/press` も同じ）。
- 横向き（landscapeLeft / landscapeRight）でも、identifier 指定のタップでフォーカスが移りました（`point` は 874×402 の座標で `{"x":437,"y":87}` など）。
- 設定: `{"label":"General","type":"button"}` → `{"label":"About","type":"button"}` と順にタップして「情報」画面に移りました。

## 座標系と画面の向き

- 座標は **前面アプリの表示の向き（interface orientation）での、画面左上を原点とするポイント単位** です。縦向きなら 402×874、横向きなら 874×402 の範囲で指定します（iPhone 17 Pro の場合）。
- `/health` の `screen.width` / `screen.height` はこの向きでの値です。`orientation` は表示の向きを `/orientation` と同じ名前（`portrait` / `portraitUpsideDown` / `landscapeLeft` / `landscapeRight`）で返します。`/orientation landscapeLeft` の後は `"orientation":"landscapeLeft"` になります（UIKit の interface orientation としては `landscapeRight` にあたります。デバイスとインターフェースで左右の名前が逆になるためです）。
- 表示の向きは、端末の向き（`XCUIDevice.orientation`）と一致するとは限りません。横向きの iPhone でもホーム画面は縦のままですし、iPhone のアプリは `portraitUpsideDown` に回転しません。そのため、端末の向きではなく、リクエストのたびに前面アプリの向きを読み直します。`/orientation` を使わずに端末を手で回した場合や、アプリを切り替えた場合にも追従します。
- 向きの取得には非公開の `-[XCUIApplication interfaceOrientation]` を使います（SpringBoard 経由で呼んでも前面アプリの向きが返り、約 1 ms）。使えない場合は、スクリーンショットの `UIImage.imageOrientation` で代用します（約 90 ms）。
- `/screenshot` の画素も表示の向きにそろえます。横向きなら幅 > 高さになり、`width = screen.width × scale`、`height = screen.height × scale` です。ただし iPhone 14 Pro 実機では、XCUI のスクリーンショット自体が 1178×2556 px で、393 pt × 3 = 1179 より短辺が 1 px 足りません（向きの正規化を入れる前から同じです）。XCUI のスクリーンショットは画素が常に縦向きで、回転は向きのメタデータとしてだけ付いているので、縦向き以外では描き直します。そのぶん時間が増えます（p50 で、シミュレータは png +50 ms・jpeg +7 ms、実機は png +30 ms・jpeg はほぼ変わらず）。
- `maxSize` / `scale` で縮小した画像では、画素 = ポイント × `X-Relay-Image-Scale` です（下の「スクリーンショットの縮小」）。タップなどの座標は、縮小してもポイントのままです。
- タッチ: `xcui` 経路では、XCTest が SpringBoard 基準の座標を表示の向きで解釈します。`private` 経路の合成イベントは `XCSynthesizedEventRecord` の向きの指定では座標が変換されない（縦向きの画面座標として扱われる）ため、ランナーが表示の向きの座標を縦向きの画面座標に変換し、`portrait` として送ります。どちらの経路でも同じ座標が同じ位置に当たります。

### スクリーンショットの縮小

`GET /screenshot` は、フル解像度（iPhone 17 Pro の縦向きで 1206×2622 px）のほかに、端末側で縮小した画像を返せます。エージェントに画像を渡すとき（転送量と画像のトークン）を減らすためのものです。

| クエリ | CLI | 内容 |
| --- | --- | --- |
| `maxSize=<px>` | `--max-size <px>` | 長辺をこの画素数以下にします（16 以上の整数） |
| `scale=<px/pt>` | `--scale <px/pt>` | 1 ポイントあたりの画素数をこの値以下にします（0.1–10。`/health` の `screen.scale` と同じ単位）。`scale=1` なら画像の画素とタップのポイントが一致します |

- 両方を指定すると、小さくなる方に合わせます（`--scale 1 --max-size 1024` なら、iPhone は 402×874、長辺が 1024 pt を超える iPad では 1024 px）。縦横比は保ち、拡大はしません（元の大きさ以上の指定や、端末の scale 以上の `scale` では縮小しません）。範囲外・数値以外は `400` です。
- 縮小は、表示の向きへの正規化と同じ 1 回の描画で行います（向きのメタデータつきの画像を、縮小後の大きさのキャンバスに描きます）。正規化の後に縮小すると、フル解像度で描き直してからもう一度描くことになり、縮小を先にしても向きを直す描画は別に要るので、1 回にまとめるのがいちばん速く、エンコーダーには小さな画像だけが渡ります。横向きでは正規化のための描き直しがもともと要るので、縮小した方がエンコードが軽いぶん速くなります。縦向きのフル解像度の png は XCUI の PNG をそのまま返す（描き直さない）ので、縦向きで縮小すると画像の展開と描画のぶん少し遅くなります（下の表）。
- 応答には、画像と座標の対応を示すヘッダーを付けます（縮小しないときも付きます）。

| ヘッダー | 内容 |
| --- | --- |
| `X-Relay-Image-Width` / `X-Relay-Image-Height` | 返した画像の画素数 |
| `X-Relay-Screen-Width` / `X-Relay-Screen-Height` | 表示の向きでの画面の大きさ（ポイント）。`/health` の `screen.width` / `height` と同じ値 |
| `X-Relay-Image-Scale` | 1 ポイントあたりの画素数（画像の幅 ÷ 画面の幅。小数点以下 3 桁）。フル解像度なら `/health` の `screen.scale`（実機では 1 px の差で 2.997 などになることがあります） |

- 画像上の位置 (px) をタップの座標にするには `X-Relay-Image-Scale` で割ります（`maxSize=1024` の縦向きなら 471×1024 px、402×874 pt、`1.172`。画像の (120, 375) は (102, 320) pt）。`/tap` などの座標は、縮小した画像でも常にポイントです。
- `relay screenshot --max-size` / `--scale` は、保存先のパスを stdout に 1 行出すのは変えずに（`-o -` なら画像だけを stdout に出します）、stderr に `relay: image 471x1024 px, screen 402x874 pt, 1.172 px/pt (tap in points: px / 1.172)` と出します。どちらも付けないときは、これまでどおりパスだけです。
- 既定（どちらも付けない）は、これまでどおりフル解像度です。画素 = ポイント × `screen.scale` という関係や、細部を確かめたい人やスクリプトの使い方を変えないためです。エージェントスキルでは `--scale 1` を勧め、細部が要るときだけフル解像度を使うように案内しています。

計測（iPhone 17 Pro シミュレータ、iOS 27.0。`curl` で 10 回の p50。縦は設定アプリのトップ、横は RelayRunnerHost の landscapeLeft）:

| リクエスト | 縦: 画像 | 縦: 時間 | 縦: 大きさ | 横: 時間 | 横: 大きさ |
| --- | --- | ---: | ---: | ---: | ---: |
| png（既定） | 1206×2622 | 68 ms | 289 KB | 94 ms | 81 KB |
| jpeg（q=0.7） | 1206×2622 | 82 ms | 207 KB | 83 ms | 104 KB |
| png `maxSize=1024` | 471×1024 | 88 ms | 85 KB | 83 ms | 24 KB |
| jpeg `maxSize=1024` | 471×1024 | 87 ms | 55 KB | 81 ms | 24 KB |
| png `scale=1` | 402×874 | 87 ms | 69 KB | 82 ms | 19 KB |
| jpeg `scale=1` | 402×874 | 86 ms | 43 KB | 83 ms | 19 KB |

画像のトークン（画素数に比例）は、`scale=1` でフル解像度の 9 分の 1 です。RelayRunnerHost の `maxSize=1024` の画像で、入力欄の位置を 1.172 で割った座標をタップすると、その欄にフォーカスが移ることを確かめました（縦向きの Password 欄 (236, 229) px → (201, 195) pt、横向きの Second field 欄 (512, 102) px → (437, 87) pt）。

## 認証

- `relay start` は起動ごとに 32 バイトのランダムなトークン（`SecRandomCopyBytes`、hex 64 文字）を生成します。ランナーにはトークンそのものではなく、その SHA-256 だけを xcodebuild の環境変数 `TEST_RUNNER_RELAY_RUNNER_TOKEN_SHA256` で渡します（コマンドライン引数には載せません）。ランナーは提示されたトークンの SHA-256 を、保持しているハッシュと定数時間で比較します。
- ランナーは全エンドポイント（`/ping`、`/health`、`/shutdown` を含む）で `Authorization: Bearer <token>` を要求し、ない場合や一致しない場合は `401` を返します。比較は定数時間で行います。判定は HTTP キュー上で、リクエストヘッダーを読み終えた時点（ボディを読む前）に行い、`409` の busy 判定や `/ping` の応答よりも先です。未認証のリクエストからは busy 状態も処理時間もわからず、ボディを溜め込ませることもできません。
- 認証の前に処理するのはリクエストヘッダーの解析だけで、ヘッダーは 64 KB まで、リクエスト全体が届くまでは 30 秒までに制限しています。
- ready になると `relay start` は `{"url","token","udid"}` を `~/.relay/runner.json` にパーミッション 0600 で書き出し、stdout には `ready: <url>` とファイルの場所（`token: <path>`）だけを出します。トークンそのものは stdout に出しません（CI のログやターミナルの履歴に残りやすいため）。停止時にファイルを削除します。
- `relay bench` は `--token` を受け付け、省略時はランナー操作のコマンドと同じ探し方で見つけた `runner.json` から読みます。`relay start` 内部の `/health` 探索、`/ping` の生存確認、`/shutdown` もトークンを付けます。
- ランナーのログ（`relay-runner GET /health -> 200 1ms`、busy で弾いた `relay-runner GET /screenshot -> 409` など）には、メソッドとパスしか出しません。`/ping` は数秒おきに届くのでログに出しません。
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

`relay bench` は縮小したスクリーンショット（`png scale=1`、`jpeg 1024px`）も計測します。設定アプリのトップ（縦）で `relay bench --count 10` の p50 は、png 70 ms（289 KB）、jpeg q=0.5 87 ms（152 KB）、png scale=1 92 ms（69 KB）、jpeg 1024px 90 ms（55 KB）でした（縮小の計測は「スクリーンショットの縮小」）。

| `POST /tap` (xcui) | 1598 | 1617 | 1634 | 1636 | – |

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

409 が起きるのは、ゲートを通るリクエスト（`/ping` と `/shutdown` 以外のすべて。`/health` も含みます）が、別のゲートを通るリクエストの実行中に届いたときだけです。1 本のクライアントが応答を待ってから次を送る使い方では、自分のリクエスト同士は重なりません。ランナーは 409 を返すたびに `relay-runner GET /screenshot -> 409` の形でログに出します（`~/.relay/logs/runner-*.log`）。

### 生存確認（/ping）

以前は `relay start` が ready の後も 3 秒ごとに `/health` を送っていました。`/health` は他のコマンドと同じくゲートを通ってメインスレッドで実行される（前面アプリの取得を含み、実機で p50 約 16 ms）ため、利用者のリクエストとたまたま重なると、利用者側に 409 が返っていました。いまは生存確認に `GET /ping` を使います。

- `/ping` は HTTP キュー上で即答し、ゲートを取らず、メインスレッドにも入りません。コマンドの実行中でも `200` です。
- 応答は `{"ok":true,"busy":<bool>,"busyForMs":<ms or null>}` です。`busy` はゲートを通ったコマンドが実行中かどうか、`busyForMs` はそのコマンドが受け付けられてからの経過ミリ秒（実行中でなければ `null`）です。
- 認証は他のエンドポイントと同じく必須で、`401` の判定が先なので、トークンなしでは busy 状態はわかりません。
- `/ping` はメインスレッドが止まっていても応答するので、「XCUI が動くこと」の確認にはなりません。そのため ready の判定（起動直後のアドレス探索）は、これまでどおり `/health` の `200` で行います。
- 生存確認では `200` だけを生存扱いにします（`/ping` は 409 を返さないので、409 は失敗として数えます）。`--rebuild` を付けずに `/ping` のない古いランナーを使い回した場合は `404` が返るので、`relay start` は警告を出して `/health` に切り替えます（この場合だけ 409 も生存扱いで、利用者側の 409 も起こりえます）。
- 利用者のクライアントも、`/ping` の `busy` が `false` になるのを見てから送れば、実行中のコマンドとの重なりによる 409 を避けられます（ただし、ほかのクライアントが先に入ることはあります）。

## 既知の制約

- **タッチ合成は非公開 API 依存**: `private` 経路は Xcode / iOS の更新でセレクタやシグネチャが変わると使えなくなります。消えた場合は自動で `xcui` に落ちますが、シグネチャだけ変わった場合は検出できません。表示の向きの取得（`interfaceOrientation`）も非公開 API で、使えない場合はスクリーンショットから求めるので遅くなります。
- **`xcui` 経路は遅い**: XCUI はイベントを送る前後に対象アプリがアイドルになる（quiescence）のを待つため、タップ 1 回にシミュレータの Safari で約 1.6 秒、実機の計算機で約 1.2 秒（以前の計測では約 1.9 秒）かかります。
- **`/type`・`/key`**: キーボードのフォーカスがある要素が必要です。対象は前面アプリで、`fallback`（非公開 API が使えない場合）では手で切り替えたアプリを判別できないので、`bundleId` を明示してください。`tab` と `escape` は iPhone で効かないため対応しておらず、400 になります（「文字入力と特殊キー」）。
- **前面アプリの取得は非公開 API 依存**: `XCAXClient_iOS` などが変わると `fallback` に落ちます。`/health` も前面アプリを返すぶん遅くなりました（実機で p50 約 16 ms）。
- **映像ストリームはまだない**: 画面はスクリーンショットのポーリングで取得します（シミュレータの縦向きで png 約 90 ms / jpeg 約 110 ms、横向きは正規化のぶん遅くなります）。縮小（`maxSize` / `scale`）しても、XCUI の撮影自体（約 60 ms）は変わりません。
- **ローカルネットワーク許可**: 実機では初回にローカルネットワークの許可ダイアログが出ることがあります。
- **`/health` の画面サイズ**: xctrunner には起動画面の設定がないため、実機ではランナー内の `UIScreen` が 320×480 の互換モードになります。そのため `/health` は SpringBoard の frame から縦向きの画面サイズを、スクリーンショットのピクセル数から scale を求めます（初回だけ計測してキャッシュします）。向きはリクエストのたびに読み直して幅と高さに反映します。
- **`portraitUpsideDown`**: iPhone のアプリの多くは上下逆さに回転しないので、`/orientation portraitUpsideDown` の後も `/health` の `orientation` は直前の向きのままになることがあります。表示が逆さになった場合の座標変換は実装していますが、検証していません。
- **音量ボタン**: `volumeUp` / `volumeDown` は実機でのみ使えます（シミュレータでは 400）。
- **実機の `home`**: 実機では `XCUIDevice.press(.home)` が成功を返すのに何も起きません（iOS 26.7.1 + Xcode 27 で確認）。testmanagerd が `Failed to load displays from CADisplay` で画面を取得できず、ボタンのイベントを画面に結びつかないキーボードから送るため、SpringBoard が無視します。そのため実機の `/button home` は、ホームインジケーターのジェスチャー（画面下端から上への素早いスワイプ）で代用します。`private` 経路では 0.12 秒のスワイプ（約 0.35 秒で応答）、`private` が使えない場合は XCUI のドラッグ（最初に 0.02 秒押す必要があります。約 1.8 秒）です。ホームボタンのない端末が前提で、ホームボタンのある端末では同じジェスチャーでコントロールセンターが開きます。シミュレータでは `press(.home)` が効くので、そのまま使います。
- **要素セレクタ**: 完全一致だけです（「要素セレクタ」）。キーボードやシートに隠れている要素も frame が画面内なら `offscreen` にならず、隠している側がタップされます（`isHittable` は見ていません。`/source?filter=interactive` はキーボードと手前のコントロールに隠れた要素を外しますが、近似です）。`timeout` は 1 回のスナップショットを中断できず、別プロセスのシート（設定の Apple Account のサインイン画面など）が出ている間は、XCTest のスナップショットが `Timed out while evaluating UI query` で失敗するまで約 3 分戻らないことがありました（`/source` も同じです）。その間は busy ゲートを持ったままなので、ほかのリクエストは `409` になります。また `/launch` の直後は前面アプリの取得が切り替え前のアプリを返すことがあるので、確実に対象を決めたい場合は `bundleId` を指定してください。
- **automation mode の有効化でパスコードを求められる**: XCTest は、テストを始める前に端末の testmanagerd が automation mode を有効にするのを `XCUIApplicationStateTimeout`（既定 60 秒）だけ待ちます。このとき端末にパスコード入力画面が出ることがあり、入力されるまで有効化は終わりません（iOS 26.7.1 + Xcode 27 で、有効化に約 53 秒かかった回や、60 秒を超えて `Timed out while enabling automation mode.` で失敗した回がありました）。いったん許可されるとしばらくは有効なようで、直後に起動し直すと有効化は数 ms で終わります。入力の時間を取るため、スキームのテストアクションで `-XCUIApplicationStateTimeout 120` をランナーに渡し、ランナーは有効化が終わったら非公開関数 `_XCTSetApplicationStateTimeout` で 60 秒に戻します（`/launch` や `/terminate` の待ち時間は変わりません。関数がなければ 120 秒のままです）。120 秒以内に入力されなければ時間切れになるので、端末でパスコードを入力してから `relay start` し直してください。この引数のない古いビルドを再利用すると、`relay start` が note を表示します。チェックアウトの Runner なら `relay start --rebuild` で作り直せば済みます。`relay install` で入れた Runner（`~/.relay/runner`）は `--rebuild` だけではコピー済みの古いスキームのままビルドされるので、note のとおり `relay install` をやり直してから `relay start --rebuild` してください。起動に失敗したときの hint は、実機の UI テスト初期化の失敗（`Failed to initialize for UI testing`）ならパスコードの入力、UI オートメーションの設定、ロック解除の順に、シミュレータでの同じ失敗なら「1 回だけ起動し直す」を表示します。`** TEST FAILED **` などテストの失敗では hint は出さず、ランナーのログのパスだけを示します。
- **usbmux 非対応**: 実機への接続には CoreDevice トンネル（または `--allow-wifi` で Wi-Fi）が必要です。
- **通信は平文**: 認証はトークンだけで、TLS はありません（「認証」の脅威モデルを参照）。`relay` を `kill -9` などで強制終了した場合は `~/.relay/runner.json` が残ります（サブコマンドは接続できずに終了コード 3、別のランナーが同じポートにいれば 4 になります）。
