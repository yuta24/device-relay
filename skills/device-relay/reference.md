# device-relay リファレンス

[SKILL.md](SKILL.md) の補足です。ここにないことは device-relay の README と docs/ の各文書（ファイル名と節の名前を「」で示します）か `relay --help` / `relay <command> --help` を見てください。`--help` はランナー操作のコマンド（`screenshot`・`tap` など）、`status`・`stop`・`record`、`relay skill` にあります。`start`・`doctor`・`devices`・`install` は `relay --help` の全体のヘルプに書かれています。

## ランナーの起動・確認・停止

| コマンド | 内容 |
| --- | --- |
| `relay status [--json] [--runner <path> \| --session <name> \| --all]` | runner.json のランナーの URL・端末・`relay start` の PID・起動時刻と `/ping` の結果。下の「start --background / status / stop」。`--all` は全セッションの一覧（下の「セッション」） |
| `relay start --background [オプション]` | `relay start` を端末から切り離して起動し、ready になったら戻ります。同上 |
| `relay stop [--runner <path> \| --session <name> \| --all]` | runner.json の `relay start` を止めます（ランナー、relay が boot したシミュレータ、runner.json も片付く）。同上。`--all` はほかのエージェントのものも止めます |
| `relay devices [--json] [--os <version>]` | 実機とシミュレータの一覧（NAME、UDID、KIND、OS、STATE）。`--os` でその OS のものだけ |
| `relay doctor [--udid <UDID> \| --device <名前>] [--simulator] [--os <version>] [--project <path>] [--json]` | Xcode、Runner、署名、端末（同じ指定の `relay start` が使うもの）を確認。✗ があれば 1。`--json` は 1 行の JSON オブジェクト `{"ok":…,"problems":n,"warnings":n,"checks":[{"section","name","status":"ok"\|"warning"\|"problem","detail","fix"}]}`（`fix` は ok で `null`）だけを出す（終了コードは同じ） |
| `relay ping` | `{"ok":true,"busy":<bool>,"busyForMs":<ms or null>,"runner":{"version":…,"sourceHash":…}}`。生きているか・busy かの即答で、操作中でも返ります（端末には触れません）。`runner` はランナーをビルドした relay とソースのハッシュ（古いランナーにはない） |
| `relay skill status` | このスキルの取り出し元とインストール先（プロジェクト・グローバル）、relay とのバージョンのずれ（!）。入れ直しは `relay skill install [--global \| --dir <skills dir>]`（利用者に確認してから）。詳しくは `relay skill --help` |
| `relay health` | 操作の前に要る情報（操作中は 409 で終了コード 5。busy でも調べるなら `relay ping`）。端末情報、表示の向きでの画面サイズ（`screen.width` / `height` / `scale`）、`orientation`、`foreground`、表示の一覧 `displays` と前面アプリの表示 `display`、ランナーの版 `runner` |

`relay start` の主なオプション（`--background` と組み合わせられます）:

| オプション | 説明 |
| --- | --- |
| `--udid <UDID>` / `--device <名前>` | 使う端末。同時には指定できません。名前は完全一致（大文字小文字は無視）。同じ名前が複数あれば、接続中・起動中の 1 つ、なければ最も新しい iOS のシミュレータ。実機とシミュレータが同じ名前なら候補つきのエラー |
| `--simulator` | シミュレータだけから選ぶ（実機がつながっていても）。`--device` なしでは起動中の 1 台。起動中がなければエラーになるので `--device` で名前を指定する |
| `--os <version>` | OS で候補を絞る。`.` ごとの前方一致（`27` は 27.x、`26.5` は 26.5.x） |
| `--port 8100` | 端末側の待ち受けポート。同じ Mac で別の `relay start` と同時に動かすときは分けます（セッションでは省略すると `8101`〜`8199` の空きを選ぶ） |
| `--session <name>` | セッション名（`$RELAY_SESSION` でも可）。下の「セッション」 |
| `--rebuild` | 既存のビルドがあってもランナーを再ビルド（Runner のソース、Xcode の SDK、バンドル ID の接頭辞が変わったときは、付けなくても再ビルドする） |
| `--ready-timeout 180` | ready まで待つ秒数 |
| `--team-id <TEAM_ID>` | 実機の署名チーム（通常は自動検出） |
| `--project <path>` | Runner プロジェクトの場所（通常は `relay install` したもの） |
| `--verbose` | xcodebuild の出力をそのまま表示 |
| `--allow-wifi` | 実機で Wi-Fi のアドレスも使う。トークンと画面が平文で LAN を流れるので、利用者に頼まれたときだけ |

