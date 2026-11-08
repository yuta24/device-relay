# 開発者向けの情報

device-relay 自体を開発・検証するときの情報です（リポジトリ内での実行、ランナーの手動起動、検証用のホストアプリ、リリースの手順）。全体の入口は [README](../README.ja.md) です。

## リポジトリ内での開発

- 開発中はリポジトリ内で `xcrun swift run relay …` でも動きます。リポジトリ内ではカレントディレクトリのチェックアウトの Runner を使うので、`relay install` 済みでもインストールしたコピーではなく手元の変更がビルドされます。

```sh
xcrun swift build
xcrun swift test
xcrun swift run relay doctor
```

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
新しい Swift ファイルが計測結果から欠落した場合も失敗します。

ローカルで同じチェックを実行するには:

カバレッジ集計用の Python は `mise.toml` で 3.14.3 に固定しています。
CI も同じ設定を使用し、mise 本体は 2026.11.4 に固定しています。
初回は `mise trust` と `mise install` を実行してください。
Swift は Xcode 付属のものを `xcrun` で選択し、CI では Xcode 26・27 の互換性を確認します。
Xcode のパッチ版とランナーイメージは固定していません。

```sh
xcrun swift test --enable-code-coverage
mise exec -- python3 -m unittest discover -s scripts -p 'test_*.py'
mise exec -- python3 scripts/coverage.py "$(xcrun swift test --show-codecov-path)" --output coverage
```

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
