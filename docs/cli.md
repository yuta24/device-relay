# CLI

`relay` のサブコマンドでランナーを操作する方法、シナリオの実行（実験的）、エージェントスキルについて説明します。
全体の入口は [README](../README.ja.md) です。以前の版から更新するときに直す必要がある変更は「[変更履歴](../CHANGELOG.md)」にあります。

## CLI から操作する

`relay` のサブコマンドで、ランナーのエンドポイントを 1 つずつ呼び出せます。
トークンを自分で扱わずに、人もスクリプトもエージェントも同じ形で操作できます。
`relay <command> --help` で各コマンドの使い方を表示します。

インストールした `relay` は、どのディレクトリからでも使えます。
リポジトリ内では `xcrun swift run relay …` でも動きます。

### 起動・停止と接続先

ランナーは `relay start --background`、または別のターミナルの `relay start` で起動しておき、使い終わったら `relay stop` で止めます。
起動・停止と生存確認は「[起動とセッション](sessions.md#バックグラウンドで動かすrelay-start---background--status--stop)」を参照してください。

接続先の選択は「[接続先（runner.json）の探し方](sessions.md#接続先runnerjsonの探し方)」にあります。

```sh
relay start --background                       # ready: <URL> が出たら戻る（「[バックグラウンドで動かす](sessions.md#バックグラウンドで動かすrelay-start---background--status--stop)」）
relay status                                   # 生きていれば終了コード 0、いなければ 3
relay health                                   # curl -s -H "$AUTH" $R/health
relay launch host                              # RelayRunnerHost（host はそのバンドル ID の別名）
relay find --type textField                    # POST /find {"element":{"type":"textField"}}
relay find --id home.title --timeout 5 --require   # 現れるまで待ち、現れなければ終了コード 6
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
relay tap --label=OK --type=button             # --opt=value の形でも書ける（すべてのサブコマンド）
relay screenshot --max-size 1024 --format jpeg # 長辺 1024 px に縮小
relay source --max-depth 3 | jq .tree
relay source --format text --bundle-id com.apple.Preferences
relay source --format compact --filter interactive   # 操作できる要素だけを 1 行 1 要素で
relay button home
relay orientation landscapeLeft                # landscape は landscapeLeft の別名
relay terminate com.apple.Preferences
relay stop                                     # relay start ごと止める（boot したシミュレータの shutdown も）。普段はこれ
relay run about.relay                          # 1 行 1 手順のシナリオを順に実行（実験的。下の「シナリオの実行」）
relay record start                             # 画面の録画を始める（下の「録画」。シミュレータと USB 接続の実機）
relay record stop                              # 録画を止め、MP4 の絶対パスを出力
```

### サブコマンドの一覧

ランナー操作のサブコマンドは、次のエンドポイントを呼び出します。

| コマンド | エンドポイント | 主なオプション |
| --- | --- | --- |
| `ping` / `health` / `foreground` | `GET /ping` / `/health` / `/foreground` | – |
| `screenshot` | `GET /screenshot` | `-o <file>`（`-` で stdout）、`--format png\|jpeg`、`--quality 0.05–1.0`、`--max-size <px>`、`--scale <px/pt>` |
| `source` | `GET /source` | `--format json\|text\|compact`、`--filter interactive`、`--max-depth <n>`、`--bundle-id <id>` |
| `find` | `POST /find` | セレクタ、`--limit <n>`、`--timeout <s>`、`--require`、`--bundle-id <id>` |
| `tap` / `press` | `POST /tap` / `/press` | `<x> <y>` かセレクタ、`--mode private\|xcui`、`--timeout`・`--bundle-id`（セレクタのみ）、`--duration`（press のみ） |
| `swipe` | `POST /swipe` | `<x1> <y1> <x2> <y2>`、`--duration`、`--hold`、`--mode` |
| `type` | `POST /type` | `<text>` か `--stdin`、`--key <name>`（複数可、順に送る）、`--bundle-id` |
| `key` / `button` / `orientation` | `POST /key` / `/button` / `/orientation` | 名前（`key` は `--bundle-id` も可、`orientation` は `landscape` を `landscapeLeft` として送る） |
| `launch` / `terminate` | `POST /launch` / `/terminate` | `<bundle-id>`（`host` も可） |
| `shutdown` | `POST /shutdown` | – |
| `status` | `GET /ping` と runner.json（ランナーの版も表示） | `--json`、`--all`（全セッションの一覧） |
| `stop` | `relay start` への SIGTERM（なければ `POST /shutdown`） | – |
| `run`（実験的） | 手順ごとに上のエンドポイント | `<file>` か `-` か `--step <手順>`（複数可）、`--runner`、`--session`、`--quiet` |
| `record start` / `stop` / `status` | –（ホスト側で録画） | `-o <file>`、`--force`、`--max-duration <s>`（start）、`--json`（status）、`--port <n>`（stop・status）、`--runner`、`--session` |

`shutdown` はコマンドの一覧には載せません。普段は `relay stop` を使います（「[shutdown と stop](sessions.md#shutdown-と-stop)」）。

`status` の終了コードは「[バックグラウンドで動かす](sessions.md#バックグラウンドで動かすrelay-start---background--status--stop)」を参照してください。

`run` は「[シナリオの実行（relay run、実験的）](#シナリオの実行relay-run実験的)」、`record` は「[録画（relay record）](#録画relay-record)」で説明します。

### 観察と要素の検索

`relay find` は、セレクタに一致する要素を探します。一致がなくても終了コード 0（`"count":0`）です。
`--require` を付けると、一致する要素がないときは終了コード 6 で終わります。`--index` が範囲外のときも同じです。

一致なしの応答は、`count`・`elements` に `"ok":false,"code":"element_not_found","error":"no element matched"` を足した JSON として stdout に出します。
判定はホスト側で行い、ランナーへのリクエストは変わりません。

`relay find <セレクタ> --timeout 5 --require` は「現れるまで待ち、現れなければ失敗する」確認になります。
スクリプトは JSON を読まずに終了コードだけで判断できます。

`relay source` は要素ツリーを取得します。`source --format text` / `compact` の出力はテキストです。

`relay screenshot` は画像をファイルに保存し、その絶対パスを 1 行出します。
既定の保存先は `$TMPDIR/relay/screenshot-<時刻>.png` です。対象アプリのリポジトリの作業ツリーを汚さないため、`$TMPDIR` に保存します。

`--max-size` / `--scale` で縮小したときも、stdout はパス 1 行です。
stderr には、画像と画面の大きさを次のように出します（「[スクリーンショットの縮小](screen.md#スクリーンショットの縮小)」）。

```text
relay: image 471x1024 px, screen 402x874 pt, 1.172 px/pt (tap in points: px / 1.172)
```

### セレクタと入力

セレクタでは、`--id`（= `identifier`）・`--label`・`--type`・`--value` を 1 つ以上指定し、任意で `--index <n>` を付けます。
「[要素セレクタ](elements.md#要素セレクタ)」と同じ完全一致・AND です。

`--type` の名前、キー名、ボタン名、向きの名前、数値の範囲は送る前に確認し、間違っていれば終了コード 2 で何も送りません。

`-` で始まる文字列を入力するときは `relay type -- --text` のように `--` を挟みます。
パスワードなど、`ps` やシェルの履歴に残したくない文字列は `relay type --stdin` で標準入力から渡します。

標準入力では、末尾の改行 1 つ（`\n` か `\r\n`）だけを除き、それ以外はそのまま入力します。`echo` が付ける改行もこの対象です。
`--key` と併用でき、標準入力が空でも `--key` があればキーだけを送ります。
`<text>` と同時に指定すると終了コード 2 で何も送りません。
標準入力が UTF-8 のテキストでなければ、ローカルの失敗として終了コード 1 です。

### アプリの指定と起動

バンドル ID の代わりに `host` と書くと、ランナーのホストアプリ RelayRunnerHost を指せます。
`launch`・`terminate` と、`--bundle-id` を取るコマンドで使えます。

バンドル ID は利用者ごとに違うため、relay は `relay start` がビルドしたアプリの ID を runner.json の `hostBundleID` に書き、そこから置き換えます。
`relay status` の `host app` にも表示します。

接頭辞は「[バンドル ID の接頭辞](device.md#バンドル-id-の接頭辞)」を参照してください。

古い relay の `relay start` が書いた runner.json には `hostBundleID` がないので、`host` は終了コード 1（`runner_info_invalid`）になります。ランナーを起動し直してください。

入っていないアプリへの `/launch` は、XCTest がすぐには失敗せず、長く busy になります。ランナーからインストールを確かめる公開 API はなく、`XCUIApplication` は名前を持つだけで、`terminate()` は入っていないアプリにも成功します。

`activate()` も中断できないため、`relay launch` と `relay run` の `launch` は、送る前にアプリが端末に入っているかを Mac 側の `simctl` / `devicectl` で確かめます。
入っていなければランナーに送らず、すぐに終了コード 6 で終わります。ランナーは busy になりません。

| 出力先 | アプリが入っていないときの出力 |
| --- | --- |
| stdout | `{"code":"app_not_installed","error":"<id> is not installed on <端末>","ok":false}` |
| stderr | `relay: <id> is not installed on <端末>; …` |

| 端末 | 確かめるコマンド | 待ち時間の上限 |
| --- | --- | --- |
| シミュレータ | `simctl get_app_container`（約 0.3 秒） | 5 秒 |
| 実機 | `devicectl device info apps --include-all-apps --bundle-id <id>` | 10 秒 |

実機の確認では `--include-all-apps` がないと開発者のアプリだけが対象で、Safari も見つかりません。
`host` はランナーのホストアプリなので確かめません。`relay run` では、入っていると分かったアプリを同じ実行の中で再度確かめません。

ツールの失敗、シミュレータが起動していない、時間内に答えがない、といった場合は、`relay: cannot tell whether <id> is installed (…)` を出してランナーに送ります。
入っているアプリを断らないためです。

システムのアプリは、シミュレータでは `simctl` が返すので同じように確かめます。
実機では一覧に載らないものがありうるので、`com.apple.` で始まる ID を確かめずに送ります。

次の場合はこの確認で防げず、入っていないアプリへの起動で長く待ちます。

- `/launch` を直接呼ぶ場合です。
- ツールの失敗や時間切れで、入っているかを確かめられない場合です。
- 実機で `com.apple.` のアプリを消してある場合です。

バンドル ID は大文字小文字も区別されます。`com.apple.preferences` では設定は起動せず、`relay launch` は入っていないと判定します。

`terminate` と `--bundle-id` は、入っていないアプリでもすぐ返るため確かめません。
`terminate` は成功し、`find` などは `xcui_failed` になります。

#### 入っていないアプリを起動したときの待ち時間

入っていないアプリの起動をランナーに送ると、CLI の打ち切り後も busy が続くことがあります（「[応答の待ち時間](#応答の待ち時間)」）。

| 端末 | 結果 |
| --- | --- |
| シミュレータ | 約 298 秒後に `422` を返し、その間ほかのコマンドは `409` でした。 |
| 実機 | 150 秒の打ち切りの後、さらに 153 秒以上 busy でした。 |

確かめた環境: シミュレータ（iOS 27.0）、実機（iOS 26.4）。

### オプションの書き方

すべてのサブコマンドで、値を取るオプションは `--port=8101` のように書けます。`--port 8101` と同じです。
`relay run` の手順の中も同じです。

最初の `=` で分け、`--` で始まる引数だけが対象です。`-o=file` や `a=b` のような位置引数は分けません。
値を取らないフラグに `=` を付けると、書き方の誤りです（例: `--json=true`）。

`--` より後ろは分けないので、`relay type -- --x=y` は `--x=y` という文字列を入力します。
`--` を挟まない `relay type --x=y` は、不明なオプションです。

### 応答の待ち時間

ランナーの応答は、30 秒に、その操作でランナーが待ちうる時間を足した長さまで待ちます。
`relay run` の手順も同じです。

| 操作 | 30 秒に足す時間 |
| --- | --- |
| `find` / `tap` | `--timeout` の時間 |
| `press` | `--timeout` と `--duration` の時間（`--duration` の既定は 1 秒） |
| `swipe` | `--duration` と `--hold` の時間 |
| `launch` / `terminate` | 120 秒 |
| `type` | 1 文字（Unicode スカラー）につき 0.1 秒と、キー 1 つにつき 1 秒 |
| `key` | 1 秒 |

アプリの起動・終了を XCTest が待つ時間は 120 秒です。ランナーは 60 秒に戻しますが、戻せないランナーでは 120 秒のままです（「[既知の制約](limitations.md)」）。
`type` の 0.1 秒は、シミュレータで測った約 15 ms/文字の数倍です。

時間内に応答がなければ、`no response within <秒>s` で終了コード `3` になります。
ただしランナーは操作を続けていて、終わるまで busy（`409`）なので、`relay ping` の `busy` が `false` になってから続けてください。

`launch` の時間切れの後は、数分待つことがあります。入っていないアプリでは、ランナーが応答するまで全体で約 300 秒でした。
XCTest の待ちは中断できませんが、busy の間も `relay stop` は効きます。
自分で起動したランナーなら、`relay stop` → `relay start` のほうが早く戻せます。シミュレータでは停止 11 秒、起動 13 秒でした。

### 出力と終了コード

ランナー操作のコマンドは、成功時も失敗時も JSON を stdout に 1 つ出します。
`relay:` で始まる人向けのヒント・警告は stderr に出します。
`--json` も受け付けますが、出力は変わりません。ほかのツール向けに書いたコマンドラインをそのまま通すためです。

ランナーの JSON は成功時も失敗時もそのまま出します。
relay 側の失敗も、同じ形 `{"ok":false,"code":"<snake_case>","error":"…"}` で stdout に出します。
runner.json がない、接続できない、アプリが入っていない、保存できないなどの場合が該当します。

| JSON 以外を出す場合 | 出力 |
| --- | --- |
| `source --format text` / `compact` | テキスト |
| `relay screenshot` の成功 | 保存先のパス 1 行 |
| `screenshot -o -` | stdout は画像そのものなので、失敗時の JSON は stderr |
| 書き方の誤り（終了コード 2） | stderr に誤りとヘルプの案内の 2 行だけで、stdout は空 |

書き方の誤りでは、`relay: <誤りの内容>` と `relay: see relay <command> --help` を出します。
そのコマンドに `--help` がなければ `relay --help` を案内し、使い方の全文は出しません。

relay が自分で出す JSON は、すべて **1 行・キーを辞書順・`/` をエスケープしない** 形です。
次が対象です。ランナーが返した JSON はそのままなので、ランナーの書式です。

- `status --json`・`status --all --json`・`record status --json`・`devices --json`・`doctor --json`
- relay 側の失敗と、`find --require` の一致なし

#### 終了コードの一覧

終了コードは、成功・書き方の誤り・ランナーの応答などで決まります。

| 終了コード | 意味 |
| --- | --- |
| `0` | 成功（2xx） |
| `1` | ローカルの失敗: runner.json が読めない、スクリーンショットを保存できない、端末が使用中・ビルドの失敗・シミュレータがない・ファイルがない、`relay start --background` で「すでに動いている」「ポートを握られている」、`relay doctor` が問題を見つけた、など |
| `2` | 書き方の誤り: 不明なオプション、値の不足・不正、両立しないオプション、不正なセッション名、`RELAY_RUNNER` と `RELAY_SESSION` の両方の設定、`relay run` の不正な手順（何も実行しない）など |
| `3` | ランナーに届かない（runner.json がない、接続できない・タイムアウト、接続が OS に拒否された） |
| `4` | `401`: runner.json のトークンが動いているランナーのものではない（古いファイル、別のランナー） |
| `5` | `409`（busy）: 再試行してよい |
| `6` | `422` の XCUI の失敗（フォーカスがない、要素が見つからない・1 つに決まらないなど）、または `relay launch` の `app_not_installed` |
| `7` | `400` とその他の 4xx |
| `8` | 5xx などそれ以外 |

終了コード `3` なら `relay status` で確認し、動いていなければ `relay start --background` で起動してください。

`the OS refused the connection (Operation not permitted)` と出たら、relay の側がエージェントなどの sandbox の中にいて localhost に接続できません。
ランナーを起動し直しても直りません（「[エージェントの sandbox から使う](sessions.md#エージェントの-sandbox-から使う)」）。

#### 失敗の code とヒント

失敗の JSON には、機械向けの `code` が入ります。
ランナーの `code`（`no_keyboard_focus`、`element_ambiguous` など）は「[エラーの形式と code](http-api.md#エラーの形式と-code)」を参照してください。
relay 自身は次の `code` を出します。ランナーは返しません。名前は変えません。

| `code` | 終了コード | 意味 |
| --- | --- | --- |
| `runner_unavailable` | `3` | runner.json がない、接続できない、接続が OS に拒否された |
| `runner_timeout` | `3` | 時間内に応答がない（ランナーは操作を続けていて、終わるまで busy） |
| `runner_info_invalid` | `1` | runner.json が読めない、url が不正、`host` を解決できない |
| `runner_bad_response` | ランナーのステータスによる（`8` など） | JSON でない本文のエラー（古いランナー、別のサーバー）で、`status` に HTTP ステータスが入ります。 |
| `screenshot_save_failed` | `1` | 画像を受け取ったが、ファイルに保存できない |
| `app_not_installed` | `6` | `launch` で、アプリが端末に入っていない（ランナーには送らない） |
| `element_not_found` | `6` | `find --require` で一致なし（ランナーの `code` と同じで、`count`・`elements` も付く） |

JSON 形式の状態確認の失敗も、stdout に JSON を 1 つ出します。stderr に同じ文は出しません。

| コマンド | 失敗の JSON |
| --- | --- |
| `relay status --json` | 上記と同じ形に `alive:false` を追加 |
| `relay record status --json` | `runner_unavailable` か `recording_unavailable` |
| `relay devices --json` | `devices_unavailable`（終了コード 1）の `{"ok":false,"code":…,"error":…}` |

終了コードは、ランナーに送らない `app_not_installed` を除いて、ステータスだけで決まります。
同じ終了コード内の違いは `code` で判断します。たとえば `6` のうち、フォーカスがないのか、要素が 1 つに決まらないのかを区別できます。

`relay:` のヒントは、`401`・`409` のほかに、次の code で出します。
code を返さない古いランナーでは、`401`・`409` のヒントだけが出ます。

| `code` | `relay:` のヒント |
| --- | --- |
| `no_keyboard_focus` | 入力欄を先にタップしてから送り直す |
| `element_not_found` | `relay find --type …` / `relay source` で画面を確かめるか、`--timeout <秒>` で待つ |
| `element_ambiguous` | `--type`・`--label`・`--id` を足すか、候補から `--index <n>` で選ぶ |
| `touch_mode_unavailable` | `--mode` を外すか、エラーが示す経路で送り直す |
| `covered_by_other_app` | `relay screenshot` か `relay find --type alert --bundle-id com.apple.springboard` で覆っている画面を確かめ、閉じてから送り直す |
| `remote_view_position_unknown` | `relay screenshot` で位置を確かめ、`relay tap <x> <y>` で座標を指定する |
| `not_found` | ランナーが relay より古いかもしれない（`relay start --rebuild` でビルドし直す） |

`covered_by_other_app` は、システムのダイアログやコントロールセンターなどがアプリを覆っている場合です。
`remote_view_position_unknown` は、要素が別のプロセスが描くビュー（共有シート）の中にあり、frame が画面の座標でない場合です。

### シナリオの実行（relay run、実験的）

`relay run` は、ランナー操作のコマンドを 1 行 1 手順で並べたシナリオを、1 回の呼び出しで順に実行します。
ログインのような決まった手順や、エージェントが一度探索して確かめた手順を再生できます。

> **実験的な機能です。** 手順の書き方、出力、終了コードの扱いは今後変わることがあります。

```sh
relay run about.relay                     # ファイルから
relay run - < about.relay                 # 標準入力から
relay run --step "launch com.apple.Preferences" --step "tap --label General --type button --timeout 5"
relay run about.relay --runner path/to/runner.json --quiet
relay run about.relay --session agent-1   # そのセッションのランナーで
relay run about.relay --check             # 検証だけ（runner.json を読まず、何も実行しない）
```

```
# relay-run: 1
# 設定 > 一般 > 情報 を開いて確かめる（about.relay）
terminate com.apple.Preferences
launch com.apple.Preferences
tap --id com.apple.settings.general --timeout 5 --bundle-id com.apple.Preferences
find --label About --type button --timeout 5 --require --bundle-id com.apple.Preferences
tap --label About --type button --timeout 5 --bundle-id com.apple.Preferences
find --label "iOS Version" --timeout 5 --require --bundle-id com.apple.Preferences
screenshot --output about.png --scale 1
```

「情報」の identifier は iOS のバージョンで違うので、上の例ではラベルと型で指定しています。
「一般」が画面外にある端末では、`tap` の前に `swipe` と `sleep 2` が要ります（「[待ちと確認](#待ちと確認)」）。

#### シナリオの入力と書式

シナリオはファイル、標準入力、`--step` のいずれかから読みます。

| 入力 | 指定方法 |
| --- | --- |
| ファイル | `<file>` |
| 標準入力 | `-` |
| コマンドライン | `--step <手順>`（複数可） |

入力を 2 つ以上指定した場合や、どれもない場合は、書き方の誤りとして終了コード 2 です。
ファイルが読めない場合や、標準入力が UTF-8 でない場合は、ローカルの失敗として終了コード 1 です。

ファイルと標準入力は UTF-8 で、先頭の BOM（U+FEFF）は取り除き、CRLF の改行も読めます。
ファイルの相対パスと、手順の中の `--output` の相対パスは、どちらもカレントディレクトリが基準です。

1 行 1 手順で、`relay` を付けずにサブコマンドをそのまま書きます。
空行と、`#` で始まる行は飛ばします。`#` より前の空白は無視します。行の途中の `#` はコメントではなく文字です。
`--step` は 1 つが 1 手順で、改行を含められません。

語の区切りはシェルに似た最小限のもので、変数展開やグロブはありません。

| 書き方 | 解釈 |
| --- | --- |
| 空白・タブ | 語を区切る |
| `'...'` | 中身をそのまま使う |
| `"..."` | `\"` と `\\` だけを解釈する |
| 引用符の外の `\` | 次の 1 文字をそのまま使う |

最初の手順より前に `# relay-run: 1` と書くと、形式 1 のシナリオであることを示せます。
任意で、書かなければ今の形式として読みます。形式が変わったとき、古いシナリオが黙って違う意味で動かないようにするためのものです。
保存して使い回すシナリオには書いておくことをおすすめします。

`1` 以外の値、値のないもの、最初の手順より後にあるものは、その行のエラーとして何も実行しません。
コメント行の形なので、この行を知らない relay では読み飛ばされます。

#### 使える手順と制約

シナリオでは、ランナーへの操作と `sleep <秒>` を手順にできます。

| 種類 | 使える手順 |
| --- | --- |
| 観察 | `ping`、`health`、`foreground`、`screenshot`、`source`、`find` |
| 操作 | `tap`、`press`、`swipe`、`type`、`key`、`button`、`orientation` |
| アプリ | `launch`、`terminate` |
| 疑似手順 | `sleep <秒>`（0 < 秒 ≤ 60） |

オプションと値の確認は単独のコマンドと同じです。`--json` は何も変えず、`--opt=value` も書けます。

| 使えない手順・指定 | 理由・代わりの指定 |
| --- | --- |
| `start`、`stop`、`status`、`install`、`doctor`、`devices`、`skill`、`bench`、`config`、`run` など | ランナーへの操作ではありません。 |
| `shutdown` | 以降の手順が実行できないため、後片付けには `relay stop` を使います。 |
| 手順の中の `--runner` | 接続先は `relay run` に 1 回だけ指定します。 |
| `--help` | 手順の中では使えません。 |
| `type --stdin` | 標準入力はシナリオのために使います。 |
| `screenshot` の出力先省略と `-o -` | stdout はほかの手順の出力に使うため、`--output <file>` が必須です。 |

#### 検証と実行

`relay run` は、実行前に全手順を確かめ、1 つでも不正なら何も実行しません。
不正な行ごとに `relay: line <N>: <理由>` を stderr に出し、続けて `relay: see relay run --help` を出して終了コード 2 で終わります。
`--step` では何番目かを行番号とします。

`--check` を付けると、検証だけを行って終わります。runner.json を読まず何も実行しないので、ランナーが動いていなくても使えます。
エージェントが書いたシナリオを流す前の確認に使えます。

問題がなければ、stderr に `relay: 7 steps checked; nothing was run` を出して終了コード 0 です。
`--quiet` なら何も出しません。

実行時は、runner.json を最初に 1 回だけ探して読み、同じプロセスの中で手順を順に送ります。
手順ごとに `relay` を起動し直さないので、そのぶん速くなります。
探す順は「[接続先（runner.json）の探し方](sessions.md#接続先runnerjsonの探し方)」と同じです。`--runner` は `relay run` に付けます。

#### シナリオの出力と失敗

各手順の stdout は、単独で実行したときと同じものが順に出ます。`find` の JSON や、`screenshot` の保存先などです。
失敗した手順の JSON（`{"ok":false,"code":…}`）も stdout に出るので、stdout の最後の JSON が失敗の内容です。

stderr には、手順ごとの進行行と最後の結果を出します。

| 種類 | 出力例 |
| --- | --- |
| 進行行 | `relay: [3/7] tap --id com.apple.settings.general --timeout 5 --bundle-id com.apple.Preferences ... ok (448 ms)` |
| 全手順が成功 | `relay: 7 of 7 steps succeeded in 7672 ms` |
| 途中で失敗 | `relay: 3 of 7 steps succeeded in … ms; exit status 6` |

`--quiet`（`-q`）で、この 2 種類（進行行と最後の結果）を消せます。
進行行と失敗行では、`type` の文字列を `***` に伏せます（`relay: [4/9] type *** --key return ... ok`）。
シナリオでは `--stdin` が使えず、パスワードを書くならシナリオに書くしかないためです。ファイル自体は利用者が管理してください。

最初に失敗した手順で止めます。通常のエラーの JSON は stdout に、`relay:` のヒントは stderr に出します。
stderr には、続けて失敗した手順も次の形で出します。

```text
relay: step 4/7 (line 5) failed: find --label About --type button --timeout 5 --require --bundle-id com.apple.Preferences
```

| 結果 | 終了コード |
| --- | --- |
| すべて成功 | 0 |
| 手順の失敗 | その手順の終了コード（3・4・5・6・7・8） |
| スクリーンショットを保存できない | 1 |

失敗しても続ける `--continue-on-error` はありません。

#### 待ちと確認

画面が変わる操作の後は、次の画面の要素が現れるまで待てます。
`find <セレクタ> --timeout <秒>`、または `tap` / `press` の `--timeout` を使います。
要素が現れた時点で次に進むので、固定の `sleep` より速く、遅い環境でも崩れにくくなります。
`sleep` は、要素で表せない待ち（アニメーションの終わりなど）のための最後の手段です。

確認には `find --require` を使います。単独のコマンドと同じく、`find` は一致がなくても成功（`"count":0`）し、シナリオは先に進みます。
`find <セレクタ> --timeout 5 --require` は「現れるまで待ち、現れなければそこで止める」確認になります。終了コードは 6 です。

観察のためだけの `find` で、結果を後で読む場合は `--require` を付けません。

`find --timeout` は要素が現れた時点で進むので、直後の `screenshot` が画面遷移のアニメーションの途中を写すことがあります。
止まった画面がほしいときに限って、`sleep 0.5` などを挟みます。

**スワイプの後は固定の待ちが要ります。** 慣性スクロール中に `tap` すると、タップはスクロールを止めるだけで、要素は押されません。
`tap` は成功するので、次の `find` で止まります。

実機の設定アプリでは、スワイプ後 1 秒ではまだ数 pt 動いていて同じ失敗になり、`sleep 2` で通りました。
スクロールが止まったことは要素では表せないので、ここは `sleep` を使います。

#### AXe との違い

`relay run` は、AXe の `axe batch` と同じく、1 行 1 手順を順に実行し、最初の失敗で止まります。
`--step` の並び・ファイル・標準入力から読めることと、`sleep` の手順があることも同じです。

- 要素を待つのは、AXe の `--wait-timeout` ではなく、手順ごとの `find --timeout` / `tap --timeout` / `press --timeout`（最大 10 秒）です。
- 途中に確認の手順を書けます。`find --timeout <秒> --require` は待ちと確認を兼ね、見つからなければそこで止まります。
- `source` / `screenshot` / `health` / `foreground` などの観察も手順にでき、結果は stdout に出ます。
- 実行の前に全手順を確かめ、不正な行があれば何も実行しません。

#### シナリオの所要時間

`relay run` は、手順ごとに `relay` を呼ぶより起動と runner.json の読み込みの回数を減らせます。
同じ手順を `relay run` と、1 手順ずつ `relay` を呼ぶシェルのループとで比べました。各 3 回の参考値です。
シミュレータは debug ビルドです。

| シナリオ | `relay run` | 1 手順ずつ |
| --- | --- | --- |
| `ping` × 20 | 41–43 ms | 324–332 ms |
| 設定 > 一般 > 情報（`launch`、`tap` × 2、`find` × 2、`health`、`foreground`、`screenshot` の 8 手順） | 1287–1301 ms | 1428–1457 ms |
| 上の例（about.relay の 7 手順、`terminate` と `launch` で約 5.8 秒） | 6818–7027 ms | 7141–7220 ms |
| 実機（iPhone 14 Pro / iOS 26.7.1）: `ping` × 20 | 67–73 ms | 360–370 ms |
| 実機: 設定 > 一般 > 情報（`swipe` と `sleep 2` を含む 10 手順） | 7011–7050 ms | 7455–7513 ms |

差は `relay` の起動と runner.json の読み込み（1 回約 15 ms）だけで、操作そのものの時間は変わりません。
ふつうのシナリオでは数 % です。
主な利点は、エージェントやスクリプトが 1 回の呼び出しで決まった手順を再生でき、途中で止まった位置が行番号でわかることです。

確かめた環境: シミュレータは iPhone 17 Pro / iOS 27.0。実機は iPhone 14 Pro / iOS 26.7.1。

## 録画（relay record）

`relay record` は、ランナーが動いているシミュレータと USB 接続の実機の画面を MP4（H.264）に保存します。

操作の前後を動画で残したいときに、`record start` → 操作 → `record stop` の順で使います。プルリクエストに貼る動作の証拠などに使えます。
どちらもランナーは使わず、ホスト側で録ります。音声は録りません。Wi-Fi だけで接続している端末は録れません。

シミュレータでは `xcrun simctl io <UDID> recordVideo --codec h264 --force <file>` で録ります。
実機の初回準備は「[録画の準備](device.md#録画の準備)」、内部処理は「[録画の実装の背景](development.md#録画の実装の背景)」を参照してください。

```sh
relay record start                    # 保存先の絶対パスを出して戻る（既定は $TMPDIR/relay/relay-recording-<時刻>.mp4）
relay launch host
relay tap --id relay.input --timeout 3
relay type "hello" --key return
relay record stop                     # 書き出しを待ち、MP4 の絶対パスを出す
relay record start -o demo.mp4 --max-duration 120   # カレントディレクトリの demo.mp4 に、最長 120 秒
relay record start -o demo.mp4 --force              # demo.mp4 がすでにあれば上書き（--force なしではエラー）
relay record status [--json]          # 録画中か、保存先、経過時間
relay record stop --port 8101         # runner.json によらず、そのポートのランナーの録画を止める
```

### 録画する端末の確認

`record start` は、runner.json の UDID から録画する端末を決めます。
runner.json は「[接続先（runner.json）の探し方](sessions.md#接続先runnerjsonの探し方)」と同じ順に探します。`--runner` も使えます。

UDID を `simctl list devices` と照らし、シミュレータでなければ `devicectl list devices` の実機と照らします。
実機は `relay devices` の KIND が `device` のものです。

| 状態 | 結果 |
| --- | --- |
| どちらにも UDID がない | 何も起動せず終了コード `1` |
| シミュレータが boot していない | 終了コード `1` |
| runner.json がない・ランナーが応答しない | ランナー操作のコマンドと同じく `3` |
| `401` | `4` |

実機は、`devicectl` で接続中であり、接続方式が USB（`wired`）であることを確かめます。

| 実機の状態 | メッセージと結果 |
| --- | --- |
| Wi-Fi だけ（`localNetwork`） | `… is connected over the network only (localNetwork); recording a device needs a USB cable …` で `1` |
| 接続されていない | `… is not connected …` で `1` |

続けてカメラの許可を確かめ、未決定なら macOS のダイアログで求めます。
拒否・制限されていれば、設定の場所を示して `1` です（「[録画の準備](device.md#録画の準備)」）。

### 録画の開始と待ち時間

`record start` は、録画が実際に始まったら保存先の絶対パスを stdout に 1 行出し、`0` で戻ります。
録画するプロセスは `relay start --background` と同じく新しいセッションとして切り離して起動するので、ターミナルを閉じても、そこで Ctrl-C を押しても録画は続きます。
開始を待っている間の Ctrl-C は録画を止めて `1` です。

| 録画プロセスの入出力 | 接続先 |
| --- | --- |
| stdin | `/dev/null` |
| 出力 | `~/.relay/logs/record-<時刻>-<port>.log` |

シミュレータは、simctl が `Recording started` を出したら開始とみなします。
15 秒以内に出ない場合や、simctl が先に終了した場合は、simctl のログの末尾を添えて `1` で終わり、何も残しません。

実機は、切り離したプロセス `relay record supervise` が最初のフレームを書き込んだ時点で開始とみなします。

| 実機の開始待ち | 時間 |
| --- | --- |
| 端末の画面がキャプチャデバイスとして現れるまで | 最大 10 秒（新しいプロセスでは 0.3〜4.5 秒ほど） |
| 通常の `record start` が戻るまで | ふつう 1.5〜4 秒 |
| 各プロセスで最初のフレームが来るまで | 25 秒以内に来なければ `1` |
| 画面が現れず再試行するとき | `record start` は 20 秒ほど |

画面が 1 つも現れなかったときは、新しいプロセスでもう一度だけ試し、次のメッセージを出します。

```text
relay: the screen of … did not show up; trying once more in a new process
```

それでも現れなければ、見えている画面の名前と、USB で接続する・ロックを解除する・「信頼」する、という対処を示して `1` です。
本当に繋がっていない端末では、ここまで 20 秒ほどかかります。

同じ名前の端末が複数つながっていると区別できないため、`1` です。どちらかの名前を変えるか、外してください。
大文字小文字などを無視して比べ直した結果、複数が一致したときも同じです。
対応付けと再試行の理由は「[実機のキャプチャデバイスと再試行](development.md#実機のキャプチャデバイスと再試行)」を参照してください。

### 動画の保存先と形式

`record start` の `-o` / `--output` で、動画の保存先を指定できます。
指定がなければ `$TMPDIR/relay/relay-recording-<時刻>.mp4` です。スクリーンショットと同じく、対象アプリの作業ツリーを汚さないためです。

相対パスはカレントディレクトリが基準です。そのディレクトリがなければ、relay は作らず `1` です。
同じ名前のファイルがすでにあれば、何も起動せず次のメッセージで `1` です。`--force` を付けたときだけ上書きします。
既定の時刻入りの名前でも、衝突すれば同じ扱いです。

```text
<path> already exists; pass --force to replace it, or give another --output
```

判定は録画を始める前に行います。判定と書き込みの間にファイルが作られた場合は上書きされます。実機も同じです。

実機は H.264 の MP4 に書き出します。`-o` の拡張子が `.mov` のときだけ、同じ H.264 を QuickTime ムービーにします。
実機のフレームレートは画面の更新に合わせた可変です。静止画面でも 40〜60 fps で、フレームの間隔は長くても 0.1 秒ほどです。

キャプチャ中、端末のステータスバーの時刻は iOS が 9:41 に固定して表示します。QuickTime と同じです。

動画は画面の画素数なので、ランナーの座標（ポイント）とは倍率（scale）が違います。

| 端末 | 動画の大きさの例 |
| --- | --- |
| iPhone 14 Pro（実機） | 1180×2556 |
| iPhone 17 Pro（シミュレータ） | 1206×2622 |

実機で録画中に画面が回転したときは、最初の大きさの中に縦横比を保って収めます。

### 録画の状態と自動停止

1 つのランナーで同時に録画できるのは 1 つです。
録画中にもう一度 `record start` すると、`a recording is already running for the runner at … ; stop it with relay record stop …` で `1` です。

状態は `~/.relay/recording-<port>.json` に保存します。ポートは runner.json の URL のものです。
録画プロセスがもう動いていない状態ファイルは、次の `record start` を妨げません。自動停止や強制終了などの場合です。
古い状態ファイルを削除して新しく始め、動画ファイルは残します。

`record status` は、録画中か、保存先、UDID、録画プロセスの PID、開始時刻、ログを出します。
終了コードは録画の有無によらず `0` です。

| 状態 | 表示 |
| --- | --- |
| 録画中 | `recording: yes (12s; stops by itself after 600s)` |
| 自動停止などで終了済み | `ended` |
| 実機のフレームが停止中 | `frames: no frame for 5s (the device may be locked, …)` の行も表示 |

`--json` では、次のキーを持つ JSON オブジェクトを 1 つ出します。録画していなければ `{"recording":false}` です。

| キー | 内容 |
| --- | --- |
| `kind` | `simulator` / `device` |
| `recording`・`output`・`udid`・`port` | 録画中か、保存先、UDID、ポート |
| `pid`・`startedAt`・`elapsedSeconds` | 録画プロセスの PID、開始時刻、経過時間 |
| `maxDuration`・`log`・`state` | 自動停止までの時間、ログ、状態 |
| `stall` | フレームが止まっている間に追加 |

`--max-duration <秒>`（既定 600 秒）で録画を自動停止します。止め忘れてディスクを使い続けないためです。
時間は録画プロセスの開始から数えるので、実機では最初のフレームまでの 1 秒ほど動画が短くなります。

自動停止した後も状態ファイルは残ります。`record stop` で、`relay: the recording had already ended (reached --max-duration of …)` を stderr に、保存先を stdout に出します。

### 録画の停止とポートの選択

`record stop` は、録画プロセスに SIGINT を送り、MP4 の書き出しを待って保存先の絶対パスを stdout に出します。
ファイルが存在して空でないことを確かめ、`0` で終わり、状態ファイルを削除します。

| 停止時の状態 | 結果 |
| --- | --- |
| 録画していない | `not recording` で `0`（`relay stop` と同じ考え方） |
| 30 秒以内に終了しない | 状態ファイルを残して `1`、再度 `record stop` が可能 |
| 動画が空・ない | `1` |

実機では、書き出し後にキャプチャを止めてから 3.5 秒待って終わるので、`record stop` は 4 秒ほどかかります。
直後の `record start` が画面を見つけられるようにするためです。

`--runner` か `$RELAY_RUNNER` で指定した runner.json がなければ、ほかのコマンドと同じく `--runner … does not exist; is relay start running?` で `3` です。

runner.json がなくなった後でも、`--runner` も `$RELAY_RUNNER` もなければ、`~/.relay` に状態ファイルが 1 つだけならそれを止めます。
ランナーが止まった後も使えます。複数あるときは、ポートごとに保存先と録画中か（`recording` / `ended`）を一覧にして `choose one with --port <n>` で `1` です。

`record stop` と `record status` は、`--port <n>` を付けると runner.json を探さず、そのポートの状態ファイル `~/.relay/recording-<n>.json` を直接使います。
runner.json がなくても、複数のランナーを別のポートで動かしていても使えます。

そのポートに録画がなければ `not recording` で `0` です。

`--runner` と同時には指定できません。書き方の誤りとして `2` です。

### ランナー停止時と録画中の切断

`relay stop` は、ランナーを止める前に、そのランナーの runner.json のポートの録画を止めて書き出します。
`relay: saved the recording: <path>` を stderr に出し、stdout は `stopped` / `not running` です。

`relay start` も、Ctrl-C や SIGTERM で終わるときは、boot したシミュレータを shutdown する前に自分のポートの録画を書き出します。実機でも同じです。

シミュレータが先に shutdown されても、simctl は録画を続け、自動停止までは終わりません。

`record stop` は通常どおり SIGINT を送り、shutdown した時点までの動画を書き出して保存先を出します。
stderr には `relay: the simulator … is no longer booted; the video ends where it shut down` を添えます。

実機が録画中に外されると、録画プロセスはそれまでの動画を書き出して終わります。
`record stop` は、`relay: the recording had already ended (the device was disconnected; …)` を stderr に添えて保存先を出します。

### 実機のフレームが止まったとき

録画中に実機がロックされたりキャプチャが止まったりしても、録画は止めません。
最後のフレームから 5 秒フレームが来なければ、録画のログに次を 1 回書きます。

```text
relay: no frame for 5s (the device may be locked, or the capture stalled); still recording, …
```

また来始めたら、`relay: frames came again after <n>s without one` を書きます。
その間、動画は最後のフレームのまま止まり、来始めたところから続きます。
止まっている間は `record status` の `frames:` の行で分かります。`--json` では `stall` です。

ロックを解除すればふつうは再開します。再開しなければ `record stop` し、ロックを解除してから録画し直してください。

## エージェントスキル

`skills/device-relay/` は、コーディングエージェントが対象アプリのリポジトリで作業しながら、relay でアプリの動作を確かめるためのスキルです。
Claude Code などで使います。

### スキルの構成

`SKILL.md` は、基本の流れと操作のコツ、事故を防ぐ決まり、よく出る終了コードと `code` の対処だけを説明します。
使うたびに全文が読み込まれるので、8 KB 以内に保ちます。必要になったときに読む `references/` のファイルも示します。

基本の流れは、`relay status` → `relay start --background` → `relay launch` → スクリーンショットと要素の観察 → 操作 → 確認 → `relay stop` です。
事故を防ぐ決まりには、動いているランナーを止めない、対象アプリの外に出ない、パスワードを勝手に入力しない、などがあります。

詳細は `references/` に話題ごとのファイルとして置きます。それぞれ 8 KB 程度までで、単独で読める形です。
オプション、終了コードと `code` の全一覧、並列実行、録画、`relay run`、トラブルシューティングを扱います。
エージェントが調べるたびに、必要な 1 つだけを読めば済むようにします。

`reference.md` はその索引です。以前の版や入れたままのコピーから参照されるので残します。

### スキルのインストールと削除

`relay skill install` は、展開したリリースやチェックアウトの `skills/device-relay` から、対象アプリのリポジトリなどへスキルを入れます。
使う前に relay をインストールし、`relay doctor` で確認してください（「[インストール](../README.ja.md#インストール)」）。

展開したリリースもチェックアウトも見つからない場合は、`relay install` がコピーした `~/.relay/runner/skills/device-relay` を使います。
`relay` のバイナリだけをコピーした場合が該当します。

```sh
cd /path/to/app
relay skill install            # <git のルート>/.claude/skills/device-relay にコピー（チームでコミットできる）
relay skill install --global   # ~/.claude/skills/device-relay（どのリポジトリでも使う）
relay skill install --dir <skills dir>   # <skills dir>/device-relay
relay skill status             # 取り出し元と、プロジェクト・グローバルのインストール先、バージョンのずれ（!）
relay skill uninstall          # relay が入れたものだけを削除（--global / --dir も同じ）
```

既定の入れ先は、カレントディレクトリの git のルートの `.claude/skills/device-relay` です。git の外ならカレントディレクトリを使います。
コピーなので、そのままコミットしてチームで共有できます。

どのコマンドも、入れ先や削除先のパスを必ず表示します。
表示・比較するパスは、存在する部分のシンボリックリンクを解決した形にそろえます。macOS では `/private/tmp/...` も `/tmp/...` になります。

取り出し元は、`relay install` と同じ探し方で見つけた、展開したリリースか device-relay のチェックアウトの `skills/device-relay` です。
`$RELAY_HOME`、カレントディレクトリとその親、`relay` の実行ファイルの場所から探します。

なければ、`relay install` した `~/.relay/runner/skills/device-relay` を使います。`--link` でも同じ順です。

コピーには、SKILL.md を変えずに隠しファイル `.relay-skill.json` を置きます。
relay のバージョン、コミット、取り出し元、日時を記録します。

この記録があるもの、または relay のスキルを指すリンクは、relay が入れたものとみなし、再実行で上書き更新します。
それ以外のものが入れ先にあれば、`--force` なしでは上書きしません。
`uninstall` は relay が入れたものだけを削除し、それ以外は残してエラーにします。

`--link` は、コピーの代わりにシンボリックリンクを作ります。
スキルを編集する開発用で、チェックアウトの変更がそのまま反映されます。
リンクはこの Mac の絶対パスを指すので、コミットして共有するには向きません。

### スキルの状態と更新

`relay skill status` は、記録や取り出し元とバージョンが違う場合に ! を付けます。

| ! が付く条件 | 比較するもの |
| --- | --- |
| 記録したバージョンと `relay` のバージョンが違う | コピーの記録と実行中の CLI |
| 取り出し元とバージョンかコミットが違う | コピーと取り出し元（`differs from the source …`） |

取り出し元のほうが古いこともあるので、どちらが新しいかは示しません。
`source` の行の `from …` は、取り出し元の種類です。

| 種類 | 取り出し元 |
| --- | --- |
| `checkout` | `.git` がある git のチェックアウト |
| `release` | `.git` のない展開したリリース |
| `relay install` | `~/.relay/runner` のコピー |

relay を更新したら、`relay skill install` をやり直してください。`--global` などで入れたなら同じオプションを使います。
バイナリだけをコピーして `relay install` のコピーから取り出している場合は、先に展開したディレクトリ、またはチェックアウトで `relay install` を実行します。

### スキルが使うランナーと端末

スキルは、`relay status` が 0 なら動いているランナーを使い、止めません。
自分で `relay start --background` したときだけ、終わりに `relay stop` します。
実機を指定されない限り、`relay devices` で選んだシミュレータを `--device` / `--udid` で明示します。