`--background` では、ランナーの起動まで（シミュレータの boot とビルド）を最大 30 分、起動後は `--ready-timeout` + 15 秒待ちます。

### start --background / status / stop

詳しくは device-relay の docs/setup.md の「バックグラウンドで動かす」。

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
runner:      0.2.0 (sources <12 桁>)
runner.json: /Users/<you>/.relay/runner.json
```

`runner.json:` も絶対パスで出ます。

`--json` は 1 つのオブジェクトです: `alive`（`/ping` が 200 か）、`url`、`udid`、`name`、`pid`、`processRunning`（その `relay start` がまだ動いているか）、`startedAt`（ISO 8601）、`ping`（`{"status":200,"busy":…,"busyForMs":…}`、`{"status":401}` など、応答がなければ `{"error":"…"}`）、`runner`（`/ping` が返したランナーの版 `{"version":…,"sourceHash":…}`。古いランナーや応答なしなら `null`）、`expectedRunner`（`relay start` が runner.json に保存した期待値）、`runnerInfo`（runner.json のパス）。値がないものは `null` です。runner.json がなければ `{"alive":false,"error":"…"}` だけを出します。

| 終了コード | 場合 |
| --- | --- |
| 0 | `/ping` に応答した |
| 3 | runner.json がない、または応答しない（stderr に「relay stop で片付け、relay start --background で起動」の案内。`--json` なら `{"alive":false,"ok":false,"code":"runner_unavailable",…}` も stdout に出る） |
| 4 | トークンが拒否された（401）。runner.json が、そのアドレスで動いているランナーのものではない（別の `relay start`、古いファイル、`--runner` / `$RELAY_RUNNER` / `~/.relay/runner.json`。カレントディレクトリの `.relay/runner.json` は読みません）。自分で起動したものでなければ利用者に確認する |
| ほか | `/ping` がそれ以外の HTTP 状態を返した（ランナー操作のコマンドと同じ対応: 404 などは 7、5xx は 8） |

**`relay stop`**: runner.json の `relay start` に SIGTERM を送り、終わるのを待ちます（Ctrl-C と同じ経路で、ランナーの `/shutdown`、relay が boot したシミュレータの shutdown、runner.json の削除）。フォアグラウンドの `relay start` も止まるので、自分で起動したものにだけ使います。

| 出力・終了コード | 場合 |
| --- | --- |
| `stopped`、0 | 止めた。`relay start` がもう動いていなかった場合は、ランナーに `/shutdown` を送って runner.json を削除した |
| `not running`、0 | 何も動いていない（runner.json がない、応答しない古い runner.json を削除した） |
| 1 | `relay start` が 60 秒以内に終わらなかった。`~/.relay/logs/start-*.log` を見て、利用者に知らせる |

実機の準備（デベロッパモード、ペアリング、UI オートメーション、Team ID）は device-relay の docs/setup.md の「実機」「Team ID（実機の署名）」を参照してください。

## 録画（relay record）

動作の証拠を残すときは `relay record start` → 操作 → `relay record stop` です。シミュレータ（ホストの `simctl io recordVideo`）と、USB で接続した実機（Mac のキャプチャデバイスとして、QuickTime と同じ仕組み）で使えます。実機は relay を動かすアプリ（ターミナルなど）に macOS のカメラの許可が要り、初回の `record start` がダイアログで求めます。詳しくは docs/cli.md の「録画（relay record）」と `relay record --help`。

| コマンド | 出力・終了コード |
| --- | --- |
| `relay record start [-o <file>] [--force] [--max-duration 600] [--runner <path> \| --session <name>]` | 録画が始まったら保存先の絶対パスを stdout に出して 0。既定は `$TMPDIR/relay/relay-recording-<時刻>.mp4`、相対パスはカレントディレクトリ基準。1: シミュレータが boot していない、実機が USB で接続されていない（Wi-Fi だけ・未接続）、カメラの許可がない（利用者に システム設定 > プライバシーとセキュリティ > カメラ で許可してもらう）、端末の画面がキャプチャデバイスとして現れない（USB 接続・ロック解除・「信頼」を利用者に頼む）、同じ名前の実機が複数つながっている、ディレクトリがない、ファイルがすでにある（`--force` で上書き。利用者のファイルなら上書きしてよいか確認）、すでに録画中、録画が始まらない（stderr に simctl か録画プロセスの出力）。3: ランナーがない・応答しない |
| `relay record stop [--runner <path> \| --session <name> \| --port <n>]` | 書き出しを待ち（最大 30 秒）、空でない MP4 の絶対パスを stdout に出して 0。録画していなければ `not recording` で 0。自動停止（`--max-duration`）した録画もここで取り出す。1: 書き出しが終わらない（もう一度 stop できる）、動画が空、runner.json がなく録画が複数ある（ポートごとの一覧から `--port <n>` で選ぶ） |
| `relay record status [--json] [--runner <path> \| --session <name> \| --port <n>]` | 録画中か（`yes` / `ended`）、保存先、経過時間。実機のフレームが 5 秒以上来ていなければ `frames:` の行（`--json` では `stall`）。常に 0 |

- 録画はターミナルから切り離して続くので、`record start` の後に別のコマンドを続けて実行できます。`relay stop` も録画を先に書き出します（パスは stderr）。
- シミュレータが録画中に shutdown しても、実機が録画中に外されても、`record stop` はそこまでの動画を返します。
- 実機の `record stop` は 4 秒ほどかかります（直後の `record start` が画面を見つけられるように待つため）。別の録画が止まった直後の `record start` は、新しいプロセスでもう一度試すので 20 秒ほどかかることがあります。
- 実機が録画中にロックされるなどしてフレームが止まっても、録画は続きます（動画は最後のフレームのまま）。`record status` に `frames: no frame for 5s …` が出ていたら、利用者にロックの解除を頼みます。
- 実機の動画は `-o` が `.mov` のときだけ QuickTime ムービー、それ以外は MP4（どちらも H.264、音声なし）です。

## sandbox の中から使う

Claude Code などがシェルコマンドを sandbox（macOS では Seatbelt）で動かすと、relay は次のようになります。

| 症状 | 意味 |
| --- | --- |
| `relay start` が `~/.relay/locks` を作れない、DerivedData に書けない、testmanagerd の socket につなげない、疑似端末を作れない | `relay start` は sandbox の中では動かない。sandbox の外で起動する |
| `cannot reach the runner at http://127.0.0.1:8100/: the OS refused the connection (Operation not permitted); relay may be running inside a sandbox …`（終了コード 3） | ランナーは動いているかもしれない。relay の接続が OS に拒否された。`relay stop`・`relay start` をし直さない（`relay stop` もこの場合は runner.json を消さずに 3 で終わる） |
| `relay doctor` の `✗ localhost` / `✗ ~/.relay`（`Operation not permitted`） | 127.0.0.1 への接続か `~/.relay` への書き込みが拒否された。sandbox の中で動いているようだ |
| `relay stop` が `cannot signal relay start (pid …): Operation not permitted; relay may be running inside a sandbox …`（終了コード 1） | sandbox の外で動いている `relay start` に、sandbox の中からシグナルを送れない。`relay stop` を sandbox の外で実行してもらう（引数の誤りではない） |

