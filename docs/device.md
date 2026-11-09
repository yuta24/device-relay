# 実機

実機でランナーを使うための準備、署名、バンドル ID、接続経路、録画の初回準備を説明します。
インストールは「[セットアップ](setup.md)」、起動後の運用は「[起動とセッション](sessions.md)」を参照してください。

## 準備

実機でランナーを起動するには、端末の設定と Mac とのペアリングを済ませます。

1. 端末の 設定 > プライバシーとセキュリティ > デベロッパモード を有効にします。有効にすると端末が再起動します。
2. USB で Mac に接続し、端末で「このコンピュータを信頼」を選んでペアリングします。`relay devices` に `connected` で表示されることを確認します。
3. Xcode の Window > Devices and Simulators で端末を選び、接続済み（準備完了）の状態にします。初回は開発用ディスクイメージ（DDI）が端末に適用されるので、完了まで待ちます。
4. 端末の 設定 > デベロッパ >「UI オートメーションを有効にする」をオンにします。起動中は端末を手元に置き、パスコード入力画面が出たら入力してください。
5. `relay doctor` で、ペアリング、デベロッパモード、DDI、ロック、署名の Team ID に ✗ がないことを確認します。
6. `relay start` でランナーをビルドして起動します。意図した端末を確実に使うには `--device "<端末名>"` か `--udid` で指定します。
7. 初回の起動時に「信頼されていないデベロッパ」と表示されたら、端末の 設定 > 一般 > VPNとデバイス管理 で開発元の証明書を信頼し、もう一度 `relay start` します。無料の Personal Team などで署名した場合に表示されることがあります。
8. 初回に「ローカルネットワーク上のデバイスの検索および接続」の許可ダイアログが出たら許可します。許可しないと Wi-Fi 経由（`--allow-wifi`）では届きません。

