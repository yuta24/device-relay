# セットアップ

インストールと Runner の用意、端末の選択、環境の確認から、シミュレータ・実機でランナーを起動するまでの詳細です。最初の手順は README の「[インストール](../README.ja.md#インストール)」と「[クイックスタート](../README.ja.md#クイックスタート)」にまとめています。

## インストールと更新

`relay` 本体（CLI）はビルド済みのものを GitHub Release の tarball（`device-relay-v<version>-macos-<arm64|x86_64>.tar.gz`）で配布します。端末で動かす Runner（XCUITest の Xcode プロジェクト）はソースのまま tarball に入っていて、`relay start` が手元の Mac の Xcode でビルドします。

```
device-relay-v<version>/
  bin/relay
  Runner/                 Xcode プロジェクト
  Sources/Relay/Shared/   Runner が参照する CLI との共有ソースだけ
  skills/                 エージェントスキル
  LICENSE README.md README.ja.md
```

| 入れ方 | インストール | 更新 |
| --- | --- | --- |
| mise | `mise use -g github:yuta24/device-relay` | `mise upgrade github:yuta24/device-relay` |
| 手動 | tarball を展開し、`bin/relay` へのリンクを PATH に置く（[README](../README.ja.md#手動でインストールする)） | 新しい tarball を展開し、リンクを張り直す（`ln -sfn`） |
| ソース | `git clone` して `make install` | `git pull` して `make install` |

- どの入れ方でも、`relay` は自分の実行ファイルの場所から Runner を見つけるので、`relay install` は要りません。
- 更新の後の最初の `relay start` は Runner をビルドし直します。DerivedData は Runner の場所ごとに分かれるので（`~/.relay/build/<ディレクトリ名>-<パスのハッシュ>`）、古いバージョンの分は別のディレクトリに残ります。元の Runner がなくなったものと 30 日使っていないものは `relay start` が消します（「[ログとテスト結果の掃除](sessions.md#ログとテスト結果の掃除)」）。
- 以前 `relay install` したコピー（`~/.relay/runner`）は、更新の後は使われません。`relay skill install` の取り出し元にもなりません（「[エージェントスキル](cli.md#エージェントスキル)」）。要らなければ `relay uninstall` で削除できます。

## Runner の用意（relay install）

`relay install` が要るのは、`relay` のバイナリだけを別の場所にコピーして、そこから Runner が見つからないときです。展開したディレクトリ（またはチェックアウト）で 1 回実行します。Runner プロジェクトを `~/.relay/runner/` にコピーし、relay のバージョンと、元がチェックアウトならそのコミットを `~/.relay/runner/install.json` に記録します。

- コピー元は `--project <path>` > `$RELAY_HOME` > カレントディレクトリとその親 > `relay` の実行ファイルの場所（シンボリックリンクを解決）とその親、の順に探した、展開したリリースか device-relay のチェックアウトです（どちらも同じ配置です）。
- コピーするのは `Runner/` と、プロジェクトが参照している CLI 側の共有ソース（`Sources/Relay/Shared/RunnerAuth.swift` など、`project.pbxproj` の `../Sources/...` の参照）、それにエージェントスキル（`skills/device-relay`。「[エージェントスキル](cli.md#エージェントスキル)」を参照）です。リポジトリと同じ配置（`~/.relay/runner/Runner/RelayRunner.xcodeproj`、`~/.relay/runner/skills/device-relay`）にします。
- 再実行すると上書き更新します。一時ディレクトリにコピーしてから入れ替えるので、途中で失敗しても前の Runner は残ります。入れ替えたときは、古いソースのビルド成果物（`~/.relay/build/installed`）を削除します。
- `relay install --build` は、コピーの後にシミュレータ用の `build-for-testing`（`generic/platform=iOS Simulator`）を行い、初回の `relay start` でビルドを省きます（下の「ランナーの版」の記録も書くので、ソースが同じなら `relay start` はそのビルドを使い回します）。ビルドログは `relay start` と同じく `~/.relay/logs/` の `build-<時刻>.log`（ポートはないので付けません）に保存し、失敗したときはそのパスを示します（コピーした Runner は残ります）。`--verbose` を付けると xcodebuild の出力をそのまま表示します。
- `relay uninstall`（= `relay install --remove`）は `~/.relay/runner` とそのビルド成果物を削除します。`config.json`、`runner.json`、ログは残します。
- `relay start` は、`~/.relay/runner` を使うときに記録したバージョンが `relay` のバージョンと違えば「relay install を再実行して」と知らせます。止めはしません。`relay doctor` も同じ確認をし、チェックアウトの中などで別の Runner を使っているときも、コピーが古ければ（元のチェックアウトのコミットが記録と違う場合を含む）知らせます。ただし実行ファイルのそばの Runner を使っているときは、コピーは使われないので、古くても問題にしません（`not used: relay executable wins`）。コピーがなくても問題にしません。

`relay start` が使う Runner プロジェクトは、次の順に探します。

1. `--project <path>`（チェックアウトのルート、`Runner/`、`.xcodeproj` のどれでも可）
2. `$RELAY_HOME`（同上）
3. カレントディレクトリとその親にある device-relay のチェックアウト（開発時用）
4. `relay` の実行ファイルの場所（シンボリックリンクを解決したもの）とその親にある Runner（mise や手動で展開したリリース、`make install` のチェックアウト）
5. `~/.relay/runner`（`relay install` したもの）

対象アプリのリポジトリなどから実行すると、4 の実行ファイルのそばの Runner を使います。relay を更新すれば Runner も一緒に新しくなり、前に `relay install` したコピーが使われ続けることはありません。5 を使うのは、バイナリだけを別の場所にコピーした場合です。device-relay のリポジトリ内で実行すると 3 のチェックアウトを使うので、編集中（未コミットを含む）の Runner がそのままビルドされます。`make install` したリンクでは、チェックアウトの外から実行しても 4 でそのチェックアウトの Runner を使います。

1 と 2 で指定した場所にプロジェクトがなければ、ほかを探さずにエラーにします。どこにも見つからなければ、バイナリだけをコピーした場合は展開したディレクトリ（またはチェックアウト）で `relay install` を 1 回実行することなど、設定方法を示して終了します。DerivedData は Runner プロジェクトごとに `~/.relay/build/installed`（インストールしたもの）か `~/.relay/build/<ディレクトリ名>-<パスのハッシュ>` に分けるので、別のソースでビルドした `.xctestrun` を使い回すことはありません。Xcode では分けないので、`DEVELOPER_DIR` で Xcode を切り替えてビルドすると、SDK のバージョン入りの名前（`RelayRunner_iphonesimulator27.2-….xctestrun` など）の `.xctestrun` が並びますが、指すビルド成果物（`Debug-iphonesimulator` など）は共有で、最後のビルドのものです。そのため relay は、ビルドした直後はそのビルドが書いた（更新日時が新しい）ものを、使い回すときは最後のビルドのもの（更新日時が最も新しいもの）を使い、その名前の SDK のバージョンが今の Xcode の SDK（`xcrun --sdk iphonesimulator|iphoneos --show-sdk-version`）と違えば `… is not for this Xcode's … SDK …; rebuilding` と出して再ビルドします（SDK のバージョンが取れないときや、名前から読めないときは、そのまま使い回します）。Xcode を切り替えるたびにビルドし直すことになりますが、同じ Xcode のままなら今までどおりビルドせずに使い回します。SDK が同じでも、Runner のソースがビルドの後に変わっていれば作り直します（下の「ランナーの版」）。ランナーを起動する `xcodebuild test-without-building` には、ポートごとの `~/.relay/build/…/TestData/port-<port>` を `-derivedDataPath` として渡すので、テストのログと xcresult はそこの `Logs/Test` に入り、`~/Library/Developer/Xcode/DerivedData` には何も作りません（以前の relay は `DerivedData-*/Logs/Test` に書いていました）。古いものは `relay start` が消します（「[ログとテスト結果の掃除](sessions.md#ログとテスト結果の掃除)」）。

### ランナーの版（ソースのハッシュ）

`git pull` や `relay install` の後に、古いソースでビルドしたランナーが黙って使われないよう、relay はランナーのソースのハッシュでビルドを見分けます。

- **対象**: `Runner/` 以下のすべてのファイル（プロジェクト、スキーム、ランナーのソース、`Info.plist` など）と、プロジェクトが `../Sources/Relay/Shared/*.swift` として参照する CLI との共有ファイル（`relay install` がコピーするものと同じ）です。Xcode の利用者ごとの状態（`xcuserdata`）と隠しファイル（`.DS_Store` など）は含めません。ファイルのパスと内容を、パスの順に SHA-256 にかけます（列挙の順には依りません）。`relay install` したコピーは元のチェックアウトと同じファイルなので、同じハッシュになります。計算は `relay start` のたびに行い、数 ms です。
- **記録**: ビルドに成功すると、`.xctestrun` の横（`DerivedData-*/Build/Products/relay-runner-build.json`）にハッシュと relay のバージョン、バンドル ID の接頭辞を記録します（`relay install --build` も同じ）。ビルドの前には消すので、失敗したビルドは記録を持ちません。
- **使い回しの判断**: 最後のビルドが今の Xcode の SDK のものでも、記録がない（古い relay のビルド、失敗したビルド）、バンドル ID の接頭辞が違う（記録に接頭辞がない場合も）、ハッシュが今のソースと違う、relay のバージョンが違う、のどれかなら、この順に調べて最初の理由を `runner sources changed since the last build (<前> -> <今>); rebuilding` などと出し、 `--rebuild` なしでも再ビルドします。ハッシュだけが変わった再ビルドは、Xcode の差分ビルドなので変わったファイルの分だけで済みます。
- **ランナーが名乗る版**: ビルドのときに `RELAY_RUNNER_VERSION=<relay のバージョン>` と `RELAY_RUNNER_SOURCE_HASH=<ハッシュ>` をビルド設定として渡し、UI テストバンドルの Info.plist（`Runner/RelayRunnerUITests/Info.plist`。自動生成の Info.plist に足されます）に埋め込みます。ランナーは自分のバンドルから読み、`/ping` と `/health` の `runner`（`{"version":"0.6.0","sourceHash":"<64 桁>"}`）で返します。起動時の環境変数ではないので、ビルドしたものを表します。Xcode から直接ビルドしたランナーでは値が `null` です。
- **照合**: `relay start` は ready の時点で `/health` の `runner` を確かめ、一致すれば `relay: runner 0.6.0 (sources <12 桁>)` と出します。違う、または名乗らない場合は `warning:` を出しますが、止めはしません（ソースは relay が今ビルドまたは確認したものなので、ずれているのは名乗る値だけです）。runner.json には期待する版（`runner`）を保存し、`relay status` は `/ping` の `runner` と並べて表示します。ランナー操作のコマンドはソースのハッシュを計算しません。版を名乗らない古いランナーにも、これまでどおり接続できます（`relay status` の `runner:` は `not reported`）。

## 端末の選択（relay devices）

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

実機の一覧には `devicectl list devices` を使いますが、`--simulator` を付けたときと、`--udid` が `simctl` の一覧にあるシミュレータのときは、実機を選ぶことはないので devicectl を呼びません（CoreDevice が応答しないときの待ちや `Timed out waiting for CoreDeviceService` などの警告も出ません）。このとき `relay doctor` の `devices` の行は `0 booted simulator(s), … iOS simulator(s) (devices not listed: --udid is a simulator)` のように実機の数を出さず、候補が見つからないときのエラーにも実機は並びません。`--device <名前>` だけでは、同じ名前の実機があるかを確かめるために devicectl を呼びます（シミュレータだけから選ぶなら `--simulator` を付けます）。

次の 2 つで、上の選択の前に候補を絞れます。`--udid` / `--device` とも、自動選択とも組み合わせられます。

- `--simulator`: シミュレータだけから選びます。実機が接続されていても、`--device` で同じ名前の実機があっても、シミュレータを選びます。`--device` なしでは、起動中のシミュレータが 1 台ならそれ、複数ならエラー（候補つき）です。0 台のときもエラーにし、新しい iOS のものから順に候補を示して、`--device <名前>` で選ぶよう案内します。どのシミュレータ（iPhone か iPad か、画面の大きさ）を使うかはスクリーンショットや座標に関わるので、勝手に選んで boot はしません
- `--os <version>`: OS のバージョンが前方一致するもの（区切りの `.` ごとに比べます）だけから選びます。`--os 27` は iOS 27.0 や 27.1、`--os 26.5` は 26.5 や 26.5.1 に一致し、26.6 や 26.50 には一致しません（足りない桁は 0 とみなすので、`--os 27.0` は iOS 27 にも一致します）。「以上」の比較にしないのは、`--os 26.5` で 27.0 が選ばれると意図と違うためです

停止中のシミュレータを `--udid` / `--device` で指定した場合は、`relay start` が `simctl boot` して起動を待ちます。relay が boot したシミュレータは、`relay start` の終了時（Ctrl-C を含む）に shutdown します。boot やビルドの途中（ランナーの起動前）に Ctrl-C（または SIGTERM）した場合も、実行中の simctl や xcodebuild を止めてから shutdown します。もともと起動していたシミュレータはそのままにします。

## Team ID（実機の署名）

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

## バンドル ID の接頭辞

Runner のアプリのバンドル ID は `<接頭辞>.RelayRunnerHost`（ホストアプリ）と `<接頭辞>.RelayRunnerHost.UITests`（テストランナー）です。明示的な App ID は最初に登録したチームのものになり、ほかのチームでは登録できないので、接頭辞は既定で Team ごとに変わります。`relay start` は次の順に決めて、xcodebuild に `RELAY_BUNDLE_ID_PREFIX=<接頭辞>` を渡します。

1. `~/.relay/config.json` の `bundleIDPrefix`（`relay config set bundleIDPrefix <接頭辞>`）
2. 既定値: Team ID があれば `dev.devicerelay.<Team ID の小文字>`（例: `dev.devicerelay.abcde12345`）。Team ID は App ID の重複を避けつつ同じ人では変わらないので、そのまま実機で自動署名できます
3. Team がない（シミュレータ）とき: `dev.devicerelay.local`。シミュレータは署名も App ID の登録もしないので、衝突しても困りません

```sh
relay config set bundleIDPrefix com.example.devicerelay   # 逆ドメイン形式（英数字とハイフンを . で 2 つ以上）。不正ならその場でエラー
relay config get bundleIDPrefix
relay config unset bundleIDPrefix                          # 既定値に戻す
```

起動時に `relay: runner host app: dev.devicerelay.abcde12345.RelayRunnerHost (prefix from the Team ID)` のように表示し、`relay doctor` も使われる接頭辞と出どころ（config / Team ID から作った既定値 / Team がまだ分からない）を表示します。config の値が不正なときだけ ✗ です。

ホストアプリを relay のコマンドで指すときは、バンドル ID の代わりに `host` と書きます（`relay launch host`、`relay tap --id relay.input --bundle-id host`）。relay は `relay start` がビルドしたアプリの ID を runner.json の `hostBundleID` に書いて置き換えます（`relay status` の `host app` にも出ます）。HTTP API を直接呼ぶときは `jq -r .hostBundleID ~/.relay/runner.json` で読みます。

接頭辞が前回のビルド（使い回す DerivedData の記録 `relay-runner-build.json`。「ランナーの版」）と違えば、ソースの変化より先にそれを調べて、`relay start` は `bundle ID prefix changed from X to Y; rebuilding, and the device gets new apps with the new IDs (the old ones stay)` と出して作り直します（`--rebuild` は要りません）。

0.2.0 以前の relay から更新するときは、実機で最初に `relay start` する前に「[変更履歴](../CHANGELOG.md#runner-のバンドル-id-の接頭辞移行の注意)」を読んでください。バンドル ID が変わり、新しい App ID が登録されます。

## 環境の確認（relay doctor）

`relay doctor [--udid <UDID> | --device <名前>] [--simulator] [--os <version>] [--project <path>] [--json]` は、ビルドや起動をせずに次を確認し、各項目を ✓（問題なし）/ ✗（このままでは動かない）/ !（注意）で表示します。✗ と ! には直し方を 1 行添えます。✗ があれば終了コード 1（ローカルの失敗）、なければ 0 です。

- relay のバージョン、Xcode（`xcodebuild -version` と `xcode-select -p`）、xcrun、devicectl
- Runner プロジェクトの解決結果と、`relay install` の状態（記録したバージョン・コミット・コピー元、ずれていれば !）
- 端末一覧と、同じオプションの `relay start` が使う端末（`--udid` / `--device` がなければ自動選択の結果）。自動選択で実機になる場合は、シミュレータで試すなら `--simulator` か `--device <シミュレータ名>` を付けるよう ! で知らせます
- 使用中の端末: ほかの `relay start`（セッション）が使っている端末が候補にあるときは、`in use` の行に端末と使っている相手（`session a, relay start pid 123`）を出します。自動選択はそれらを外します（`relay start` と同じ）。`--udid` / `--device` で指定した端末が使用中なら target を ✗ にし、止め方（`relay stop --session <名前>` など）か別の端末を指定するよう案内します（その端末の残りの確認は続けます）。使用中がなければこの行は出ません。`relay doctor` はセッションを持たないので、空いている起動中のシミュレータが複数あっても 1 台には決めません（`relay start --session` なら選びます）。使用中でない候補が 1 台もなければ、target は ! です
- 実機: OS のバージョン（17 以上）、接続状態、ペアリング、デベロッパモード（`devicectl list devices`）、DDI のマウント状態（`ddiServicesAvailable`）、ロック状態（`devicectl device info lockState` の `passcodeRequired`）。UI オートメーションの有効状態は Mac から読めないので、常に ! で確認を促します
- シミュレータ: ランタイムが入っているか、起動状態
- 署名: 証明書と Team ID（実機なら見つからなければ ✗、シミュレータなら !）
- バンドル ID: `relay start` が使う接頭辞と出どころ（`bundleIDPrefix` の設定、Team ID から作った既定値、Team が分からない、シミュレータの既定値）。表示だけで、config の値が不正なときだけ ✗（「[バンドル ID の接頭辞](#バンドル-id-の接頭辞)」）
- sandbox: 127.0.0.1 への接続と、`~/.relay`（あれば）へのファイルの作成を試します。OS に拒否された（`Operation not permitted`）ら、エージェントなどの sandbox の中で動いているようだとして ✗ にします（「[エージェントの sandbox から使う](sessions.md#エージェントの-sandbox-から使う)」）
- エージェントスキル: カレントディレクトリの git のルートの `.claude/skills/device-relay` と `~/.claude/skills/device-relay` の状態（`relay skill status` と同じ判定。relay や取り出し元とバージョン・コミットが違う、relay が入れたものでない、のどれかなら !。入っていなくても問題にはしません）

### relay doctor --json

`--json` を付けると、人向けの行（✓ / ✗ / !）を出さず、1 つの JSON オブジェクトを 1 行で stdout に出します（キーは辞書順）。終了コードは同じです（✗ があれば `1`、なければ `0`）。

```json
{"checks":[{"detail":"0.6.0","fix":null,"name":"relay","section":"Host","status":"ok"},{"detail":"no booted iOS simulator (--simulator); pass --device <name> to boot one","fix":"relay devices lists the simulators; …","name":"target","section":"Devices","status":"warning"}],"ok":true,"problems":0,"warnings":1}
```

| キー | 内容 |
| --- | --- |
| `ok` | ✗（`problem`）が 1 つもなければ `true`。終了コード 0 と同じ |
| `problems` / `warnings` | `status` が `problem` / `warning` の項目の数 |
| `checks` | 項目の配列（人向けの表示と同じ順）。端末の一覧表は含みません（`relay devices --json`） |
| `checks[].section` | 見出し（`Host`、`Devices`、`Target: <端末名>`、`Signing`） |
| `checks[].name` | 項目名（`Xcode`、`signing`、`target` など） |
| `checks[].status` | `"ok"`（✓）、`"warning"`（!）、`"problem"`（✗）の 3 つだけ |
| `checks[].detail` | 内容（人向けの行と同じ文） |
| `checks[].fix` | `warning` と `problem` では直し方（1 行）、`ok` では `null`。`warning` で直し方のない項目も `null` |

これらのキーと `status` の 3 つの値は変えません。`name` と `detail` の文言は人向けで、変わることがあります。

`relay start` も、ビルドの前に同じ端末のチェックを行い、✗（接続されていない、ペアリングされていない、デベロッパモードが無効、iOS 17 未満、シミュレータのランタイムがない）があればビルドせずに終了します。! の項目（ロック中、DDI 未マウント）は表示だけして続けます。

## シミュレータ

```sh
relay start --device "iPhone 17 Pro"   # 停止中なら boot し、終了時に shutdown
# relay: runner project: <展開したディレクトリ> (from relay executable)
# relay: using iPhone 17 Pro (iPhone 17 Pro, iOS 27.0, simulator, shutdown) <SIM_UDID> (--device; the newest iOS of 3 simulators named "iPhone 17 Pro")
# relay: booting simulator iPhone 17 Pro (<SIM_UDID>); it is shut down when relay exits
# relay: building runner from sources <ハッシュ 12 桁> (log: ~/.relay/logs/build-<時刻>-8100.log)   ← 初回、ソースが変わったとき、--rebuild 指定時
#        （使い回すときは relay: reusing RelayRunner_iphonesimulator27.2-….xctestrun (runner sources <ハッシュ 12 桁>)）
# relay: launching runner on <SIM_UDID> (log: ~/.relay/logs/runner-<時刻>-8100.log)
# relay: runner listening; device addresses: 127.0.0.1   ← シミュレータのランナーは 127.0.0.1 だけで待ち受けます
# relay: runner 0.6.0 (sources <ハッシュ 12 桁>)   ← ランナーが名乗る版（「ランナーの版」）
# ready: http://127.0.0.1:8100/
# token: ~/.relay/runner.json
```

ready になると、URL とアクセストークンが `~/.relay/runner.json`（パーミッション 0600）に書き出されます。別のターミナルから（`relay health` などのサブコマンドは「[CLI から操作する](cli.md#cli-から操作する)」を参照）:

```sh
TOKEN=$(jq -r .token ~/.relay/runner.json)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8100/health
relay bench --count 5 --tap 200,120   # URL もトークンも runner.json から読む（他のコマンドと同じ探し方。--url と --token で上書きできる）
```

Ctrl-C を押す（または別のターミナルで `relay stop` を実行する）と `relay` が `/shutdown` を送り、`runner.json` を削除します。ランナーがテストメソッドから抜けて `** TEST EXECUTE SUCCEEDED **` で終了し、`relay` も終了します（10 秒以内に終わらなければ xcodebuild を terminate します）。ランナーが ready になる前に Ctrl-C を押した場合は、`/shutdown` を送る先がないので xcodebuild をすぐに terminate します。ランナーの起動前（シミュレータの boot やビルドの途中）なら、そのビルドの xcodebuild を止め、relay が boot したシミュレータを shutdown して、`relay: stopped before launching the runner` と表示して終了コード 1 で終わります。

ready の後も、`relay start` は 3 秒ごとに `/ping` を送ってランナーの生存を確認します（`200` だけが生存扱い）。`/ping` はコマンドの実行中でも busy ゲートを通らずに即答するので、生存確認が利用者のリクエストと重なって `409` を起こすことはありません。ready の判定（起動直後の探索）には、XCUI が動くことを確かめるため `/health` を使います。3 回続けて応答がなければ（`200` 以外が 3 回続けば）、ランナーが落ちたとみなしてエラーを表示し、xcodebuild を止めて `runner.json` を削除し、終了コード 1 で終わります。`/ping` のない古いソース（`/ping` より前に `relay install` したコピーなど。`relay start` はそのコピーが古いことも知らせます）から作ったランナーでは、`/ping` が `404` になるので警告を出し、以後は `/health` で確認します（このときは `409` も生存扱いで、利用者のリクエストが `409` になることがあります）。`runner.json` を書き出せなかった場合も、ランナーを止めてから終了コード 1 で終わります。

オプション:

| オプション | 説明 |
| --- | --- |
| `--udid <UDID>` / `--device <名前>` | 使う端末（「端末の選択」）。省略すると自動で選びます。同時には指定できません |
| `--simulator` | シミュレータだけから選びます（「端末の選択」）。実機が接続されていてもシミュレータを使えます |
| `--os <version>` | OS のバージョン（`27`、`27.0`、`26.5` など）で候補を絞ります（「端末の選択」） |
| `--project <path>` | Runner プロジェクトの場所（「Runner の用意」）。`$RELAY_HOME` より優先します |
| `--port 8100` | 端末側の待ち受けポート。xcodebuild には `TEST_RUNNER_RELAY_RUNNER_PORT` として渡され、ランナーからは `RELAY_RUNNER_PORT` として見えます。セッションでは省略すると空きポートを選びます |
| `--session <名前>` | セッション名（環境変数 `RELAY_SESSION` でも可）。ほかのランナーと状態ファイルとポートを分けます（「[複数のセッションを並列に動かす](sessions.md#複数のセッションを並列に動かすrelay-start---session)」） |
| `--team-id <TEAM_ID>` | 実機向けの署名チーム（「Team ID」。省略時は自動検出）。`-allowProvisioningUpdates RELAY_DEVELOPMENT_TEAM=<TEAM_ID>` を付けてビルドし、ランナーが起動できたら `~/.relay/config.json` に保存します |
| `--rebuild` | `~/.relay/build/…/DerivedData-*` に既存の `.xctestrun` があっても再ビルドします（最後のビルドが今の Xcode の SDK と違うとき、Runner のソースやバンドル ID の接頭辞が変わったとき、記録のない古いビルドのときは、付けなくても再ビルドします。「ランナーの版」） |
| `--verbose` | xcodebuild の出力をそのまま表示します |
| `--allow-wifi` | 実機で、CoreDevice トンネルに加えて Wi-Fi などのアドレスも探索します。トークンが同じネットワークに平文で流れるので、既定では無効です |
| `--ready-timeout 180` | `/health` が応答するまで待つ秒数。xcodebuild の出力に `Failed to initialize for UI testing` やテストの失敗が出た場合は、待たずにエラー内容と対処のヒントを表示して非ゼロで終了します |
| `--background` | 端末から切り離して起動し、ready になったら終了します（「[バックグラウンドで動かす](sessions.md#バックグラウンドで動かすrelay-start---background--status--stop)」） |

## 起動とセッション

起動・停止、接続先の選択、並列セッション、ログとテスト結果の掃除は「[起動とセッション](sessions.md)」を参照してください。

## エージェントの sandbox から使う

エージェントから relay を使う設定は「[エージェントの sandbox から使う](sessions.md#エージェントの-sandbox-から使う)」を参照してください。

## 実機

1. 端末で デベロッパモード を有効にします（設定 > プライバシーとセキュリティ > デベロッパモード。有効にすると再起動します）。
2. USB で接続して Mac とペアリングし（端末で「このコンピュータを信頼」）、`relay devices` に `connected` で表示されることを確認します。
3. Xcode の Window > Devices and Simulators で端末を選び、接続済み（準備完了）の状態にします。初回はここで開発用ディスクイメージ（DDI）が端末に適用されるので、完了するまで待ちます。
4. 端末の 設定 > デベロッパ >「UI オートメーションを有効にする」をオンにします。オフのままだと、ランナーが `Failed to initialize for UI testing`（`Timed out while enabling automation mode.`）で起動に失敗します（Mac からは状態を読めないので、`relay doctor` は確認を促すだけです）。オンでも、automation mode の有効化のときに端末がパスコードの入力を求めることがあります。起動中は端末を手元に置き、パスコード入力画面が出たら入力してください（「[既知の制約](limitations.md)」の「automation mode の有効化でパスコードを求められる」）。
5. `relay doctor` で ✗ がないことを確認します（ペアリング、デベロッパモード、DDI、ロック、署名の Team ID）。
6. ランナーをビルドして起動します。接続中の実機が 1 台だけなら `--udid` も `--team-id` も要りません（Team ID はキーチェーンから検出し、起動できたら保存します）。意図した端末を確実に使うには `--device "<端末名>"` か `--udid` で指定します。

   ```sh
   relay start
   # relay: using <端末名> (iPhone 14 Pro, iOS 26.7.1, device, connected) <DEVICE_UDID> (selected automatically; the only connected device)
   # relay: signing team: <TEAM_ID> (from keychain)
   # relay: runner host app: dev.devicerelay.<team id>.RelayRunnerHost (prefix from the Team ID)
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
