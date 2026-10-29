---
name: device-relay
description: relay CLI（device-relay）で iOS のシミュレータや実機を操作し、アプリの実際の動作を確かめる。アプリの起動、スクリーンショットを撮って画面を見る、要素ツリーを読む、タップ・長押し・スワイプ・文字入力ができ、アプリ側には何も組み込まない。iOS アプリの変更をシミュレータや実機で確かめるとき、画面がどう見えるか知りたいとき、UI の不具合を再現するとき、iPhone のアプリをタッチやキーボードで操作するときに使う。
---

# device-relay

`relay` は、常駐する XCTest ランナーを通じて Mac から iOS のシミュレータや実機を操作する CLI です。対象アプリの改修は要りません。どのディレクトリ（対象アプリのリポジトリなど）からでも使え、そこには何も作りません（ランナーの URL とトークンは `~/.relay/runner.json`、スクリーンショットは `$TMPDIR/relay/`）。

オプションの詳細、要素ツリー、失敗の理由ごとの対処、トラブルシューティングは [reference.md](reference.md) にあります。全体の説明は device-relay の README です。

## セットアップ（初回だけ）

1. `command -v relay` で確認します。なければ、device-relay のチェックアウトで `make install`（`~/.local/bin/relay` にリンク。`~/.local/bin` が PATH にあること）→ `relay install`（Runner プロジェクトとこのスキルを `~/.relay/runner` にコピー）を実行するよう利用者に頼みます。利用者のホームに書き込むので、断りなく実行しないでください。
2. `relay doctor [--udid <UDID> | --device <名前>]` で環境を確かめます。✗ があれば終了コード 1 で、各行に直し方が出ます。! は注意で、起動は止めません。
3. このスキル自体は `relay skill install`（対象アプリのリポジトリの `.claude/skills/device-relay` にコピー。`--global` なら `~/.claude/skills`）で入ります。`relay skill status` で ! が出たら（relay の更新でスキルが古い）、`relay skill install` で更新するよう利用者に伝えます。リポジトリやホームのファイルを書き換えるので、断りなく実行しないでください。

## 基本の流れ

```sh
relay status                                    # 0: 応答あり（それを使う）。3: ランナーがない・応答なし。4: トークン拒否
relay devices                                   # 端末の一覧（NAME、UDID、KIND、OS、STATE）
relay start --background --device "<名前>"      # または --udid <UDID>。ready まで待ち、stdout に ready:/device:/pid:/log:/token: を出して 0
relay launch <bundle-id>                        # 対象アプリを起動・前面化
relay screenshot                                # 保存先の絶対パスが出る → そのファイルを画像として読む
relay find --type button                        # 要素の一覧（JSON）。全体は relay source
relay tap --id <identifier>                     # 要素を指定して操作
relay find --id <次の画面の要素> --timeout 5    # 結果を待ってから観察し直す
relay stop                                      # 自分で起動したときだけ。stopped か not running で 0
```