推奨は relay を sandbox の外で動かすことです。利用者に、Claude Code の設定（`~/.claude/settings.json`、またはプロジェクトの `.claude/settings.json` / `.claude/settings.local.json`）に次を足してもらいます（エージェントが断りなく書き換えないこと）。

```json
{
  "sandbox": {
    "excludedCommands": ["relay *"]
  }
}
```

- 除外は Bash の 1 回の呼び出しの中のコマンドがすべて一致したときだけ効きます。`cd … && relay …`、`relay … > file`、`$(relay …)`、`for` / `if` の中では sandbox に戻るので、relay は単独で呼びます（保存先は `-o <file>` で指定する）。
- 管理者が sandbox を必須にしているとリポジトリの設定の `excludedCommands` は無視されます（`~/.claude/settings.json` なら効く）。
- 操作のコマンドだけを sandbox の中から通すなら `"network": {"allowLocalBinding": true}`（macOS。localhost のすべてのポートに届くようになり、localhost 以外で待ち受けるコマンドはほかのマシンからの接続も受けうる。管理者が sandbox を必須にしているとリポジトリの設定の `true` は無視される（`~/.claude/settings.json` なら効く））。それでも `relay start` は外で起動が要るので、通常は `excludedCommands` を使う。
- 実機のランナーは localhost ではなく CoreDevice トンネルのアドレスなので、やはり sandbox の外で動かす。
- ほかのエージェントでも同じで、relay を sandbox の外で動かす設定を使う。詳しくは device-relay の docs/setup.md の「エージェントの sandbox から使う」。

## 接続先（runner.json）

