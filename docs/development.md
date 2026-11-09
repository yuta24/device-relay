# 開発者向けの情報

device-relay 自体を開発・検証するときの情報です（リポジトリ内での実行、ランナーの手動起動、検証用のホストアプリ、リリースの手順）。全体の入口は [README](../README.ja.md) です。

## リポジトリ内での開発

- 開発中はリポジトリ内で `xcrun swift run relay …` でも動きます。リポジトリ内ではカレントディレクトリのチェックアウトの Runner を使うので、`relay install` 済みでもインストールしたコピーではなく手元の変更がビルドされます。

```sh
xcrun swift build
xcrun swift test
xcrun swift run relay doctor
```

変更後の CLI の一括検証は、リポジトリ内で `mise run check` を実行します。
初回は `mise trust` と `mise install --locked` を実行してください。
Swift・Python の整形検査、Python・Workflow・Shell の静的検査、カバレッジ付き Swift テストと Python テストを実行し、Swift テスト成功後に
カバレッジ下限を検証します。Python テストは独立して並列実行できます。
いずれかが失敗するとタスク全体が失敗します。CI の CLI ジョブも同じタスクを使います。
結果は `coverage/` に出力します。端末側 Runner のビルドとシミュレータ動作は CI の別ジョブで検証します。

必要な検証だけを個別に実行することもできます。

| コマンド | 内容 |
| --- | --- |
| `mise run build` | CLI のビルド |
| `mise run test:swift` | Swift テストとカバレッジ計測（ビルドも含む） |
| `mise run test:python` | カバレッジ集計・ツール更新確認・Runnerスモークの Python テスト |
| `mise run coverage` | Swift テストを実行してからカバレッジ下限を検証 |
| `mise run lint:workflow` | 全 Workflow を actionlint で検査（埋め込み Shell の ShellCheck も含む） |
| `mise run lint:shell` | `scripts/*.sh` を ShellCheck で検査 |
| `mise run format` | Swift ソースと Package.swift を自動整形 |
| `mise run lint:swift` | 同じ設定で整形漏れを検査（ファイルは変更しない） |
| `mise run format:python` | Python スクリプトのimport順序と書式を Ruff で自動整形 |
| `mise run lint:python` | Python の静的検査と整形チェック（ファイルは変更しない） |
| `mise run check` | 静的検査、Python テスト、Swift テストとカバレッジ検証を一括実行 |
| `mise run test:package` | 署名なしの arm64・Intel 配布パッケージを生成・検証 |
| `mise run test:runner` | 専用シミュレータでRunnerの起動・認証・ping・停止を検証 |
| `mise run tools:outdated` | プロジェクトのツール更新候補を確認（候補があれば終了コード1） |

`check` は `lint:swift`・`lint:python`・`lint:workflow`・`lint:shell`・`coverage`・`test:python` に、`coverage` は `test:swift` に依存します。
`swift test` がビルドも行うため、`check` から `build` を別途呼び出すことはありません。
`test:package` は Release ビルドを行うため `check` には含めず、CI の専用ジョブで実行します。
PR では `Sources/`・`Runner/`・`skills/`・`scripts/`・`Package.swift`・`Makefile`・mise 設定とロック・
CI／Release Workflow の変更時に実行し、文書だけの変更では省略します。`main` への push では毎回実行します。
同じビルドディレクトリを使うため、ローカルで `check` と `test:package` を同時実行しないでください。

### Swift の整形

SwiftFormat（nicklockwood版）0.64.6 を mise と `mise.lock` で固定しています。
`mise run format` で整形し、`mise run lint:swift` で同じルールによる検査を行います。
CI の `mise run check` も整形漏れがあると失敗します。
対象は `Package.swift`・`Sources/`・`Tests/`・`Runner/` の Swift ファイルで、
生成物のある `.build/`・`.relay/` は対象に含めません。グローバルの整形キャッシュは使用しません。