- **動いているランナーはそのまま使う。** `relay status` が 0 なら、利用者などがすでに起動しています。それを使い、止めないでください。`~/.relay/runner.json` のランナーが同じポート（`--port`、既定 8100）で応答していると `relay start --background` は起動せずに終了コード 1 で終わり `relay stop` を案内しますが、`relay stop` はフォアグラウンドの `relay start` も止めるので、止めてよいのは自分が起動したものだけです。
- **`relay status` が 4 なら止めずに確かめる。** 見つかった runner.json のトークンが、そのアドレスで応答しているランナーのものではありません（別の `relay start` のランナーが同じポートにいる、古い runner.json、`--runner` / `$RELAY_RUNNER` / カレントディレクトリから親へ順にたどった `.relay/runner.json` が別のものを指している）。自分で起動したものでなければ、`relay stop` や起動し直しをせずに利用者に確認します。
- **自分のランナーを覚えておく。** `relay start --background` が出す `pid:` を控え、終わるときは `relay status` の `pid` が同じであることを確かめてから `relay stop` します。
- **端末は明示する。** `--udid` / `--device` がないと、`relay start` は接続中の実機が 1 台ならそれ、なければ起動中のシミュレータが 1 台ならそれを選び、決まらなければ候補つきでエラーにします。実機がつながっているとシミュレータより実機が選ばれるので、利用者に実機を指定されていない限り、`relay devices` で選んだシミュレータを `--device` / `--udid` で指定します。同じ名前のシミュレータが複数ある（ランタイム違い）ときは `--udid` を使います。停止中のシミュレータを指定すると boot し、`relay stop` で shutdown します。
- `relay start --background` の進行状況（boot、ビルド、起動）は stderr の `relay:` 行に出ます。初回はランナーのビルドで数分かかるので、コマンドのタイムアウトを長めにします（起動まで最大 30 分、起動後は `--ready-timeout`（既定 180 秒）+ 15 秒待ちます）。
- 起動に失敗すると、子の `relay start` を止め、stderr にログの末尾と原因（ログのパス付き）を出して非ゼロで終わります。終了コードは、ready の前に子が終了した（ビルドの失敗、端末が見つからない、`Failed to initialize for UI testing` など）なら 1、時間切れなら 3、同じポートですでにランナーが応答しているなら 1 です。ログの末尾と、必要ならログファイル（`~/.relay/logs/start-<時刻>.log`）を読んでから対処します（[トラブルシューティング](reference.md#トラブルシューティング)）。
- 対象アプリは端末にインストール済みである必要があります（プロジェクトのやり方で Xcode や `xcodebuild` / `xcrun simctl install` でビルド・インストールする）。`relay launch` は起動・前面化だけです。
- バンドル ID はプロジェクトの `PRODUCT_BUNDLE_IDENTIFIER` で調べるか、アプリを前面にして `relay foreground` で確かめます。

## 観察

- `relay screenshot` は PNG を保存して絶対パスを 1 行出します。そのファイルを読んで画面を見ます。小さくしたいときは `-o <file>.jpg` か `--quality 0.5`（JPEG）。
- `relay find <セレクタ>` は一致した要素の `type`・`identifier`・`label`・`value`・`frame`・`enabled`・`index` を返します。要素を探すにはこれがいちばん速く、一致がなくても終了コード 0（`"count":0`）です。
- `relay source` は要素ツリー全体の JSON です（大きいので `jq` で絞るか `--max-depth <n>`）。人が読むなら `--format text`。どちらも `--bundle-id` がなければ前面アプリが対象です。
- スクリーンショットは利用者に見えるもの、ツリーは指定できるものです。画面の理解にはスクリーンショット、セレクタを決めるには `find` / `source` と、両方を使います。

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
- 座標（`relay tap <x> <y>`、`relay swipe <x1> <y1> <x2> <y2>`）は、表示の向きでの画面左上を原点とするポイント単位です。要素の `frame` や `relay health` の `screen.width` / `screen.height` から求め、スクリーンショットの画素から求めないでください（画素 = ポイント × scale）。座標は、スクロールなど要素で指定できない操作だけに使います（例: `relay swipe 200 700 200 200` で下から上へ）。
- 文字入力: 入力欄をタップしてから `relay type "text"`。確定は `--key return` を付けます。1 文字消すのは `relay key delete`。キーは `return`・`delete`・`space` だけです。`-` で始まる文字列は `relay type -- -text` のように `--` を挟みます。
- **sleep せずに待つ。** 画面が変わる操作の後は、次の画面にある要素を `relay find <セレクタ> --timeout <秒>`（最大 10 秒。`count` を確認）で待つか、`tap` / `press` に `--timeout` を付けて要素が現れるのを待たせます。もっと長く待つときは短い timeout を繰り返します。
- **画面が変わったら観察し直す。** frame、index、前面アプリは変わります。前の画面のセレクタや座標を確かめずに使い回さないでください。
- コマンドは 1 つずつ、前の結果を待ってから送ります。ランナーは一度に 1 コマンドしか実行せず、重なると busy（終了コード 5）になります。
- `relay launch` の直後は前面アプリが切り替え前のまま返ることがあります。対象を確実にしたいときは `find` / `tap` / `type` / `source` に `--bundle-id <id>` を付けます。

## 終了コード

| コード | 意味 | 対処 |
| --- | --- | --- |
| 0 | 成功 | – |
| 1 | 引数の誤りやローカルの失敗（何も送っていない） | コマンドを直す。`relay <command> --help` |
| 3 | ランナーに届かない（runner.json がない、接続できない） | `relay status`。runner.json がなければ `relay start --background …`。runner.json はあるが応答しない（`relay start` が強制終了されたなど）なら、`relay stop` で片付けてから起動 |
| 4 | トークンが拒否された（401）。runner.json が古いか、別のランナーのもの | `relay status` で URL・端末・PID を確かめ、`--runner` / `$RELAY_RUNNER` / カレントディレクトリから親へ順にたどった `.relay/runner.json` も確認。自分で起動したものなら `relay stop` → 起動し直す。そうでなければ止めずに利用者に確認 |
| 5 | busy（409）。別のコマンドを実行中 | 1 秒ほど待つか、`relay ping` が `"busy":false` になってから再試行 |
| 6 | 操作の失敗（422）: 要素が見つからない・1 つに決まらない・無効・画面外、キーボードのフォーカスがない | stderr の `reason` と `candidates` を読み、観察し直してセレクタを直す |
| 7 | リクエストの拒否（400 などの 4xx） | エラー文を読む。多くは値の範囲や対応外の値 |
| 8 | ランナーのエラー（5xx など） | 1 回だけ再試行。続くなら `relay status` とログを確認 |

成功時はランナーの JSON が stdout に、失敗時は stderr に出ます。stderr の `relay:` で始まる行は人向けのヒントです。`reason` ごとの対処は [reference.md](reference.md#操作が失敗したとき終了コード-6) にあります。

## 安全のために

- **対象アプリの外に出ない。** タスクに必要でない限り、設定、Safari、メッセージなど対象アプリ以外のアプリを開いたり操作したりしないでください。ほかのアプリに移ってしまったら、`relay button home` → `relay launch <bundle-id>` で戻ります。
- **状態をそろえてから始める。** 前の操作の影響を避けたいときは、`relay button home` → `relay launch <bundle-id>`（まっさらに起動し直すなら先に `relay terminate <bundle-id>`）。
- **パスワードや個人情報を勝手に入力しない。** 利用者から渡されたものだけを入力します。パスワードはコマンドラインに書かず（`ps` やシェルの履歴に残るため）、利用者が用意した環境変数やファイルから標準入力で渡します: `printf '%s' "$PASSWORD" | relay type --stdin`。
- **実機では破壊的な操作をしない。** データやアプリの削除、購入、メッセージやメールの送信、システム設定の変更、サインアウトなどは、事前に利用者に確認します。実機のスクリーンショットには個人情報が写りうるので、タスクに必要な範囲を超えて共有しないでください。
- **後片付け。** 向きを変えたら `relay orientation portrait` で戻し、アプリを妥当な画面に戻し、自分で起動したランナーだけを `relay stop` で止めます。

## よくある失敗

- `Failed to initialize for UI testing`（`Timed out while enabling automation mode.`）: 実機では 設定 > デベロッパ >「UI オートメーションを有効にする」をオンにしてもらう。シミュレータなら 1 回だけ起動し直す。
- 実機で「信頼されていないデベロッパ」: 設定 > 一般 > VPNとデバイス管理 で開発元を信頼してもらってから、起動し直す。
- 実機がロックされている: 利用者にロックを解除してもらう。
- ローカルネットワークの許可（実機で `--allow-wifi` のとき）: 端末のダイアログで許可してもらう。

どれも端末を手で操作する必要があるので、回避しようとせず、利用者に何をしてほしいかを伝えます。詳しくは [reference.md](reference.md#トラブルシューティング)。