ランナー操作のコマンドは、URL とトークンを次の順に探した runner.json から読みます（トークンはコマンドラインでは渡せません）。

1. `--runner <path>` か `--session <name>`（両方は不可）
2. 環境変数 `RELAY_RUNNER` か `RELAY_SESSION`（両方あると書き方の誤りで終了コード 2）
3. `~/.relay/runner.json`（セッションなしの `relay start` が書く場所）

1・2 で指定したファイルやセッションがなければ、3 を見ずに終了コード 3 です。カレントディレクトリや親の `.relay/runner.json` は読みません（以前の版が残した古いファイルによる 401 を防ぐため）。3 がなくてそのようなファイルがあるときは、エラーの文に `.relay/runner.json in <dir> is no longer read; pass --runner <path> to use it` と出ます。手で置いたファイルは `--runner <path>` で使います。終了コード 4 が続くときは、`--runner` / `$RELAY_RUNNER` が古いファイルを指していないか確かめます。

### セッション

複数のエージェントが並列に使うときは、セッションを分けます（名前は英数字で始まる、英数字と `.`・`_`・`-` の 64 文字まで）。`$RELAY_SESSION` が設定されていなければ、各コマンドに毎回 `--session <name>` を付けます。コマンドごとに新しいシェルになる環境では `export` は次のコマンドに残りません。

| 分かれるもの | 内容 |
| --- | --- |
| runner.json | `~/.relay/sessions/<name>/runner.json`。`~/.relay/runner.json` には書かず、ほかのファイルへも進まない |
| ポート | `--port` を省くと `8101`〜`8199` の空き。`ready:` の行に出る。予約は `relay start` どうしだけなので、ほかのプロセスが先に取るとランナーの起動に失敗する（ログに `Address already in use`）。もう一度起動すれば次の空きを選ぶ |
| 端末 | 1 台に 1 ランナー（セッションなしも同じ）。使用中の端末を指定すると、持ち主つきのエラーで終了コード 1。端末を省くと使用中のものは候補から外す |
| ビルド | 共有。同じ DerivedData へのビルドは 1 つずつで、ほかの起動のビルド中と、同じビルドからの起動中（ready まで）は `waiting for another relay start's build` と出して待つ。数分かかることがあるが失敗ではない |
| ログ | `~/.relay/logs/start-<時刻>-<name>-<port>.log` など |

セッションなしのコマンドが 3・4 のファイルを使い、ほかにセッションが動いていれば、stderr に `relay: warning: no session selected; using <path>, while sessions <names> are running; pass --session or set RELAY_SESSION` が出ます。終了コードは変わりません。

`relay status --all [--json]` は、全セッションと `~/.relay/runner.json` のランナー（`(default)`。JSON の `session` は `null`）を一覧します（SESSION、STATE、DEVICE、URL、PID）。STATE は `starting`、`running`、`busy`、`no answer`、`rejected`、`unknown`。終了コードは常に 0。`relay stop --session <name>` はビルド中のセッションも止めます。詳しくは device-relay の docs/setup.md の「複数のセッションを並列に動かす」。

## コマンドとオプション

