# 変更履歴

以前の版から更新するときに、スクリプトや設定を直す必要がある変更を書きます。すべての変更の一覧は GitHub の [Releases](https://github.com/yuta24/device-relay/releases) にあります。全体の入口は [README](README.ja.md) です。

## 次の版（0.8.0 から）

### ダブルタップ tap --count 2（0.8.0 から）

`relay tap <x> <y> --count 2`、`relay tap <セレクタ> --count 2` で、同じ点をダブルタップできるようになりました（HTTP API では `/tap` の `"taps": 2`）。
これまでは `relay tap` を 2 回送るしかなく、2 回の間隔が往復の時間で決まるので、ダブルタップと認識されないことがありました。
応答には `"taps": 2` が付きます。
`taps` を知らない以前のランナーは 1 回だけタップするので、`relay tap --count 2` は終了コード 8（`runner_bad_response`）で失敗します。
`relay start --rebuild` でランナーを作り直してください。扱いは「[ダブルタップ（taps）](docs/http-api.md#エンドポイント)」にあります。

### スライダーとピッカーの値を設定する relay adjust（0.8.0 から）

`relay adjust <セレクタ> --position <0-1>` でスライダーを、`relay adjust <セレクタ> --picker-value <値>` でピッカーのホイール（日付のピッカーの列を含む）を設定できるようになりました（HTTP API では `/adjust`）。
これまでは、位置を計算して `relay swipe` するしかありませんでした。設定した後の値を応答の `value`（スライダーは `position` も）で返します。
`code` には新しい `element_not_adjustable`（スライダーでもホイールでもない要素）と `adjust_failed`（狙いの値にならなかった）があり、どちらも終了コード 6 です。
`code` で分岐しているスクリプトは、この値を足してください。扱いは「[スライダーとピッカー（/adjust）](docs/http-api.md#スライダーとピッカーadjust)」にあります。
以前のランナーは `/adjust` を知らないので、`not_found`（終了コード 7）になります。`relay start --rebuild` でランナーを作り直してください。

## 0.8.0

### 入力欄を空にする type --clear（0.7.0 から）

`relay type --clear [<text>]` で、フォーカスがある入力欄を空にしてから入力できるようになりました（HTTP API では `/type` の `"clear": true`）。
これまでは文字数を数えて `--key delete` を並べるしかなく、カーソルが途中にあると消え残りました。
空にならなければ何も入力せず、終了コード 6 で、`code` は新しい `clear_failed` です。
`code` で分岐しているスクリプトは、この値を足してください。消し方は「[入力欄を空にする（clear）](docs/http-api.md#入力欄を空にするclear)」にあります。

### 要素が消えるのを待つ find --gone（0.7.0 から）

`relay find <セレクタ> --gone --timeout <秒>` で、一致する要素がなくなるまで待てるようになりました（HTTP API では `/find` の `"gone": true`）。
これまでは `find` を繰り返すか `sleep` を挟むしかありませんでした。
`--require` と組み合わせると、時間内に消えなければ終了コード 6 で、`code` は新しい `element_still_present` です。
`code` で分岐しているスクリプトは、この値を足してください。消えたとみなす条件は「[消えるのを待つ（gone）](docs/elements.md#消えるのを待つgone)」にあります。

### ランナーの実行中の画面録画をやめた（0.7.0 から）

`relay start` で動くランナーの間、XCTest が画面を録画しなくなりました。xcresult にも画面の録画とスクリーンショットは入りません。
0.7.0 までは、Xcode の既定のままずっと録画していました。ランナーが失敗扱いで終わると動画が xcresult に残り、シミュレータにも動画が残っていることがあります（1 台で数 GB になることがあります）。
画面を録るときは `relay record start` / `relay record stop` を使ってください。
以前の動画の場所と消し方は「[以前の relay が残した画面録画](docs/sessions.md#以前の-relay-が残した画面録画)」にあります。

### 別のコントロールに当たる要素のタッチ（0.7.0 から）

要素を指定した `tap`・`press` は、押す点が別のコントロールに当たると hit test で確かめられたとき、何も送らずに失敗するようになりました。
応答は `422`（`element_point_covered`）で、CLI の終了コードは 6 です。応答の `hit` には当たる要素が入ります。

0.7.0 までは、同じ操作が `ok: true` で成功していました。実際には別の要素が押されていました。
このため、終了コード 0 を前提にしているスクリプトは、終了コード 6 の扱いを足してください。
扱い方は「[要素セレクタ](docs/elements.md#要素セレクタ)」にあります。

文字や画像に当たる、API がないなど、別のコントロールへの hit を確かめられないときは、これまでどおり送ります。

### Runner のコピーは relay runner install に（0.7.0 から）

`relay install` と `relay uninstall` は、アプリを端末に入れる・消すコマンドになりました。
Runner プロジェクトを `~/.relay/runner` にコピーする・消すコマンドは、`relay runner install` と `relay runner uninstall` に移りました。

| 0.7.0 までの書き方 | 今の書き方 |
| --- | --- |
| `relay install [--project <path>] [--build [--verbose]]` | `relay runner install` に同じオプション |
| `relay install --remove`、`relay uninstall` | `relay runner uninstall` |

古い書き方は、0.8.0 では同じように動きます。そのときは stderr に `relay:` で始まる注意を 1 行出し、終了コードは変わりません。
0.8.0 の次の版で外すので、スクリプトは `relay runner install` に書き換えてください。

アプリを渡した `relay install <path>` と `relay uninstall <bundle-id>` は新しいコマンドです（「[アプリを入れる・消す](docs/cli.md#アプリを入れる消すrelay-install--relay-uninstall)」）。
アプリと、`--project`・`--build`・`--verbose`・`--remove` を一緒に渡すと、書き方の誤りで終了コード 2 です。

`relay doctor` や `relay start` の案内も、`run relay runner install again` などに変わりました。

### 更新の後にすること

- ランナーは、次の `relay start` で自動でビルドし直します。
- エージェントのスキルを入れている場合は、`relay skill install`（または `--global`）で入れ直してください。要素のタッチ、失敗の扱い、画面の録画を説明する references が更新され、`type --clear` と `find --gone` を説明する新しい `references/clear-and-gone.md` が入ります。

## 0.7.0

### 覆われたアプリへの要素のタッチ（0.6.0 から）

要素を指定した `tap`・`press` は、システムのダイアログやコントロールセンターなどがアプリを覆っているとき、何も送らずに失敗するようになりました。
応答は `422`（`covered_by_other_app`）で、CLI の終了コードは 6 です。応答の `alert` にはダイアログの質問文が入ります。

0.6.0 までは、同じ操作が `ok: true` で成功していました。実際には何も起きないか、同じ位置にあるダイアログのボタンが押されていました。
このため、ダイアログが出る場面で終了コード 0 を前提にしているスクリプトは、終了コード 6 の扱いを足してください。
扱い方は「[別のアプリに覆われているとき](docs/elements.md#別のアプリに覆われているとき)」にあります。

### 共有シートの中の要素（0.6.0 から）

共有シートの中の要素は、frame を画面の座標に直すので、要素を指定して押せるようになりました。
位置が決まらないときは、何も送らずに `422`（`remote_view_position_unknown`、終了コード 6）で失敗します。そのときは座標を指定して押します（「[共有シートの中の要素](docs/elements.md#共有シートの中の要素)」）。

### 更新の後にすること

- ランナーは、次の `relay start` で自動でビルドし直します。
- エージェントのスキルを入れている場合は、`relay skill install`（または `--global`）で入れ直してください。新しい `references/system-alerts.md` が入り、docs の場所の案内も新しい構成に合います。

## 0.3.0

### CLI の破壊的な変更（0.2.0 から）

0.3.0 で CLI の約束事をそろえました。0.2.0 のコマンドラインを使っているスクリプトやエージェントのスキルは、次の点を直してください。

- **終了コード `2` を追加**: 書き方の誤りは `2` になりました。
  - 書き方の誤りは、不明なオプション、値の不足・不正、両立しないオプション、不正なセッション名、`RELAY_RUNNER` と `RELAY_SESSION` の両方の設定、`relay run` の不正な手順です。
  - `1` はローカルの失敗（端末が使用中、ビルドの失敗、ファイルがない、`relay start --background` の「すでに動いている」など）だけです。
- **失敗の JSON は stdout**: ランナー操作のコマンドで、失敗時のランナーの JSON を stderr ではなく stdout に出します。
  - `2>&1` を付けて stderr の JSON を読んでいたなら、stdout を読んでください。
  - runner.json がない・接続できない（`3`）などの relay 側の失敗も `{"ok":false,"code":"runner_unavailable","error":"…"}` で stdout に出ます。
  - `launch` の `app_not_installed` と `find --require` の一致なしも stdout です。
  - 例外は `screenshot -o -` です。stdout が画像なので、失敗の JSON は stderr に出ます。
- **書き方の誤りは 2 行だけ**: 使い方の全文は出さず、`relay: <誤り>` と `relay: see relay <command> --help` の 2 行を stderr に出します。
- **`--json` を受け付ける**: ランナー操作のコマンドが受け付けます。出力は常に JSON なので何も変えません。
  - `status --json`・`record status --json`・`devices --json` は、失敗でも JSON を stdout に出し、stderr に同じ文を重ねません。
- **`--opt=value`** がすべてのサブコマンドで書けます。
- **カレントディレクトリの `.relay/runner.json` を読みません**: 探す順は `--runner` / `--session`、`RELAY_RUNNER` / `RELAY_SESSION`、`~/.relay/runner.json` だけになりました。
  - 今の `relay start` は `~/.relay/` にしか書かないので、そこで見つかるのは古いファイルか手で置いたファイルだけで、401（終了コード 4）の原因になっていました。
  - 手で置いたファイルは `--runner <path>` で使います。
  - `~/.relay/runner.json` がなく、カレントディレクトリか親に `.relay/runner.json` があるときは、探さずに、エラーに `.relay/runner.json in <dir> is no longer read; pass --runner <path> to use it` を足して知らせます（終了コードは `3`）。
- **`relay shutdown` を一覧から外しました**: `relay --help` の一覧と SKILL.md には載りません。
  - コマンドは今までどおり動き、`relay shutdown --help` に「通常は `relay stop`」と違いが書いてあります。`relay shutdown` はランナーだけを止めて即座に戻り、後始末は `relay start` が後から行います。
  - 止めるときは `relay stop` を使ってください。
- **`relay bench` はランナーを他のコマンドと同じ探し方で見つけます**: `--url` も `--session` も要らなくなり（付けなかったときの書き方の誤りがなくなった）、`--runner` も受け付けます。
  - `--url` と `--token` は runner.json の URL とトークンを上書きする任意のオプションで、`--url` だけならトークンは runner.json のものです。
  - ランナーが見つからなければ終了コード `3` です。`--url` だけでトークンを読めないときは、以前は `1` でした。
  - `--runner` と `--session` の併用は書き方の誤り（`2`）です。
- **`relay doctor --json`（追加）**: 人向けの行の代わりに、1 つの JSON オブジェクトを stdout に出します。
  - 終了コードは変わりません（✗ があれば `1`）。形は「[relay doctor --json](docs/setup.md#relay-doctor---json)」。
- **`relay doctor` は、ほかの `relay start` が使用中の端末を考慮します**: 自動選択は使用中の端末を外し（`relay start` と同じ）、Devices に `in use` の行が出ます（`--json` の checks にも入ります）。
  - `--udid` / `--device` で指定した端末が使用中なら target が ✗ で、終了コードは `1` です。
- **`relay devices --json` は 1 行になりました**: 整形（改行・字下げ）していたのを、ほかの `--json` と同じ 1 行・キー順にそろえました。
  - JSON として読むなら変わりません。`jq` や `JSON.parse` なら影響はなく、行単位で読んでいたなら直してください。
- **`--help` の行は 100 文字以内**に折り返しました。内容は、上の変更と `ping`・`health`・`status` の使い分けの追記を除いて同じです。

### Runner のバンドル ID の接頭辞（移行の注意）

0.2.0 以前から更新するときは、実機で最初に `relay start` する前に以下の変更を確認してください。

以前の relay は、バンドル ID を `dev.yuta24.devicerelay.RelayRunnerHost`（と `.UITests`）に固定していました。

この版に上げてそのまま実機で `relay start` すると、接頭辞が既定値の `dev.devicerelay.<Team ID の小文字>` に変わります（「[バンドル ID の接頭辞](docs/device.md#バンドル-id-の接頭辞)」）。

- 自動署名（`-allowProvisioningUpdates`）が新しい App ID をあなたの Apple Developer アカウントに登録します。
- 端末には新しいバンドル ID の RelayRunner が入ります。古い ID のアプリは端末に残ります（不要ならホーム画面から削除します）。
- 古い App ID も Apple Developer の Identifiers に残ります。

今の App ID のまま使い続けたい（`dev.yuta24.devicerelay` を登録したチームで使っている）場合は、**更新後に最初の `relay start` をする前に** 旧接頭辞を設定します:

```sh
relay config set bundleIDPrefix dev.yuta24.devicerelay
relay doctor            # bundle ID の行が prefix dev.yuta24.devicerelay (from bundleIDPrefix in ~/.relay/config.json) になる
```

- ほかのチームでは `dev.yuta24.devicerelay` は登録できないので、この設定は元のチームで使う人だけのものです。
- `relay install` でコピーした Runner（`~/.relay/runner`）を使っている場合は、`relay install` をやり直してから起動します。
  - 古いコピーはバンドル ID が固定のままで、接頭辞を渡しても変わりません。
  - 記録には渡した接頭辞が入るので、作り直しを繰り返すことはありません。
  - runner.json の `hostBundleID` はビルドしたアプリの Info.plist から読むので、`host` は実際の ID を指します。
