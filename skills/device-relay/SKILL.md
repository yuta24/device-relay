---
name: device-relay
description: relay CLI（device-relay）で iOS のシミュレータや実機を操作し、アプリの実際の動作を確かめる。アプリの起動、スクリーンショットを撮って画面を見る、要素ツリーを読む、タップ・長押し・スワイプ・文字入力ができ、アプリ側には何も組み込まない。iOS アプリの変更をシミュレータや実機で確かめるとき、画面がどう見えるか知りたいとき、UI の不具合を再現するとき、iPhone のアプリをタッチやキーボードで操作するときに使う。
---

# device-relay

`relay` は、常駐する XCTest ランナーを通じて Mac から iOS のシミュレータや実機を操作する CLI です。対象アプリの改修は要りません。どのディレクトリ（対象アプリのリポジトリなど）からでも使え、そこには何も作りません（ランナーの URL とトークンは `~/.relay/runner.json`、スクリーンショットは `$TMPDIR/relay/`）。

オプションの詳細、要素ツリー、失敗の理由ごとの対処、トラブルシューティングは [reference.md](reference.md) にあります。全体の説明は device-relay の README と docs/ の各文書です。

## セットアップ（初回だけ）

1. `command -v relay` で確認します。なければ、device-relay のチェックアウトで `make install`（`~/.local/bin/relay` にリンク。`~/.local/bin` が PATH にあること）→ `relay install`（Runner プロジェクトとこのスキルを `~/.relay/runner` にコピー）を実行するよう利用者に頼みます。利用者のホームに書き込むので、断りなく実行しないでください。
2. `relay doctor [--udid <UDID> | --device <名前>] [--simulator] [--os <version>]` で環境を確かめます（`relay start` に付けるのと同じ指定で、その端末を確認します）。✗ があれば終了コード 1 で、各行に直し方が出ます。! は注意で、起動は止めません。
3. このスキル自体は `relay skill install`（対象アプリのリポジトリの `.claude/skills/device-relay` にコピー。`--global` なら `~/.claude/skills`）で入ります。`relay skill status` で ! が出たら（relay の更新でスキルが古い）、`relay skill install` で更新するよう利用者に伝えます。リポジトリやホームのファイルを書き換えるので、断りなく実行しないでください。

### sandbox の中で動くとき