| コマンド | 使い方 |
| --- | --- |
| `screenshot` | `relay screenshot [-o <file>\|-] [--format png\|jpeg] [--quality 0.05-1.0] [--max-size <px>] [--scale <px/pt>]`。保存先の絶対パスを 1 行出します（既定は `$TMPDIR/relay/screenshot-<時刻>.png`）。`.jpg` / `.jpeg` の拡張子か `--quality` で JPEG（既定の quality 0.7）。`--max-size` は長辺の画素数、`--scale` は 1 ポイントあたりの画素数の上限で、端末側で縮小します（両方なら小さい方。拡大はしない）。縮小したときは stderr に画像と画面の大きさと px/pt を出します（下の「座標と向き」） |
| `source` | `relay source [--format json\|text\|compact] [--filter interactive] [--max-depth <n>] [--bundle-id <id>]`。`--max-depth 0` はルートだけ。`compact` は 1 行 1 要素、`--filter interactive` は操作できる要素だけ（下の「要素ツリーの形式」） |
| `find` | `relay find <selector> [--limit 20] [--timeout <s>] [--require] [--bundle-id <id>]`。`--limit` は 1–100、`--timeout` は最大 10 秒。一致がなくても終了コード 0（`"count":0`）、`--require` なら 6 |
| `tap` | `relay tap (<x> <y> \| <selector>) [--mode private\|xcui] [--timeout <s>] [--bundle-id <id>]`。`--timeout`・`--bundle-id` はセレクタのときだけ |
| `press` | `relay press (<x> <y> \| <selector>) [--duration 1.0] [--mode private\|xcui] [--timeout <s>] [--bundle-id <id>]` |
| `swipe` | `relay swipe <x1> <y1> <x2> <y2> [--duration 0.3] [--hold 0.05] [--mode private\|xcui]`。始点で `--hold` 秒止まってから `--duration` 秒かけて終点へ |
| `type` | `relay type [<text> \| --stdin] [--key return\|delete\|space]... [--bundle-id <id>]`。`--key` は複数可、文字の後に順に送ります。入力し終わるまで返らず（シミュレータで約 15 ms/文字）、応答を 30 秒 + 1 文字 0.1 秒 + キー 1 つ 1 秒まで待ちます |
| `key` | `relay key return\|delete\|space [--bundle-id <id>]` |
| `button` | `relay button home\|volumeUp\|volumeDown`（音量ボタンは実機のみ） |
| `orientation` | `relay orientation portrait\|portraitUpsideDown\|landscapeLeft\|landscapeRight\|landscape`（`landscape` は `landscapeLeft` の別名） |
| `launch` / `terminate` | `relay launch <bundle-id>` / `relay terminate <bundle-id>`。アプリが起動・終了するまで返らず、応答を最大 150 秒（30 + 120 秒）待ちます。`launch` は入っていないアプリならランナーに送らず、すぐに終了コード 6（`app_not_installed`）。確かめられないときは `cannot tell whether …` を出して送ります |
| `foreground` | 前面アプリの `bundleId` と `pid` |

- `relay shutdown` は一覧に載せていません。普段は `relay stop` を使います。`shutdown` はランナーに `/shutdown` を送って `{"ok":true}` で即座に戻るだけで、runner.json の削除とシミュレータの shutdown は、ランナーの終了を見た `relay start` が数秒後に行います（終わったかどうかは分かりません）。`relay start` がもう動いていなければ runner.json が残ります。`relay stop` は終了まで待って `stopped` を出します。
- 応答を待つのは 30 秒に、その操作が待ちうる時間（`--timeout`、`--duration`、`--hold`、上の `type` / `launch` / `terminate`、`key` は 1 秒）を足した長さです。自分のコマンド実行のタイムアウトはそれより長くします。時間切れ（`no response within <秒>s`、終了コード 3）でもランナーはその操作を続けていて、終わるまでほかのコマンドは 409（終了コード 5）なので、`relay ping` の `busy` が `false` になるのを待ってから続けます。`launch` の時間切れは数分続くことがあります。busy の間も `relay stop` は効くので、自分で起動したランナーなら止めて起動し直すほうが早く戻ります。
- `--type` の名前、キー名、ボタン名、向き、数値の範囲は送る前に確認され、間違っていれば書き方の誤りで終了コード 2、何も送りません（例: `relay key tab` → `unsupported key 'tab'`）。
- `--mode` は通常指定しません（既定の `private` が速い。`xcui` はアプリのアイドルを待つので 1 回 1–2 秒）。

## シナリオの実行（relay run、実験的）

実験的な機能です。手順の書き方や出力は今後変わることがあります。決まった手順や、一度確かめた手順を 1 回の呼び出しで再生するときに使えます。

```sh
relay run steps.relay        # ファイル（1 行 1 手順。空行と # で始まる行は無視）
relay run - < steps.relay    # 標準入力
relay run --step "launch <bundle-id>" --step "tap --id login.button --timeout 5" --step "find --id home.title --timeout 5 --require"
relay run steps.relay --check   # 検証だけ（ランナー不要、何も実行しない。問題なければ 0）
```

