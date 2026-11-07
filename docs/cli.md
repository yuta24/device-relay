# CLI

`relay` のサブコマンドでランナーを操作する方法、シナリオの実行（実験的）、エージェントスキルについて説明します。全体の入口は [README](../README.ja.md) です。

## 0.3.0 の破壊的な変更（0.2.0 から）

0.3.0 で CLI の約束事をそろえました。0.2.0 のコマンドラインを使っているスクリプトやエージェントのスキルは、次の点を直してください。

- **終了コード `2` を追加**: 書き方の誤り（不明なオプション、値の不足・不正、両立しないオプション、不正なセッション名、`RELAY_RUNNER` と `RELAY_SESSION` の両方の設定、`relay run` の不正な手順）は `2` になりました。`1` はローカルの失敗（端末が使用中、ビルドの失敗、ファイルがない、`relay start --background` の「すでに動いている」など）だけです。
- **失敗の JSON は stdout**: ランナー操作のコマンドで、失敗時のランナーの JSON を stderr ではなく stdout に出します。`2>&1` を付けて stderr の JSON を読んでいたなら、stdout を読んでください。runner.json がない・接続できない（`3`）などの relay 側の失敗も `{"ok":false,"code":"runner_unavailable","error":"…"}` で stdout に出ます。`launch` の `app_not_installed` と `find --require` の一致なしも stdout です。例外は `screenshot -o -`（stdout が画像なので、失敗の JSON は stderr）。
- **書き方の誤りは 2 行だけ**: 使い方の全文は出さず、`relay: <誤り>` と `relay: see relay <command> --help` の 2 行を stderr に出します。
- **`--json` を受け付ける**（ランナー操作のコマンド。出力は常に JSON なので何も変えません）。`status --json`・`record status --json`・`devices --json` は、失敗でも JSON を stdout に出し、stderr に同じ文を重ねません。
- **`--opt=value`** がすべてのサブコマンドで書けます。
- **カレントディレクトリの `.relay/runner.json` を読みません**: 探す順は `--runner` / `--session`、`RELAY_RUNNER` / `RELAY_SESSION`、`~/.relay/runner.json` だけになりました。今の `relay start` は `~/.relay/` にしか書かないので、そこで見つかるのは古いファイルか手で置いたファイルだけで、401（終了コード 4）の原因になっていました。手で置いたファイルは `--runner <path>` で使います。`~/.relay/runner.json` がなく、カレントディレクトリか親に `.relay/runner.json` があるときは、探さずに、エラーに `.relay/runner.json in <dir> is no longer read; pass --runner <path> to use it` を足して知らせます（終了コードは `3`）。
- **`relay shutdown` を一覧から外しました**: `relay --help` の一覧と SKILL.md には載りません。コマンドは今までどおり動き、`relay shutdown --help` に「通常は `relay stop`」と違いが書いてあります（ランナーだけを止めて即座に戻り、後始末は `relay start` が後から行う）。止めるときは `relay stop` を使ってください。
- **`relay bench` はランナーを他のコマンドと同じ探し方で見つけます**: `--url` も `--session` も要らなくなり（付けなかったときの書き方の誤りがなくなった）、`--runner` も受け付けます。`--url` と `--token` は runner.json の URL とトークンを上書きする任意のオプションで、`--url` だけならトークンは runner.json のものです。ランナーが見つからなければ終了コード `3` です（`--url` だけでトークンを読めないときは、以前は `1` でした）。`--runner` と `--session` の併用は書き方の誤り（`2`）です。
- **`relay doctor --json`（追加）**: 人向けの行の代わりに、1 つの JSON オブジェクトを stdout に出します。終了コードは変わりません（✗ があれば `1`）。形は「[relay doctor --json](setup.md#relay-doctor---json)」。
- **`relay doctor` は、ほかの `relay start` が使用中の端末を考慮します**: 自動選択は使用中の端末を外し（`relay start` と同じ）、Devices に `in use` の行が出ます（`--json` の checks にも入ります）。`--udid` / `--device` で指定した端末が使用中なら target が ✗ で、終了コードは `1` です。
- **`relay devices --json` は 1 行になりました**: 整形（改行・字下げ）していたのを、ほかの `--json` と同じ 1 行・キー順にそろえました。JSON として読むなら変わりません。`jq` や `JSON.parse` なら影響はなく、行単位で読んでいたなら直してください。
- **`--help` の行は 100 文字以内**に折り返しました（内容は、上の変更と `ping`・`health`・`status` の使い分けの追記を除いて同じです）。

## CLI から操作する

`relay` には、エンドポイントを 1 つずつ呼ぶサブコマンドがあります。ランナーは `relay start --background`（または別のターミナルの `relay start`）で起動しておき、使い終わったら `relay stop` で止めます。トークンを自分で扱わずに、人もスクリプトもエージェントも同じ形で操作できます。`relay <command> --help` で各コマンドの使い方を表示します。

```sh
relay start --background                       # ready: <URL> が出たら戻る（「[バックグラウンドで動かす](setup.md#バックグラウンドで動かすrelay-start---background--status--stop)」）
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

（インストールした `relay` をどのディレクトリからでも使えます。リポジトリ内では `xcrun swift run relay …` でも動きます。）

| コマンド | エンドポイント | 主なオプション |
| --- | --- | --- |
| `ping` / `health` / `foreground` | `GET /ping` / `/health` / `/foreground` | – |
| `screenshot` | `GET /screenshot` | `-o <file>`（`-` で stdout）、`--format png\|jpeg`、`--quality 0.05–1.0`、`--max-size <px>`、`--scale <px/pt>` |
| `source` | `GET /source` | `--format json\|text\|compact`、`--filter interactive`、`--max-depth <n>`、`--bundle-id <id>` |
| `find` | `POST /find` | セレクタ、`--limit <n>`、`--timeout <s>`、`--require`、`--bundle-id <id>` |
| `tap` / `press` | `POST /tap` / `/press` | `<x> <y>` かセレクタ、`--mode private\|xcui`、`--timeout`・`--bundle-id`（セレクタのみ）、`--duration`（press のみ） |
| `swipe` | `POST /swipe` | `<x1> <y1> <x2> <y2>`、`--duration`、`--hold`、`--mode` |
| `type` | `POST /type` | `<text>` か `--stdin`、`--key <name>`（複数可、順に送る）、`--bundle-id` |
| `key` / `button` / `orientation` | `POST /key` / `/button` / `/orientation` | 名前（`key` は `--bundle-id` も可。`orientation` は `landscape` を `landscapeLeft` として送る） |
| `launch` / `terminate` | `POST /launch` / `/terminate` | `<bundle-id>`（`host` も可） |
| `shutdown` | `POST /shutdown`。一覧には載せません。普段は `relay stop` を使います（下の「`shutdown` と `stop`」） | – |
| `status` | `GET /ping` と runner.json（ランナーの版も表示） | `--json`、`--all`（全セッションの一覧）。終了コードは「[バックグラウンドで動かす](setup.md#バックグラウンドで動かすrelay-start---background--status--stop)」 |
| `stop` | `relay start` への SIGTERM（なければ `POST /shutdown`） | – |
| `run`（実験的） | 手順ごとに上のエンドポイント | `<file>` か `-` か `--step <手順>`（複数可）、`--runner`、`--session`、`--quiet`。「シナリオの実行（relay run、実験的）」 |
| `record start` / `stop` / `status` | –（シミュレータはホストの `simctl io recordVideo`、実機は Mac のキャプチャデバイス） | `-o <file>`、`--force`、`--max-duration <s>`（start）、`--json`（status）、`--port <n>`（stop・status）、`--runner`、`--session`。「録画（relay record）」 |

- **`shutdown` と `stop`**: 普段は `relay stop` を使います。`relay shutdown` はランナーに `POST /shutdown` を送るだけで、`{"ok":true}` を返してすぐ終わります。ランナーが終わったのを見た `relay start` が、その後で runner.json を削除し、boot したシミュレータを shutdown し、終了します（シミュレータで数秒かかり、いつ終わったかは `shutdown` からは分かりません）。`relay stop` は `relay start` に SIGTERM を送ってその終了まで待ち、`stopped` を出します。`relay start` がもう動いていないときに `shutdown` を使うと runner.json が残りますが、`relay stop` は片付けます。このため `relay --help` の一覧と SKILL.md には `shutdown` を載せていません（コマンドと `relay shutdown --help` は残してあります）。
- **`ping`・`health`・`status` の使い分け**: `ping` は「生きているか、操作中（`busy`）か」の即答で、ほかのコマンドの実行中でも返り、端末には触れません。`health` は操作の前に要る情報（画面サイズ（pt）・向き・タッチの経路・前面アプリ）を返しますが、ほかのコマンドの実行中は `409`（終了コード 5）になります。`status` は runner.json と `relay start`（pid・端末・起動時刻・ランナーの版）も見る確認で、`relay start --background` の後や、機械向けには `--json` で使います。
- バンドル ID の代わりに `host` と書くと、ランナーのホストアプリ RelayRunnerHost のバンドル ID になります（`launch`・`terminate` と、`--bundle-id` を取るコマンド）。バンドル ID は利用者ごとに違う（「[バンドル ID の接頭辞](setup.md#バンドル-id-の接頭辞)」）ので、relay は `relay start` がビルドしたアプリの ID を runner.json の `hostBundleID` に書き、そこから置き換えます。`relay status` の `host app` にも出ます。古い relay の `relay start` が書いた runner.json にはないので、`host` は終了コード 1（`runner_info_invalid`）になります（ランナーを起動し直します）。
- セレクタは `--id`（= `identifier`）・`--label`・`--type`・`--value` を 1 つ以上と、任意の `--index <n>` です（「[要素セレクタ](elements.md#要素セレクタ)」と同じ完全一致・AND）。`--type` の名前、キー名、ボタン名、向きの名前、数値の範囲は送る前に確認し、間違っていれば終了コード 2 で何も送りません。
- `relay find` は一致がなくても終了コード 0（`"count":0`）です。`--require` を付けると、一致する要素がないときに終了コード 6 で終わり、応答（`count`・`elements`）に `"ok":false,"code":"element_not_found","error":"no element matched"` を足した JSON を stdout に出します（`--index` が範囲外のときも同じ）。`relay find <セレクタ> --timeout 5 --require` は「現れるまで待ち、現れなければ失敗する」確認になり、スクリプトは JSON を読まずに終了コードだけで判断できます。判定はホスト側で行い、ランナーへのリクエストは変わりません。
- `-` で始まる文字列を入力するときは `relay type -- --text` のように `--` を挟みます。
- パスワードなど、`ps` やシェルの履歴に残したくない文字列は `relay type --stdin` で標準入力から渡します。末尾の改行 1 つ（`\n` か `\r\n`。`echo` が付けるもの）だけを除き、それ以外はそのまま入力します。`--key` と併用でき、`<text>` と同時に指定すると終了コード 2 で何も送りません。標準入力が UTF-8 のテキストでなければ、ローカルの失敗として終了コード 1 です。標準入力が空でも `--key` があればキーだけを送ります。
- 成功時はランナーの JSON をそのまま stdout に出します（`source --format text` / `compact` はテキスト）。`screenshot` だけは画像をファイルに保存し、その絶対パスを 1 行出します。既定の保存先を `$TMPDIR` にしたのは、操作する側（対象アプリのリポジトリ）の作業ツリーを汚さないためです。`--max-size` / `--scale` で縮小したときは、stdout は同じくパス 1 行のままで、stderr に `relay: image 471x1024 px, screen 402x874 pt, 1.172 px/pt (tap in points: px / 1.172)` のように画像と画面の大きさを出します（「[スクリーンショットの縮小](screen.md#スクリーンショットの縮小)」）。
- ランナーの応答を待つのは、30 秒に、その操作でランナーが待ちうる時間を足した長さです: `find` / `tap` / `press` の `--timeout`、`press` の `--duration`（既定 1 秒）、`swipe` の `--duration` と `--hold`、`launch` / `terminate` は 120 秒（アプリが起動・終了するまで XCTest が待つ時間。ランナーは 60 秒に戻しますが、戻せないランナーでは 120 秒のままです。「[既知の制約](limitations.md)」）、`type` は 1 文字（Unicode スカラー）0.1 秒とキー 1 つ 1 秒（シミュレータで測った約 15 ms/文字の数倍）、`key` は 1 秒。`relay run` の手順も同じです。時間内に応答がなければ `no response within <秒>s` で `3` になりますが、ランナーはその操作を続けていて終わるまで busy（`409`）なので、`relay ping` の `busy` が `false` になってから続けてください。`launch` の時間切れの後は、数分待つことがあります（入っていないアプリでは、ランナーが応答するまで全体で約 300 秒でした）。XCTest の待ちは中断できませんが、busy の間も `relay stop` は効くので、自分で起動したランナーなら `relay stop` → `relay start` のほうが早く戻せます（シミュレータで停止 11 秒、起動 13 秒）。
- `relay launch` と `relay run` の `launch` は、送る前にアプリが端末に入っているかを `simctl` / `devicectl` で確かめ、入っていなければランナーに送らず、すぐに終了コード 6 で終わります。stdout に `{"code":"app_not_installed","error":"<id> is not installed on <端末>","ok":false}` を、stderr に `relay: <id> is not installed on <端末>; …` を出します。ランナーは busy になりません。
  - **確かめ方**: シミュレータは `simctl get_app_container`（約 0.3 秒）、実機は `devicectl device info apps --include-all-apps --bundle-id <id>`。`--include-all-apps` がないと開発者のアプリだけが対象で、Safari も見つかりません。`host` はランナーのホストアプリなので確かめません。`relay run` では、入っていると分かったアプリを同じ実行の中で再度確かめません。
  - **確かめられないとき**: ツールが失敗した、シミュレータが起動していない、時間内（`simctl` 5 秒、`devicectl` 10 秒）に答えがない、といった場合は、`relay: cannot tell whether <id> is installed (…)` を出してこれまでどおりランナーに送ります。入っているアプリを断らないためです。
  - **システムのアプリ**: シミュレータでは `simctl` が返すので同じように確かめます。実機では、一覧に載らないものがありうるので `com.apple.` で始まる ID を確かめずに送ります。
  - **対象外**: `terminate` と `--bundle-id` は確かめません。入っていないアプリでもすぐ返るからです（`terminate` は成功、`find` などは `xcui_failed`）。
- **出力の規則**: ランナー操作のコマンドの出力は常に JSON です（`--json` は受け付けますが何も変えません。ほかのツール向けに書いたコマンドラインをそのまま通すためです）。**JSON を出すコマンドは、成功でも失敗でも JSON を stdout に 1 つ出し**、`relay:` で始まる人向けの行（ヒント・警告）は stderr に出します。失敗時は、ランナーの JSON をそのまま stdout に出し、relay 側で起きた失敗（runner.json がない、接続できない、アプリが入っていない、保存できないなど）も同じ形 `{"ok":false,"code":"<snake_case>","error":"…"}` で stdout に出します。ステータスごとの終了コードは次のとおりです。
  - 例外 1: `relay screenshot` の成功時は JSON ではなく保存先のパス 1 行です。`-o -` のときは stdout が画像そのものなので、失敗時の JSON は stderr に出します。
  - 例外 2: 書き方の誤り（終了コード 2）は JSON にしません。stderr に `relay: <誤りの内容>` と `relay: see relay <command> --help`（そのコマンドに `--help` がなければ `relay --help`）の 2 行だけを出し、stdout には何も出しません。使い方の全文は出しません。
- **JSON の書式**: relay が自分で出す JSON（`status --json`・`status --all --json`・`record status --json`・`devices --json`・`doctor --json`、relay 側の失敗、`find --require` の一致なし）は、すべて **1 行・キーを辞書順・`/` をエスケープしない** 形です（ランナーが返した JSON はそのまま出すので、ランナーの書式です）。
- **`--opt=value`**: すべてのサブコマンドで、値を取るオプションは `--port=8101` のように書けます（`--port 8101` と同じ）。最初の `=` で分け、`--` で始まる引数だけが対象です（`-o=file` や `a=b` のような位置引数は分けません）。値を取らないフラグに `=` を付ける（`--json=true`）と書き方の誤りです。`--` より後ろは分けないので、`relay type -- --x=y` は `--x=y` という文字列を入力します。`--` を挟まない `relay type --x=y` は、以前と同じく不明なオプションです。`relay run` の手順の中も同じです。

| 終了コード | 意味 |
| --- | --- |
| `0` | 成功（2xx） |
| `1` | ローカルの失敗: runner.json が読めない、スクリーンショットを保存できない、端末が使用中・ビルドの失敗・シミュレータがない・ファイルがない、`relay start --background` で「すでに動いている」「ポートを握られている」、`relay doctor` が問題を見つけた、など |
| `2` | 書き方の誤り: 不明なオプション、値の不足・不正、両立しないオプション、不正なセッション名、`RELAY_RUNNER` と `RELAY_SESSION` の両方の設定、`relay run` の不正な手順（何も実行しない）など |
| `3` | ランナーに届かない（runner.json がない、接続できない・タイムアウト、接続が OS に拒否された）。`relay status` で確認し、動いていなければ `relay start --background` で起動してください。`the OS refused the connection (Operation not permitted)` と出たら、ランナーではなく relay の側がエージェントなどの sandbox の中にいて localhost に接続できません（「[エージェントの sandbox から使う](setup.md#エージェントの-sandbox-から使う)」）。起動し直しても直りません |
| `4` | `401`。runner.json のトークンが動いているランナーのものではない（古いファイル、別のランナー） |
| `5` | `409`（busy）。再試行してよい |
| `6` | `422`。XCUI で失敗（フォーカスがない、要素が見つからない・1 つに決まらないなど）。`relay launch` でアプリが入っていないとき（`app_not_installed`。relay 自身の判定で、ランナーには送りません） |
| `7` | `400` とその他の 4xx |
| `8` | 5xx などそれ以外 |

失敗の JSON には、機械向けの `code` が入ります。ランナーの `code`（`no_keyboard_focus`、`element_ambiguous` など。一覧は「[エラーの形式と code](http-api.md#エラーの形式と-code)」）のほかに、relay 自身が出す次の `code` があります（ランナーは返しません。名前は変えません）。

| `code` | 終了コード | 意味 |
| --- | --- | --- |
| `runner_unavailable` | `3` | runner.json がない、接続できない、接続が OS に拒否された |
| `runner_timeout` | `3` | 時間内に応答がない（ランナーは操作を続けていて、終わるまで busy） |
| `runner_info_invalid` | `1` | runner.json が読めない、url が不正、`host` を解決できない |
| `runner_bad_response` | ランナーのステータスによる（`8` など） | ランナーが JSON でない本文のエラーを返した（古いランナー、別のサーバー）。`status` に HTTP ステータスが入ります |
| `screenshot_save_failed` | `1` | 画像を受け取ったが、ファイルに保存できない |
| `app_not_installed` | `6` | `launch` で、アプリが端末に入っていない（ランナーには送らない） |
| `element_not_found` | `6` | `find --require` で一致なし（ランナーの `code` と同じ。`count`・`elements` も付く） |

`relay status --json` の失敗は `alive:false` を足した同じ形、`relay record status --json` の失敗は `runner_unavailable` か `recording_unavailable`、`relay devices --json` の失敗は `devices_unavailable`（終了コード 1）の `{"ok":false,"code":…,"error":…}` を stdout に 1 つ出します（stderr に同じ文は出しません）。

終了コードは（ランナーに送らない `app_not_installed` を除いて）ステータスだけで決まり、同じ終了コードの中の区別（たとえば `6` のうちフォーカスがないのか、要素が 1 つに決まらないのか）は `code` で行います。`relay:` のヒントは、`401`・`409` のほかに、次の code で出します。code を返さない古いランナーでは、`401`・`409` のヒントだけが出ます。

| `code` | `relay:` のヒント |
| --- | --- |
| `no_keyboard_focus` | 入力欄を先にタップしてから送り直す |
| `element_not_found` | `relay find --type …` / `relay source` で画面を確かめるか、`--timeout <秒>` で待つ |
| `element_ambiguous` | `--type`・`--label`・`--id` を足すか、候補から `--index <n>` で選ぶ |
| `touch_mode_unavailable` | `--mode` を外すか、エラーが示す経路で送り直す |
| `not_found` | ランナーが relay より古いかもしれない（`relay start --rebuild` でビルドし直す） |

### 接続先（runner.json）の探し方

URL とトークンは `runner.json` から読みます。トークンはコマンドライン引数では受け取りません（`ps` やシェルの履歴に残るため）。次の順に探し、最初に見つかったものを使います。

1. `--runner <path>` か `--session <名前>`（両方は指定できません）
2. 環境変数 `RELAY_RUNNER`（runner.json のパス）か `RELAY_SESSION`（セッション名）。両方が設定されていると、どちらを指すのか決められないので書き方の誤り（終了コード 2）です
3. `~/.relay/runner.json`（セッションなしの `relay start` が書くファイル）

オプションは環境変数より優先するので、`RELAY_SESSION` が設定された環境でも `--runner` で別のファイルを指定できます。セッションの runner.json は `~/.relay/sessions/<名前>/runner.json` です。

1 と 2 で指定したファイルやセッションがなければ、3 や他のセッションに進まずに終了コード 3 で終わります（意図しない別の端末を操作しないため）。不正なセッション名は終了コード 2 です。`relay status`・`relay stop`・`relay record`・`relay run`・`relay bench` も同じ順に探します（`relay bench` は `--url` と `--token` を省いた分を、見つけたファイルから読みます）。

**カレントディレクトリや親の `.relay/runner.json` は読みません。** 以前の版は 3 番目に探していましたが、今の `relay start` はそこへ書かないので、見つかるのは古いファイルか手で置いたものだけで、別のランナーのトークンによる 401 の原因になっていました。そうしたファイルを使うなら `--runner <path>` で指定します。3 のファイルがなく、カレントディレクトリか親（近い順）に `.relay/runner.json` があるときだけ、探さずにエラーの文へ `.relay/runner.json in <ディレクトリ> is no longer read; pass --runner <path> to use it` を足します（案内のためだけに親をたどります。ファイルは開きません）。

3 で見つけたファイルを使うとき、ほかにセッションが動いていれば（`~/.relay/sessions/*/runner.json` があるか、`session.lock` が握られていれば）、`relay: warning: no session selected; using <パス>, while sessions <名前> are running; pass --session or set RELAY_SESSION` を stderr に出します。エージェントのコマンドがセッションの指定を失って、別のランナーを操作している恐れがあるためです。失敗にはせず、終了コードも変えません。ランナーには問い合わせません。

使い方は「[複数のセッションを並列に動かす](setup.md#複数のセッションを並列に動かすrelay-start---session)」を参照してください。

`relay start` は、どのディレクトリで実行しても、セッションがなければ `~/.relay/runner.json`（パーミッション 0600）だけに書き出します。カレントディレクトリ（対象アプリのリポジトリなど）には `.relay/` を作りません。停止時には、まだ自分のトークンが書かれている場合だけ削除します（`relay stop` が片付けるときも同じです）。複数の `relay start` を同時に動かすこと（`--port` を分けて）はできますが、`~/.relay/runner.json` は最後に起動したものになり、前のランナーには `relay health` などのコマンドが届かなくなります（前のランナーのトークンはファイルに残りません）。同時に動かすならセッションを使ってください。

### シナリオの実行（relay run、実験的）

> **実験的な機能です。** 手順の書き方、出力、終了コードの扱いは今後変わることがあります。

`relay run` は、ランナー操作のコマンドを 1 行 1 手順で並べたもの（シナリオ）を、1 回の呼び出しで順に実行します。ログインのような決まった手順や、エージェントが一度探索して確かめた手順を再生するためのものです。

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

（「情報」の identifier は iOS のバージョンで違うので、ラベルと型で指定しています。「一般」が画面外にある端末では、`tap` の前に `swipe` と `sleep 2` が要ります（下の「スワイプの後は固定の待ちが要ります」）。）

- **入力**は `<file>`、`-`（標準入力）、`--step <手順>`（複数可）のどれか 1 つです。2 つ以上や、どれもないときは書き方の誤り（終了コード 2）です。ファイルが読めない、標準入力が UTF-8 でない、はローカルの失敗（終了コード 1）です。ファイルと標準入力は UTF-8 で、先頭の BOM（U+FEFF）は取り除き、CRLF の改行も読めます。ファイルの相対パスと、手順の中の `--output` の相対パスは、どちらもカレントディレクトリが基準です。
- **1 行 1 手順**で、`relay` を付けずにサブコマンドをそのまま書きます。空行と、`#` で始まる行（前の空白は無視）は飛ばします。行の途中の `#` はコメントではなく文字です。`--step` は 1 つが 1 手順で、改行を含められません。
- **語の区切り**はシェルに似た最小限のものです。空白とタブで区切り、`'...'` は中身をそのまま、`"..."` は `\"` と `\\` だけを解釈し、引用符の外の `\` は次の 1 文字をそのまま使います。変数展開やグロブはありません。
- **使える手順**: `ping` `health` `foreground` `screenshot` `source` `find` `tap` `press` `swipe` `type` `key` `button` `orientation` `launch` `terminate` と、疑似手順の `sleep <秒>`（0 < 秒 ≤ 60）。オプションと値の確認は単独のコマンドと同じで、`--json`（何も変えません）と `--opt=value` も書けます。
- **使えない手順**: `start` `stop` `status` `install` `doctor` `devices` `skill` `bench` `config` `run` など、ランナーへの操作でないものと、`shutdown`（以降の手順が実行できないため。後片付けは `relay stop`）。手順の中の `--runner`（接続先は `relay run` に 1 回だけ指定）、`--help`、`type --stdin`（標準入力はシナリオのもの）も使えません。`screenshot` は `--output <file>` が必須です（stdout はほかの手順の出力に使うので、`-o -` も不可）。
- **形式の版**: 最初の手順より前に `# relay-run: 1` と書くと、そのシナリオが形式 1 で書かれたことを示せます（任意。書かなければ今の形式として読みます）。形式が変わったとき、古いシナリオが黙って違う意味で動かないようにするためのものです。`1` 以外の値、値のないもの、最初の手順より後にあるものは、その行のエラーとして何も実行しません。コメント行の形なので、この行を知らない relay では読み飛ばされます。保存して使い回すシナリオには書いておくことをおすすめします。
- **事前検証**: 実行の前に全手順を確かめ、1 つでも不正なら何も実行せずに、不正な行ごとに `relay: line <N>: <理由>` を stderr に出し、続けて `relay: see relay run --help` を出して終了コード 2 で終わります（`--step` では何番目かを行番号とします）。`--check` を付けると、この検証だけを行って終わります。runner.json を読まず何も実行しないので、ランナーが動いていなくても使えます。問題がなければ stderr に `relay: 7 steps checked; nothing was run` を出して終了コード 0（`--quiet` なら何も出しません）。エージェントが書いたシナリオを流す前の確認に使えます。
- **実行**: runner.json は最初に 1 回だけ探して読み（「接続先（runner.json）の探し方」と同じ順。`--runner` は `relay run` に付けます）、手順は同じプロセスの中で順に送ります。手順ごとに `relay` を起動し直さないので、そのぶん速くなります。
- **出力**: 各手順の stdout（`find` の JSON、`screenshot` の保存先など）は、単独で実行したときと同じものが stdout にそのまま順に出ます。失敗した手順の JSON（`{"ok":false,"code":…}`）も同じ規則で stdout に出るので、stdout の最後の JSON が失敗の内容です。stderr には手順ごとに `relay: [3/7] tap --id com.apple.settings.general --timeout 5 --bundle-id com.apple.Preferences ... ok (448 ms)` を、最後に `relay: 7 of 7 steps succeeded in 7672 ms` を出します（失敗したときは `relay: 3 of 7 steps succeeded in … ms; exit status 6`）。`--quiet`（`-q`）でこの 2 種類を消せます。進行行と失敗行では、`type` の文字列を `***` に伏せます（`relay: [4/9] type *** --key return ... ok`）。シナリオでは `--stdin` が使えず、パスワードを書くならシナリオに書くしかないためです。ファイル自体は利用者が管理してください。
- **失敗**: 最初に失敗した手順で止めます。その手順の通常のエラーの JSON は stdout に、`relay:` のヒントは stderr に出て、stderr にはそれに続いて `relay: step 4/7 (line 5) failed: find --label About --type button --timeout 5 --require --bundle-id com.apple.Preferences` を出し、その手順の終了コード（3・4・5・6・7・8、スクリーンショットを保存できなければ 1）で終わります。すべて成功すれば 0 です。失敗しても続ける `--continue-on-error` はありません。
- **待ちは `find --timeout` / `--timeout` で。** 画面が変わる操作の後は、次の画面の要素を `find <セレクタ> --timeout <秒>` で待つか、`tap` / `press` の `--timeout` で要素が現れるのを待たせます。要素が現れた時点で次に進むので、固定の `sleep` より速く、遅い環境でも崩れにくくなります。`sleep` は、要素で表せない待ち（アニメーションの終わりなど）のための最後の手段です。
- **確認は `find --require` で。** 手順は単独のコマンドと同じ意味なので、`find` は一致がなくても成功（`"count":0`）で、シナリオは先に進みます。`find <セレクタ> --timeout 5 --require` と書くと「現れるまで待ち、現れなければそこで止める」確認になります（終了コード 6）。観察のためだけの `find`（結果を後で読む）には `--require` を付けません。

**AXe の `axe batch` との違い**: 1 行 1 手順で、`--step` を並べる・ファイル・標準入力から読めること、`sleep` の手順、最初の失敗で止まることは同じです。違いは次のとおりです。

- 要素を待つのは、AXe の `--wait-timeout` ではなく、手順ごとの `find --timeout` / `tap --timeout` / `press --timeout`（最大 10 秒）です。
- 途中に確認の手順を書けます。`find --timeout <秒> --require` は待ちと確認を兼ね、見つからなければそこで止まります。`source` / `screenshot` / `health` / `foreground` などの観察も手順にでき、結果は stdout に出ます。
- 実行の前に全手順を確かめ、不正な行があれば何も実行しません。

**所要時間（参考値）**: シミュレータ（iPhone 17 Pro / iOS 27.0、debug ビルド）で、同じ手順を `relay run` と、1 手順ずつ `relay` を呼ぶシェルのループとで比べました（各 3 回）。

| シナリオ | `relay run` | 1 手順ずつ |
| --- | --- | --- |
| `ping` × 20 | 41–43 ms | 324–332 ms |
| 設定 > 一般 > 情報（`launch`、`tap` × 2、`find` × 2、`health`、`foreground`、`screenshot` の 8 手順） | 1287–1301 ms | 1428–1457 ms |
| 上の例（about.relay の 7 手順。`terminate` と `launch` で約 5.8 秒） | 6818–7027 ms | 7141–7220 ms |
| 実機（iPhone 14 Pro / iOS 26.7.1）: `ping` × 20 | 67–73 ms | 360–370 ms |
| 実機: 設定 > 一般 > 情報（`swipe` と `sleep 2` を含む 10 手順） | 7011–7050 ms | 7455–7513 ms |

差は `relay` の起動と runner.json の読み込み（1 回約 15 ms）だけで、操作そのものの時間は変わりません。ふつうのシナリオでは数 % で、主な利点は、エージェントやスクリプトが 1 回の呼び出しで決まった手順を再生でき、途中で止まった位置が行番号でわかることです。なお `find --timeout` は要素が現れた時点で進むので、直後の `screenshot` が画面遷移のアニメーションの途中を写すことがあります。止まった画面がほしいときに限って、`sleep 0.5` などを挟みます。

**スワイプの後は固定の待ちが要ります。** 慣性スクロール中に `tap` すると、タップはスクロールを止めるだけで、要素は押されません（`tap` は成功するので、次の `find` で止まります）。実機の設定アプリでは、スワイプ後 1 秒ではまだ数 pt 動いていて同じ失敗になり、`sleep 2` で通りました。スクロールが止まったことは要素では表せないので、ここは `sleep` を使います。

## 録画（relay record）

`relay record` は、ランナーが動いているシミュレータか実機の画面を MP4 に録画します。操作の前後を動画で残したいとき（プルリクエストに貼る動作の証拠など）に、`record start` → 操作 → `record stop` の順で使います。どちらもランナーは使わず、ホスト側で録ります。

- **シミュレータ**: `xcrun simctl io <UDID> recordVideo --codec h264 --force <file>` で録ります。
- **実機（USB 接続のみ）**: QuickTime Player と同じ仕組みで録ります。CoreMediaIO で画面のキャプチャを許可すると（`kCMIOHardwarePropertyAllowScreenCaptureDevices`）、USB で接続した端末の画面が Mac のキャプチャデバイスとして現れるので、その映像を AVFoundation で H.264 に書き出します（音声は録りません。シミュレータと同じです）。`simctl` も `devicectl` も実機の録画を持たないためです。Wi-Fi だけで接続している端末は録れません。

### 実機を録画する前に（初回だけ）

1. 端末を **USB ケーブルで** Mac に接続し、ロックを解除しておきます（「このコンピュータを信頼しますか」と出たら「信頼」）。`relay devices` で `connected` になっていれば十分です。
2. **macOS のカメラの許可**が要ります。端末の画面はカメラと同じキャプチャデバイスとして扱われるため、relay を動かしているアプリ（ターミナル、IDE など。relay 自身ではありません）にカメラへのアクセスを許可します。最初の `relay record start` で macOS が許可を求めるダイアログを出すので、「許可」を押します（`record start` は答えを最大 120 秒待ちます）。誤って拒否したときは、**システム設定 > プライバシーとセキュリティ > カメラ** でそのアプリをオンにし、アプリを再起動します。
   - 許可はアプリごとです。別のターミナルや IDE から使うときは、そのアプリにも許可が要ります。切り離して動く録画のプロセス（`relay record supervise`）は、起動したアプリの許可をそのまま使います。
   - ダイアログを出せない環境（SSH でログインしたセッション、launchd のジョブなど）では許可を得られず、録画を始められないことがあります。先に手元のターミナルから一度 `record start` して許可しておいてください。

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

- **端末**: runner.json（「接続先（runner.json）の探し方」と同じ順。`--runner` も可）の UDID を `simctl list devices` と照らし、シミュレータでなければ `devicectl list devices` の実機（`relay devices` の KIND が `device`）と照らします。どちらにもなければ終了コード `1` です（何も起動しません）。シミュレータが boot していないときも `1` です（simctl は shutdown 中のシミュレータでも開始を報告し、空のファイルを作るため、先に確かめます）。runner.json がない・ランナーが応答しないときは、ランナー操作のコマンドと同じく `3`（`401` なら `4`）です。
- **実機の確認**: 実機は、`devicectl` で接続中であり、接続方式が USB（`wired`）であることを確かめます。Wi-Fi だけ（`localNetwork`）なら `… is connected over the network only (localNetwork); recording a device needs a USB cable …`、接続されていなければ `… is not connected …` で `1` です。続けてカメラの許可を確かめ、未決定なら macOS のダイアログで求め、拒否・制限されていれば設定の場所を示して `1` です（「実機を録画する前に」）。
- **開始**: 録画するプロセスを `relay start --background` と同じく新しいセッションとして切り離して起動します（stdin は `/dev/null`、出力は `~/.relay/logs/record-<時刻>-<port>.log`）。ターミナルを閉じても、そこで Ctrl-C を押しても録画は続きます。録画が実際に始まったら、保存先の絶対パスを stdout に 1 行出して `0` で戻ります。開始を待っている間の Ctrl-C は録画を止めて `1` です。
  - シミュレータは simctl を起動し、simctl が `Recording started` を出したら開始とみなします。15 秒以内に出ない、または simctl が先に終了したときは、simctl の出力（ログの末尾）を添えて `1` で終わり、何も残しません。
  - 実機は切り離したプロセス（`relay record supervise`）自身が録画します。端末の画面がキャプチャデバイスとして現れるのを最大 10 秒待ち（新しいプロセスでは 0.3〜4.5 秒ほど）、**最初のフレームを書き込んだ時点**で開始とみなします（`record start` はふつう 1.5〜4 秒で戻ります）。キャプチャデバイスは端末の名前（`devicectl` の名前と同じ）を持ちますが UDID は持たないので、名前で対応付けます。完全に一致するものを優先し、なければ大文字小文字・アクセント記号・アポストロフィや引用符の種類（`’` と `'` など）を無視して比べ直します。画面が 1 つも現れなかったときは、新しいプロセスでもう一度だけ試します（`relay: the screen of … did not show up; trying once more in a new process`）。別の録画（QuickTime Player を含む）がキャプチャを止めてから 2.5 秒ほどの間に探し始めたプロセスは、その後いくら待っても画面が見えず、新しいプロセスなら見えるためです。このときの `record start` は 20 秒ほどかかります。それでも現れなければ、見えている画面の名前と、USB で接続する・ロックを解除する・「信頼」する、という対処を示して `1` です（本当に繋がっていない端末では、ここまで 20 秒ほどかかります）。同じ名前の端末が複数つながっている（比べ直して複数が一致したときも含む）と区別できないので `1` です（どちらかの名前を変えるか、外してください）。それぞれのプロセスで 25 秒以内に最初のフレームが来なければ `1` です。
- **保存先**: `-o` / `--output` がなければ `$TMPDIR/relay/relay-recording-<時刻>.mp4`（スクリーンショットと同じく、対象アプリの作業ツリーを汚さないため）。相対パスはカレントディレクトリが基準で、そのディレクトリがなければ `1` です（relay は作りません）。同じ名前のファイルがすでにあれば、`<path> already exists; pass --force to replace it, or give another --output` で `1` です（何も起動しません）。`--force` を付けたときだけ上書きします。既定の時刻入りの名前でも、衝突すれば同じ扱いです。判定は relay が録画を始める前に行い、simctl には常に `--force` を渡します（simctl に任せると、エラーは録画を始めようとした後に simctl のログの中に出るため。判定と書き込みの間にファイルが作られた場合は上書きされます。実機も同じです）。
- **形式**: 実機は H.264 の MP4 に書き出します。`-o` の拡張子が `.mov` のときだけ QuickTime ムービー（中身は同じ H.264）にします。大きさは端末の画面の画素数（iPhone 14 Pro で 1180×2556）、フレームレートは画面の更新に合わせた可変（静止画面でも 40〜60 fps で、フレームの間隔は長くても 0.1 秒ほど）です。キャプチャ中、端末のステータスバーの時刻は iOS が 9:41 に固定して表示します（QuickTime と同じです）。
- **1 つのランナーに 1 つ**: 録画の状態（録画するプロセス（simctl、実機なら `relay record supervise`）の PID と起動時刻、保存先、UDID、開始時刻、ポート、ログ、シミュレータか実機か）を `~/.relay/recording-<port>.json`（パーミッション 0600。runner.json と同じ書き方）に保存します。ポートは runner.json の URL のものです。録画中にもう一度 `record start` すると、`a recording is already running for the runner at … ; stop it with relay record stop …` で `1` です。録画するプロセスがもう動いていない状態ファイル（自動停止した、強制終了されたなど）は次の `record start` を妨げず、削除して新しく始めます（動画ファイルは残ります）。PID は起動時刻と実行ファイル名・引数（simctl の recordVideo、実機なら relay の record supervise）も一致したときだけ録画中とみなすので、PID が再利用されても誤りません。
- **自動停止**: `--max-duration <秒>`（既定 600 秒）で録画を止めます。止め忘れてディスクを使い続けないためです。切り離したプロセス（`relay record supervise`。内部用）が時間を数え、シミュレータなら simctl に SIGINT を送り、実機なら自分で書き出しを終えます（時間は録画プロセスの開始から数えるので、実機では最初のフレームまでの 1 秒ほど動画が短くなります）。自動停止した後も状態ファイルは残り、`record stop` で `relay: the recording had already ended (reached --max-duration of …)` を stderr に、保存先を stdout に出します。
- **停止**: `record stop` は録画するプロセス（simctl、実機なら `relay record supervise`）に SIGINT を送り、終了（MP4 の書き出し）を最大 30 秒待ち（実機では、書き出した後もキャプチャを止めてから 3.5 秒待ってから終わるので、`record stop` は 4 秒ほどかかります。直後の `record start` が画面を見つけられるようにするためです）、ファイルが存在して空でないことを確かめてから、絶対パスを stdout に出して `0` で終わり、状態ファイルを削除します。録画していなければ `not recording` で `0` です（`relay stop` と同じ考え方）。30 秒以内に終わらなければ状態ファイルを残して `1`（もう一度 `record stop` できます）、動画が空・ないときは `1` です。`--runner` か `$RELAY_RUNNER` で指定した runner.json がなければ、ほかのコマンドと同じく `--runner … does not exist; is relay start running?` で `3` です。runner.json がなくなった後（ランナーが止まった後）でも、`--runner` も `$RELAY_RUNNER` もなければ、`~/.relay` に状態ファイルが 1 つだけならそれを止めます。複数あるときは、ポートごとに保存先と録画中か（`recording` / `ended`）を一覧にして `choose one with --port <n>` で `1` です。
- **ポートで選ぶ**: `record stop` と `record status` は、`--port <n>` を付けると runner.json を探さずに、そのポートの状態ファイル（`~/.relay/recording-<n>.json`）を直接使います。runner.json がなくても、複数のランナーを別のポートで動かしていても使えます。そのポートに録画がなければ `not recording` で `0` です。`--runner` と同時には指定できません（書き方の誤りなので `2`）。
- **状態**: `record status` は、録画中か（`recording: yes (12s; stops by itself after 600s)`、自動停止などで終わっていれば `ended`）、保存先、UDID、録画するプロセスの PID、開始時刻、ログを出します。実機の録画でフレームが止まっている間は、`frames: no frame for 5s (the device may be locked, …)` の行も出します（下の「実機のフレームが止まったとき」）。`--json` では 1 つの JSON オブジェクト（`kind`（`simulator` / `device`）、`recording`、`output`、`udid`、`port`、`pid`、`startedAt`、`elapsedSeconds`、`maxDuration`、`log`、`state`。フレームが止まっている間は `stall` も）、録画していなければ `{"recording":false}` です。終了コードは録画の有無によらず `0` です。
- **後片付け**: `relay stop` は、ランナーを止める前に、そのランナー（runner.json のポート）の録画を止めて書き出し、`relay: saved the recording: <path>` を stderr に出します（stdout は今までどおり `stopped` / `not running`）。`relay start` も、Ctrl-C や SIGTERM で終わるとき、boot したシミュレータを shutdown する前に、自分のポートの録画を同じように書き出します。実機でも同じです。
- **シミュレータが先に shutdown されたとき**: simctl は録画を続けたまま終わりません（自動停止までそのまま）。`record stop` は通常どおり SIGINT を送り、shutdown した時点までの動画を書き出して保存先を出し、`relay: the simulator … is no longer booted; the video ends where it shut down` を stderr に添えます。
- **実機が録画中に外されたとき**: 録画のプロセスがそれまでの動画を書き出して終わります。`record stop` は `relay: the recording had already ended (the device was disconnected; …)` を stderr に添えて保存先を出します。
- **実機のフレームが止まったとき**（録画中にロックされた、キャプチャが止まったなど）: 録画は止めません。最後のフレームから 5 秒フレームが来なければ、録画のログに `relay: no frame for 5s (the device may be locked, or the capture stalled); still recording, …` を 1 回書き、また来始めたら `relay: frames came again after <n>s without one` を書きます。その間、動画は最後のフレームのまま止まり、来始めたところから続きます。止まっている間は `record status` の `frames:` の行（`--json` では `stall`）で分かります。ロックを解除すればふつうは再開します。再開しなければ `record stop` し、ロックを解除してから録画し直してください。
- 動画は画面の画素数（iPhone 17 Pro のシミュレータで 1206×2622）で、ランナーの座標（ポイント）とは倍率（scale）が違います。実機で録画中に画面が回転したときは、最初の大きさの中に縦横比を保って収めます。

## エージェントスキル

`skills/device-relay/` は、コーディングエージェント（Claude Code など）が対象アプリのリポジトリで作業しながら relay でアプリの動作を確かめるためのスキルです。`SKILL.md` に基本の流れ（`relay status` → `relay start --background` → `relay launch` → スクリーンショットと要素の観察 → 操作 → 確認 → `relay stop`）、要素セレクタを優先する操作のコツ、終了コードごとの対処、安全上の注意をまとめ、オプションやトラブルシューティングの詳細は `reference.md` に分けています。

使う前に、relay をインストールし、`relay doctor` で確認しておきます（「[インストール](../README.ja.md#インストール)」）。`relay skill install` は、展開したリリースやチェックアウトの `skills/device-relay` から対象アプリのリポジトリなどへスキルを入れます。どちらも見つからないとき（`relay` のバイナリだけをコピーしたとき）は、`relay install` が一緒にコピーした `~/.relay/runner/skills/device-relay` を使います。

```sh
cd /path/to/app
relay skill install            # <git のルート>/.claude/skills/device-relay にコピー（チームでコミットできる）
relay skill install --global   # ~/.claude/skills/device-relay（どのリポジトリでも使う）
relay skill install --dir <skills dir>   # <skills dir>/device-relay
relay skill status             # 取り出し元と、プロジェクト・グローバルのインストール先、バージョンのずれ（!）
relay skill uninstall          # relay が入れたものだけを削除（--global / --dir も同じ）
```

- 既定の入れ先は、カレントディレクトリの git のルート（git の外ならカレントディレクトリ）の `.claude/skills/device-relay` です。コピーなので、そのままコミットしてチームで共有できます。どのコマンドも入れ先（削除先）のパスを必ず表示します。relay が表示・比較するパスは、存在する部分のシンボリックリンクを解決した形にそろえます（macOS では `/private/tmp/...` も `/tmp/...` になります）。
- 取り出し元は、`relay install` と同じ探し方で見つけた展開したリリースか device-relay のチェックアウト（`$RELAY_HOME`、カレントディレクトリとその親、`relay` の実行ファイルの場所）の `skills/device-relay`、なければ `~/.relay/runner/skills/device-relay`（`relay install` したもの）です。`--link` でも同じ順です。
- コピーには、SKILL.md を変えずに隠しファイル `.relay-skill.json` を置き、relay のバージョン、コミット、取り出し元、日時を記録します。この記録があるもの（または relay のスキルを指すリンク）は relay が入れたものとみなし、再実行で上書き更新します。それ以外のものが入れ先にあれば、`--force` なしでは上書きしません。`uninstall` は relay が入れたものだけを削除し、それ以外は残してエラーにします。
- `--link` はコピーの代わりにシンボリックリンクを作ります。スキルを編集する開発用で、チェックアウトの変更がそのまま反映されます。リンクはこの Mac の絶対パスを指すので、コミットして共有するには向きません。
- `relay skill status` は、記録したバージョンが `relay` のバージョンと違う場合や、取り出し元とバージョンかコミットが違う場合に ! を付けます（`differs from the source …`。取り出し元のほうが古いこともあるので、どちらが新しいかは示しません）。`source` の行の `from …` は取り出し元の種類で、`checkout`（`.git` がある git のチェックアウト）、`release`（`.git` のない展開したリリース）、`relay install`（`~/.relay/runner` のコピー）のどれかです。relay を更新したら `relay skill install`（`--global` などで入れたなら同じオプション）をやり直してください。バイナリだけをコピーして `relay install` のコピーから取り出している場合は、先に展開したディレクトリ（またはチェックアウト）で `relay install` を実行します。
- スキルは、ランナーが動いていれば（`relay status` が 0）それを使い、止めません。自分で `relay start --background` したときだけ、終わりに `relay stop` します。端末は、実機を指定されない限り `relay devices` で選んだシミュレータを `--device` / `--udid` で明示します。