エージェントのシェルが sandbox（Claude Code の sandbox など）の中で動くと、`relay start` は動かず（`~/.relay` や DerivedData に書けない、testmanagerd に接続できないなど）、ランナー操作のコマンドも localhost に接続できません。relay が `the OS refused the connection (Operation not permitted)` と出したり、`relay doctor` の `localhost` / `~/.relay` が ✗ なら、ランナーが止まっているのではなく、relay が sandbox の中にいます。`relay stop` や起動し直しをせず、relay を sandbox の外で動かす設定（Claude Code では `sandbox.excludedCommands` に `"relay *"`。[reference.md](reference.md#sandbox-の中から使う)）を利用者に頼みます。設定ファイルは断りなく書き換えないでください。除外が効くよう、relay は 1 回に 1 コマンドで呼び、`cd … &&`、リダイレクト（`>`）、`$(…)` と組み合わせません。

## 基本の流れ

```sh
relay status                                    # 0: 応答あり（それを使う）。3: ランナーがない・応答なし。4: トークン拒否
relay devices                                   # 端末の一覧（NAME、UDID、KIND、OS、STATE）
relay start --background --device "<名前>"      # または --udid <UDID>（--os <version> で絞れる）。ready まで待ち、stdout に ready:/device:/pid:/log:/token: を出して 0
relay launch <bundle-id>                        # 対象アプリを起動・前面化
relay screenshot --scale 1                      # 保存先の絶対パスが出る → そのファイルを画像として読む（1 px = 1 pt）
relay source --format compact --filter interactive   # 操作できる要素を 1 行 1 要素で
relay find --type button                        # セレクタに一致する要素（JSON）
relay tap --id <identifier>                     # 要素を指定して操作
relay find --id <次の画面の要素> --timeout 5 --require   # 現れるまで待つ（現れなければ終了コード 6）。その後で観察し直す
relay stop                                      # 自分で起動したときだけ。stopped か not running で 0
```

- **動いているランナーはそのまま使う。** `relay status` が 0 なら、利用者などがすでに起動しています。それを使い、止めないでください。`~/.relay/runner.json` のランナーが同じポート（`--port`、既定 8100）で応答していると `relay start --background` は起動せずに終了コード 1 で終わり `relay stop` を案内しますが、`relay stop` はフォアグラウンドの `relay start` も止めるので、止めてよいのは自分が起動したものだけです。同じポートで別の `relay start` がまだ起動の途中（boot やビルド中）のときも、`another relay start ... is starting or running a runner on port ...` で終了コード 1 になります。そのときは `relay status` が 0 になるのを待ってそれを使います。
- **`relay status` が 4 なら止めずに確かめる。** 見つかった runner.json のトークンが、そのアドレスで応答しているランナーのものではありません（別の `relay start` のランナーが同じポートにいる、古い runner.json、`--runner` / `$RELAY_RUNNER` / カレントディレクトリから親へ順にたどった `.relay/runner.json` が別のものを指している）。自分で起動したものでなければ、`relay stop` や起動し直しをせずに利用者に確認します。
- **自分のランナーを覚えておく。** `relay start --background` が出す `pid:` を控え、終わるときは `relay status` の `pid` が同じであることを確かめてから `relay stop` します。
- **端末は明示する。** `--udid` / `--device` がないと、`relay start` は接続中の実機が 1 台ならそれ、なければ起動中のシミュレータが 1 台ならそれを選び、決まらなければ候補つきでエラーにします。実機がつながっているとシミュレータより実機が選ばれるので、利用者に実機を指定されていない限り、`relay devices` で選んだシミュレータを `--device` / `--udid` で指定します（起動中のシミュレータを使うなら `--simulator` でも、実機を除いて選べます）。同じ名前のシミュレータが複数ある（ランタイム違い）ときは、`--device` が最も新しい iOS のものを選び、`relay: using …` に OS を出します。特定の iOS が要るときは `--os 26.5` のように絞るか `--udid` を使います。停止中のシミュレータを指定すると boot し、`relay stop` で shutdown します。
- `relay start --background` の進行状況（boot、ビルド、起動）は stderr の `relay:` 行に出ます。初回はランナーのビルドで数分かかるので、コマンドのタイムアウトを長めにします（起動まで最大 30 分、起動後は `--ready-timeout`（既定 180 秒）+ 15 秒待ちます）。
- 起動に失敗すると、子の `relay start` を止め、stderr にログの末尾と原因（ログのパス付き）を出して非ゼロで終わります。終了コードは、ready の前に子が終了した（ビルドの失敗、端末が見つからない、`Failed to initialize for UI testing` など）なら 1、時間切れなら 3、同じポートですでにランナーが応答しているなら 1 です。ログの末尾と、必要ならログファイル（`~/.relay/logs/start-<時刻>-<port>.log`）を読んでから対処します（[トラブルシューティング](reference.md#トラブルシューティング)）。
- 対象アプリは端末にインストール済みである必要があります（プロジェクトのやり方で Xcode や `xcodebuild` / `xcrun simctl install` でビルド・インストールする）。`relay launch` は起動・前面化だけで、入っていなければランナーに送らず、すぐに終了コード 6（`app_not_installed`）で終わります。
- バンドル ID はプロジェクトの `PRODUCT_BUNDLE_IDENTIFIER` で調べるか、アプリを前面にして `relay foreground` で確かめます。

### 並列に使うとき

ほかのエージェントも relay を使っている（または使うかもしれない）ときは、セッションを使います。

**まず `echo "$RELAY_SESSION"` で確かめます。** 利用者がエージェントの起動時に渡していれば（`RELAY_SESSION=agent-1 claude` など）値が出て、どのコマンドもそのセッションを使うので、そのまま進めます。空なら、自分のセッション名を決めて、relay の各コマンドに毎回 `--session <name>` を付けます。

**`export` に頼りません。** コマンドごとに新しいシェルになる環境では次のコマンドに残らず、そのコマンドはセッションなしになって、終了コード 3 で失敗するか、別の誰かのランナーを操作します。

```sh
relay status --all                                                     # 全セッションの一覧（どの端末が使用中か）
relay start --background --session agent-1 --device "<名前>" --os 27.0  # 端末はセッションごとに分ける。ポートは自動
relay tap --session agent-1 --id <id>                                  # 自分のランナーだけに届く
relay stop --session agent-1                                           # 自分のセッションだけ止まる
```

- `relay: warning: no session selected; using <パス>, while sessions <名前> are running` が出たら、そのコマンドはセッションなしで動いています（失敗にはなりません）。自分のランナーを使うつもりなら `--session` を付け直し、その操作がどの端末に届いたかを確かめます。
- セッションを指定すると、ほかの runner.json へは決して進みません。まだ起動していなければ終了コード 3 です。`RELAY_SESSION` と `RELAY_RUNNER` の両方があると終了コード 1 です。
- 1 台の端末で動かせるランナーは 1 つです。使用中の端末を指定すると、持ち主つきのエラーで終わるので、別の端末を選びます。ほかのセッションのランナーは止めません（`relay stop --all` も同様に使いません）。
- 同じソースのビルドは共有です。ほかの `relay start` がビルド中か、同じビルドからランナーを起動している間は `waiting for another relay start's build` と出して待ちます。先の起動が ready になるまで数分かかることがありますが、失敗ではないので、止めたり起動し直したりせずに待ちます。
- セッションのポートはほかの `relay start` とは重なりませんが、ほかのプロセスが先に取ると、`relay start` はランナーの起動に失敗します（ログに `Address already in use`）。そのときはもう一度 `relay start` すれば、次の空きポートを選びます。

## 観察

- **ふだんは縮小したスクリーンショットと絞り込んだツリーを使います。** フル解像度の画像や全体のツリーは大きく（設定のトップで画像 1206×2622 px、ツリー 37 KB）、読むたびにコンテキストを使います。
- `relay screenshot --scale 1` は、端末側で 1 ポイント = 1 画素に縮小した PNG を保存し、絶対パスを 1 行出します（iPhone で約 400×870 px）。そのファイルを読んで画面を見ます。画像の画素がそのままタップのポイントになります。stderr の `relay: image … px, screen … pt, … px/pt` で確かめられます。iPad など画面が大きいときは `--max-size 1024` も付けます（そのときは画素を stderr の px/pt で割るとポイント）。
- 小さな文字や細部を確かめたいときだけ、フル解像度の `relay screenshot`（オプションなし）を使います。その画像の画素はポイント × scale（iPhone では 3）です。
- `relay source --format compact --filter interactive` は、画面に見えていて有効な、操作できる要素（ボタン、セル、入力欄、スイッチなど）だけを 1 行 1 要素で出します（設定のトップで 12 行・約 1 KB）。行の `type`・`label`・`id`・`value` はそのままセレクタに使えます: `button label="General" id="com.apple.settings.general" frame=16,293,370,52` → `relay tap --id com.apple.settings.general` か `relay tap --type button --label General`。キーボードのキーは出ません（`relay type` / `relay key` を使う）。JSON がほしければ `--format compact` を外します。
- 一覧にない要素（見出しや結果のテキスト、無効なボタン）を確かめたいときは、`relay find <セレクタ>` か、全体のツリー `relay source --format compact`（1 行 1 要素、字下げで親子関係）を使います。`relay source`（JSON）と `--format text` は大きいので、必要なときだけ（JSON は `jq` で絞るか `--max-depth <n>`）。どれも `--bundle-id` がなければ前面アプリが対象です。
- `relay find <セレクタ>` は一致した要素の `type`・`identifier`・`label`・`value`・`frame`・`enabled`・`index` を返します。決まった要素を探すにはこれがいちばん速く、一致がなくても終了コード 0（`"count":0`）です。`--require` を付けると、一致がないとき終了コード 6 になります（あるはずの要素を確かめるとき）。
- スクリーンショットは利用者に見えるもの、ツリーは指定できるものです。画面の理解にはスクリーンショット、セレクタを決めるには絞り込んだツリーや `find` と、両方を使います。

## 操作

**座標より要素セレクタを優先します。** セレクタは `--id`・`--label`・`--type`・`--value` を 1 つ以上（すべて完全一致・大文字小文字を区別・AND）と、任意の `--index <n>` です。

```sh
relay tap --id login.button
relay tap --label "Sign In" --type button
relay tap --type textField --index 1
relay press --label "Photo" --type cell --duration 1.0
```

- アプリが accessibilityIdentifier を付けていれば `--id`、なければ `--label` と `--type` を使います（セルは同じラベルの `button` と `staticText` の 2 つに見えることが多いので `--type` を足す）。
- `ambiguous` で失敗したら、候補を読んで条件か `--index` を足します。
- 座標（`relay tap <x> <y>`、`relay swipe <x1> <y1> <x2> <y2>`）は、表示の向きでの画面左上を原点とするポイント単位です。画面の外（`0 ≤ x < screen.width`、`0 ≤ y < screen.height` の外）は何も送らずに終了コード 7 です。要素の `frame` や `relay health` の `screen.width` / `screen.height` から求めます。スクリーンショットから求めるときは、`--scale 1` の画像なら画素がそのままポイント、それ以外は画素を stderr の px/pt（フル解像度なら scale）で割ります。座標は、スクロールなど要素で指定できない操作だけに使います（例: `relay swipe 200 700 200 200` で下から上へ）。
- 文字入力: 入力欄をタップしてから `relay type "text"`。確定は `--key return` を付けます。1 文字消すのは `relay key delete`。キーは `return`・`delete`・`space` だけです。`-` で始まる文字列は `relay type -- -text` のように `--` を挟みます。
- **sleep せずに待つ。** 画面が変わる操作の後は、次の画面にある要素を `relay find <セレクタ> --timeout <秒>`（最大 10 秒。`count` を確認）で待つか、`tap` / `press` に `--timeout` を付けて要素が現れるのを待たせます。もっと長く待つときは短い timeout を繰り返します。
- iPad のウィンドウ表示でも、要素の frame と `point` は画面の座標です。`relay find --type window` の `window` でウィンドウの位置と倍率がわかります。同じアプリのウィンドウが複数あるなどで位置が決まらないと、要素指定のタップは終了コード 6 で `window_position_unknown` になり（何も送りません）、`find` と `source` には `warning` が付きます。そのときはスクリーンショットから座標で指定します。
- 表示が複数ある端末（iPhone Duo。外側と内側）では、`relay health` の `display` と `screen`、スクリーンショット、座標、要素の frame は、すべて前面アプリが載っている表示のものです。折りたたみを変えたら（変えるのは利用者です）`relay status` と `relay health` を読み直します（切り替えでランナーが止まることがあります）。終了コード 6 で `display_unknown`（`cannot tell which display`）が出たら画面が暗いので利用者に確かめ、`touch_mode_unavailable`（`xcui touches can't reach`）が出たら `--mode` を外して（または `--mode private` で）送り直します。詳しくは reference.md の「座標と向き」。
- **画面が変わったら観察し直す。** frame、index、前面アプリは変わります。前の画面のセレクタや座標を確かめずに使い回さないでください。
- コマンドは 1 つずつ、前の結果を待ってから送ります。ランナーは一度に 1 コマンドしか実行せず、重なると busy（終了コード 5）になります。
- `relay launch` の直後は前面アプリが切り替え前のまま返ることがあります。対象を確実にしたいときは `find` / `tap` / `type` / `source` に `--bundle-id <id>` を付けます。
- `relay health` の `foreground.source` が `fallback` のときは、手で切り替えたアプリを追えないので `--bundle-id <id>` を付けます。`touchSynthesis` が `xcui` のときは、タッチが 1 回 1–2 秒かかります。どちらも非公開 API が使えない状態です（詳しくは device-relay の docs/private-api.md）。

## 手順の再生（relay run、実験的）

実験的な機能で、形式は変わることがあります。初めての画面は 1 コマンドずつ観察して進め、確かめ終えた手順だけを再生に回します。

1. 確かめた手順を、`relay` を除いて 1 行 1 手順で `<名前>.relay` に書き出す（先頭に `# relay-run: 1`。リポジトリに置くかは利用者に確認）。画面が変わるところは `find <セレクタ> --timeout 5 --require` か `tap … --timeout 5` で待ち、到着を確かめる。
2. 流す前に `relay run <file> --check` で検証する（何も実行しない）。
3. 次からは `relay run <file>` で再生する。最初に失敗した手順で止まり、`relay: step i/n (line N) failed: …` とその手順の終了コード（下の表）が出る。
4. 失敗したら、止まった時点の画面を観察し直し（スクリーンショット、`relay source --format compact --filter interactive`）、line N のセレクタや待ちを直して 2 からやり直す。

書き方の詳細は [reference.md](reference.md#シナリオの実行relay-run実験的)。

## 録画

動作の証拠（プルリクエストに貼る動画など）を残すときは、`relay record start` → 操作 → `relay record stop` です。シミュレータと、USB で接続した実機で使えます（Wi-Fi だけの実機は終了コード 1）。

- 実機は、relay を動かしているアプリ（ターミナルなど）に macOS のカメラの許可が要ります。初回は `record start` が macOS のダイアログを出して答えを待つので、利用者に「許可」を押すよう頼みます。拒否済みなどで終了コード 1 になったら、システム設定 > プライバシーとセキュリティ > カメラ で許可してもらいます。エージェントが自分で設定を変えたり `tccutil` を使ったりしてはいけません。

- `relay record start` は保存先の絶対パスを出して戻ります（既定は `$TMPDIR/relay/`、`-o <file>` で指定。ディレクトリは存在すること）。`relay record stop` は書き出しを待って同じパスを出します。そのファイルを利用者に伝えます。
- 止め忘れても `--max-duration`（既定 600 秒）で止まり、`record stop` で取り出せます。自分で起動したランナーを `relay stop` で止めるときも、録画は先に書き出されます。
- 録画中に別の `record start` は終了コード 1 です。`relay record status` で確かめます。詳しくは [reference.md](reference.md#録画relay-record)。

## 終了コード

| コード | 意味 | 対処 |
| --- | --- | --- |
| 0 | 成功 | – |
| 1 | 引数の誤りやローカルの失敗（何も送っていない） | コマンドを直す。`relay <command> --help` |
| 3 | ランナーに届かない（runner.json がない、接続できない、`no response within <秒>s`） | `no response within` なら、ランナーは操作を続けているので `relay ping` の `busy` が `false` になるまで待つ（`launch` / `terminate` は最大 150 秒、長い `type` は 1 文字 0.1 秒ぶん待つので、自分のコマンドのタイムアウトをそれより長くする）。`launch` の時間切れは、busy がさらに数分続くことがあるので、自分で起動したランナーなら `relay stop` → 起動し直すほうが早い。それ以外は `relay status`。runner.json がなければ `relay start --background …`。runner.json はあるが応答しない（`relay start` が強制終了されたなど）なら、`relay stop` で片付けてから起動。`the OS refused the connection` なら relay が sandbox の中にいる（上の「sandbox の中で動くとき」）ので、止めも起動もしない |
| 4 | トークンが拒否された（401）。runner.json が古いか、別のランナーのもの | `relay status` で URL・端末・PID を確かめ、`--runner` / `--session` / `$RELAY_RUNNER` / `$RELAY_SESSION` / カレントディレクトリから親へ順にたどった `.relay/runner.json` も確認。自分で起動したものなら `relay stop` → 起動し直す。そうでなければ止めずに利用者に確認 |
| 5 | busy（409）。別のコマンドを実行中 | 1 秒ほど待つか、`relay ping` が `"busy":false` になってから再試行 |
| 6 | 操作の失敗（422）: 要素が見つからない・1 つに決まらない・無効・画面外、キーボードのフォーカスがない。`relay launch` のアプリが入っていない | stderr の JSON の `code` で分ける（下の表）。要素の失敗は `reason` と `candidates` を読み、観察し直してセレクタを直す |
| 7 | リクエストの拒否（400 などの 4xx） | `code` が `point_offscreen` なら座標が画面の外（`relay health` の `screen` を読み直す。向きを変えると縦横が入れ替わる）。`touch_mode_unavailable` なら `--mode` を外して送り直す。`invalid_request` などはエラー文を読んで直す |
| 8 | ランナーのエラー（5xx など） | 1 回だけ再試行。続くなら `relay status` とログを確認 |

成功時はランナーの JSON が stdout に、失敗時は stderr に出ます。stderr の `relay:` で始まる行は人向けのヒントです。

失敗時の JSON（`{"ok":false,"code":"…","error":"…"}`）の `code` は安定した文字列なので、英文の `error` ではなく `code` で分岐します。終了コード 6 でよく出るもの:

| `code` | 対処 |
| --- | --- |
| `element_not_found` | `--timeout` で待つ、`relay foreground` で前面アプリを確かめる、`relay find --type …` で実際の値を確かめる |
| `element_ambiguous` | `candidates` を見て `--type` などの条件か `--index` を足す（待っても直らない） |
| `element_not_hittable` | `reason` が `offscreen` ならスクロール、`disabled` なら前提の操作、`emptyFrame` なら観察し直す |
| `no_keyboard_focus` | 入力欄をタップしてから送り直す |
| `touch_mode_unavailable` | `--mode` を外して送り直す |
| `display_unknown` | 画面が暗い。利用者に確かめる |
| `window_position_unknown` | iPad のウィンドウの位置が不明。ウィンドウを 1 つにするか、スクリーンショットから座標で指定する |
| `touch_failed` / `xcui_failed` | 1 回だけ再試行し、続くなら観察し直す |
| `app_not_installed` | バンドル ID を確かめる（大文字小文字も区別される）か、アプリをインストールしてから送り直す。待っても直らない |

`code` がなければ古いランナーです（終了コードとエラー文で判断）。code の一覧は [reference.md](reference.md#操作が失敗したとき終了コード-6)、`reason` ごとの対処も同じ所にあります。

## 安全のために

- **対象アプリの外に出ない。** タスクに必要でない限り、設定、Safari、メッセージなど対象アプリ以外のアプリを開いたり操作したりしないでください。ほかのアプリに移ってしまったら、`relay button home` → `relay launch <bundle-id>` で戻ります。
- **状態をそろえてから始める。** 前の操作の影響を避けたいときは、`relay button home` → `relay launch <bundle-id>`（まっさらに起動し直すなら先に `relay terminate <bundle-id>`）。
- **パスワードや個人情報を勝手に入力しない。** 利用者から渡されたものだけを入力します。パスワードはコマンドラインに書かず（`ps` やシェルの履歴に残るため）、利用者が用意した環境変数やファイルから標準入力で渡します: `printf '%s' "$PASSWORD" | relay type --stdin`。
- **実機では破壊的な操作をしない。** データやアプリの削除、購入、メッセージやメールの送信、システム設定の変更、サインアウトなどは、事前に利用者に確認します。実機のスクリーンショットには個人情報が写りうるので、タスクに必要な範囲を超えて共有しないでください。
- **後片付け。** 向きを変えたら（`relay orientation landscape` は `landscapeLeft` と同じ）`relay orientation portrait` で戻し、アプリを妥当な画面に戻し、自分で起動したランナーだけを `relay stop` で止めます。

## よくある失敗

- `Failed to initialize for UI testing`（`Timed out while enabling automation mode.`）: 実機では、有効化のときに端末がパスコードの入力を求めていることがある。利用者に、端末にパスコード入力画面が出ていたら入力してもらうよう依頼してから起動し直す（`relay start` が「relay install を再実行して」と知らせていたら、利用者に確認して先に `relay install` をやり直す）。続くなら 設定 > デベロッパ >「UI オートメーションを有効にする」をオンにしてもらう。シミュレータなら 1 回だけ起動し直す。
- 実機で「信頼されていないデベロッパ」: 設定 > 一般 > VPNとデバイス管理 で開発元を信頼してもらってから、起動し直す。
- 実機がロックされている: 利用者にロックを解除してもらう。
- ローカルネットワークの許可（実機で `--allow-wifi` のとき）: 端末のダイアログで許可してもらう。

どれも端末を手で操作する必要があるので、回避しようとせず、利用者に何をしてほしいかを伝えます。詳しくは [reference.md](reference.md#トラブルシューティング)。
