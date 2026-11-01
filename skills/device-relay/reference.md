# device-relay リファレンス

[SKILL.md](SKILL.md) の補足です。ここにないことは device-relay の README（節の名前を「」で示します）か `relay --help` / `relay <command> --help` を見てください。`--help` はランナー操作のコマンド（`screenshot`・`tap` など）、`status`・`stop`、`relay skill` にあります。`start`・`doctor`・`devices`・`install` は `relay --help` の全体のヘルプに書かれています。

## ランナーの起動・確認・停止

| コマンド | 内容 |
| --- | --- |
| `relay status [--json] [--runner <path>]` | runner.json のランナーの URL・端末・`relay start` の PID・起動時刻と `/ping` の結果。下の「start --background / status / stop」 |
| `relay start --background [オプション]` | `relay start` を端末から切り離して起動し、ready になったら戻ります。同上 |
| `relay stop [--runner <path>]` | runner.json の `relay start` を止めます（ランナー、relay が boot したシミュレータ、runner.json も片付く）。同上 |
| `relay devices [--json] [--os <version>]` | 実機とシミュレータの一覧（NAME、UDID、KIND、OS、STATE）。`--os` でその OS のものだけ |
| `relay doctor [--udid <UDID> \| --device <名前>] [--simulator] [--os <version>] [--project <path>]` | Xcode、Runner、署名、端末（同じ指定の `relay start` が使うもの）を確認。✗ があれば 1 |
| `relay ping` | `{"ok":true,"busy":<bool>,"busyForMs":<ms or null>}`。busy でも即答します |
| `relay skill status` | このスキルの取り出し元とインストール先（プロジェクト・グローバル）、relay とのバージョンのずれ（!）。入れ直しは `relay skill install [--global \| --dir <skills dir>]`（利用者に確認してから）。詳しくは `relay skill --help` |
| `relay health` | 端末情報、表示の向きでの画面サイズ（`screen.width` / `height` / `scale`）、`orientation`、`foreground` |

`relay start` の主なオプション（`--background` と組み合わせられます）:

| オプション | 説明 |
| --- | --- |
| `--udid <UDID>` / `--device <名前>` | 使う端末。同時には指定できません。名前は完全一致（大文字小文字は無視）。同じ名前が複数あれば、接続中・起動中の 1 つ、なければ最も新しい iOS のシミュレータ。実機とシミュレータが同じ名前なら候補つきのエラー |
| `--simulator` | シミュレータだけから選ぶ（実機がつながっていても）。`--device` なしでは起動中の 1 台。起動中がなければエラーになるので `--device` で名前を指定する |
| `--os <version>` | OS で候補を絞る。`.` ごとの前方一致（`27` は 27.x、`26.5` は 26.5.x） |
| `--port 8100` | 端末側の待ち受けポート。同じ Mac で別の `relay start` と同時に動かすときは分けます |
| `--rebuild` | 既存のビルドがあってもランナーを再ビルド |
| `--ready-timeout 180` | ready まで待つ秒数 |
| `--team-id <TEAM_ID>` | 実機の署名チーム（通常は自動検出） |
| `--project <path>` | Runner プロジェクトの場所（通常は `relay install` したもの） |
| `--verbose` | xcodebuild の出力をそのまま表示 |
| `--allow-wifi` | 実機で Wi-Fi のアドレスも使う。トークンと画面が平文で LAN を流れるので、利用者に頼まれたときだけ |

`--background` では、ランナーの起動まで（シミュレータの boot とビルド）を最大 30 分、起動後は `--ready-timeout` + 15 秒待ちます。

### start --background / status / stop

詳しくは README の「バックグラウンドで動かす」。

**`relay start --background`**: 同じオプションの `relay start` を新しいセッションとして起動し（端末を閉じても止まらない。stdin は `/dev/null`、出力は `~/.relay/logs/start-<時刻>-<port>.log`）、そのログを読んで待ちます。

```
relay: started relay start in the background (pid <PID>, log: /Users/<you>/.relay/logs/start-<時刻>-<port>.log)   ← stderr（進行状況の relay: 行）
relay: building runner (log: ...)
relay: launching runner on <UDID> (log: ...)
ready: http://127.0.0.1:8100/                                                                   ← ここから stdout
device: <端末名> (<UDID>)
pid: <PID>
log: /Users/<you>/.relay/logs/start-<時刻>-<port>.log
token: /Users/<you>/.relay/runner.json
```