ルールは `.swiftformat` に明示し、2スペース・LF、空白・インデント・改行の整形に限定しています。
`.editorconfig` にも Swift ファイルの2スペース・LF・末尾改行を定義しています。
構文や宣言を書き換えるルールは導入していません。
最低コンパイラ版は Swift 6.2、言語モードはCLI・Tests・Package.swiftで6です。
Runner と両ターゲットでコンパイルする `Sources/Relay/Shared/` は、各ディレクトリの
`.swiftformat` で言語モード5を指定しています。

初回の一括整形コミットは `.git-blame-ignore-revs` に記録しています。
ローカルでも履歴調査から除外する場合は `git config blame.ignoreRevsFile .git-blame-ignore-revs` を実行してください。

### Python の静的検査・整形

Ruff 0.17.4 を mise と `mise.lock` で固定しています。
`mise run format:python` でimport順序を整えてから整形し、`mise run lint:python` で
静的検査と整形チェックを行います。CI も `check` 経由で同じ検査を実行します。
対象はテストを含む `scripts/` の Python ファイルです。

設定は `ruff.toml` に置き、Python 3.14を対象に基本的な構文・名前の検査
（`E4`・`E7`・`E9`・`F`）とimport順序（`I`）を有効にしています。
書式は4スペース・行長88・LFを使用し、`.editorconfig` にも4スペース・LF・末尾改行を定義しています。
`format:python` の自動修正はimport順序と整形のみです。
未使用importなどの指摘は `lint:python` で確認して修正してください。
Ruff のキャッシュ `.ruff_cache/` は Git の管理対象外です。

### 配布パッケージのスモークテスト

```sh
mise run test:package
```

リリースと同じ `scripts/package.sh` で両アーキテクチャの tarball と `.sha256` を生成し、
リポジトリ外の空白を含む一時パスへコピー・展開して検証します。署名用の環境変数は除去します。
チェックサム、アーカイブのトップディレクトリ、実行権限、バイナリのアーキテクチャ、
Runner・スキル・文書の全追跡ファイルと Xcode プロジェクトが参照する共有ソースの内容を確認します。
ホストと同じアーキテクチャでは、展開した CLI の `--version` と `--help` も実行します。
別アーキテクチャの実行確認、署名・公証、実機操作は対象外です。

CI のパッケージ専用ジョブでは `.build` を `actions/cache` で保存します。
OS・ホストアーキテクチャ・Xcode のパスとビルド番号・Swift・macOS SDK・macOS バージョン・
Release 構成と対象アーキテクチャの組・Package 定義でキャッシュを分離します。
同じ条件なら直近のソース版のキャッシュも復元し、Swift が必要な再ビルドを行います。
キャッシュ命中時も、パッケージ生成とスモークテストは毎回実行します。
CLI のテスト用 `.build` や Runner の DerivedData とは共有しません。
初回やツールチェーン更新時はキャッシュミスになります。実際の短縮効果は CI で確認します。
正式な Release Workflow はこのキャッシュを復元・保存せず、毎回ビルドして署名・公証します。

生成物は `dist/` に残し、一時展開先は終了時に削除します。
`package.sh` は配布ファイルを `HEAD` から取得するため、同梱ファイルの変更を検証するときは
先にコミットしてください。ネイティブ向けだけ試す場合は `bash scripts/package-smoke.sh` で実行できます。

actionlint 1.7.12 と ShellCheck 0.11.0 は `mise.toml` で固定しています。
既存チェックアウトでは `mise install --locked` で追加ツールをインストールしてください。
actionlint は全 `.github/workflows/` を検査し、PATH 上の固定版 ShellCheck と連携します。
未導入ツールの有無で結果が変わらないよう、任意の Python 検査連携（Pyflakes）は無効です。
既知ラベル一覧にない既存の `xcode-27` のみ `.github/actionlint.yaml` に明示しています。

## CI のカバレッジ計測

