# 変更履歴

以前の版から更新するときに、スクリプトや設定を直す必要がある変更を書きます。すべての変更の一覧は GitHub の [Releases](https://github.com/yuta24/device-relay/releases) にあります。全体の入口は [README](README.ja.md) です。

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