パスはホームディレクトリを含む絶対パスで出ます（`/Users/<you>` は利用者のホーム）。

| 終了コード | 場合 |
| --- | --- |
| 0 | ready |
| 1 | ready の前に子の `relay start` が終了した（ビルドの失敗、端末が見つからない、`Failed to initialize for UI testing` など）。`~/.relay/runner.json` のランナーが同じポートですでに応答している。待っている間に中断された |
| 3 | 時間切れ（起動まで 30 分、起動後 `--ready-timeout` + 15 秒） |

失敗したときは子を止め（ビルド中の xcodebuild も止まり、relay が boot したシミュレータは shutdown されます）、stderr にログの末尾 20 行と原因、ログのパス（`(log: …)`）を出します。末尾で足りなければログファイル全体を読みます。

**`relay status [--json]`**: runner.json（「接続先（runner.json）」と同じ順。`--runner <path>` も可）の内容と `/ping` の結果を表示します。

```
url:         http://127.0.0.1:8100/
device:      <端末名> (<UDID>)
pid:         <PID> (relay start running)
started:     <日時>
ping:        ok (idle)
runner.json: /Users/<you>/.relay/runner.json
```

`runner.json:` も絶対パスで出ます。

`--json` は 1 つのオブジェクトです: `alive`（`/ping` が 200 か）、`url`、`udid`、`name`、`pid`、`processRunning`（その `relay start` がまだ動いているか）、`startedAt`（ISO 8601）、`ping`（`{"status":200,"busy":…,"busyForMs":…}`、`{"status":401}` など、応答がなければ `{"error":"…"}`）、`runnerInfo`（runner.json のパス）。値がないものは `null` です。runner.json がなければ `{"alive":false,"error":"…"}` だけを出します。

| 終了コード | 場合 |
| --- | --- |
| 0 | `/ping` に応答した |
| 3 | runner.json がない、または応答しない（stderr に「relay stop で片付け、relay start --background で起動」の案内） |
| 4 | トークンが拒否された（401）。runner.json が、そのアドレスで動いているランナーのものではない（別の `relay start`、古いファイル、`--runner` / `$RELAY_RUNNER` / カレントディレクトリから親へ順にたどった `.relay/runner.json`）。自分で起動したものでなければ利用者に確認する |
| ほか | `/ping` がそれ以外の HTTP 状態を返した（ランナー操作のコマンドと同じ対応: 404 などは 7、5xx は 8） |

**`relay stop`**: runner.json の `relay start` に SIGTERM を送り、終わるのを待ちます（Ctrl-C と同じ経路で、ランナーの `/shutdown`、relay が boot したシミュレータの shutdown、runner.json の削除）。フォアグラウンドの `relay start` も止まるので、自分で起動したものにだけ使います。

| 出力・終了コード | 場合 |
| --- | --- |
| `stopped`、0 | 止めた。`relay start` がもう動いていなかった場合は、ランナーに `/shutdown` を送って runner.json を削除した |
| `not running`、0 | 何も動いていない（runner.json がない、応答しない古い runner.json を削除した） |
| 1 | `relay start` が 60 秒以内に終わらなかった。`~/.relay/logs/start-*.log` を見て、利用者に知らせる |

実機の準備（デベロッパモード、ペアリング、UI オートメーション、Team ID）は README の「実機」「Team ID（実機の署名）」を参照してください。

## 接続先（runner.json）

ランナー操作のコマンドは、URL とトークンを次の順に探した runner.json から読みます（トークンはコマンドラインでは渡せません）。

1. `--runner <path>`
2. 環境変数 `RELAY_RUNNER`
3. カレントディレクトリから親へ順に `.relay/runner.json`
4. `~/.relay/runner.json`（`relay start` が書く場所）

1・2 で指定したファイルがなければ、3・4 を見ずに終了コード 3 です。終了コード 4 が続くときは、3 の古いファイルが `~/.relay/runner.json` より先に見つかっていないか確かめます。

## コマンドとオプション

