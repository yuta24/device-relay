# セットアップ

インストールと Runner の用意、端末の選択、環境の確認から、シミュレータ・実機でランナーを起動するまでの詳細です。最初の手順は README の「[インストール](../README.ja.md#インストール)」と「[クイックスタート](../README.ja.md#クイックスタート)」にまとめています。

## インストールと更新

`relay` 本体（CLI）は、ビルド済みの tarball を GitHub Release で配布します。
ファイル名は `device-relay-v<version>-macos-<arm64|x86_64>.tar.gz` です。

端末で動かす Runner は、XCUITest の Xcode プロジェクトです。ソースのまま tarball に入っていて、`relay start` が手元の Mac の Xcode でビルドします。

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
| 手動 | tarball を展開し、`bin/relay` へのリンクを PATH に置きます（[README](../README.ja.md#手動でインストールする)）。 | 新しい tarball を展開し、リンクを張り直します（`ln -sfn`）。 |
| ソース | `git clone` して `make install` します。 | `git pull` して `make install` します。 |

どの入れ方でも、`relay` は自分の実行ファイルの場所から Runner を見つけるので、`relay runner install` は要りません。

### 更新後の Runner とビルド

更新後の最初の `relay start` は、Runner をビルドし直します。
DerivedData は Runner の場所ごとに分かれるので、古いバージョンの分は別のディレクトリに残ります。
保存先は `~/.relay/build/<ディレクトリ名>-<パスのハッシュ>` です。

元の Runner がなくなったものと、30 日使っていないものは `relay start` が消します。
詳しくは「[ログとテスト結果の掃除](sessions.md#ログとテスト結果の掃除)」を参照してください。

以前 `relay runner install`（0.7.0 までは `relay install`）したコピーの `~/.relay/runner` は、更新後は使われません。
`relay skill install` の取り出し元にもなりません（「[エージェントスキル](cli.md#エージェントスキル)」）。
要らなければ `relay runner uninstall` で削除できます。

## Runner の用意（relay runner install）

`relay runner install` は、Runner プロジェクトを `~/.relay/runner/` にコピーします。
必要なのは、`relay` のバイナリだけを別の場所にコピーして、そこから Runner が見つからないときです。
展開したディレクトリ、またはチェックアウトで 1 回実行します。

relay のバージョンと、元がチェックアウトならそのコミットを `~/.relay/runner/install.json` に記録します。

### コピー元とコピーするファイル

`relay runner install` は、展開したリリースか device-relay のチェックアウトを次の順に探します。どちらも同じ配置です。

| 優先順 | コピー元を探す場所 |
| --- | --- |
| 1 | `--project <path>` です。 |
| 2 | `$RELAY_HOME` です。 |
| 3 | カレントディレクトリとその親です。 |
| 4 | `relay` の実行ファイルの場所とその親です（シンボリックリンクを解決します）。 |

コピーするファイルと配置は次のとおりです。リポジトリと同じ配置にします。

| コピーするもの | 内容・配置 |
| --- | --- |
| `Runner/` | プロジェクトは `~/.relay/runner/Runner/RelayRunner.xcodeproj` に置きます。 |
| CLI 側の共有ソース | `Sources/Relay/Shared/RunnerAuth.swift` など、`project.pbxproj` の `../Sources/...` の参照先です。 |
| エージェントスキル | `skills/device-relay` を `~/.relay/runner/skills/device-relay` に置きます。 |

スキルについては「[エージェントスキル](cli.md#エージェントスキル)」を参照してください。

### コピーの更新と削除

`relay runner install` を再実行すると、コピーを上書き更新します。
一時ディレクトリにコピーしてから入れ替えるので、途中で失敗しても前の Runner は残ります。
入れ替えたときは、古いソースのビルド成果物 `~/.relay/build/installed` を削除します。

`relay runner uninstall` は、`~/.relay/runner` とそのビルド成果物を削除します。
`config.json`、`runner.json`、ログは残します。

0.7.0 までの書き方も、次の版までは同じように動き、stderr に `relay runner …` を使うよう注意を出します。

| 0.7.0 までの書き方 | 今の書き方 |
| --- | --- |
| `relay install [--project <path>] [--build [--verbose]]` | `relay runner install` に同じオプション |
| `relay install --remove`、アプリを渡さない `relay uninstall` | `relay runner uninstall` |

パスを渡した `relay install` と、バンドル ID を渡した `relay uninstall` は、アプリを入れる・消すコマンドです（「[アプリを入れる・消す](cli.md#アプリを入れる消すrelay-install--relay-uninstall)」）。

### コピー時にビルドする

`relay runner install --build` は、コピー後にシミュレータ用の `build-for-testing` を行います。
ビルド先は `generic/platform=iOS Simulator` です。

「[ランナーの版（ソースのハッシュ）](#ランナーの版ソースのハッシュ)」の記録も書くので、ソースが同じなら初回の `relay start` はそのビルドを使い回し、ビルドを省きます。

ビルドログは `relay start` と同じく `~/.relay/logs/` に保存します。
名前は `build-<時刻>.log` です。ポートはないので、名前に付けません。
失敗したときはログのパスを示し、コピーした Runner は残します。
`--verbose` を付けると xcodebuild の出力をそのまま表示します。

### コピーの古さの確認

`relay start` は、`~/.relay/runner` に記録したバージョンが `relay` と違えば、「relay runner install を再実行して」と知らせます。
そのコピーを使う場合に確認し、古くても止めません。

`relay doctor` も同じ確認をします。チェックアウトの中などで別の Runner を使っているときも、コピーが古ければ知らせます。
元のチェックアウトのコミットが記録と違う場合も含みます。

ただし、実行ファイルのそばの Runner を使うときはコピーを使わないので、古くても問題にしません。
このときは `not used: relay executable wins` と表示します。コピーがなくても問題にしません。

### 起動に使う Runner の探し方

`relay start` は、次の順に Runner プロジェクトを探します。

| 優先順 | 探す場所 |
| --- | --- |
| 1 | `--project <path>` で指定した場所です。 |
| 2 | `$RELAY_HOME` で指定した場所です。 |
| 3 | カレントディレクトリとその親にある device-relay のチェックアウトです。 |
| 4 | `relay` の実行ファイルの場所とその親にある Runner です（シンボリックリンクを解決します）。 |
| 5 | `relay runner install` した `~/.relay/runner` です。 |

`--project <path>` と `$RELAY_HOME` には、チェックアウトのルート、`Runner/`、`.xcodeproj` のどれでも指定できます。
どちらも、指定した場所にプロジェクトがなければ、ほかを探さずにエラーにします。

対象アプリのリポジトリなどから実行すると、4 の実行ファイルのそばの Runner を使います。
mise や手動で展開したリリース、`make install` のチェックアウトが対象です。
relay を更新すれば Runner も一緒に新しくなり、以前のコピーが使われ続けることはありません。
5 を使うのは、バイナリだけを別の場所にコピーした場合です。

開発時に device-relay のリポジトリ内で実行すると、3 のチェックアウトを使います。
そのため、編集中の Runner が未コミットの変更も含めてビルドされます。
`make install` したリンクでは、チェックアウトの外から実行しても 4 でそのチェックアウトの Runner を使います。

どこにもプロジェクトが見つからなければ、設定方法を示して終了します。
バイナリだけをコピーした場合は、展開したディレクトリかチェックアウトで `relay runner install` を 1 回実行することなどを案内します。

### ビルドの保存先と Xcode の切り替え

DerivedData は Runner プロジェクトごとに分けるので、別のソースでビルドした `.xctestrun` を使い回すことはありません。

| Runner | DerivedData の保存先 |
| --- | --- |
| `relay runner install` したもの | `~/.relay/build/installed` です。 |
| それ以外 | `~/.relay/build/<ディレクトリ名>-<パスのハッシュ>` です。 |

Xcode ごとには分けません。`DEVELOPER_DIR` で Xcode を切り替えてビルドすると、SDK のバージョン入りの `.xctestrun` が並びます。
名前の例は `RelayRunner_iphonesimulator27.2-….xctestrun` です。

これらが指すビルド成果物は `Debug-iphonesimulator` などを共有し、最後のビルドのものになります。

そのため relay は、ビルド直後にはそのビルドが書いた更新日時の新しい `.xctestrun` を選びます。
使い回すときは、最後のビルドのもの、つまり更新日時が最も新しいものを使います。

名前の SDK バージョンが今の Xcode の SDK と違えば、`… is not for this Xcode's … SDK …; rebuilding` と出して再ビルドします。
SDK は `xcrun --sdk iphonesimulator|iphoneos --show-sdk-version` で確認します。

SDK のバージョンが取れないときや、名前から読めないときは、そのまま使い回します。

Xcode を切り替えるたびにビルドし直しますが、同じ Xcode のままならビルドせずに使い回します。
SDK が同じでも、Runner のソースがビルド後に変わっていれば作り直します。
詳しくは「[ランナーの版（ソースのハッシュ）](#ランナーの版ソースのハッシュ)」を参照してください。

### テストのログと結果の保存先

ランナーのテストログと xcresult は、ポートごとの `~/.relay/build/…/TestData/port-<port>` の `Logs/Test` に入ります。
ランナーを起動する `xcodebuild test-without-building` に、この場所を `-derivedDataPath` として渡します。

`~/Library/Developer/Xcode/DerivedData` には何も作りません。

`-xctestrun` には、ビルドした `.xctestrun` ではなく、そのコピー `TestData/port-<port>/RelayRunner.xctestrun` を渡します。
コピーでは XCTest の画面キャプチャを切ります（`PreferredScreenCaptureFormat` を `screenshots`、`SystemAttachmentLifetime` と `UserAttachmentLifetime` を `keepNever`）。
Xcode の既定のままだと、ランナーが動いている間ずっと XCTest が画面を録画します。
`relay stop` で止めればテストは成功扱いで動画は消えますが、xcodebuild の中断などで失敗扱いになると、動画が xcresult に残ります。
コピーを使うので、xcresult には画面の録画もスクリーンショットも入りません。
spindump などの添付も残りませんが、失敗時の診断（xcresult の diagnostics）はこれまでどおり集めます。
画面を録るときは、必要な間だけ `relay record` を使います（「[録画（relay record）](cli.md#録画relay-record)」）。
ビルド済みの成果物、`relay runner install` のコピー、`--project` の Runner のどれでも同じです。
コピーを書けないときは `relay: cannot write …` を出して元の `.xctestrun` で起動し、その場合は録画されます。

古い形式の保存先は「[古い形式の生成物](development.md#古い形式の生成物)」にあります。
古いものは `relay start` が消します（「[ログとテスト結果の掃除](sessions.md#ログとテスト結果の掃除)」）。

### ランナーの版（ソースのハッシュ）

relay はソースのハッシュでビルドを見分け、`git pull` や `relay runner install` 後に古いソースのランナーが黙って使われるのを防ぎます。
`relay start` のたびに計算し、数 ms で済みます。
対象ファイルと計算方法は「[ソースのハッシュの計算](development.md#ソースのハッシュの計算)」を参照してください。

ビルドが成功すると、`.xctestrun` の横の `DerivedData-*/Build/Products/relay-runner-build.json` に記録します。
`relay runner install --build` も同じ記録を書きます。

| 記録する値 | 内容 |
| --- | --- |
| ハッシュ | ビルドした Runner のソースから求めた値です。 |
| relay のバージョン | ビルドに使った relay です。 |
| バンドル ID の接頭辞 | ビルドに使った接頭辞です。 |

記録はビルド前に消すので、失敗したビルドは記録を持ちません。

#### ビルドを使い回す条件

最後のビルドが今の Xcode の SDK のものでも、次の順に調べて該当すれば再ビルドします。`--rebuild` は要りません。

| 確認順 | 再ビルドする条件 |
| --- | --- |
| 1 | 記録がありません（古い relay のビルドや失敗したビルド）。 |
| 2 | バンドル ID の接頭辞が違うか、記録に接頭辞がありません。 |
| 3 | ハッシュが今のソースと違います。 |
| 4 | relay のバージョンが違います。 |

最初に該当した理由を、`runner sources changed since the last build (<前> -> <今>); rebuilding` などと表示します。
ハッシュだけが変わった再ビルドは Xcode の差分ビルドなので、変わったファイルの分だけで済みます。

#### ランナーが返す版と照合

ランナーは、ビルドした版を `/ping` と `/health` の `runner` で返します。
形は `{"version":"0.8.0","sourceHash":"<64 桁>"}` です。Xcode から直接ビルドしたランナーでは値が `null` です。
埋め込み方は「[ランナーの版の埋め込み](development.md#ランナーの版の埋め込み)」にあります。

`relay start` は ready の時点で `/health` の `runner` を確かめます。
一致すれば `relay: runner 0.8.0 (sources <12 桁>)` と表示します。
違う場合や、版を名乗らない場合は `warning:` を出しますが、止めません。
ソースは relay が今ビルドまたは確認したものなので、ずれているのは名乗る値だけです。

runner.json には期待する版を `runner` に保存します。
`relay status` は、期待する版と `/ping` の `runner` を並べて表示します。
ランナー操作のコマンドは、ソースのハッシュを計算しません。

版を名乗らない古いランナーにも接続できます。このとき `relay status` の `runner:` は `not reported` です。

## 端末の選択（relay devices）

`relay devices` は、実機と iOS シミュレータの名前、UDID、種類、OS、状態を一覧表示します。
実機は `xcrun devicectl list devices`、シミュレータは `xcrun simctl list devices` で取得します。

`--json` で JSON の配列を出します。
`--os <version>` を付けると、その OS のものだけを表示します。一致の仕方は「[OS で候補を絞る](#os-で候補を絞る)」と同じです。

実機の一覧を取得できない場合は、シミュレータだけを表示していることを stderr の警告で知らせ、その後に devicectl のエラー詳細を出します。実機が接続されていないという意味ではありません。
権限拒否や書き込み拒否が含まれるときだけ、relay がサンドボックスの中にいる可能性と、サンドボックスの外で実行する対処を案内します（「[エージェントの sandbox から使う](sessions.md#エージェントの-sandbox-から使う)」）。タイムアウトだけでは、この案内は出しません。
`--json` の stdout は従来どおりシミュレータの JSON 配列で、終了コードは 0 です。シミュレータの一覧も取得できない場合は、従来どおりコマンドが失敗します。

```
NAME           UDID                                  KIND       OS          STATE
Test Phone     00000000-0000000000000000             device     iOS 26.7.1  connected
iPhone 17 Pro  11111111-1111-1111-1111-111111111111  simulator  iOS 27.0    booted
iPhone 17      22222222-2222-2222-2222-222222222222  simulator  iOS 27.0    shutdown
```

### 起動・確認する端末の決め方

`relay start` と `relay doctor` は、次の順に端末を決めます。
選んだ端末は必ず `relay: using …` として、OS と選んだ理由つきで表示します。

| 優先順 | 指定・条件 | 選ぶ端末 |
| --- | --- | --- |
| 1 | `--udid <UDID>` | 指定した UDID の端末です。 |
| 2 | `--device <名前>` | 大文字小文字を無視して名前が完全一致する端末です。 |
| 3 | どちらも指定しない | 接続中の実機が 1 台だけなら、それを使います。 |
| 3 | どちらも指定せず、実機がない | 起動中のシミュレータが 1 台だけなら、それを使います。 |

自動選択で候補が複数、または 0 台なら、候補一覧つきでエラーにします。

`--device <名前>` で同じ名前が複数ある場合は、ランタイム違いのシミュレータなどを次の順に選びます。

| 確認順 | 条件 | 結果 |
| --- | --- | --- |
| 1 | 接続中・起動中のものが 1 つだけある | その端末を使います。 |
| 2 | 候補がすべてシミュレータ | 最も新しい iOS のものを使います。 |
| 3 | 実機とシミュレータが混在、同名の実機が複数、または最新 iOS のシミュレータが複数 | 候補つきでエラーにします。 |

2 の候補は、起動中のものがあればその中、なければすべてです。
iOS のバージョンは数値で比べるので、`26.10` は `26.5` より新しいと判定します。
実機は OS で推測しません。エラーの場合は `--simulator` か `--udid` で選びます。

同名のシミュレータから最新の iOS を選ぶと、次のように表示します。

```text
relay: using iPhone 17 Pro (iPhone 17 Pro, iOS 27.0, simulator, shutdown) <SIM_UDID> (--device; the newest iOS of 3 simulators named "iPhone 17 Pro")
```

### シミュレータだけから選ぶ

`--simulator` を付けると、端末の選択前に候補をシミュレータだけに絞ります。
実機が接続されていても、`--device` で同じ名前の実機があっても、シミュレータを選びます。
`--udid` / `--device` とも、自動選択とも組み合わせられます。

`--device` なしで選ぶ場合の結果は、次のとおりです。

| 起動中のシミュレータ | 結果 |
| --- | --- |
| 1 台 | そのシミュレータを使います。 |
| 複数 | 候補つきでエラーにします。 |
| 0 台 | 新しい iOS のものから順に候補を示し、`--device <名前>` で選ぶようエラーで案内します。 |

どのシミュレータを使うかは、iPhone か iPad か、画面の大きさによってスクリーンショットや座標に関わります。
そのため、勝手に選んで boot はしません。

### OS で候補を絞る

`--os <version>` は、端末の選択前に OS が前方一致するものだけに絞ります。
区切りの `.` ごとに比べ、足りない桁は 0 とみなします。
`--udid` / `--device` とも、自動選択とも組み合わせられます。

| 指定 | 一致する OS | 一致しない OS |
| --- | --- | --- |
| `--os 27` | iOS 27.0、27.1 です。 | — |
| `--os 26.5` | iOS 26.5、26.5.1 です。 | iOS 26.6、26.50 です。 |
| `--os 27.0` | iOS 27 です。 | — |

`--os 26.5` で 27.0 が選ばれると意図と違うため、「以上」の比較にはしません。

### 実機の一覧を取得しない場合

`--simulator` を付けたときと、`--udid` が `simctl` の一覧にあるシミュレータのときは、devicectl を呼びません。
実機を選ぶことがないため、`devicectl list devices` による実機の一覧は不要です。

CoreDevice が応答しないときの待ちや、`Timed out waiting for CoreDeviceService` などの警告も出ません。

このとき `relay doctor` の `devices` の行には、実機の数を出しません。
候補が見つからないときのエラーにも実機は並びません。表示例は次のとおりです。

```text
0 booted simulator(s), … iOS simulator(s) (devices not listed: --udid is a simulator)
```

`--device <名前>` だけでは、同じ名前の実機があるかを確かめるために devicectl を呼びます。
シミュレータだけから選ぶなら `--simulator` を付けます。

### シミュレータの自動起動と終了

停止中のシミュレータを `--udid` / `--device` で指定すると、`relay start` が `simctl boot` して起動を待ちます。
relay が boot したシミュレータは、`relay start` の終了時に shutdown します。Ctrl-C で終了した場合も同じです。

boot やビルドの途中で、ランナーの起動前に Ctrl-C または SIGTERM を送った場合も shutdown します。
実行中の simctl や xcodebuild を止めてから行います。もともと起動していたシミュレータは、そのままにします。

## Team ID（実機の署名）

実機の署名チームの指定と保存は「[Team ID（実機の署名）](device.md#team-id実機の署名)」を参照してください。

## 環境の確認（relay doctor）

`relay doctor` は、ビルドや起動をせずに環境と端末を確認します。

```sh
relay doctor [--udid <UDID> | --device <名前>] [--simulator] [--os <version>] [--project <path>] [--json]
```

| 表示 | 意味 | 終了コードへの影響 |
| --- | --- | --- |
| ✓ | 問題なしです。 | ✗ がなければ `0` です。 |
| ✗ | このままでは動きません。 | `1` で終了します（ローカルの失敗）。 |
| ! | 注意が必要です。 | ✗ がなければ `0` です。 |

✗ と ! には、直し方を 1 行添えます。

### ホストと Runner の確認

`relay doctor` は、relay、Xcode、Runner、エージェントスキルを確認します。

| 項目 | 確認する内容 |
| --- | --- |
| ホスト | relay のバージョン、Xcode、xcrun、devicectl です。 |
| Xcode | `xcodebuild -version` と `xcode-select -p` の結果です。 |
| Runner | プロジェクトの解決結果と、`relay runner install` の状態です。 |
| コピーの記録 | バージョン・コミット・コピー元がずれていれば ! です。 |

エージェントスキルは、カレントディレクトリの git のルートの `.claude/skills/device-relay` と `~/.claude/skills/device-relay` を確認します。
判定は `relay skill status` と同じです。

relay や取り出し元とバージョン・コミットが違う場合、または relay が入れたものでない場合は ! です。
入っていなくても問題にはしません。

### 端末の選択と使用状況

`relay doctor` は、端末一覧と、同じオプションの `relay start` が使う端末を確認します。
`--udid` / `--device` がなければ自動選択の結果です。

自動選択で実機になる場合は、シミュレータで試すなら `--simulator` か `--device <シミュレータ名>` を付けるよう、! で知らせます。

ほかの `relay start` やセッションが使っている端末が候補にあれば、`in use` の行を出します。
端末と使っている相手を `session a, relay start pid 123` のように表示し、使用中がなければこの行は出ません。

自動選択では、`relay start` と同じく使用中の端末を外します。
`--udid` / `--device` で指定した端末が使用中なら、target を ✗ にします。
`relay stop --session <名前>` などの止め方か、別の端末を指定するよう案内し、その端末の残りの確認は続けます。

`relay doctor` はセッションを持たないので、空いている起動中のシミュレータが複数あっても 1 台には決めません。
`relay start --session` なら選びます。使用中でない候補が 1 台もなければ、target は ! です。

### 端末・署名・バンドル ID の確認

`relay doctor` は、選んだ端末の状態と署名を確認します。

| 端末・項目 | 確認する内容 |
| --- | --- |
| 実機の OS | 17 以上かを確認します。 |
| 実機の接続 | 接続状態とペアリングを確認します。 |
| 実機のデベロッパモード | `devicectl list devices` で確認します。 |
| 実機の DDI | `ddiServicesAvailable` でマウント状態を確認します。 |
| 実機のロック | `devicectl device info lockState` の `passcodeRequired` で確認します。 |
| シミュレータ | ランタイムが入っているかと、起動状態を確認します。 |
| 署名 | 証明書と Team ID を確認します。 |

UI オートメーションの有効状態は Mac から読めないので、常に ! で確認を促します。
署名の証明書と Team ID が見つからなければ、実機では ✗、シミュレータでは ! です。

バンドル ID は、`relay start` が使う接頭辞と出どころを表示します。

| 出どころ | 内容 |
| --- | --- |
| config | `bundleIDPrefix` の設定です。 |
| Team ID | Team ID から作った既定値です。 |
| Team が分からない | Team が分からない状態を表示します。 |
| シミュレータ | シミュレータの既定値です。 |

表示だけで、config の値が不正なときだけ ✗ です。
詳しくは「[バンドル ID の接頭辞](device.md#バンドル-id-の接頭辞)」を参照してください。

### sandbox の確認

`relay doctor` は、127.0.0.1 への接続と、`~/.relay` があればその中へのファイルの作成を試します。
OS に `Operation not permitted` で拒否されたら、エージェントなどの sandbox の中で動いているようだとして ✗ にします。

設定は「[エージェントの sandbox から使う](sessions.md#エージェントの-sandbox-から使う)」を参照してください。

### relay doctor --json

`--json` を付けると、1 つの JSON オブジェクトを 1 行で stdout に出します。
キーは辞書順で、人向けの ✓ / ✗ / ! の行は出しません。終了コードは同じで、✗ があれば `1`、なければ `0` です。

```json
{"checks":[{"detail":"0.8.0","fix":null,"name":"relay","section":"Host","status":"ok"},{"detail":"no booted iOS simulator (--simulator); pass --device <name> to boot one","fix":"relay devices lists the simulators; …","name":"target","section":"Devices","status":"warning"}],"ok":true,"problems":0,"warnings":1}
```

| キー | 内容 |
| --- | --- |
| `ok` | ✗ にあたる `problem` が 1 つもなければ `true` です。 |
| `problems` / `warnings` | `status` が `problem` / `warning` の項目の数です。 |
| `checks` | 人向けの表示と同じ順の項目の配列です。 |
| `checks[].section` | `Host`、`Devices`、`Target: <端末名>`、`Signing` の見出しです。 |
| `checks[].name` | `Xcode`、`signing`、`target` などの項目名です。 |
| `checks[].status` | `"ok"`、`"warning"`、`"problem"` の 3 つだけです。 |
| `checks[].detail` | 人向けの行と同じ内容の文です。 |
| `checks[].fix` | 直し方の 1 行か、`null` です。 |

`ok` が `true` であることは、終了コード 0 と同じです。
`checks` には端末の一覧表を含みません。一覧には `relay devices --json` を使います。

| `checks[].status` | 人向けの表示 | `checks[].fix` |
| --- | --- | --- |
| `"ok"` | ✓ です。 | `null` です。 |
| `"warning"` | ! です。 | 直し方がなければ `null` です。 |
| `"problem"` | ✗ です。 | 直し方を示します。 |

`warning` と `problem` の直し方は 1 行です。
これらのキーと `status` の 3 つの値は変えません。`name` と `detail` の文言は人向けで、変わることがあります。

### relay start のビルド前の確認

`relay start` も、ビルド前に同じ端末のチェックを行います。

| 判定 | 条件 | 動作 |
| --- | --- | --- |
| ✗ | 未接続、未ペアリング、デベロッパモードが無効、iOS 17 未満、シミュレータのランタイムがない場合です。 | ビルドせずに終了します。 |
| ! | ロック中、DDI 未マウントの場合です。 | 表示だけして続けます。 |

## シミュレータ

`relay start --device "iPhone 17 Pro"` は、指定したシミュレータでランナーを起動します。
停止中なら boot し、relay の終了時に shutdown します。シミュレータのランナーは 127.0.0.1 だけで待ち受けます。

```sh
relay start --device "iPhone 17 Pro"   # 停止中なら boot し、終了時に shutdown
# relay: runner project: <展開したディレクトリ> (from relay executable)
# relay: using iPhone 17 Pro (iPhone 17 Pro, iOS 27.0, simulator, shutdown) <SIM_UDID> (--device; the newest iOS of 3 simulators named "iPhone 17 Pro")
# relay: booting simulator iPhone 17 Pro (<SIM_UDID>); it is shut down when relay exits
# relay: building runner from sources <ハッシュ 12 桁> (log: ~/.relay/logs/build-<時刻>-8100.log)   ← 初回、ソースが変わったとき、--rebuild 指定時
#        （使い回すときは relay: reusing RelayRunner_iphonesimulator27.2-….xctestrun (runner sources <ハッシュ 12 桁>)）
# relay: launching runner on <SIM_UDID> (log: ~/.relay/logs/runner-<時刻>-8100.log)
# relay: runner listening; device addresses: 127.0.0.1   ← シミュレータのランナーは 127.0.0.1 だけで待ち受けます
# relay: runner 0.8.0 (sources <ハッシュ 12 桁>)   ← ランナーが名乗る版（「ランナーの版」）
# ready: http://127.0.0.1:8100/
# token: ~/.relay/runner.json
```

初回、ソースが変わったとき、`--rebuild` 指定時にビルドします。
ランナーが名乗る版は「[ランナーの版（ソースのハッシュ）](#ランナーの版ソースのハッシュ)」を参照してください。

### ready 後に接続する

ready になると、URL とアクセストークンを `~/.relay/runner.json` に書き出します。
パーミッションは 0600 です。別のターミナルから接続できます。

```sh
TOKEN=$(jq -r .token ~/.relay/runner.json)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8100/health
relay bench --count 5 --tap 200,120   # URL もトークンも runner.json から読む（他のコマンドと同じ探し方。--url と --token で上書きできる）
```

`relay bench` は、ほかのコマンドと同じ探し方で runner.json から URL とトークンを読みます。
`--url` と `--token` で上書きできます。
`relay health` などのサブコマンドは「[CLI から操作する](cli.md#cli-から操作する)」を参照してください。

### ランナーを停止する

Ctrl-C を押すか、別のターミナルで `relay stop` を実行すると、`relay` が `/shutdown` を送り、`runner.json` を削除します。
ランナーはテストメソッドから抜けて `** TEST EXECUTE SUCCEEDED **` で終了し、`relay` も終了します。

| 停止した時点・条件 | 動作 |
| --- | --- |
| ランナーが 10 秒以内に終了しない | xcodebuild を terminate します。 |
| ready 前に Ctrl-C を押す | `/shutdown` を送る先がないので、xcodebuild をすぐに terminate します。 |
| ランナー起動前の boot やビルド中 | そのビルドの xcodebuild を止め、relay が boot したシミュレータを shutdown します。 |

ランナー起動前に停止すると、`relay: stopped before launching the runner` と表示して終了コード 1 で終わります。

### ready 後の生存確認と失敗

`relay start` は、ready 後も 3 秒ごとに `/ping` を送り、ランナーの生存を確認します。
`200` だけを生存扱いにします。

`/ping` はコマンドの実行中でも busy ゲートを通らずに即答します。
そのため、生存確認が利用者のリクエストと重なって `409` を起こすことはありません。
ready の判定、つまり起動直後の探索には、XCUI が動くことを確かめるため `/health` を使います。

`200` 以外が 3 回続けば、応答がないものとしてランナーが落ちたとみなします。
エラーを表示し、xcodebuild を止めて `runner.json` を削除し、終了コード 1 で終わります。
`runner.json` を書き出せなかった場合も、ランナーを止めてから終了コード 1 で終わります。

古いソースで `/ping` に対応しないランナーの扱いは「[古いランナーの生存確認](development.md#古いランナーの生存確認)」を参照してください。

### 起動オプション

`relay start` のオプションで、端末、Runner、ポート、起動時の動作を指定できます。

| オプション | 説明 |
| --- | --- |
| `--udid <UDID>` / `--device <名前>` | 使う端末を指定します。同時には指定できず、省略すると自動で選びます。 |
| `--simulator` | 実機が接続されていても、シミュレータだけから選びます。 |
| `--os <version>` | `27`、`27.0`、`26.5` などの OS バージョンで候補を絞ります。 |
| `--project <path>` | `$RELAY_HOME` より優先して Runner プロジェクトの場所を指定します。 |
| `--port 8100` | 端末側の待ち受けポートを指定します。 |
| `--session <名前>` | 状態ファイルとポートをほかのランナーと分けます。 |
| `--team-id <TEAM_ID>` | 実機向けの署名チームを指定します。 |
| `--rebuild` | `~/.relay/build/…/DerivedData-*` に既存の `.xctestrun` があっても再ビルドします。 |
| `--verbose` | xcodebuild の出力をそのまま表示します。 |
| `--allow-wifi` | 実機で CoreDevice トンネルに加えて Wi-Fi などのアドレスも探索します。トークンが同じネットワークに平文で流れるので、既定では無効です。 |
| `--ready-timeout 180` | `/health` が応答するまで待つ秒数を指定します。 |
| `--background` | 端末から切り離して起動し、ready になったら終了します。 |

端末の指定は、`--simulator`、`--os <version>` と合わせて「[端末の選択（relay devices）](#端末の選択relay-devices)」を参照してください。

`--project <path>` の指定先は「[Runner の用意（relay runner install）](#runner-の用意relay-runner-install)」にあります。

`--rebuild` がなくても、最後のビルドが今の Xcode の SDK と違う場合、Runner のソースやバンドル ID の接頭辞が変わった場合、記録のない古いビルドの場合は再ビルドします。
詳しくは「[ランナーの版（ソースのハッシュ）](#ランナーの版ソースのハッシュ)」を参照してください。

ポートは xcodebuild に `TEST_RUNNER_RELAY_RUNNER_PORT` として渡され、ランナーからは `RELAY_RUNNER_PORT` として見えます。
セッションでは、ポートを省略すると空きポートを選びます。セッション名は環境変数 `RELAY_SESSION` でも指定できます。

詳しくは「[複数のセッションを並列に動かす](sessions.md#複数のセッションを並列に動かすrelay-start---session)」を参照してください。

`--team-id <TEAM_ID>` を省略すると署名チームを自動検出します（「[Team ID](device.md#team-id実機の署名)」）。
`-allowProvisioningUpdates RELAY_DEVELOPMENT_TEAM=<TEAM_ID>` を付けてビルドし、ランナーが起動できたら `~/.relay/config.json` に保存します。

xcodebuild の出力に `Failed to initialize for UI testing` やテストの失敗が出た場合は、`--ready-timeout 180` の時間を待ちません。
エラー内容と対処のヒントを表示して、非ゼロで終了します。

`--background` の使い方は「[バックグラウンドで動かす](sessions.md#バックグラウンドで動かすrelay-start---background--status--stop)」にあります。

## 起動とセッション

起動・停止、接続先の選択、並列セッション、ログとテスト結果の掃除は「[起動とセッション](sessions.md)」を参照してください。

## エージェントの sandbox から使う

エージェントから relay を使う設定は「[エージェントの sandbox から使う](sessions.md#エージェントの-sandbox-から使う)」を参照してください。

## 実機

実機で使うための手順は「[実機](device.md)」を参照してください。

- [準備](device.md#準備): 端末の設定、ペアリング、初回の起動
- [Team ID（実機の署名）](device.md#team-id実機の署名): 署名チームの指定と保存
- [バンドル ID の接頭辞](device.md#バンドル-id-の接頭辞): アプリの ID と `host` の指定
- [接続の経路](device.md#接続の経路): CoreDevice トンネルと Wi-Fi
- [録画の準備](device.md#録画の準備): USB 接続と macOS のカメラの許可