push（main）と pull request の CLI ジョブで、Xcode 26・27 のそれぞれについて
`swift test --enable-code-coverage` を実行します。Actions のジョブサマリーに
全体・領域別・ファイル別の結果を表示し、`coverage-<image>` artifact に生の LLVM JSON、
`summary.json`、`summary.md` を30日間保存します。実行ごとの artifact で推移を比較できます。
artifact の保存方法は [GitHub の公式ドキュメント](https://docs.github.com/en/actions/tutorials/store-and-share-data) を参照してください。

集計対象は `Sources/Relay/**/*.swift`（`main.swift` を含む）のみです。
テスト、生成コード、端末側 Runner は含みません。行・関数・region のカバレッジを計測します。
region は LLVM の実行領域であり、分岐カバレッジとは異なります。

`scripts/coverage-thresholds.json` の全体の行・関数・region 下限と領域別の行下限を
下回ると CI が失敗します。初期下限はコミット `4c60eb3` のローカル計測を基に、
環境差を考慮して少し切り下げています。Xcode ごとの初回 CI 結果は確認してください。
これは固定下限で、直前実行からのすべての低下を検出するものではありません。
テストを追加して安定して改善した際には、同じ PR で下限も引き上げてください。
閾値を下げる場合は、その理由と検証への影響を PR に記載してください。
領域は `Sources/Relay/` 直下のディレクトリ単位です。新しい領域を追加した場合は、
同じ PR で `scripts/coverage-thresholds.json` の `areas` に行カバレッジ下限を追加してください。
下限未設定の領域はエラーになります。領域を削除・改名したときも、残った旧領域の下限を
削除・更新しないとエラーになります。既存領域内のサブディレクトリはその領域の下限を使います。
`main.swift` など直下のファイルは従来どおり全体の下限で検証し、領域別の設定は不要です。
新しい Swift ファイルが計測結果から欠落した場合も失敗します。

ローカルでも CI と同じ `check` タスクを使用します。

カバレッジ集計用の Python は `mise.toml` で 3.14.3 に固定しています。
CI も同じ設定を使用し、mise 本体は 2026.11.4 に固定しています。
初回は `mise trust` と `mise install --locked` を実行してください。
Swift は Xcode 付属のものを `xcrun` で選択し、CI では Xcode 26・27 の互換性を確認します。
CI の27系は CLI・Runner ともに Release と同じ Xcode 27.2 を明示的に選択します。
26系は引き続きランナー既定の安定版を使用します。ランナーイメージのリビジョンは固定していません。
Release は以下のとおり、Xcode のバージョンとビルド番号を明示しています。

```sh
mise run check
```

`mise.lock` はプロジェクトの5ツールについて、`macos-arm64`（Apple Silicon）と
`macos-x64`（Intel）のバージョン・取得先 URL・SHA-256 チェックサムを管理します。
CI の mise セットアップにも `--locked` を指定しています。未記録のプラットフォームや
バージョンでは、取得先を自動解決せずインストールを失敗させます。
`mise.toml` の `[tool_config] locked = true` により、通常の `mise install` や
タスク実行でもプロジェクトのツールにはロックを強制します。
グローバルや親ディレクトリで定義されたツールの方針には影響しません。
Xcode・macOS 自体はこのロックの対象外です。

ツールを更新するときは `mise.toml` のバージョンを変更し、次を実行して
`mise.lock` と一緒にレビュー・コミットしてください。ロックファイルは手編集しません。

```sh
mise lock --platform macos-arm64,macos-x64
mise install --locked
mise run check
```

## mise 管理ツールの更新確認

`mise run tools:outdated` は `mise outdated --bump --no-global --json` を使い、
Python・actionlint・ShellCheck・SwiftFormat・Ruff の更新候補を調べます。グローバルのツールは対象外です。
完全固定バージョンにも更新候補を出すため `--bump` を使用し、メジャー更新も含みます。
通常の `check` には含めず、ネットワークを使う保守タスクとして分けています。

`.github/workflows/tool-updates.yml` が毎週月曜00:23 UTC（日本時間09:23）に実行します。
Actions の `mise tool updates` から手動実行も可能です（定期実行は main へのマージ後に有効）。
候補がある場合はジョブを失敗させ、サマリーに現在版・候補版を表示し、
`tool-updates/` の JSON と Markdown を30日間 artifact として保存します。
候補がなければ成功します。取得エラーも失敗として扱い、更新なしとは判断しません。
mise が終了コード0でも、未確認ツールを示す `Could not check ... for updates` 警告があれば
失敗させ、サマリーに確認未完了と明記します。取得できた更新候補はその場合も保存します。
通知を受け取るかどうかは個人の GitHub Actions 通知設定に従います。

この処理はバージョンやロックファイルの変更、自動PR作成、マージを行いません。
候補が見つかったら、リリースノートと公開脆弱性情報を確認し、`mise.toml` の対象バージョンを変更して
`mise lock --platform macos-arm64,macos-x64`、`mise install --locked`、`mise run check` を実行します。
配布処理への影響がある場合は `mise run test:package` も実行し、設定とロックを同じPRで更新してください。
ツールのバージョンを記載した README・開発ドキュメントも更新します。

## Runner のシミュレータ動作テスト

`mise run test:runner` は CLI をビルドし、インストール済みの iOS ランタイムから
選択した Xcode の Simulator SDK 以下で iPhone 17 Pro に対応する最新バージョンを選び、
テスト専用の iPhone 17 Pro を作成します。同じバージョンではランタイム識別子で順序を固定します。
対応ランタイムがない場合は失敗し、別機種には切り替えません。ランタイムのダウンロードは自動実行しません。

一意のセッションで `relay start` を起動し、待ち受け開始、不正・未指定トークンの401拒否、
正しいトークンのHTTP pingとCLI ping、`relay stop` を検証します。停止後は起動プロセス群、
待ち受けポート、runner.json が残っていないことと、セッションロックが解放されることを確認します。
成功・失敗とも専用シミュレータをshutdown・削除し、専用セッションディレクトリを削除します。
SIGINT・SIGTERMによるキャンセルでも同じ後片付けを行い、終了コードはそれぞれ130・143になります。
リソース作成中は所有情報を記録してからキャンセルを処理し、後片付け中の追加シグナルでは中断しません。
SIGKILLやCIホストの強制停止では後片付けを保証できません。
既存シミュレータの流用や、既存セッションの停止は行いません。

`relay stop` は Runner の停止後に行うシミュレータ停止（最大120秒）も含め、
起動プロセスの終了を最大180秒待ちます。スモークテスト側は通常停止・後片付けともに
その外側の上限を240秒とし、CLIの処理途中で打ち切らないようにしています。
`relay start --background` の起動失敗時も、同じ180秒を待ってから強制終了に進みます。

通常の `check` には含めません。同じビルドディレクトリを使うため、ローカルでは
`check`・`test:package` と同時実行しないでください。CIでは26・27両系のRunnerジョブで実行します。
診断情報は実行ごとに `runner-smoke/<session>/` へ保存し、CIでは成功・失敗とも7日間artifactとして保存します。

- `start.log`・`stop.log`・`cleanup.log`: CLIの起動・停止と、必要になった場合の後片付けログ
- `build-*.log`・`runner-*.log`: このセッションのビルド・XCTest詳細ログ（作成されたものだけ回収）
- `environment.json`: Xcode・SDK、ホスト、機種、ランタイム識別子・バージョン・ビルド番号
- `timeline.jsonl`: 工程イベントのUTC時刻と実行開始からの経過秒数
- `summary.json`: 成否・エラー、boot・build・ready待ち・stop・後片付けの所要時間、収集時の警告

CLIの工程マーカーは250ミリ秒ごとに読み取るため、時刻と所要時間は観測時点の概算です。
途中で失敗した工程は所要時間が `null` となり、ビルド再利用時は `build_reused` が `true`、buildは0秒になります。
成功・失敗・キャンセル時の後片付けを試みてから詳細ログを回収するため、セッションの状態を削除してもログは残ります。
収集エラーは警告として扱い、テストの結果を変更しません。CIで実行自体がキャンセルされた場合はartifactをアップロードしません。
ほかのセッション、シンボリックリンク、認証トークンを含むrunner.jsonは回収しません。
認証トークンとして取得した値や、ログの生成トークン・Authorizationヘッダは保存前に伏せます。
画面操作・実機・署名公証は検証対象外です。

## ランナーを手動で起動する

手動で起動する場合（リポジトリのルートで）:

```sh
xcodebuild build-for-testing -project Runner/RelayRunner.xcodeproj -scheme RelayRunner \
  -destination 'id=<SIM_UDID>' -derivedDataPath /tmp/relay-DerivedData-sim
TEST_RUNNER_RELAY_RUNNER_PORT=8100 xcodebuild test-without-building \
  -xctestrun /tmp/relay-DerivedData-sim/Build/Products/*.xctestrun -destination 'id=<SIM_UDID>' \
  -derivedDataPath /tmp/relay-DerivedData-sim
```

Runner のバンドル ID は `$(RELAY_BUNDLE_ID_PREFIX).RelayRunnerHost`（と `.UITests`）です。接頭辞の既定値はプロジェクトに `dev.devicerelay.$(DEVELOPMENT_TEAM:default=local:lower)` として置いてあるので、Team なし（シミュレータ）では `dev.devicerelay.local`、Xcode で Team を選ぶか `RELAY_DEVELOPMENT_TEAM=<TEAM_ID>` を渡せば `dev.devicerelay.<Team ID の小文字>` になります。別の接頭辞にするときは `RELAY_BUNDLE_ID_PREFIX=com.example.devicerelay` を xcodebuild に渡します（`relay start` は「[バンドル ID の接頭辞](setup.md#バンドル-id-の接頭辞)」のとおりに決めて、毎回渡します）。実機向けに手動でビルドする例:

```sh
xcodebuild build-for-testing -project Runner/RelayRunner.xcodeproj -scheme RelayRunner \
  -destination 'id=<DEVICE_UDID>' -derivedDataPath /tmp/relay-DerivedData-device \
  -allowProvisioningUpdates RELAY_DEVELOPMENT_TEAM=<TEAM_ID>   # App ID dev.devicerelay.<team id>.RelayRunnerHost を登録します
```

（`test-without-building` にも `-derivedDataPath` を付けると、テストのログと xcresult が `~/Library/Developer/Xcode/DerivedData` ではなくそこに入ります。`relay start` はテスト実行が重ならないよう、ポートごとの `~/.relay/build/…/TestData/port-<port>` を渡します。）

xcodebuild の出力に `RELAY_RUNNER_READY port=8100 addresses=en0=…,utun3=…` が出たら待ち受け開始です。シミュレータでは `127.0.0.1` だけで待ち受けるので `addresses=lo0=127.0.0.1` になり、`http://127.0.0.1:<port>/` で接続します（Mac の LAN 側のアドレスや `[::1]` では届きません。`localhost` は `127.0.0.1` に落ちて届きます）。`TEST_RUNNER_RELAY_RUNNER_TOKEN_SHA256` を渡さずに起動した場合は、ランナーがトークンを生成して `relay-runner: RELAY_RUNNER_TOKEN_SHA256 is not set; generated token: <token>` と 1 回だけ出力します。認証なしでは待ち受けません。自分で決めたトークンを使う場合は、そのトークンの SHA-256（hex 64 文字、例: `printf %s "$TOKEN" | shasum -a 256`）を渡します。64 文字の hex でない値を渡すと、ランナーは待ち受けずに失敗します。

## 検証用のホストアプリ

実機で他のアプリやデータに触れずに文字入力を試せるよう、RelayRunnerHost（`<接頭辞>.RelayRunnerHost`）に入力欄とラベルを置いています。ランナーの起動時に一緒にインストールされるので、`/launch`（`relay launch host`）で前面に出して使います。`relay start` はそのバンドル ID を runner.json の `hostBundleID` に書きます。

| accessibilityIdentifier | 内容 |
| --- | --- |
| `relay.input` / `relay.input2` | 入力欄 |
| `relay.password` | パスワード欄（`isSecureTextEntry`） |
| `relay.text` | `relay.input` の現在の文字列（`text: …`） |
| `relay.passwordLength` | `relay.password` の文字数だけ（`password: 5 chars`）。文字列そのものは表示しません |
| `relay.submitted` | Return で確定したときの文字列と回数（`submitted #2: …`） |
| `relay.events` | 直近の編集（insert / delete / return）とハードウェアキーの押下（`press Tab` など）。新しい順。パスワード欄の編集は文字数だけ（`insert 3 chars`） |

```sh
HOST=$(jq -r .hostBundleID ~/.relay/runner.json)   # 例: dev.devicerelay.local.RelayRunnerHost
curl -s -H "$AUTH" -X POST $R/launch -H 'Content-Type: application/json' -d "{\"bundleId\":\"$HOST\"}"
curl -s -H "$AUTH" -X POST $R/tap -H 'Content-Type: application/json' -d '{"element":{"identifier":"relay.input"}}'
curl -s -H "$AUTH" -X POST $R/type -H 'Content-Type: application/json' -d '{"text":"hello","keys":["return"]}'
curl -s -H "$AUTH" "$R/source" | jq -r '.tree | .. | objects | select(.identifier? == "relay.submitted") | .label'
```

iOS 27 では UIScene のライフサイクルを採用していないアプリが起動時に落ちるので、ホストアプリは `UIWindowSceneDelegate` を使います。また起動画面の設定（`UILaunchScreen`）がないと実機で 320×480 の互換モードになるので、Info.plist に生成させています。

## リリースの手順

Release は `xcode-27` ランナー上で Xcode 27.2（27B52、2026-11-08 時点の最新安定版）を
`DEVELOPER_DIR` で明示的に選択します。開始時にバージョンとビルド番号を照合し、
存在しない場合や一致しない場合は失敗します。ランナーの既定 Xcode や beta にフォールバックしません。
テスト・各アーキテクチャのビルド・公証まで同じ設定を継承します。
macOS の最低対応バージョンは引き続き `Package.swift` の macOS 26 です。

Xcode を更新するときは [Apple のリリース情報](https://developer.apple.com/news/releases/) と
[ランナーの搭載ツール](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)を確認し、
`release.yml` の `DEVELOPER_DIR`、バージョン・ビルド番号の照合条件、
`ci.yml` の27系の選択ステップと、この文書を一緒に更新してください。

1. `Sources/Relay/Setup/RunnerInstall.swift` の `RelayVersion.current` を上げて、main にマージします。
2. マージしたコミットにタグ `vX.Y.Z`（`RelayVersion.current` と同じ）を付けて push します。

```sh
git checkout main && git pull
git tag v0.6.0
git push origin v0.6.0
```

3. GitHub の Actions でそのタグの実行を開き、「Review deployments」から `release` environment を承認します。承認するまでジョブは始まりません。

タグの push で `.github/workflows/release.yml` が動きます。タグと `RelayVersion.current` が違えば失敗し、同じなら次の順に進みます。どこかで失敗すると、以降は実行されず Release は作られません。

1. `swift test`
2. 証明書と API キーを一時的な keychain とファイルに取り込む（`$RUNNER_TEMP` の下）
3. arm64 と x86_64 をビルドして署名する（Hardened Runtime、secure timestamp。`scripts/package.sh --build-only`）
4. 両方のバイナリを 1 回の提出で公証する（`scripts/notarize.sh`。Accepted でなければ失敗）
5. keychain と API キーを削除する（`if: always()` なので、失敗したときも実行）
6. tarball に固める（`scripts/package.sh --pack-only`）
7. tarball と `.sha256` を添付した GitHub Release を作る（リリースノートは自動生成）

Hardened Runtime で entitlements は要りません。tarball や単体の Mach-O には公証のチケットを staple できないので、macOS はオンラインで確認します。

手元で同じ tarball を作るには `make dist`、または `scripts/package.sh <version> <arm64|x86_64>` を使います。出力先は `dist/` です。バイナリは作業ツリーから、ほかのファイルは `git archive` で HEAD からとるので、未コミットの変更があると警告します。シークレットは要らず、署名も公証もされません（`RELAY_CODESIGN_IDENTITY` を設定すると署名だけします）。

### シークレット

`release` environment に置きます。リポジトリのファイルに署名 ID の名前や Team ID を書かないでください。ワークフローは keychain の中の「Developer ID Application」の ID を実行時に探し、SHA-1 ハッシュで指定します。

| シークレット | 内容 |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Developer ID Application 証明書と秘密鍵の `.p12` を base64 にしたもの |
| `DEVELOPER_ID_P12_PASSWORD` | その `.p12` のパスワード |
| `NOTARY_KEY_P8_BASE64` | App Store Connect API キー（`.p8`）を base64 にしたもの |
| `NOTARY_KEY_ID` | その API キーの Key ID |
| `NOTARY_ISSUER_ID` | App Store Connect の Issuer ID |

### 証明書と API キーの更新

**証明書**（期限切れ、または漏えいしたとき）:

1. Apple Developer の Certificates で Developer ID Application 証明書を作り、キーチェーンアクセスで秘密鍵ごと `.p12` に書き出します。`.p12` には証明書を 1 つだけ入れます（有効な Developer ID Application の ID が 1 つでないとワークフローは失敗します）。
2. シークレットを更新します。`gh` はプロンプトで値を受け取るので、シェルの履歴に残りません。

   ```sh
   base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --env release
   gh secret set DEVELOPER_ID_P12_PASSWORD --env release
   ```

3. 手元の `.p12` を削除します。

secure timestamp 付きで署名したバイナリは、証明書が期限切れになっても動きます。失効（revoke）すると配布済みのバイナリも動かなくなることがあるので、漏えいしたとき以外は失効させないでください。

**API キー**:

1. App Store Connect の「ユーザとアクセス」>「統合」で Team Key を作ります（アクセス権は Developer）。`.p8` をダウンロードできるのは 1 回だけです。
2. シークレットを更新します。

   ```sh
   base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8_BASE64 --env release
   gh secret set NOTARY_KEY_ID --env release
   gh secret set NOTARY_ISSUER_ID --env release
   ```

3. 次のリリースで動くことを確かめてから、古いキーを失効させ、手元の `.p8` を削除します。

### 署名や公証が失敗したとき

Release は作られていないので、利用者への影響はありません。失敗の内容はジョブのログで確かめます。公証が Accepted でなければ、Apple のログ（`notarytool log`）も出力されます。

- **Apple 側の問題やタイムアウト（`In Progress` のまま 30 分）**: 同じタグのままジョブを「Re-run jobs」します。再実行にも承認が要ります。
- **修正が要るとき**: 修正を main にマージしてから、タグを削除して付け直します。`RelayVersion.current` はそのままです。

  ```sh
  git push origin :refs/tags/v0.6.0
  git tag -d v0.6.0
  git checkout main && git pull
  git tag v0.6.0
  git push origin v0.6.0
  ```

### tarball の名前と配置を変えるとき

`mise use github:yuta24/device-relay` がオプションなしで動くのは、次の形に依存しています。変えるときは mise で確かめ直してください。

- **asset の名前**: mise の github backend は、名前の OS（`macos`）とアーキテクチャ（`arm64`、`x86_64`）で asset を選びます。`.sha256` は選ばれず、mise は同じ名前に `.sha256` を付けたファイルを Release からダウンロードし、その中から asset の名前の行を探して検証します。名前が違うと照合する行が見つからないので、中のファイル名は asset の名前そのままにします（`dist/` などを付けない）。
- **配置**: トップレベルがディレクトリ 1 つだけのアーカイブは mise がその 1 段を取り除くので、`bin/` がインストール先の直下に来て PATH に入ります。
- **`bin/` と `Runner/` の位置関係**: relay は実行ファイルの親をたどって `Runner/` を探します（`RunnerProject.resolve`）。
- **共有ソース**: Runner のプロジェクトは `../Sources/Relay/Shared/*.swift` を参照するので、`scripts/package.sh` は `project.pbxproj` から読んだファイルも同梱します。`Runner/` だけではビルドできません。