- 手順は `relay` を除いたランナー操作のコマンド（`tap`・`press`・`swipe`・`type`・`key`・`button`・`orientation`・`launch`・`terminate`・`find`・`source`・`screenshot`・`health`・`foreground`・`ping`）と `sleep <秒>`（60 秒まで）です。`start` / `stop` / `shutdown` などは書けません。
- 語の区切りはシェル風（空白、`'...'`、`"..."`、`\`）です。`--runner` は `relay run` 側に付け、手順には書けません。`type --stdin` も使えません。`screenshot` は `--output <file>` が必須です。
- 保存するシナリオは、最初の行に `# relay-run: 1`（形式の版）を書きます。対応しない版なら、その行のエラーで何も実行しません。
- 実行前に全行を確かめ、不正な行があれば `relay: line <N>: <理由>` を出して何も実行せず終了コード 2（stderr のみ）。書いたシナリオは、流す前に `--check` で確かめられます。
- 実行中は最初に失敗した手順で止まり、その手順のエラーと `relay: step i/n (line N) failed: <手順>` を出して、その手順の終了コード（1・3〜8。1 はスクリーンショットを保存できなかったとき）で終わります。
- 手順は単独のコマンドと同じ意味です。確認したい要素は `find <セレクタ> --timeout <秒> --require` で待ち、現れなければそこで止めます（終了コード 6）。`--require` のない `find` は一致がなくても先に進みます。固定の `sleep` は最後の手段です。
- 各手順の stdout（失敗した手順の `{"ok":false,"code":…}` も）はそのまま stdout に、手順ごとの進行（`relay: [i/n] … ok (… ms)`）と合計は stderr に出ます（`--quiet` で消える）。進行行と失敗行では `type` の文字列を `***` に伏せますが、シナリオのファイルには書いたまま残ります。利用者から渡されたパスワードをシナリオに書かないでください（1 コマンドずつ `relay type --stdin` を使う）。

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

stdout に JSON が出ます（`relay screenshot -o -` だけは stderr）。

```json
{"candidates":[…],"code":"element_ambiguous","count":2,"error":"2 elements match the selector; add conditions or an index","ok":false,"reason":"ambiguous"}
```

要素の失敗の `code` は `element_not_found`（`notFound`・`indexOutOfRange`）、`element_ambiguous`（`ambiguous`）、`element_not_hittable`（`emptyFrame`・`offscreen`・`disabled`）で、`reason` がその詳細です。

| `reason` | 意味 | 対処 |
| --- | --- | --- |
| `notFound` | 一致なし | 画面がまだ変わっていない → `--timeout` を付ける。前面アプリが違う → `relay foreground`、`--bundle-id`。名前が違う → `relay find --type …` / `relay source` で実際の値を確かめる |
| `ambiguous` | 2 件以上一致して `--index` がない（待たずにすぐ返る） | `candidates` を見て `--type` などの条件か `--index` を足す |
| `indexOutOfRange` | `--index` が一致件数以上 | `relay find` で件数を確かめる |
| `emptyFrame` | 要素の幅か高さが 0 | 表示されていない。画面を観察し直す |
| `offscreen` | 要素が画面の外 | `relay swipe` でスクロールしてから探し直す |
| `disabled` | 要素が `enabled: false` | 前提の入力・操作が足りない。画面を確かめる |

`relay type` / `relay key` で `no_keyboard_focus`（`no element has keyboard focus in <bundleId>`）が出たら、入力欄をタップしてから送り直します（判定に 2–3 秒かかります）。

### code の一覧

失敗時の JSON は `{"ok":false,"code":"…","error":"…"}` です。`code` は変わらない文字列なので、これで分岐します（`error` の文言は変わりえます）。`code` がない応答は古いランナーのものです。

| `code` | 終了コード | 対処 |
| --- | --- | --- |
| `invalid_request` | 7 | エラー文を読んで値を直す |
| `point_offscreen` | 7 | `relay health` の `screen` を読み直して座標を直す |
| `touch_mode_unavailable` | 7 / 6 | `--mode` を外して送り直す |
| `http_malformed` / `request_too_large` | 7 / 8 | relay 経由では起きない。curl などのクライアントを直す |
| `unauthorized` | 4 | 上の終了コード 4 と同じ |
| `busy` | 5 | 待って再試行 |
| `not_found` / `method_not_allowed` | 7 | パス・メソッドの誤り。relay のコマンドで出たらランナーが古い（自分で起動したものなら `relay stop` → `relay start --rebuild`） |
| `element_not_found` / `element_ambiguous` / `element_not_hittable` | 6 | 上の `reason` の表 |
| `no_keyboard_focus` | 6 | 入力欄をタップしてから送り直す |
| `display_unknown` | 6 | 画面が暗い。利用者に確かめる |
| `window_position_unknown` | 6 | iPad のウィンドウの位置が不明。ウィンドウを 1 つにするか、スクリーンショットから座標で指定する |
| `touch_failed` | 6 / 8 | 1 回だけ再試行。続くなら `relay status` とログ |
| `xcui_failed` | 6 | エラー文（XCUI の文）を読み、前面アプリと画面を観察し直す |
| `app_not_installed` | 6 | relay が送る前に判定（ランナーは返さない）。バンドル ID を確かめるか、アプリをインストールする |
| `internal_error` | 8 | 1 回だけ再試行。続くなら `relay status` とログ |