接続中の実機が 1 台だけなら `--udid` も `--team-id` も要りません。
Team ID はキーチェーンから検出し、ランナーが起動できたら保存します。
署名チームを指定するときは「[Team ID（実機の署名）](#team-id実機の署名)」を参照してください。

```sh
relay start
# relay: using <端末名> (iPhone 14 Pro, iOS 26.7.1, device, connected) <DEVICE_UDID> (selected automatically; the only connected device)
# relay: signing team: <TEAM_ID> (from keychain)
# relay: runner host app: dev.devicerelay.<team id>.RelayRunnerHost (prefix from the Team ID)
# ...
# relay: saved the team to ~/.relay/config.json; relay config unset teamID forgets it   ← ランナーが起動できたとき
# ready: http://<アドレス>:8100/
```

### UI オートメーションとパスコード

UI オートメーションがオフだと、ランナーは `Failed to initialize for UI testing`（`Timed out while enabling automation mode.`）で起動に失敗します。
Mac からは設定の状態を読めないため、`relay doctor` は確認を促すだけです。

オンでも、automation mode の有効化時に端末がパスコードの入力を求めることがあります。
詳しくは「[既知の制約](limitations.md)」の「automation mode の有効化でパスコードを求められる」を参照してください。

## Team ID（実機の署名）

実機の署名に使う Team ID は、次の順に決めます。シミュレータでは不要です。

1. `--team-id <TEAM_ID>`
2. `~/.relay/config.json` の `teamID`
3. キーチェーンの Apple Development 証明書から検出した Team ID

キーチェーンでは、`security find-identity -v -p codesigning` の有効な ID と、その証明書のサブジェクトの OU を使います。
証明書の名前の括弧内の ID は個人の ID で、Team ID ではありません。
チームが 1 つならそれを使い、複数ならエラーで候補を示します。

1 か 3 で決めた Team ID は、ランナーが起動できて `ready:` が出たところで `~/.relay/config.json` に保存し、次回から使います。
ビルドや起動に失敗した Team ID は保存しないので、打ち間違えた `--team-id` が残ることはありません。

変更するときは `--team-id` を付けて起動すると保存し直します。`relay config` でも変更できます。

```sh
relay config                      # 設定の一覧
relay config get teamID           # 未設定なら終了コード 1（標準エラーに relay: teamID is not set）
relay config set teamID <TEAM_ID>
relay config unset teamID         # 忘れて、次回はキーチェーンから検出し直す
```

## バンドル ID の接頭辞

Runner のバンドル ID は、ホストアプリが `<接頭辞>.RelayRunnerHost`、テストランナーが `<接頭辞>.RelayRunnerHost.UITests` です。

明示的な App ID は最初に登録したチームのものになり、ほかのチームでは登録できません。そのため、接頭辞は既定で Team ごとに変わります。

`relay start` は次の順に接頭辞を決め、xcodebuild に `RELAY_BUNDLE_ID_PREFIX=<接頭辞>` を渡します。

1. `~/.relay/config.json` の `bundleIDPrefix`（`relay config set bundleIDPrefix <接頭辞>`）
2. Team ID があるときの既定値: `dev.devicerelay.<Team ID の小文字>`（例: `dev.devicerelay.abcde12345`）
3. Team がないシミュレータでの既定値: `dev.devicerelay.local`

Team ID は App ID の重複を避けつつ同じ人では変わらないので、そのまま実機で自動署名できます。
シミュレータは署名も App ID の登録もしないため、接頭辞が衝突しても困りません。

```sh
relay config set bundleIDPrefix com.example.devicerelay   # 逆ドメイン形式（英数字とハイフンを . で 2 つ以上）。不正ならその場でエラー
relay config get bundleIDPrefix
relay config unset bundleIDPrefix                          # 既定値に戻す
```

起動時には、次のように接頭辞の出どころも表示します。

```text
relay: runner host app: dev.devicerelay.abcde12345.RelayRunnerHost (prefix from the Team ID)
```

`relay doctor` も接頭辞と出どころを表示します。出どころは config、Team ID から作った既定値、Team がまだ分からない状態のいずれかです。
config の値が不正なときだけ ✗ になります。

### ホストアプリを指す（host）

relay のコマンドでは、バンドル ID の代わりに `host` と書くとホストアプリを指せます。
たとえば `relay launch host`、`relay tap --id relay.input --bundle-id host` と書きます。

relay は `relay start` がビルドしたアプリの ID を runner.json の `hostBundleID` に書き、`host` をその値に置き換えます。
`relay status` の `host app` にも表示します。

HTTP API を直接呼ぶときは `jq -r .hostBundleID ~/.relay/runner.json` で読みます。

### 接頭辞を変えたとき

前回のビルドと接頭辞が違うと、`relay start` は次のメッセージを出して作り直します。`--rebuild` は要りません。

```text
bundle ID prefix changed from X to Y; rebuilding, and the device gets new apps with the new IDs (the old ones stay)
```

判定に使う記録は「[実機のバンドル ID の判定](development.md#実機のバンドル-id-の判定)」を参照してください。
以前の版から更新するときの注意は「[変更履歴](../CHANGELOG.md#runner-のバンドル-id-の接頭辞移行の注意)」にあります。

## 接続の経路

`relay start` は次の順に `/health` を送り、最初に応答したアドレスを `ready:` として表示します。

1. CoreDevice トンネルアドレス: `xcrun devicectl device info details` の `tunnelIPAddress`。USB 接続だけで使える IPv6 の ULA です。
2. `<udid>.coredevice.local`
3. `--allow-wifi` を付けたときだけ、ランナーが `RELAY_RUNNER_READY` で報告したインターフェースのアドレス。Wi-Fi などを使い、`169.254.*` は除外します。

既定ではトンネルが見つかるまで 1 と 2 だけを試し、Wi-Fi のアドレスには何も送りません。

| 経路 | 長所 | 短所 |
| --- | --- | --- |
| CoreDevice トンネル | USB だけで動き、同じ LAN にいる必要がありません。 | Xcode/CoreDevice のトンネルが張られている間しか使えません。 |
| Wi-Fi IP（`--allow-wifi`） | ケーブルが不要です。 | 同じ LAN とローカルネットワーク許可が必要で、トークンと画面は LAN 上を平文で流れ、ネットワークによっては AP 間の通信が遮断されます。 |

## 録画の準備

USB 接続の実機を録画するには、端末の接続と macOS のカメラの許可が必要です。
録画コマンドの使い方と動きは「[録画（relay record）](cli.md#録画relay-record)」を参照してください。

1. 端末を **USB ケーブルで** Mac に接続し、ロックを解除します。「このコンピュータを信頼しますか」と出たら「信頼」を選びます。`relay devices` で `connected` になっていれば十分です。
2. 最初の `relay record start` で macOS のカメラの許可ダイアログが出たら、「許可」を押します。`record start` は答えを最大 120 秒待ちます。
3. 誤って拒否したときは、**システム設定 > プライバシーとセキュリティ > カメラ** で relay を動かすアプリをオンにし、アプリを再起動します。

端末の画面はカメラと同じキャプチャデバイスとして扱われます。許可する対象は relay 自身ではなく、relay を動かしているターミナルや IDE などのアプリです。

許可はアプリごとなので、別のターミナルや IDE から使うときは、そのアプリにも許可が要ります。
切り離して動く録画のプロセス（`relay record supervise`）は、起動したアプリの許可をそのまま使います。

SSH でログインしたセッションや launchd のジョブなど、ダイアログを出せない環境では許可を得られず、録画を始められないことがあります。
先に手元のターミナルから一度 `record start` して許可しておいてください。
