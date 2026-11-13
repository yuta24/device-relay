# 起動とセッション

relay の起動・停止、接続先の選択、並列セッション、sandbox の設定、ログの掃除を説明します。全体の入口は [README](../README.ja.md) です。

## バックグラウンドで動かす（relay start --background / status / stop）

`relay start --background` で起動すると、ターミナルを占有せずに端末を操作でき、`relay stop` で停止できます。エージェントや CI、スクリプトではこの流れを使います。`relay start` だけならフォアグラウンドで動き続けます。

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

### 起動の完了と失敗

`relay start --background [start の他のオプション]` は、同じオプションから `--background` だけを除いた `relay start` を新しいセッションとして起動します。端末を閉じても止まりません。

| 子の入出力 | 接続先 |
| --- | --- |
| stdin | `/dev/null` です。 |
| stdout・stderr | `~/.relay/logs/start-<時刻>-<port>.log` です。 |

親のコマンドはログを新しく作ってから子に渡します。同じ秒に別のポートで起動しても、同じポートですぐに起動し直しても、ほかの起動のログと混ざりません。

同じログ名があれば `-2`、`-3` … を付けます。`build-`・`runner-` のログも同じ名前の付け方です。

親はログを読み、`ready:` が出たら URL・端末・PID・ログのパスを表示して終了します。ready にならなければ子に SIGTERM を送り、ログの末尾と原因を表示します。

停止時はビルド中の xcodebuild を止め、relay が boot したシミュレータを shutdown します。停止処理が 180 秒以内に終わらなければ、子と子が起動したプロセスを強制終了します。

| 起動待ちの範囲 | 時間切れの上限 |
| --- | --- |
| シミュレータの boot とビルド | ランナー起動まで 30 分です。 |
| ランナー起動後 | ビルド完了から `--ready-timeout` + 15 秒です。 |

| 結果 | 終了コード |
| --- | --- |
| ready になった | `0` です。 |
| 子が ready の前に終了した | `1` です。 |
| 時間切れになった | `3` です。 |
| 待機中に Ctrl-C を押した | 子を止めて `1` です。 |

ready 前の終了には、ビルドの失敗、端末が見つからない場合、`Failed to initialize for UI testing` などを含みます。時間切れの終了コード `3` は、ランナーに届かないことを表します。

### ポートの予約と起動前の確認

同じポートで動かせる `relay start` は 1 つです。フォアグラウンドでもバックグラウンドでも、端末を選ぶ前から終了まで `~/.relay/locks/start-<port>.lock` を `flock` で保持します。ランナーの動作中も保持します。

そのポートで別の `relay start` が起動中か実行中なら、boot もビルドもせずに終了コード `1` で終わります。`--background` はロックを取ってから runner.json を確認し、子にロックを引き継ぐため、ほぼ同時に起動しても片方だけが進みます。

プロセスが終われば、強制終了でもロックは外れます。ロックファイルが残っていても次の起動を妨げません。

起動前に `~/.relay/runner.json` を確認します。その URL のポートと、新しく使う `--port` のポートで動作が分かれます。セッションなしの既定ポートは `8100` です。

| runner.json の状態 | 動作 |
| --- | --- |
| URL のポートが新しく使うポートと違う | 衝突しないので起動し、runner.json を後から起動したランナーで上書きします。 |
| URL のポートが同じ、または取り出せない | その URL へ `/ping` を送ります。 |
| ファイルがない | 起動に進みます。 |

ポートが違う場合の上書きは、フォアグラウンドで複数起動するときも同じです。`/ping` に何かが HTTP で応答した場合は、新しいランナーが待ち受けられないため、起動せず終了コード `1` で終わります。

| `/ping` の結果 | 案内・対処 |
| --- | --- |
| `200` | 動作中のランナーをそのまま使うか、`relay stop` で止めるか、`--port` で別のポートを使います。 |
| `401` | 別のトークンのランナーの可能性があるため、それを止めるか別のポートを使います。 |
| `404` など、その他の HTTP 応答 | 別の何かが待ち受けているため、それを止めるか別のポートを使います。 |
| 接続できない・タイムアウト | 起動に進みます。 |

`401` などで止める場合は、`relay stop` またはそのランナーを起動した `relay start` から止めます。

### 状態を確かめる（relay status）