| コマンド | 使い方 |
| --- | --- |
| `screenshot` | `relay screenshot [-o <file>\|-] [--format png\|jpeg] [--quality 0.05-1.0] [--max-size <px>] [--scale <px/pt>]`。保存先の絶対パスを 1 行出します（既定は `$TMPDIR/relay/screenshot-<時刻>.png`）。`.jpg` / `.jpeg` の拡張子か `--quality` で JPEG（既定の quality 0.7）。`--max-size` は長辺の画素数、`--scale` は 1 ポイントあたりの画素数の上限で、端末側で縮小します（両方なら小さい方。拡大はしない）。縮小したときは stderr に画像と画面の大きさと px/pt を出します（下の「座標と向き」） |
| `source` | `relay source [--format json\|text\|compact] [--filter interactive] [--max-depth <n>] [--bundle-id <id>]`。`--max-depth 0` はルートだけ。`compact` は 1 行 1 要素、`--filter interactive` は操作できる要素だけ（下の「要素ツリーの形式」） |
| `find` | `relay find <selector> [--limit 20] [--timeout <s>] [--bundle-id <id>]`。`--limit` は 1–100、`--timeout` は最大 10 秒 |
| `tap` | `relay tap (<x> <y> \| <selector>) [--mode private\|xcui] [--timeout <s>] [--bundle-id <id>]`。`--timeout`・`--bundle-id` はセレクタのときだけ |
| `press` | `relay press (<x> <y> \| <selector>) [--duration 1.0] [--mode private\|xcui] [--timeout <s>] [--bundle-id <id>]` |
| `swipe` | `relay swipe <x1> <y1> <x2> <y2> [--duration 0.3] [--hold 0.05] [--mode private\|xcui]`。始点で `--hold` 秒止まってから `--duration` 秒かけて終点へ |
| `type` | `relay type [<text> \| --stdin] [--key return\|delete\|space]... [--bundle-id <id>]`。`--key` は複数可、文字の後に順に送ります |
| `key` | `relay key return\|delete\|space [--bundle-id <id>]` |
| `button` | `relay button home\|volumeUp\|volumeDown`（音量ボタンは実機のみ） |
| `orientation` | `relay orientation portrait\|portraitUpsideDown\|landscapeLeft\|landscapeRight` |
| `launch` / `terminate` | `relay launch <bundle-id>` / `relay terminate <bundle-id>` |
| `foreground` | 前面アプリの `bundleId` と `pid` |
| `shutdown` | ランナーを止めます（`relay start` の後片付けは行いません。通常は `relay stop` を使う） |

- `--type` の名前、キー名、ボタン名、向き、数値の範囲は送る前に確認され、間違っていれば終了コード 1 で何も送りません（例: `relay key tab` → `unsupported key 'tab'`）。
- `--mode` は通常指定しません（既定の `private` が速い。`xcui` はアプリのアイドルを待つので 1 回 1–2 秒）。

## 要素ツリーの形式

| コマンド | 出力 | 設定のトップでの大きさ |
| --- | --- | --- |
| `relay source --format compact --filter interactive` | 操作できる要素だけ、1 行 1 要素（ふだんはこれ） | 12 行、約 1 KB |
| `relay source --filter interactive` | 同じ要素の JSON（`elements` の配列） | 約 2.3 KB |
| `relay source --format compact` | 全要素、1 行 1 要素、字下げで親子関係 | 167 行、約 11 KB |
| `relay source` | 全要素の JSON ツリー（`placeholder`、`enabled`、`hasKeyboardFocus` なども） | 約 37 KB |
| `relay source --format text` | XCUI の `debugDescription`（遅い。人が読む用） | 約 17 KB |

compact の 1 行: `type`、空でない `label="…"`・`id="…"`（identifier）・`value="…"`・`placeholder="…"`（JSON の文字列）、`frame=x,y,width,height`（ポイント、整数に丸め）、フラグ（`selected`、`focused`＝キーボードのフォーカス、`disabled`、`truncated`）。

```
textField id="relay.input" placeholder="Type here" frame=16,86,370,34 focused
button label="General" id="com.apple.settings.general" frame=16,293,370,52
```

`--filter interactive` に残るもの・外れるもの:

- 残る: ボタン、セル、リンク、ホーム画面のアイコン、タブ、スイッチ、スライダー、ステッパー、ピッカー、入力欄（`textField`・`secureTextField`・`searchField`・`textView`）などで、identifier・label・placeholder のどれかを持つもの（入力欄は何もなくても残る）。名前のないセルは、中のラベル付きテキストが代わりに残る（テキストをタップするとセルに当たる）
- 外れる: 無効（`enabled: false`）、画面の外、キーボードとそのキー、タップ位置がキーボードや手前のコントロール（下部の検索バーなど）に隠れたもの、見出しや本文のテキスト、画像、入れ物（`table` など）
- 隠れているかの判定は近似です。コントロールでないシートの下にある要素は残るので、スクリーンショットで見えていることを確かめます。
- セレクタは全体のツリーから探します。同じラベルの `staticText` があると `--label` だけでは `ambiguous` になるので、行の `type` も付けるか `--id` を使います。

## 要素セレクタ

- 条件: `--id`（accessibilityIdentifier）、`--label`、`--type`、`--value`。`relay source` の同名の値との完全一致（大文字小文字も区別）で、すべて AND。部分一致・正規表現はありません。
- `--index <n>`: 一致した要素のうち n 番目（0 から、`relay source` の JSON と同じ順）。`relay find` の結果の `index` をそのまま使えます。
- `--type` の名前は `relay source` の `type` と同じ（`button`、`staticText`、`textField`、`secureTextField`、`searchField`、`cell`、`switch`、`image`、`navigationBar`、`scrollView`、`table`、`collectionView`、`alert` など）。知らない名前は終了コード 1。
- 名前があいまいなときは `relay find --type <型>` で一覧を取り、その `identifier` や `index` を使います。
- タップ位置は要素の frame（画面と重なる部分）の中心です。
- キーボードやシートに隠れている要素も、frame が画面内なら隠している側をタップしてしまいます。タップの前にスクリーンショットで見えていることを確かめ、隠れていればキーボードを閉じる（アプリによっては `relay key return` で閉じる）かスクロールします。

## 操作が失敗したとき（終了コード 6）

stderr に JSON が出ます。

```json
{"candidates":[…],"count":2,"error":"2 elements match the selector; add conditions or an index","ok":false,"reason":"ambiguous"}
```

| `reason` | 意味 | 対処 |
| --- | --- | --- |
| `notFound` | 一致なし | 画面がまだ変わっていない → `--timeout` を付ける。前面アプリが違う → `relay foreground`、`--bundle-id`。名前が違う → `relay find --type …` / `relay source` で実際の値を確かめる |
| `ambiguous` | 2 件以上一致して `--index` がない（待たずにすぐ返る） | `candidates` を見て `--type` などの条件か `--index` を足す |
| `indexOutOfRange` | `--index` が一致件数以上 | `relay find` で件数を確かめる |
| `emptyFrame` | 要素の幅か高さが 0 | 表示されていない。画面を観察し直す |
| `offscreen` | 要素が画面の外 | `relay swipe` でスクロールしてから探し直す |
| `disabled` | 要素が `enabled: false` | 前提の入力・操作が足りない。画面を確かめる |

`relay type` / `relay key` で `no element has keyboard focus in <bundleId>` が出たら、入力欄をタップしてから送り直します（判定に 2–3 秒かかります）。

## 座標と向き

- 座標は前面アプリの表示の向きでの、画面左上を原点とするポイント単位です。縦向きなら `relay health` の `screen` が例えば 402×874、横向きなら 874×402 になります。
- フル解像度のスクリーンショットの画素は `screen.width × scale` × `screen.height × scale` です。画像上の位置から座標を出すときは scale で割ります。
- `--scale 1` の画像は画素 = ポイントです（iPhone 17 Pro の縦向きで 402×874）。`--max-size` などで縮小した画像は、stderr の `relay: image 471x1024 px, screen 402x874 pt, 1.172 px/pt (tap in points: px / 1.172)` の px/pt で割ります（例: (120, 375) px → (102, 320) pt）。curl では応答ヘッダー `X-Relay-Image-Scale` などで同じ値が得られます。
- タップやスワイプの座標は、どの画像を使っても常にポイントです。
- `relay orientation` の後は `relay health` の `orientation` と `screen` を読み直します。iPhone のアプリの多くは `portraitUpsideDown` に回転しません。
- 詳しくは README の「座標系と画面の向き」。

## スクロールの例

```sh
relay health                          # screen.width / height を確かめる
relay swipe 200 700 200 250           # 下から上へ（内容を下に送る）
relay find --label "Privacy" --type button
```