## 座標と向き

- 座標は前面アプリの表示の向きでの、画面左上を原点とするポイント単位です。縦向きなら `relay health` の `screen` が例えば 402×874、横向きなら 874×402 になります。
- フル解像度のスクリーンショットの画素は `screen.width × scale` × `screen.height × scale` です。画像上の位置から座標を出すときは scale で割ります。
- `--scale 1` の画像は画素 = ポイントです（iPhone 17 Pro の縦向きで 402×874）。`--max-size` などで縮小した画像は、stderr の `relay: image 471x1024 px, screen 402x874 pt, 1.172 px/pt (tap in points: px / 1.172)` の px/pt で割ります（例: (120, 375) px → (102, 320) pt）。curl では応答ヘッダー `X-Relay-Image-Scale` などで同じ値が得られます。
- タップやスワイプの座標は、どの画像を使っても常にポイントです。
- 座標は `0 ≤ x < screen.width`、`0 ≤ y < screen.height`（表示の向き）の中でなければなりません。外なら何も送らずに 400（終了コード 7）で、`invalid field: x, y: (500, 100) is outside the screen, which is 402x874 points in portrait (...)` のように画面の大きさと向きが出ます。`swipe` は始点（`from:`）と終点（`to:`）の両方を確かめます。端ぎりぎりではなく、数ポイント内側を使います。
- `relay orientation` の後は `relay health` の `orientation` と `screen` を読み直します。iPhone のアプリの多くは `portraitUpsideDown` に回転しません。
- iPad のウィンドウ表示（ウィンドウ表示のアプリ、Stage Manager、Slide Over）でも、座標は画面全体のものです。`find`・`source`（`--format text` を除く）の frame と要素指定のタップの `point` も画面の座標に変換され、応答の `window`（`x`・`y`・`width`・`height`・`scale`）にウィンドウの位置と倍率が出ます。全画面のアプリには付きません。位置が決まらないと、タップは何も送らずに終了コード 6（`window_position_unknown`）、`find`・`source` は frame がウィンドウの中の座標のままで `window: null` と `warning` が付きます（`--format compact` は先頭の `warning …` の行）。
- 表示が複数ある端末（iPhone Duo。Xcode 27.1 以上、iOS 27.1 以上）では、`relay health` の `displays` に表示の一覧（外側が ID 1 で 466×678、内側が ID 3 で 669×951。縦向きのポイント）、`display` に前面アプリの表示の ID が出ます。`screen`、スクリーンショット（応答ヘッダー `X-Relay-Display`）、座標、要素の frame はその表示のものです。内側はふつう横向きで、`screen` は 951×669 です。折りたたみを変えたら `relay health` を読み直します（シミュレータが起動し直してランナーが止まることがあるので、先に `relay status`。止まっていれば `relay start` し直す）。Duo では `relay orientation` で画面は回転しません（外側は portrait、内側は landscapeRight のまま）。前面アプリの表示を判定できない（`display` が `null`、タッチとスクリーンショットは終了コード 6 で `cannot tell which display`）ときは、どちらの表示も暗いので利用者に確かめます。内側で SpringBoard や回転しないアプリが前面のとき、`--mode xcui` の座標タッチは `xcui touches can't reach` で断られるので、`--mode` を外して送り直します。
- 詳しくは device-relay の docs/screen.md の「座標系と画面の向き」「iPad のウィンドウ表示」「表示が複数ある端末（iPhone Duo）」。

## スクロールの例

```sh
relay health                          # screen.width / height を確かめる
relay swipe 200 700 200 250           # 下から上へ（内容を下に送る）
relay find --label "Privacy" --type button
```

画面の外の要素は `offscreen` になるので、`find` で見つかるまでスワイプと観察を繰り返します。スワイプの始点は、ナビゲーションバーやホームインジケーターの近く（画面の上下端）を避けます。

## 試し打ち用のアプリ

ランナーと一緒に RelayRunnerHost がインストールされます。バンドル ID は利用者ごとに違う（`<接頭辞>.RelayRunnerHost`）ので、relay のコマンドではバンドル ID の代わりに `host` と書きます（`relay launch host`、`--bundle-id host`）。実際の ID は `relay status` の `host app` に出ます。対象アプリの代わりに操作を試せます。identifier: `relay.input` / `relay.input2`（入力欄）、`relay.password`（パスワード欄。`secureTextField`）、`relay.text`、`relay.passwordLength`、`relay.submitted`、`relay.events`（device-relay の docs/development.md の「検証用のホストアプリ」）。

