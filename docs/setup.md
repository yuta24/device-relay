# セットアップ

Runner の用意、端末の選択、環境の確認から、シミュレータ・実機でランナーを起動するまでの詳細です。最初の手順は README の「[クイックスタート](../README.md#クイックスタート)」にまとめています。

## Runner の用意（relay install）

`relay` 本体（CLI）と、端末で動かす Runner（Xcode プロジェクト）は別に用意します。`relay install` は Runner プロジェクトを `~/.relay/runner/` にコピーし、relay のバージョンと元リポジトリのコミットを `~/.relay/runner/install.json` に記録します。

- コピー元は `--project <path>` > `$RELAY_HOME` > カレントディレクトリとその親 > `relay` の実行ファイルの場所（シンボリックリンクを解決）とその親、の順に探した device-relay のチェックアウトです。`make install` したリンクからは元のチェックアウトが見つかります。（取り出し元は差し替えられるようにしてあり、将来 GitHub Release からのダウンロードにする予定です。）
- コピーするのは `Runner/` と、プロジェクトが参照している CLI 側の共有ソース（`Sources/relay/RunnerAuth.swift` など、`project.pbxproj` の `../Sources/...` の参照）、それにエージェントスキル（`skills/device-relay`。「[エージェントスキル](cli.md#エージェントスキル)」を参照）です。リポジトリと同じ配置（`~/.relay/runner/Runner/RelayRunner.xcodeproj`、`~/.relay/runner/skills/device-relay`）にします。
- 再実行すると上書き更新します。一時ディレクトリにコピーしてから入れ替えるので、途中で失敗しても前の Runner は残ります。入れ替えたときは、古いソースのビルド成果物（`~/.relay/build/installed`）を削除します。
- `relay install --build` は、コピーの後にシミュレータ用の `build-for-testing`（`generic/platform=iOS Simulator`）を行い、初回の `relay start` でビルドを省きます（下の「ランナーの版」の記録も書くので、ソースが同じなら `relay start` はそのビルドを使い回します）。ビルドログは `relay start` と同じく `~/.relay/logs/` の `build-<時刻>.log`（ポートはないので付けません）に保存し、失敗したときはそのパスを示します（コピーした Runner は残ります）。`--verbose` を付けると xcodebuild の出力をそのまま表示します。
- `relay uninstall`（= `relay install --remove`）は `~/.relay/runner` とそのビルド成果物を削除します。`config.json`、`runner.json`、ログは残します。
- `relay start` / `relay doctor` は、記録したバージョンが `relay` のバージョンと違う場合や、元のチェックアウトのコミットが記録と違う場合（`git pull` の後など）に「relay install を再実行して」と知らせます。止めはしません。

`relay start` が使う Runner プロジェクトは、次の順に探します。

1. `--project <path>`（チェックアウトのルート、`Runner/`、`.xcodeproj` のどれでも可）
2. `$RELAY_HOME`（同上）
3. カレントディレクトリとその親にある device-relay のチェックアウト（開発時用）
4. `~/.relay/runner`（`relay install` したもの）
5. `relay` の実行ファイルの場所（シンボリックリンクを解決したもの）とその親にあるチェックアウト

対象アプリのリポジトリなど、チェックアウトの外から実行すると 4 の `~/.relay/runner` を使います。device-relay のリポジトリ内で実行すると 3 のチェックアウトを使うので、`relay install` 済みでも、編集中（未コミットを含む）の Runner がそのままビルドされます。

1 と 2 で指定した場所にプロジェクトがなければ、ほかを探さずにエラーにします。どこにも見つからなければ、`relay install` などの設定方法を示して終了します。DerivedData は Runner プロジェクトごとに `~/.relay/build/installed`（インストールしたもの）か `~/.relay/build/<ディレクトリ名>-<パスのハッシュ>` に分けるので、別のソースでビルドした `.xctestrun` を使い回すことはありません。Xcode では分けないので、`DEVELOPER_DIR` で Xcode を切り替えてビルドすると、SDK のバージョン入りの名前（`RelayRunner_iphonesimulator27.2-….xctestrun` など）の `.xctestrun` が並びますが、指すビルド成果物（`Debug-iphonesimulator` など）は共有で、最後のビルドのものです。そのため relay は、ビルドした直後はそのビルドが書いた（更新日時が新しい）ものを、使い回すときは最後のビルドのもの（更新日時が最も新しいもの）を使い、その名前の SDK のバージョンが今の Xcode の SDK（`xcrun --sdk iphonesimulator|iphoneos --show-sdk-version`）と違えば `… is not for this Xcode's … SDK …; rebuilding` と出して再ビルドします（SDK のバージョンが取れないときや、名前から読めないときは、そのまま使い回します）。Xcode を切り替えるたびにビルドし直すことになりますが、同じ Xcode のままなら今までどおりビルドせずに使い回します。SDK が同じでも、Runner のソースがビルドの後に変わっていれば作り直します（下の「ランナーの版」）。ランナーを起動する `xcodebuild test-without-building` にも同じ `-derivedDataPath` を渡すので、テストのログと xcresult も `~/.relay/build/…/DerivedData-*/Logs/Test` に入り、`~/Library/Developer/Xcode/DerivedData` には何も作りません。

### ランナーの版（ソースのハッシュ）

`git pull` や `relay install` の後に、古いソースでビルドしたランナーが黙って使われないよう、relay はランナーのソースのハッシュでビルドを見分けます。

- **対象**: `Runner/` 以下のすべてのファイル（プロジェクト、スキーム、ランナーのソース、`Info.plist` など）と、プロジェクトが `../Sources/relay/*.swift` として参照する CLI との共有ファイル（`relay install` がコピーするものと同じ）です。Xcode の利用者ごとの状態（`xcuserdata`）と隠しファイル（`.DS_Store` など）は含めません。ファイルのパスと内容を、パスの順に SHA-256 にかけます（列挙の順には依りません）。`relay install` したコピーは元のチェックアウトと同じファイルなので、同じハッシュになります。計算は `relay start` のたびに行い、数 ms です。
- **記録**: ビルドに成功すると、`.xctestrun` の横（`DerivedData-*/Build/Products/relay-runner-build.json`）にハッシュと relay のバージョン、バンドル ID の接頭辞を記録します（`relay install --build` も同じ）。ビルドの前には消すので、失敗したビルドは記録を持ちません。
- **使い回しの判断**: 最後のビルドが今の Xcode の SDK のものでも、記録がない（古い relay のビルド、失敗したビルド）、バンドル ID の接頭辞が違う（記録に接頭辞がない場合も）、ハッシュが今のソースと違う、relay のバージョンが違う、のどれかなら、この順に調べて最初の理由を `runner sources changed since the last build (<前> -> <今>); rebuilding` などと出し、 `--rebuild` なしでも再ビルドします。ハッシュだけが変わった再ビルドは、Xcode の差分ビルドなので変わったファイルの分だけで済みます。
- **ランナーが名乗る版**: ビルドのときに `RELAY_RUNNER_VERSION=<relay のバージョン>` と `RELAY_RUNNER_SOURCE_HASH=<ハッシュ>` をビルド設定として渡し、UI テストバンドルの Info.plist（`Runner/RelayRunnerUITests/Info.plist`。自動生成の Info.plist に足されます）に埋め込みます。ランナーは自分のバンドルから読み、`/ping` と `/health` の `runner`（`{"version":"0.2.0","sourceHash":"<64 桁>"}`）で返します。起動時の環境変数ではないので、ビルドしたものを表します。Xcode から直接ビルドしたランナーでは値が `null` です。
- **照合**: `relay start` は ready の時点で `/health` の `runner` を確かめ、一致すれば `relay: runner 0.2.0 (sources <12 桁>)` と出します。違う、または名乗らない場合は `warning:` を出しますが、止めはしません（ソースは relay が今ビルドまたは確認したものなので、ずれているのは名乗る値だけです）。runner.json には期待する版（`runner`）を保存し、`relay status` は `/ping` の `runner` と並べて表示します。ランナー操作のコマンドはソースのハッシュを計算しません。版を名乗らない古いランナーにも、これまでどおり接続できます（`relay status` の `runner:` は `not reported`）。

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

### 移行の注意（以前の relay を使っていた人）

以前の relay は、バンドル ID を `dev.yuta24.devicerelay.RelayRunnerHost`（と `.UITests`）に固定していました。この版に上げてそのまま実機で `relay start` すると、接頭辞が既定値の `dev.devicerelay.<Team ID の小文字>` に変わるので、

- 自動署名（`-allowProvisioningUpdates`）が新しい App ID をあなたの Apple Developer アカウントに登録し、
- 端末には新しいバンドル ID の RelayRunner が入ります。古い ID のアプリは端末に残ります（不要ならホーム画面から削除します）。古い App ID も Apple Developer の Identifiers に残ります。

今の App ID のまま使い続けたい（`dev.yuta24.devicerelay` を登録したチームで使っている）場合は、**更新後に最初の `relay start` をする前に** 旧接頭辞を設定します:

```sh
relay config set bundleIDPrefix dev.yuta24.devicerelay
relay doctor            # bundle ID の行が prefix dev.yuta24.devicerelay (from bundleIDPrefix in ~/.relay/config.json) になる
```

ほかのチームでは `dev.yuta24.devicerelay` は登録できないので、この設定は元のチームで使う人だけのものです。`relay install` でコピーした Runner（`~/.relay/runner`）を使っている場合は、`relay install` をやり直してから起動します（古いコピーはバンドル ID が固定のままで、接頭辞を渡しても変わりません。記録には渡した接頭辞が入るので作り直しを繰り返すことはなく、runner.json の `hostBundleID` はビルドしたアプリの Info.plist から読むので、`host` は実際の ID を指します）。

## 環境の確認（relay doctor）

`relay doctor [--udid <UDID> | --device <名前>] [--simulator] [--os <version>] [--project <path>]` は、ビルドや起動をせずに次を確認し、各項目を ✓（問題なし）/ ✗（このままでは動かない）/ !（注意）で表示します。✗ と ! には直し方を 1 行添えます。✗ があれば終了コード 1（ローカルの失敗）、なければ 0 です。

- relay のバージョン、Xcode（`xcodebuild -version` と `xcode-select -p`）、xcrun、devicectl
- Runner プロジェクトの解決結果と、`relay install` の状態（記録したバージョン・コミット・コピー元、ずれていれば !）
- 端末一覧と、同じオプションの `relay start` が使う端末（`--udid` / `--device` がなければ自動選択の結果）。自動選択で実機になる場合は、シミュレータで試すなら `--simulator` か `--device <シミュレータ名>` を付けるよう ! で知らせます
- 実機: OS のバージョン（17 以上）、接続状態、ペアリング、デベロッパモード（`devicectl list devices`）、DDI のマウント状態（`ddiServicesAvailable`）、ロック状態（`devicectl device info lockState` の `passcodeRequired`）。UI オートメーションの有効状態は Mac から読めないので、常に ! で確認を促します
- シミュレータ: ランタイムが入っているか、起動状態
- 署名: 証明書と Team ID（実機なら見つからなければ ✗、シミュレータなら !）
- バンドル ID: `relay start` が使う接頭辞と出どころ（`bundleIDPrefix` の設定、Team ID から作った既定値、Team が分からない、シミュレータの既定値）。表示だけで、config の値が不正なときだけ ✗（「[バンドル ID の接頭辞](#バンドル-id-の接頭辞)」）
- sandbox: 127.0.0.1 への接続と、`~/.relay`（あれば）へのファイルの作成を試します。OS に拒否された（`Operation not permitted`）ら、エージェントなどの sandbox の中で動いているようだとして ✗ にします（「[エージェントの sandbox から使う](#エージェントの-sandbox-から使う)」）
- エージェントスキル: カレントディレクトリの git のルートの `.claude/skills/device-relay` と `~/.claude/skills/device-relay` の状態（`relay skill status` と同じ判定。古い・relay が入れたものでなければ !。入っていなくても問題にはしません）

`relay start` も、ビルドの前に同じ端末のチェックを行い、✗（接続されていない、ペアリングされていない、デベロッパモードが無効、iOS 17 未満、シミュレータのランタイムがない）があればビルドせずに終了します。! の項目（ロック中、DDI 未マウント）は表示だけして続けます。

## シミュレータ

```sh
relay start --device "iPhone 17 Pro"   # 停止中なら boot し、終了時に shutdown
# relay: runner project: ~/.relay/runner (from relay install)
# relay: using iPhone 17 Pro (iPhone 17 Pro, iOS 27.0, simulator, shutdown) <SIM_UDID> (--device; the newest iOS of 3 simulators named "iPhone 17 Pro")
# relay: booting simulator iPhone 17 Pro (<SIM_UDID>); it is shut down when relay exits
# relay: building runner from sources <ハッシュ 12 桁> (log: ~/.relay/logs/build-<時刻>-8100.log)   ← 初回、ソースが変わったとき、--rebuild 指定時
#        （使い回すときは relay: reusing RelayRunner_iphonesimulator27.2-….xctestrun (runner sources <ハッシュ 12 桁>)）
# relay: launching runner on <SIM_UDID> (log: ~/.relay/logs/runner-<時刻>-8100.log)
# relay: runner listening; device addresses: 127.0.0.1   ← シミュレータのランナーは 127.0.0.1 だけで待ち受けます
# relay: runner 0.2.0 (sources <ハッシュ 12 桁>)   ← ランナーが名乗る版（「ランナーの版」）
# ready: http://127.0.0.1:8100/
# token: ~/.relay/runner.json
```

ready になると、URL とアクセストークンが `~/.relay/runner.json`（パーミッション 0600）に書き出されます。別のターミナルから（`relay health` などのサブコマンドは「[CLI から操作する](cli.md#cli-から操作する)」を参照）:

```sh
TOKEN=$(jq -r .token ~/.relay/runner.json)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8100/health
relay bench --url http://127.0.0.1:8100 --count 5 --tap 200,120   # トークンは runner.json から読む
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
| `--session <名前>` | セッション名（環境変数 `RELAY_SESSION` でも可）。ほかのランナーと状態ファイルとポートを分けます（「複数のセッションを並列に動かす」） |
| `--team-id <TEAM_ID>` | 実機向けの署名チーム（「Team ID」。省略時は自動検出）。`-allowProvisioningUpdates RELAY_DEVELOPMENT_TEAM=<TEAM_ID>` を付けてビルドし、ランナーが起動できたら `~/.relay/config.json` に保存します |
| `--rebuild` | `~/.relay/build/…/DerivedData-*` に既存の `.xctestrun` があっても再ビルドします（最後のビルドが今の Xcode の SDK と違うとき、Runner のソースやバンドル ID の接頭辞が変わったとき、記録のない古いビルドのときは、付けなくても再ビルドします。「ランナーの版」） |
| `--verbose` | xcodebuild の出力をそのまま表示します |
| `--allow-wifi` | 実機で、CoreDevice トンネルに加えて Wi-Fi などのアドレスも探索します。トークンが同じネットワークに平文で流れるので、既定では無効です |
| `--ready-timeout 180` | `/health` が応答するまで待つ秒数。xcodebuild の出力に `Failed to initialize for UI testing` やテストの失敗が出た場合は、待たずにエラー内容と対処のヒントを表示して非ゼロで終了します |
| `--background` | 端末から切り離して起動し、ready になったら終了します（「バックグラウンドで動かす」） |

## バックグラウンドで動かす（relay start --background / status / stop）

`relay start` はフォアグラウンドで動き続けてターミナルを占有します。エージェントや CI、スクリプトからは `--background` を付けて起動し、終わったら `relay stop` で止めます。

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

- `relay start --background [start の他のオプション]` は、同じオプションの `relay start`（`--background` なし）を新しいセッションとして起動します（端末を閉じても止まりません）。その stdin は `/dev/null`、stdout と stderr は `~/.relay/logs/start-<時刻>-<port>.log` です。ログは親（実行したコマンド）が新しく作ってから子に渡すので、同じ秒に別のポートで起動しても、同じポートですぐに起動し直しても、ほかの `relay start` のログと混ざりません（同じ名前があれば `-2`、`-3` … を付けます。`build-`・`runner-` のログも同じ名前の付け方です）。親はそのログを読み、`ready:` が出たら上のように URL・端末・PID・ログのパスを表示して終了コード 0 で終わります。
- ready にならなかった場合は、子の `relay start` を止め（SIGTERM。ビルド中なら xcodebuild を止め、relay が boot したシミュレータは shutdown します。60 秒以内に終わらなければ子と、子が起動したプロセスを強制終了します）、ログの末尾と原因を表示して終了します。終了コードは、子が ready の前に終了した場合（ビルドの失敗、端末が見つからない、`Failed to initialize for UI testing` など）は `1`、時間切れは `3`（ランナーに届かない）です。時間切れは、ランナーの起動（ビルドの完了）から `--ready-timeout` + 15 秒、起動まで（シミュレータの boot とビルド）は 30 分です。待っている間に Ctrl-C を押した場合も子を止めて `1` で終わります。
- 同じポートで動かせる `relay start` は 1 つだけです。`relay start`（フォアグラウンドのものと、`--background` が起動したもの）は、端末を選ぶ前から終了するまで（ランナーが動いている間も）`~/.relay/locks/start-<port>.lock` をロック（`flock`）します。そのポートでほかの `relay start` が起動中か実行中なら、boot もビルドもせずにエラー（終了コード `1`）にします。`--background` はロックを取ってから下の runner.json の確認を行い、起動した `relay start` にロックを引き継ぐので、ほぼ同時に 2 つ起動しても進むのは片方だけです。ロックはプロセスが終われば（強制終了でも）外れるので、ロックファイルが残っていても次の起動を妨げません。
- 起動の前に `~/.relay/runner.json` を確認します。その URL のポートが新しく使うポート（`--port`、既定は `8100`）と違えば、衝突しないのでそのまま起動し、runner.json は後から起動したランナーで上書きされます（フォアグラウンドで複数起動するときと同じです）。ポートが同じ（または URL からポートが取れない）ときは、その URL へ `/ping` を送り、何かが HTTP で応答したら、新しいランナーはそのポートで待ち受けられないので起動せずにエラー（終了コード `1`）にします。`200` なら、ランナーが動いているので `relay stop` で止めるか、そのまま使うか、`--port` で別のポートに起動するように案内します。`401` なら、runner.json に書かれたものとは別のランナー（別のトークン）がその URL で動いている可能性があり、`404` などそれ以外の応答なら別の何かがそのポートで待ち受けています。どちらの場合も、それを止める（`relay stop`、またはそのランナーを起動した `relay start`）か、`--port` で別のポートを使うように案内します。ポートが同じでも、応答がない（接続できない・タイムアウトした）ときと、runner.json がないときは起動に進みます。
- `relay status [--json]` は、runner.json（「[接続先（runner.json）の探し方](cli.md#接続先runnerjsonの探し方)」と同じ順に探します。`--runner <path>` も可）の URL・端末名と UDID・`relay start` の PID とそれがまだ動いているか・起動時刻・`/ping` の結果（`busy` を含む）・ランナーが名乗る版（`runner: 0.2.0 (sources <12 桁>)`。runner.json の期待値と違えばその旨、名乗らない古いランナーなら `not reported`、応答がなければ runner.json の期待値）を表示します。`--json` では 1 つの JSON オブジェクト（`alive`、`url`、`udid`、`name`、`pid`、`processRunning`、`startedAt`、`ping`、`runner`（`/ping` が返した版。なければ `null`）、`expectedRunner`（runner.json の期待値。古い runner.json なら `null`）、`runnerInfo`）を出します。ランナーが `/ping` に応答すれば `0`、runner.json がないか応答しなければ `3`、トークンが拒否されたら（`401`）`4` です。
- `relay stop` は、runner.json の `relay start` に SIGTERM を送り、終了を待ちます。フォアグラウンドの Ctrl-C と同じ経路で、ランナーの `/shutdown`、relay が boot したシミュレータの shutdown、runner.json の削除を行います。`stopped` と表示して `0` で終わります（60 秒以内に終わらなければ `1`）。`relay start` がもう動いていない場合（強制終了された場合など）は、runner.json の URL とトークンで `POST /shutdown` を送り、runner.json を削除します。何も動いていなければ `not running` と表示して `0` です。フォアグラウンドの `relay start` も同じように止められます。そのランナーの録画（`relay record`。docs/cli.md の「[録画](cli.md#録画relay-record)」）が残っていれば、ランナーを止める前に書き出し、保存先を stderr に出します。
- runner.json には `relay start` の PID と起動時刻（秒単位）を記録します。`relay stop` は、その PID のプロセスの起動時刻が一致し、実行ファイルが `relay` で最初の引数が `start` の場合だけシグナルを送ります。`relay start` の終了後にその PID が別のプロセスに再利用されても、そのプロセスには何も送りません。

## 複数のセッションを並列に動かす（relay start --session）

複数のエージェントがそれぞれ別の端末を操作するときは、名前付きのセッションを使います。エージェントを起動するときに環境変数 `RELAY_SESSION` を渡すのが基本です。エージェントが実行するコマンドのシェルはこの値を引き継ぐので、すべてのコマンドがそのセッションのランナーに届き、ほかのセッションと干渉しません。

```sh
# ターミナル 1
RELAY_SESSION=agent-1 claude

# ターミナル 2（同時に）
RELAY_SESSION=agent-2 codex
```

エージェントの中では、`--session` を付けなくても次のように動きます。

```sh
relay start --background --device "iPhone 17 Pro"   # agent-2 なら別の端末を指定する
relay tap --id relay.input
relay stop
```

環境変数を渡さずに起動したエージェントは、relay の各コマンドに毎回 `--session <名前>` を付けます。

```sh
relay start --background --session agent-1 --device "iPhone 17 Pro"
relay tap --session agent-1 --id relay.input
relay stop --session agent-1

relay status --all   # 全セッションの一覧
relay stop --all     # 全部止める（ほかのエージェントのものも）
```

`export RELAY_SESSION=...` は、同じシェルでコマンドを続けて実行するときだけ効きます。Claude Code の Bash ツールや Codex のようにコマンドごとに新しいシェルになる環境では次のコマンドに残らず、そのコマンドはセッションなしになります。セッションなしのコマンドは、`~/.relay/runner.json` がなければ終了コード 3 で終わり、あれば別の誰かのランナーを操作してしまいます。後者を見逃さないよう、探索で runner.json を使ったときにセッションが動いていれば、次の警告を stderr に出します（下記）。

```
relay: warning: no session selected; using /Users/you/.relay/runner.json, while sessions agent-1, agent-2 are running; pass --session or set RELAY_SESSION
```

名前は英数字で始まる、英数字と `.`・`_`・`-` の 64 文字までです（パスの一部になるため）。大文字と小文字を区別しないボリューム（APFS の既定）では `A` と `a` は同じセッションになります。`--session <名前>` は `RELAY_SESSION` より優先し、`relay start`・ランナー操作のコマンド・`relay status`・`relay stop`・`relay record`・`relay run`・`relay bench` で使えます。セッションなしの使い方は今までどおりで、`~/.relay/runner.json` とセッションは互いに読み書きしません。

- **状態ファイル**: `~/.relay/sessions/<名前>/runner.json`（0600）に書き、`~/.relay/runner.json` には書きません。探す順は「[接続先（runner.json）の探し方](cli.md#接続先runnerjsonの探し方)」のとおりで、セッションを指定したときは、そのファイルがなければ終了コード 3 で終わり、ほかのファイルへは進みません。`relay start` は `~/.relay/sessions/<名前>/session.lock` を終了まで `flock` するので、同じセッションを 2 つは起動できません。`relay start` が強制終了されてランナーだけが応答し続けている場合も、`relay stop --session <名前>` を案内するエラーにします。
- **ポート**: `--port` を省くと、`8101`〜`8199` を順に見て、`~/.relay/locks/start-<port>.lock` を取れて、かつ Mac の `127.0.0.1` で bind できる最初のポートを使います。既定の `8100` はセッションなしの `relay start` のために空けておきます。ロックを取ってから調べて、ランナーが待ち受けるまで保持するので、同時に起動しても同じポートにはなりません。選んだポートは runner.json に入るので、利用者が知る必要はありません（`relay status` や `ready:` の行に出ます）。`--port` を指定すればそれを使います。
- **端末の排他**: 1 台の端末で動かせるランナーは 1 つです（2 つ目の XCTest がテストのセッションを奪います）。これはセッションなしの `relay start` にも適用されます。`relay start` は端末を選んだ直後、boot とビルドの前に `~/.relay/locks/device-<UDID>.lock` を終了まで `flock` します。使用中の端末を `--udid` や `--device` で指定すると、使っているセッションと PID、止め方を示すエラー（終了コード `1`）になります。指定した端末が使用中のときに別の端末へ移ることはありません。
- **端末の自動選択**: `--udid` も `--device` もないときは、ほかの `relay start` が使用中の端末を候補から外して、「接続中の実機が 1 台ならそれ、なければ起動中のシミュレータが 1 台ならそれ」で選びます。空いている候補が複数あれば、これまでどおり候補つきのエラーです。空きがなければ、使用中の端末とその持ち主も示します。
- **ビルド**: ビルド成果物（`~/.relay/build/…/DerivedData-*`）は共有のままで、同じソースのビルドを使い回します。同時に起動しても同じ DerivedData へのビルドは 1 つだけで、後のものは `relay: waiting for another relay start's build …` と出して待ち、終わったらそのビルドを使い回します（待っている間に同じソースのビルドが終われば `--rebuild` も満たされたものとします）。ビルドしない起動どうしは並列に進みます。`~/.relay/locks/build-<ハッシュ>.lock` を、ビルド中は排他で、成果物からランナーを起動して ready になるまでは共有で持つので、起動の途中で成果物が書き換えられることもありません。待っている間も Ctrl-C と `relay stop` で止められます。`relay install --build` も同じロックを取ります。
- **テスト実行の出力**: xcodebuild の `test-without-building` が書くログと xcresult は、ポートごとの `~/.relay/build/…/TestData/port-<port>/` に分けます。同じ `-derivedDataPath` を共有すると、同じ秒に始まったテストの xcresult の名前が同じになり、`Logs/Test/LogStoreManifest.plist` も同時に書き換えられるためです。
- **ログ**: `~/.relay/logs` の `start-`・`build-`・`runner-`・`record-` のログは `<種類>-<時刻>-<セッション>-<port>.log` という名前になります。既定の出力先のスクリーンショットと録画の名前にもセッション名が入ります。
- **セッションなしのコマンドへの警告**: セッションも `--runner` も `RELAY_RUNNER` もないコマンド（ランナー操作、`relay run`、`relay status`、`relay stop`、`relay record`、`relay bench` のトークン）が探索で runner.json を見つけたとき、`~/.relay/sessions/*/runner.json` があるか `session.lock` が握られているセッションがあれば、警告を stderr に出します。失敗にはせず、終了コードも変えません。セッションなしのランナーを意図して使っているなら無視でき、警告を消すには `--runner` で指定します。調べるのはファイルとロックだけでランナーには問い合わせないので、コマンドは遅くなりません。その代わり、強制終了で残った runner.json も「動いている」と数えます（`relay stop --session <名前>` で片付きます）。
- **録画**: 録画の状態はこれまでどおりポートごとです（ポートはランナーごとに違います）。セッションを指定した `relay record stop` / `status` は、そのセッションの runner.json がなければ終了コード 3 で、ほかのセッションの録画には進みません。止まったランナーの録画は `--port <n>` で指定できます。

一覧（`relay status --all`）は、`~/.relay/runner.json` のランナー（SESSION は `(default)`）と全セッションを 1 行ずつ表示します。終わったセッション（runner.json がなく、ロックも持たれていないもの）は出ません。終了コードは状態によらず `0` です。

```
SESSION  STATE      DEVICE                        URL                     PID
agent-1  running    iPhone 17 Pro (<SIM_UDID_1>)  http://127.0.0.1:8101/  12345
agent-2  starting   -                             -                       12346
agent-3  no answer  iPhone 17 (<SIM_UDID_2>)      http://127.0.0.1:8103/  12347 (exited)
```

STATE は `starting`（boot かビルドの途中で、まだ runner.json がない）、`running`、`busy`（コマンドの実行中）、`no answer`（応答がない。`relay stop --session <名前>` で片付く）、`rejected`（そのポートで別のランナーが応答している）、`unknown`（sandbox などで接続が拒否された）です。`--json` は 1 つの配列で、各要素は `session`（`~/.relay/runner.json` なら `null`）、`state`、`alive`、`url`、`udid`、`name`、`pid`、`processRunning`、`runnerInfo` です。トークンは含みません。

`relay stop --all` は一覧の全部を順に止め、`<セッション>: stopped` を 1 行ずつ出します。ほかのエージェントのランナーも止めるので、エージェントは通常、自分のセッションだけを止めます。`relay stop --session <名前>` は、boot やビルドの途中でまだ runner.json がないセッションも止めます。

## エージェントの sandbox から使う

Claude Code などのコーディングエージェントは、シェルコマンドを OS の sandbox（macOS では Seatbelt）の中で動かすことがあります。relay はそのままでは sandbox の中では動きません。

- **`relay start` は sandbox の中では動きません。** `~/.relay`（ロック、ログ、ビルド）への書き込み、xcodebuild、testmanagerd の unix socket、CoreSimulator の XPC、疑似端末などを使うので、sandbox の書き込み先や socket を少し広げただけでは足りません。sandbox の外で起動してください。
- **ランナー操作のコマンド（`relay status`・`relay tap` など）も、既定の sandbox ではランナーに届きません。** ランナーは `127.0.0.1:<port>`（シミュレータ）で待ち受けていますが、Claude Code の macOS の sandbox は localhost への直接の接続を拒否します。このとき relay は、接続が OS に拒否された（`Operation not permitted`）ことと sandbox の可能性を示します（終了コードは届かないときと同じ `3`）。ランナーが止まっているわけではないので、`relay stop` や `relay start` をし直さないでください。`relay stop` はこの場合、runner.json を消さずに終了コード `3` で終わります。また、sandbox の外で動いている `relay start` を sandbox の中から `relay stop` しようとすると、シグナルを送れずに `cannot signal relay start (pid …): Operation not permitted; relay may be running inside a sandbox …` で終了コード `1` になります。その場合は `relay stop` を sandbox の外で実行してください。
- `relay doctor` は、127.0.0.1 への接続と `~/.relay` への書き込みを試し、OS に拒否されたら（`Operation not permitted`）✗ にします。sandbox かどうかを直接知る方法はないので「sandbox の中で動いているようだ」という扱いです（同じように拒否するネットワークフィルタも区別できません）。

いちばん簡単なのは、**relay を sandbox の外で動かす**ことです。Claude Code では `sandbox.excludedCommands` に relay を書きます（ユーザー設定 `~/.claude/settings.json`、またはプロジェクトの `.claude/settings.json` / `.claude/settings.local.json`）。

```json
{
  "sandbox": {
    "excludedCommands": ["relay *"]
  }
}
```

- パターンは `Bash(...)` の許可ルールと同じ書き方で、`relay *` は relay のコマンドすべてに一致します。除外したコマンドも、通常の許可の確認（permission）は通ります。
- 除外は 1 回の Bash 呼び出しの中のコマンドすべてが一致したときだけ効きます。`cd app && relay tap …`、`relay screenshot > out.png` のようなリダイレクト、`$(…)`、`for`・`if` などを含むと sandbox の中で動きます。relay は 1 回に 1 コマンドで呼んでください（スクリーンショットは `-o <file>` で保存先を指定できます）。
- 管理者が sandbox を必須にしている場合（admin-required）は、リポジトリの `.claude/settings.json` / `.claude/settings.local.json` の `excludedCommands` は無視されます。`~/.claude/settings.json` に書くか、管理者に相談してください。
- sandbox の中から操作のコマンドだけを通したい場合は、`sandbox.network.allowLocalBinding: true`（macOS で localhost の任意のポートへの接続と待ち受けを許す）でランナーに届くようになります。ただし localhost で動くほかのサービスすべてにも届くようになり、sandbox の中のコマンドが localhost 以外のアドレスで待ち受ければ、ほかのマシンからの接続も受けうるようになります。また、管理者が sandbox を必須にしているときは、リポジトリの設定の `allowLocalBinding: true` も無視されます（`~/.claude/settings.json` に書けば効きます）。`relay start` は相変わらず sandbox の外で起動する必要があるので、通常は `excludedCommands` を勧めます。`sandbox.network.allowUnixSockets`（macOS で接続してよい unix socket のパス）や `sandbox.network.allowMachLookup`（XPC のサービス名）、`sandbox.filesystem.allowWrite`（書き込み先）を広げて `relay start` を sandbox の中で動かすことは、試しておらず勧めません。
- エージェントが sandbox で失敗したコマンドを sandbox の外でやり直すこと（Claude Code の `dangerouslyDisableSandbox`。許可の確認が出ます）もできますが、`sandbox.allowUnsandboxedCommands: false` ではできません。
- 実機ではランナーのアドレスは CoreDevice トンネル（IPv6）などになり、localhost ではないので、sandbox のプロキシを通らない直接の接続が拒否されます。やはり relay を sandbox の外で動かします。

ほかのエージェントやツールでも事情は同じです。シェルコマンドを sandbox で動かすものでは、relay（少なくとも `relay start`）を sandbox の外で動かす設定を使い、操作のコマンドには localhost への接続を許してください。Linux 系の sandbox のようにコマンドごとに別の loopback を持つ仕組みでは、localhost はホストのランナーに届かず、接続は拒否ではなく `connection refused` になるので、relay の判定でも sandbox とはわかりません。

Claude Code の設定の根拠: [Sandboxing](https://code.claude.com/docs/en/sandboxing)、[Settings reference の `sandbox`](https://code.claude.com/docs/en/settings-reference#sandbox)。

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