`relay status [--json]` で、接続先と起動プロセス、ランナーの応答を確かめられます。runner.json は「[接続先の探し方](#接続先runnerjsonの探し方)」の順に探し、`--runner <path>` も使えます。

通常の表示には、URL、端末名と UDID、`relay start` の PID と動作中かどうか、起動時刻、`/ping` の結果と `busy`、ランナーの版が含まれます。

| ランナーの版の状態 | 表示 |
| --- | --- |
| 版を名乗る | `runner: 0.8.0 (sources <12 桁>)` の形で表示します。 |
| runner.json の期待値と違う | 違う旨を表示します。 |
| 版を名乗らない古いランナー | `not reported` と表示します。 |
| 応答がない | runner.json の期待値を表示します。 |

`--json` は次のキーを持つ JSON オブジェクトを 1 つ出します。

| キー | 内容・補足 |
| --- | --- |
| `alive` | ランナーの応答の有無です。 |
| `url` | 接続先の URL です。 |
| `udid`・`name` | 端末の UDID と名前です。 |
| `pid`・`processRunning` | `relay start` の PID と動作中かどうかです。 |
| `startedAt` | 起動時刻です。 |
| `hostBundleID` | ホストアプリのバンドル ID で、runner.json になければ `null` です。 |
| `session` | セッション名で、セッションなしなら `null` です。 |
| `ping` | `/ping` の結果です。 |
| `runner` | `/ping` が返した版で、なければ `null` です。 |
| `expectedRunner` | runner.json の期待値で、古い runner.json なら `null` です。 |
| `runnerInfo` | — |

| 結果 | 終了コード |
| --- | --- |
| ランナーが `/ping` に応答した | `0` です。 |
| runner.json がない、または応答がない | `3` です。 |
| トークンが拒否された（`401`） | `4` です。 |

### 停止と後片付け（relay stop）

`relay stop` で、フォアグラウンド・バックグラウンドのどちらの `relay start` も停止できます。runner.json に記録された `relay start` に SIGTERM を送り、その終了を待ちます。

停止はフォアグラウンドの Ctrl-C と同じ経路です。ランナーの `/shutdown`、relay が boot したシミュレータの shutdown、runner.json の削除を行います。

`relay start` が強制終了などで動いていないときは、runner.json の URL とトークンで `POST /shutdown` を送り、runner.json を削除します。

| 結果 | 表示・終了コード |
| --- | --- |
| 停止した | `stopped` と表示して `0` です。 |
| 180 秒以内に終了しない | `1` です。 |
| 何も動いていない | `not running` と表示して `0` です。 |

そのランナーの `relay record` による [録画](cli.md#録画relay-record) が残っていれば、ランナーを止める前に書き出し、保存先を stderr に出します。

runner.json には `relay start` の PID と秒単位の起動時刻を記録します。シグナルを送るのは、プロセスの起動時刻が一致し、実行ファイルが `relay`、最初の引数が `start` の場合だけです。PID が別のプロセスに再利用されても、そのプロセスには送りません。

### 強制終了したとき

`relay start` を `kill -9` などで強制終了すると、ロックは外れますが、xcodebuild とランナーが残ることがあります。
runner.json のランナーが応答していれば、同じセッションでは起動をエラーにするので、`relay stop --session <名前>` で止めてください。
別のセッションからその端末を使う場合は検出できません。

セッションなしの `relay` を強制終了した場合も `~/.relay/runner.json` が残ります。
サブコマンドは接続できずに終了コード `3`、別のランナーが同じポートにいれば `4` になります。
後片付けは「[停止と後片付け](#停止と後片付けrelay-stop)」を参照してください。

### shutdown と stop

普段の停止には、後片付けの完了まで待つ `relay stop` を使います。`relay shutdown` はランナーに `POST /shutdown` を送るだけで、`{"ok":true}` を返してすぐ終わります。

`relay shutdown` の後は、ランナーの終了を見た `relay start` が runner.json を削除し、boot したシミュレータを shutdown して終了します。いつ終わったかは `shutdown` からは分かりません。

`relay start` がもう動いていない場合、`shutdown` では runner.json が残りますが、`relay stop` なら片付きます。ヘルプ一覧の変更については [CHANGELOG 0.3.0](../CHANGELOG.md#cli-の破壊的な変更020-から) を参照してください。

シミュレータでは、shutdown の後の後片付けに数秒かかります。

### ping・health・status の使い分け

目的に応じて `relay ping`・`relay health`・`relay status` を使い分けられます。

| コマンド | 確かめること | ほかのコマンドの実行中 |
| --- | --- | --- |
| `ping` | 生きているか、操作中の `busy` かを端末に触れず即答します。 | 実行中でも返ります。 |
| `health` | 操作前に必要な画面サイズ・向き・タッチの経路・前面アプリを返します。 | `409`、終了コード `5` になります。 |
| `status` | runner.json と `relay start` の PID・端末・起動時刻・ランナーの版も確かめます。 | `/ping` の結果を含めて表示します。 |

`health` の画面サイズの単位は pt です。`status` は `relay start --background` の後の確認に使い、機械向けには `--json` を付けます。

## 接続先（runner.json）の探し方

relay は runner.json から URL とトークンを読み、操作するランナーを選びます。トークンは `ps` やシェルの履歴に残るため、コマンドライン引数では受け取りません。

### 探索の優先順位

接続先は次の順に探し、最初に見つかったものを使います。

| 順位 | 指定方法 |
| --- | --- |
| 1 | `--runner <path>` または `--session <名前>` を使います。 |
| 2 | 環境変数 `RELAY_RUNNER` にパス、または `RELAY_SESSION` にセッション名を設定します。 |
| 3 | セッションなしの `relay start` が書く `~/.relay/runner.json` を使います。 |

| 不正な指定 | 結果 |
| --- | --- |
| `--runner` と `--session` の併用 | 両方は指定できません。 |
| `RELAY_RUNNER` と `RELAY_SESSION` の両方を設定 | 接続先を決められず、書き方の誤りで終了コード `2` です。 |
| 不正なセッション名 | 終了コード `2` です。 |

オプションは環境変数より優先します。`RELAY_SESSION` が設定されていても `--runner` で別のファイルを指定できます。セッションのファイルは `~/.relay/sessions/<名前>/runner.json` です。

順位 1・2 で指定したファイルやセッションがなければ、順位 3 や他のセッションへ進まず、終了コード `3` で終わります。意図しない別の端末を操作しないためです。

`relay status`・`relay stop`・`relay record`・`relay run`・`relay bench` も同じ順です。`relay bench` は `--url` と `--token` を省いた分を、見つけたファイルから読みます。

### カレントディレクトリのファイル

カレントディレクトリや親の `.relay/runner.json` は読みません。使う場合は `--runner <path>` で指定します。探索方法が変わった経緯は [CHANGELOG 0.3.0](../CHANGELOG.md#cli-の破壊的な変更020-から) にあります。
読み込まないため、以前の版が残したファイルが原因の `401` は起きません。

`~/.relay/runner.json` がなく、カレントディレクトリか親に `.relay/runner.json` があるときだけ、近い順に親をたどり、エラーに次の文を足します。案内のためだけに調べ、ファイルは開きません。

```text
.relay/runner.json in <ディレクトリ> is no longer read; pass --runner <path> to use it
```

### 状態ファイルの書き出しと削除

セッションなしの `relay start` は、実行ディレクトリに関係なく `~/.relay/runner.json` だけに書き出します。パーミッションは `0600` です。対象アプリのリポジトリなど、カレントディレクトリに `.relay/` は作りません。

停止時は、自分のトークンがまだ書かれている場合だけ runner.json を削除します。`relay stop` が片付ける場合も同じです。

`--port` を分ければ複数起動できますが、セッションなしでは `~/.relay/runner.json` が最後の起動のものになり、前のランナーのトークンは残りません。`relay health` などが前のランナーに届かなくなるため、並列に動かすときは [名前付きセッション](#複数のセッションを並列に動かすrelay-start---session) を使ってください。

## 複数のセッションを並列に動かす（relay start --session）

名前付きセッションを使うと、複数のエージェントが別々の端末を干渉せずに操作できます。エージェントを起動するときに、環境変数 `RELAY_SESSION` を渡すのが基本です。各コマンドのシェルが値を引き継ぎ、そのセッションのランナーに届きます。

```sh
# ターミナル 1
RELAY_SESSION=agent-1 claude

# ターミナル 2（同時に）
RELAY_SESSION=agent-2 codex
```

エージェントの中では、`--session` を付けずに操作できます。

```sh
relay start --background --device "iPhone 17 Pro"   # agent-2 なら別の端末を指定する
relay tap --id relay.input
relay stop
```

環境変数を渡さずにエージェントを起動した場合は、各コマンドに毎回 `--session <名前>` を付けます。

```sh
relay start --background --session agent-1 --device "iPhone 17 Pro"
relay tap --session agent-1 --id relay.input
relay stop --session agent-1

relay status --all   # 全セッションの一覧
relay stop --all     # 全部止める（ほかのエージェントのものも）
```

### セッション名と指定方法

`--session <名前>` は `RELAY_SESSION` より優先します。パスの一部になるため、名前には次の規則があります。

| 項目 | 規則 |
| --- | --- |
| 先頭 | 英数字です。 |
| 使える文字 | 英数字と `.`・`_`・`-` です。 |
| 長さ | 64 文字までです。 |
| 大文字・小文字 | 区別しないボリュームでは `A` と `a` が同じセッションです。 |

APFS の既定では大文字と小文字を区別しません。`--session` は `relay start`・ランナー操作のコマンド・`relay status`・`relay stop`・`relay record`・`relay run`・`relay bench` で使えます。

セッションなしの使い方では `~/.relay/runner.json` を使います。セッションのファイルとは互いに読み書きしません。

### セッション指定が抜けたときの警告

セッション指定が抜けて `~/.relay/runner.json` を使ったとき、ほかのセッションが動いていれば stderr に警告を出します。別の誰かのランナーを操作している恐れがあるためです。

`export RELAY_SESSION=...` が効くのは、同じシェルでコマンドを続ける場合だけです。Claude Code の Bash ツールや Codex のようにコマンドごとに新しいシェルになる環境では、次のコマンドに残らず、セッションなしになります。

セッションなしで `~/.relay/runner.json` がなければ終了コード `3` で終わります。あれば、そのファイルが指す別の誰かのランナーを操作してしまいます。

```text
relay: warning: no session selected; using /Users/you/.relay/runner.json, while sessions agent-1, agent-2 are running; pass --session or set RELAY_SESSION
```

実際の警告文のパスとセッション名は、次の形です。

```text
relay: warning: no session selected; using <パス>, while sessions <名前> are running; pass --session or set RELAY_SESSION
```

対象は、セッション・`--runner`・`RELAY_RUNNER` のどれも指定しないランナー操作、`relay run`・`relay status`・`relay stop`・`relay record`・`relay bench` です。失敗にはせず、終了コードも変えません。

セッションなしのランナーを意図して使う場合は無視できます。警告を消すには `--runner` を指定します。

動作中かどうかは `~/.relay/sessions/*/runner.json` の存在か、`session.lock` が握られているかだけで調べます。ランナーへ問い合わせないため、コマンドは遅くなりません。

強制終了で残った runner.json も「動いている」と数えます。`relay stop --session <名前>` で片付きます。

### 状態ファイルとセッションの排他

名前付きセッションの状態は `~/.relay/sessions/<名前>/runner.json` にパーミッション `0600` で書きます。`~/.relay/runner.json` には書きません。接続先は「[探索の優先順位](#探索の優先順位)」に従います。

`relay start` は `~/.relay/sessions/<名前>/session.lock` を終了まで `flock` で保持するため、同じセッションは 2 つ起動できません。

強制終了後にランナーが残った場合は「[強制終了したとき](#強制終了したとき)」を参照してください。

### ポートの自動選択

名前付きセッションは、`--port` を省くと空いているポートを自動で選びます。

| 項目 | 選び方 |
| --- | --- |
| 探索範囲 | `8101`〜`8199` を順に調べます。 |
| 空きの条件 | `~/.relay/locks/start-<port>.lock` を取れて、Mac の `127.0.0.1` で bind できることです。 |
| `8100` | セッションなしの `relay start` のために空けます。 |
| `--port` を指定した場合 | 指定したポートを使います。 |

ロックを取ってから空きを調べ、ランナーが待ち受けるまで保持します。同時に起動しても同じポートにはなりません。選んだポートは runner.json に入り、`relay status` や `ready:` に出るため、利用者が把握しておく必要はありません。

この予約は `relay start` どうしでしか効きません。
空きを確かめてからランナーが待ち受けるまでの間（ビルドを含みます）に、ほかのプロセスが同じポートを使うと `relay start` は失敗します。
そのときは起動し直すか、`--port` で指定してください。

### 端末の排他と自動選択

1 台の端末で動かせるランナーは 1 つです。2 つ目の XCTest がテストのセッションを奪うためで、セッションなしの `relay start` にも適用されます。

`relay start` は端末を選んだ直後、boot とビルドの前に `~/.relay/locks/device-<UDID>.lock` を取り、終了まで `flock` で保持します。

使用中の端末を `--udid` や `--device` で指定すると、使っているセッション・PID・止め方を示し、終了コード `1` で終わります。別の端末へは移りません。

`--udid` も `--device` もない場合は、ほかの `relay start` が使用中の端末を候補から外し、次の順で選びます。

| 空いている候補 | 選び方 |
| --- | --- |
| 接続中の実機が 1 台 | その実機を選びます。 |
| 接続中の実機がなく、起動中のシミュレータが 1 台 | そのシミュレータを選びます。 |
| 接続中の実機が複数 | 候補付きのエラーになります。 |
| 起動中のシミュレータが複数、セッションなし | 候補付きのエラーになります。 |
| 起動中のシミュレータが複数、セッション付き | iOS の新しい順、名前の大文字小文字を無視した順、UDID の順で先頭を選びます。 |
| 空きがない | 使用中の端末とその持ち主も示すエラーになります。 |

セッション付きは `--session` または `$RELAY_SESSION` による指定です。シミュレータが複数の場合は、次のように選び方を表示します。

```text
the first of 3 free booted simulators (newest iOS, then name), for session <名前>
```

端末のロックを取る直前に、ほぼ同時に起動した別の `relay start` に取られたときは、次の文を出し、その端末を使用中に加えて選び直します。候補の数まで繰り返し、空きがなくなればエラーです。

```text
relay: <端末> was just taken by <持ち主>; selecting again
```

複数のセッションを同時に起動しても、この選び直しで残りの 1 台を取ります。

### 並列に使うシミュレータの用意

セッションごとにシミュレータを複製・作成することはしません。
並列に動かす台数のシミュレータは利用者が用意し、`--udid` / `--device` で分けます。
同じ機種名が OS ごとにあるので、同じ OS で並列に動かすときは `--os` か `--udid` で区別します。

`relay start` が boot したシミュレータは、その `relay start` の終了時に shutdown します（「[停止と後片付け](#停止と後片付けrelay-stop)」）。

### ビルドとテスト出力の共有

セッション間でも `~/.relay/build/…/DerivedData-*` の成果物を共有し、同じソースのビルドを使い回します。同じ DerivedData へのビルドは同時に 1 つだけです。後からの起動は次の文を出して待ち、完了したビルドを使います。

```text
relay: waiting for another relay start's build …
```

待機中に同じソースのビルドが終われば、`--rebuild` も満たされたものとします。ビルドしない起動どうしは並列に進みます。待機中も Ctrl-C と `relay stop` で止められます。

`~/.relay/locks/build-<ハッシュ>.lock` は、ビルド中は排他、成果物からのランナー起動から ready までは共有で保持します。起動途中で成果物が書き換わるのを防ぎます。`relay runner install --build` も同じロックを取ります。

`test-without-building` のログと xcresult は、ポートごとの `~/.relay/build/…/TestData/port-<port>/` に分けます。分ける理由は「[テスト実行の出力先](development.md#テスト実行の出力先)」を参照してください。

### ログと録画の分離

名前付きセッションでは、ログと既定の出力名にセッション名が入ります。

| 対象 | 名前・状態の単位 |
| --- | --- |
| `~/.relay/logs` の `start-`・`build-`・`runner-`・`record-` ログ | `<種類>-<時刻>-<セッション>-<port>.log` です。 |
| 既定の出力先のスクリーンショット・録画 | ファイル名にセッション名が入ります。 |
| 録画の状態 | ランナーごとに異なるポートで分けます。 |

ログと xcresult の保存件数・期間は「[ログとテスト結果の掃除](#ログとテスト結果の掃除)」を参照してください。

セッション付きの `relay record stop` / `status` は、そのセッションの runner.json がなければ終了コード `3` で終わります。ほかのセッションの録画へは進みません。止まったランナーの録画は `--port <n>` で指定できます。

### 全セッションの一覧と停止

`relay status --all` で、`~/.relay/runner.json` のランナーと全セッションを 1 行ずつ表示できます。前者の SESSION は `(default)` です。runner.json がなくロックも持たれていない、終了済みのセッションは表示しません。終了コードは状態によらず `0` です。

```text
SESSION  STATE      DEVICE                        URL                     PID
agent-1  running    iPhone 17 Pro (<SIM_UDID_1>)  http://127.0.0.1:8101/  12345
agent-2  starting   -                             -                       12346
agent-3  no answer  iPhone 17 (<SIM_UDID_2>)      http://127.0.0.1:8103/  12347 (exited)
```

| STATE | 意味 |
| --- | --- |
| `starting` | boot かビルドの途中で、まだ runner.json がありません。 |
| `running` | ランナーが動いています。 |
| `busy` | コマンドの実行中です。 |
| `no answer` | 応答がなく、`relay stop --session <名前>` で片付きます。 |
| `rejected` | そのポートで別のランナーが応答しています。 |
| `unknown` | sandbox などで接続が拒否されています。 |

`relay status --all --json` は 1 つの配列を出し、トークンを含めません。各要素のキーは次のとおりです。

| キー | 内容・補足 |
| --- | --- |
| `session` | セッション名で、`~/.relay/runner.json` なら `null` です。 |
| `state` | 一覧の状態です。 |
| `alive`・`url` | 応答の有無と接続先です。 |
| `udid`・`name` | 端末の UDID と名前です。 |
| `pid`・`processRunning` | 起動プロセスの PID と動作中かどうかです。 |
| `runnerInfo` | — |

`relay stop --all` は一覧の全部を順に止め、`<セッション>: stopped` を 1 行ずつ出します。ほかのエージェントのランナーも止めるため、エージェントは通常、自分のセッションだけを止めます。

`relay stop --session <名前>` は、boot やビルドの途中でまだ runner.json がないセッションも止めます。

## シミュレータへの接続

シミュレータのランナーは `127.0.0.1` だけで待ち受けるため、Mac の LAN 側のアドレスや、ほかのマシンからは直接接続できません。
IPv6 の `::1` でも待ち受けません。relay はシミュレータに `127.0.0.1` で接続するので、relay からの操作は変わりません。
待ち受けを限る理由と以前のビルドの挙動は「[コンセプト / アーキテクチャ](design.md#コンセプト--アーキテクチャ)」を参照してください。

## 外部コマンドが応答しないとき

`simctl`・`devicectl`・`xcrun`・`security` などは時間を区切って呼ぶので、応答がなければ relay は止まったままにならず、エラーを返します。
たとえば `xcrun simctl list devices --json timed out after 30 s` と表示します。

| 外部コマンドの用途 | 時間切れの上限 |
| --- | --- |
| 問い合わせ | 30 秒です。 |
| `devicectl` | 60 秒です。 |
| `simctl boot` | 5 分です。 |
| `bootstatus` | 10 分です。 |
| `shutdown` | 2 分です。 |

終了コードはほかの失敗と同じで、`relay doctor` は ✗ や `!` を出して先に進みます。
ビルドとランナーの実行自体には、この外部コマンドの時間制限はありません。

## エージェントの sandbox から使う

relay は sandbox の外で起動し、操作のコマンドにも接続を許可する設定で使います。Claude Code などはシェルコマンドを OS の sandbox で動かすことがあり、macOS では Seatbelt を使います。relay はそのままでは中で動きません。

### 起動・操作が拒否されたとき

`relay start` は sandbox の外で実行してください。`~/.relay` への書き込み、xcodebuild、testmanagerd の unix socket、CoreSimulator の XPC、疑似端末を使うため、書き込み先や socket を少し広げただけでは足りません。

`~/.relay` にはロック・ログ・ビルドを書きます。操作の `relay status`・`relay tap` なども、既定の sandbox ではランナーに届きません。

シミュレータのランナーは `127.0.0.1:<port>` で待ち受けますが、Claude Code の macOS の sandbox は localhost への直接接続を拒否します。relay は `Operation not permitted` と sandbox の可能性を示します。

| 拒否された操作 | 結果・対処 |
| --- | --- |
| ランナーへの接続 | 届かない場合と同じ終了コード `3` になります。 |
| 接続拒否時の `relay stop` | runner.json を消さず終了コード `3` で終わります。 |
| sandbox の外で動く `relay start` へのシグナル | 送れず終了コード `1` になるため、`relay stop` を sandbox の外で実行します。 |

シグナルを送れない場合は、次のメッセージです。

```text
cannot signal relay start (pid …): Operation not permitted; relay may be running inside a sandbox …
```

接続拒否はランナーの停止を意味しないので、`relay stop` や `relay start` をし直さないでください。

`relay doctor` は `127.0.0.1` への接続と `~/.relay` への書き込みを試し、`Operation not permitted` なら ✗ にします。sandbox を直接判定できないため「中で動いているようだ」という扱いで、同様に拒否するネットワークフィルタとも区別できません。

### Claude Code で sandbox の外に出す

Claude Code では `sandbox.excludedCommands` に relay を指定すると、sandbox の外で実行できます。いちばん簡単な設定です。

| 設定の範囲 | ファイル |
| --- | --- |
| ユーザー | `~/.claude/settings.json` です。 |
| プロジェクト | `.claude/settings.json` または `.claude/settings.local.json` です。 |

```json
{
  "sandbox": {
    "excludedCommands": ["relay *"]
  }
}
```

パターンは `Bash(...)` の許可ルールと同じ書き方です。`relay *` は relay の全コマンドに一致します。除外したコマンドも、通常の permission の確認は通ります。

除外が効くのは、1 回の Bash 呼び出しのコマンドすべてが一致した場合だけです。relay は 1 回に 1 コマンドで呼んでください。スクリーンショットは `-o <file>` で保存先を指定できます。

| 呼び出しに含むもの | 動作 |
| --- | --- |
| `cd app && relay tap …` | sandbox の中で動きます。 |
| `relay screenshot > out.png` のようなリダイレクト | sandbox の中で動きます。 |
| `$(…)`、`for`・`if` など | sandbox の中で動きます。 |

管理者が sandbox を必須にする admin-required の場合、プロジェクトの両設定ファイルの `excludedCommands` は無視されます。`~/.claude/settings.json` に書くか、管理者に相談してください。

### sandbox 内の操作コマンドに接続を許す

`sandbox.network.allowLocalBinding: true` を使うと、macOS の sandbox 内の操作コマンドが localhost のランナーに届きます。localhost の任意のポートへの接続と待ち受けを許す設定です。

localhost のほかのサービスすべてにも届くようになります。また、sandbox 内のコマンドが localhost 以外のアドレスで待ち受けると、ほかのマシンからの接続も受けうるようになります。

admin-required では、プロジェクトの `allowLocalBinding: true` も無視されます。`~/.claude/settings.json` に書けば効きます。

`relay start` は引き続き sandbox の外で起動する必要があるので、通常は `excludedCommands` を勧めます。次の許可を広げて `relay start` を中で動かす方法は試しておらず、勧めません。

| 設定 | 広げる範囲 |
| --- | --- |
| `sandbox.network.allowUnixSockets` | macOS で接続してよい unix socket のパスです。 |
| `sandbox.network.allowMachLookup` | XPC のサービス名です。 |
| `sandbox.filesystem.allowWrite` | 書き込み先です。 |

失敗したコマンドを sandbox の外でやり直す、Claude Code の `dangerouslyDisableSandbox` も使えます。許可の確認が出ますが、`sandbox.allowUnsandboxedCommands: false` では使えません。

### 実機・ほかのエージェント

実機のランナーへは、relay を sandbox の外で実行して接続します。アドレスは CoreDevice トンネルの IPv6 などで localhost ではなく、sandbox のプロキシを通らない直接接続が拒否されるためです。

ほかのエージェントやツールでも、シェルコマンドを sandbox で動かす場合は、relay、少なくとも `relay start` を外で動かす設定を使い、操作コマンドには localhost への接続を許してください。

Linux 系の sandbox のようにコマンドごとに別の loopback を持つ仕組みでは、localhost がホストのランナーに届きません。`connection refused` になるため、relay の判定でも sandbox とは分かりません。

Claude Code の設定の根拠: [Sandboxing](https://code.claude.com/docs/en/sandboxing)、[Settings reference の sandbox](https://code.claude.com/docs/en/settings-reference#sandbox)。

## ログとテスト結果の掃除

ログ・テスト結果・ビルドの古いものは、`relay start` が自動で削除します。ポートのロックを取った後、端末を選ぶ前に行います。`relay start --background` では、起動した側の `relay start` が消します。

`relay record start` も `record-` ログを同じように消します。ランナーを動かしたまま繰り返し録画するためで、ビルドは消しません。掃除用のコマンドはなく、普段は意識する必要はありません。

| 対象 | 残すもの |
| --- | --- |
| `~/.relay/logs/` の `start-`・`build-`・`runner-`・`record-` ログ | 更新から 7 日以内のすべてと、日数によらず種類ごとに新しい 20 件です。 |
| `~/.relay/build/*/TestData/port-<port>/Logs/Test/*.xcresult` | ポートごとに新しい 3 個と、更新から 1 時間以内のものです。 |
| `~/.relay/build/*/DerivedData-*/Logs/Test/*.xcresult` | ディレクトリごとに新しい 3 個と、更新から 1 時間以内のものです。 |
| `~/.relay/build/<ディレクトリ名>-<パスのハッシュ>` | 元の Runner プロジェクトがあり、最後に使ってから 30 日以内のものです。 |

### ビルドディレクトリ

ビルドディレクトリは、元の Runner がなくなるか、30 日使わないと、ディレクトリごと削除されます。必要になれば、次の `relay start` がビルドし直します。

`relay start` と `relay runner install --build` は、ディレクトリを作るか使い回すたびに、直下の `relay-build-dir.json` を書き直します。

```json
{"root": "<Runner の正規のパス>", "lastUsed": "<ISO 8601 の日時>"}
```

| 削除する条件 | 例・補足 |
| --- | --- |
| 記録の `root` に `Runner/RelayRunner.xcodeproj` がない | 古い版のディレクトリの削除、`mise prune`、worktree の削除、外付けボリュームの取り外しを同じように扱います。 |
| `lastUsed` から 30 日を過ぎた | `root` が残っていても、mise が残す古い版などを削除します。 |

記録がない場合は Xcode が書いた `DerivedData-*/info.plist` の `WorkspacePath` から `root` を読みます。値は `<root>/Runner/RelayRunner.xcodeproj` です。元の Runner がなければ消しますが、最後の使用日は分からないので 30 日の判定はしません。一度使えば記録が付きます。

| 削除しないもの・状況 | 判定・補足 |
| --- | --- |
| `~/.relay/build/installed` | `relay runner install` と `relay runner uninstall` が管理します。 |
| いま起動している `relay start` のディレクトリ | 削除しません。 |
| 使用中のディレクトリ | ポートのロック直後に書く `~/.relay/locks/start-<port>.build.json` と、runner.json の `buildDirectory` で分かります。 |
| ビルド・起動途中のディレクトリ | `~/.relay/locks/build-<ハッシュ>.lock` でも分かります。 |
| どのディレクトリを使うか不明な起動がある | その回はどのビルドディレクトリも削除しません。 |
| 出どころが確かでないもの | 下の条件に当てはまるものを残します。 |

使用先を特定できない `relay start` や runner.json がある場合、またはロックを取った直後の `relay start` がいる場合は、どれも使用先かもしれないため残します。特定できない状態は `relay stop` で解消します。

出どころが確かでないものは、次のとおりです。

- `root` から求めたディレクトリ名と実際の名前が違うものです。`info.plist` を使う場合の名前は `<root の最後の要素>-<12 桁の 16 進数>` です。
- 記録も `info.plist` もないものです。
- シンボリックリンク、`.` で始まる名前のものです。

削除時はまず `~/.relay/build/.removing-<ランダムな名前>` へ改名するため、同時起動の `relay start` が作りかけのディレクトリを見ることはありません。途中で止まり残った `.removing-*` は、次の起動で消します。量によっては起動が数秒長くかかります。

### 共通の規則

掃除では、使用中のログ・テスト結果や利用者の出力を保護します。使用中とみなすポートは次のとおりです。

| 条件 | 対象 |
| --- | --- |
| ほかの `relay start` が `~/.relay/locks/start-<port>.lock` を持つ | そのポートを使用中とみなします。 |
| runner.json が指す | セッションの runner.json も含め、そのポートを使用中とみなします。 |

使用中のポートの xcresult には触れず、ログは種類ごとに最新の 1 件を残します。何日も静かなランナーのログや、書き込み中でも更新日時が変わらない実行中の xcresult も、この判定で残ります。

録画中のログは `~/.relay/recording-<port>.json` が指すので残します。同時起動の `relay start` が同じものを消しても問題ありません。

次のものも削除しません。

- 上記の名前の形でないファイルです。利用者のファイルなどが該当します。
- `LogStoreManifest.plist` です。消した xcresult の記載は、次の実行時に xcodebuild 自身が外します。
- 残すビルドディレクトリのビルド成果物と、ロックファイルです。
- `~/.relay/sessions/<名前>/` と、`relay screenshot`・`relay record` の出力ファイルです。

削除に失敗しても起動を止めません。消せないものがあれば `relay: cannot remove …` を 1 行出して続け、消せた場合は何も表示しません。

調査に使うログや xcresult は `~/.relay` の外へコピーしてください。すぐ消したい場合、ランナーが動いていなければ `~/.relay/logs` の中身を削除してかまいません。

### 以前の relay が残した画面録画

以前の relay では、ランナーが動いている間ずっと XCTest が画面を録画していました。その動画がシミュレータに残っていることがあります。
今の relay は録画させません（「[テストのログと結果の保存先](setup.md#テストのログと結果の保存先)」）。以前の動画は relay が自動では消しません。

シミュレータでは、testmanagerd の一時ディレクトリに残っています。1 台で数 GB になることがあります。
ファイル名は UUID だけで拡張子がないので、`file` で QuickTime の動画か確かめます。

```sh
file ~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/InternalDaemon/*/tmp/Attachments/*
du -sh ~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/InternalDaemon/*/tmp/Attachments
```

ほかの UI テストの添付も同じ場所に入ります。中身と日時を確かめてから消してください。
消すときは、先に `relay stop` とそのシミュレータの `xcrun simctl shutdown <UDID>` で止めてから、そのファイルを削除します。
`xcrun simctl erase <UDID>` でも消えますが、シミュレータの中身がすべて消えます。

実機にも同じように残っている可能性がありますが、場所はホストから確かめられません。