```sh
relay launch host
relay tap --id relay.input --timeout 3
relay type "hello" --key return
relay find --id relay.submitted       # label が "submitted #1: hello"
```

## トラブルシューティング

| 症状 | 原因と対処 | device-relay の文書 |
| --- | --- | --- |
| 起動時に `Failed to initialize for UI testing`（`Timed out while enabling automation mode.`） | 実機では、automation mode の有効化で端末がパスコードの入力を求め、入力されないまま時間切れになったことが多い（「UI オートメーション」が無効な場合も同じエラーになる）。利用者に、端末にパスコード入力画面が出ていたら入力してもらうよう依頼してから、`relay start` し直す（許可はしばらく有効なので、直後の起動は通りやすい）。`relay start` が「relay install を再実行して」と知らせていたら、利用者に確認して先に `relay install` をやり直す（古いビルドは relay が自動で作り直す）。それでも続くなら 設定 > デベロッパ >「UI オートメーションを有効にする」がオンか確認してもらう。シミュレータでは一時的なことが多いので 1 回だけ起動し直す | docs/setup.md の「実機」 |
| 実機で「信頼されていないデベロッパ」 | Personal Team などの証明書。設定 > 一般 > VPNとデバイス管理 で信頼してもらってから起動し直す | docs/setup.md の「実機」 |
| `relay doctor` でロック中（`passcodeRequired`）、操作が効かない | 実機のロックを解除してもらう | docs/setup.md の「環境の確認（relay doctor）」 |
| `--allow-wifi` で届かない | 端末の「ローカルネットワーク」の許可ダイアログで許可してもらう | docs/setup.md の「実機」、docs/limitations.md |
| 実機が `connected` にならない、DDI が未マウント | USB で接続し、Xcode の Devices and Simulators で準備完了にしてもらう | docs/setup.md の「実機」 |
| 署名・Team ID のエラー（実機） | Xcode でサインインして Apple Development 証明書を作ってもらう。チームが複数なら `--team-id` | docs/setup.md の「Team ID（実機の署名）」 |
| `relay install を再実行して` と出る | `relay install` の後に relay が更新された。利用者に `relay install` を頼む（動作は止まらない） | docs/setup.md の「Runner の用意（relay install）」 |
| `unknown argument: '-target-arch-variant'`（relay のビルド時） | PATH の先頭に別の Swift がある。`make install` は `xcrun swift` を使うのでそちらで | README の「要件」 |
| 1 回の操作が数分戻らず、その間 busy が続く | 別プロセスのシート（Apple Account のサインインなど）が出ていてスナップショットが詰まっている。待つか、利用者に閉じてもらう | docs/limitations.md |
| Xcode や iOS の更新の後、`relay health` の `touchSynthesis` が `xcui`、`foreground.source` が `fallback` になった。要素の `hasKeyboardFocus` が `null` | ランナーが使う非公開 API が使えなくなった。多くは代わりの手段で動き続けるので、タッチが遅いことを見込み、対象は `--bundle-id` で指定する | docs/private-api.md |
| 実機で `relay button home` が効かない | ホームボタンのある端末では、代用のスワイプでコントロールセンターが開く | docs/limitations.md |
| `the OS refused the connection (Operation not permitted)`（終了コード 3） | relay がエージェントの sandbox の中にいて localhost に接続できない。ランナーは止まっていない。上の「sandbox の中から使う」の設定を利用者に頼む | docs/setup.md の「エージェントの sandbox から使う」 |
| 終了コード 3 だが runner.json がある | `relay start` が強制終了され、ファイルだけ残っている（`relay status` の pid が `relay start not running`、ping が応答なし）。`relay stop` で片付けて（`not running`）から起動する | docs/setup.md の「バックグラウンドで動かす」、docs/limitations.md |
| `relay start --background` が「a runner is already running」で 1 | `~/.relay/runner.json` のランナーが同じポートで応答している。`relay status` で確かめ、そのまま使う。自分で起動したものでなければ止めない | docs/setup.md の「バックグラウンドで動かす」 |

起動に失敗したときのログは `~/.relay/logs/`（`start-*.log`、`build-*.log`、`runner-*.log`）にあります。`relay start --background` は失敗時に原因、ログの末尾、`start-*.log` のパスを stderr に出すので、まずそれを読み、足りなければそのファイルや、そこに書かれた `build-*.log` / `runner-*.log` を読みます。