画面の外の要素は `offscreen` になるので、`find` で見つかるまでスワイプと観察を繰り返します。スワイプの始点は、ナビゲーションバーやホームインジケーターの近く（画面の上下端）を避けます。

## 試し打ち用のアプリ

ランナーと一緒に RelayRunnerHost（`dev.yuta24.devicerelay.RelayRunnerHost`）がインストールされます。対象アプリの代わりに操作を試せます。identifier: `relay.input` / `relay.input2`（入力欄）、`relay.password`（パスワード欄。`secureTextField`）、`relay.text`、`relay.passwordLength`、`relay.submitted`、`relay.events`（README の「検証用のホストアプリ」）。

```sh
relay launch dev.yuta24.devicerelay.RelayRunnerHost
relay tap --id relay.input --timeout 3
relay type "hello" --key return
relay find --id relay.submitted       # label が "submitted #1: hello"
```

## トラブルシューティング

| 症状 | 原因と対処 | README |
| --- | --- | --- |
| 起動時に `Failed to initialize for UI testing`（`Timed out while enabling automation mode.`） | 実機では、automation mode の有効化で端末がパスコードの入力を求め、入力されないまま時間切れになったことが多い（「UI オートメーション」が無効な場合も同じエラーになる）。利用者に、端末にパスコード入力画面が出ていたら入力してもらうよう依頼してから、`relay start` し直す（許可はしばらく有効なので、直後の起動は通りやすい）。`reusing …` の後に note が出ていたら、その指示どおり作り直す（チェックアウトなら `relay start --rebuild`、`relay install` で入れた Runner（`~/.relay/runner`。`--project` や `$RELAY_HOME` で指定した場合も）なら `relay install` をやり直してから `relay start --rebuild`）。それでも続くなら 設定 > デベロッパ >「UI オートメーションを有効にする」がオンか確認してもらう。シミュレータでは一時的なことが多いので 1 回だけ起動し直す | 「実機」 |
| 実機で「信頼されていないデベロッパ」 | Personal Team などの証明書。設定 > 一般 > VPNとデバイス管理 で信頼してもらってから起動し直す | 「実機」 |
| `relay doctor` でロック中（`passcodeRequired`）、操作が効かない | 実機のロックを解除してもらう | 「環境の確認（relay doctor）」 |
| `--allow-wifi` で届かない | 端末の「ローカルネットワーク」の許可ダイアログで許可してもらう | 「実機」「既知の制約」 |
| 実機が `connected` にならない、DDI が未マウント | USB で接続し、Xcode の Devices and Simulators で準備完了にしてもらう | 「実機」 |
| 署名・Team ID のエラー（実機） | Xcode でサインインして Apple Development 証明書を作ってもらう。チームが複数なら `--team-id` | 「Team ID（実機の署名）」 |
| `relay install を再実行して` と出る | `relay install` の後に relay が更新された。利用者に `relay install` を頼む（動作は止まらない） | 「Runner の用意（relay install）」 |
| `unknown argument: '-target-arch-variant'`（relay のビルド時） | PATH の先頭に別の Swift がある。`make install` は `xcrun swift` を使うのでそちらで | 「要件」 |
| 1 回の操作が数分戻らず、その間 busy が続く | 別プロセスのシート（Apple Account のサインインなど）が出ていてスナップショットが詰まっている。待つか、利用者に閉じてもらう | 「既知の制約」 |
| 実機で `relay button home` が効かない | ホームボタンのある端末では、代用のスワイプでコントロールセンターが開く | 「既知の制約」 |
| 終了コード 3 だが runner.json がある | `relay start` が強制終了され、ファイルだけ残っている（`relay status` の pid が `relay start not running`、ping が応答なし）。`relay stop` で片付けて（`not running`）から起動する | 「バックグラウンドで動かす」「既知の制約」 |
| `relay start --background` が「a runner is already running」で 1 | `~/.relay/runner.json` のランナーが同じポートで応答している。`relay status` で確かめ、そのまま使う。自分で起動したものでなければ止めない | 「バックグラウンドで動かす」 |

起動に失敗したときのログは `~/.relay/logs/`（`start-*.log`、`build-*.log`、`runner-*.log`）にあります。`relay start --background` は失敗時に原因、ログの末尾、`start-*.log` のパスを stderr に出すので、まずそれを読み、足りなければそのファイルや、そこに書かれた `build-*.log` / `runner-*.log` を読みます。
