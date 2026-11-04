# device-relay

対象アプリに何も埋め込まずに、iOS の実機・シミュレータを Mac から HTTP で操作するためのプロトタイプです。

## 概要

- WebDriverAgent と同じ「常駐 XCTest ランナー」方式です。端末上で UI テストとして動くランナーが HTTP サーバを立ち上げ、XCUITest の API でタップ・スワイプ・文字入力・スクリーンショット・要素ツリーの取得などを行います。対象アプリの改修や SDK の組み込みは要りません。
- Mac 側の `relay` CLI が、ランナーのビルドと起動、接続先の探索、後片付けをまとめて行い、ランナーの操作も 1 コマンドずつ呼べます。人もスクリプトもコーディングエージェントも同じ形で使えます。
- 通信にはトークン認証が必要です。ビルド成果物やログは `~/.relay` に置き、対象アプリのリポジトリには何も作りません。

仕組みの詳細は [docs/design.md](docs/design.md) を参照してください。

## 要件

- macOS 上の Xcode（Xcode 27 で動作確認。`devicectl` を使うので Xcode 15 以上）
- **iOS 17.0 以上**（CoreDevice トンネルを前提とします。デプロイメントターゲットは 17.0）
- 実機の場合
  - Apple Development 証明書（Xcode > Settings > Accounts でサインインして作成）。Team ID は証明書から自動で検出します
  - 端末側で「デベロッパモード」と「UI オートメーション」が有効になっていること
  - Mac とペアリング済みで、USB または同じネットワーク経由で CoreDevice 接続できること

> **ツールチェーンに関する注意**: `swiftly` などで入れた別の Swift ツールチェーンが PATH の先頭にあると、Xcode SDK と食い違って `unknown argument: '-target-arch-variant'` のようなエラーになることがあります。その場合は `xcrun swift build` / `xcrun swift test` / `xcrun swift run` を使い、Xcode のツールチェーンでビルドしてください（Makefile も `xcrun swift` を使います）。

> **非公開 API に関する注意**: ランナーは XCTest の非公開 API を使います。Xcode / iOS の更新で予告なく変わることがあります。使うのは端末上の UI テストバンドルの中だけで、対象アプリには何も入りません。何を使っていて、使えないときにどうなるかは [docs/private-api.md](docs/private-api.md) を参照してください。

## クイックスタート

```sh
# device-relay のリポジトリで（1 回だけ）
make install          # xcrun swift build -c release して ~/.local/bin/relay にリンク（PREFIX=... で変更可）
relay install         # Runner プロジェクトを ~/.relay/runner にコピー（--build でシミュレータ用に事前ビルド）

# 以降はどのディレクトリからでも（対象アプリのリポジトリなど）。まずはシミュレータで試します
relay doctor --simulator   # Xcode・Runner・シミュレータを確認（署名は実機でだけ必要）
relay devices              # シミュレータの名前を確かめる（下の "iPhone 17 Pro" は例）
relay start --background --device "iPhone 17 Pro"   # 停止中なら boot してランナーを起動し、ready になったらプロンプトに戻る
relay status               # 動いているランナーの確認（生きていれば終了コード 0）
relay screenshot           # 操作（docs/cli.md の「CLI から操作する」）
relay stop                 # ランナーを止める（relay が boot したシミュレータも shutdown）
```

- 同じ名前のシミュレータが iOS のランタイムごとにあっても、`--device` は最も新しい iOS のものを選び、`relay: using …` に OS つきで表示します。古い iOS で試すときは `--os 26.5` のように絞ります（「[端末の選択](docs/setup.md#端末の選択relay-devices)」）。
- すでに起動しているシミュレータを使うなら `relay start --background --simulator` でも構いません。実機が接続されていても、シミュレータの中から選びます。
- `--udid` / `--device` / `--simulator` を付けずに `relay start` すると、接続中の実機があればそれを優先します。実機は署名や UI オートメーションの準備が要るので、「[実機](docs/setup.md#実機)」の手順を済ませてから使ってください。

エージェントや CI、スクリプトからは、`relay start --background` → 操作 → `relay stop` が基本の流れです（「[バックグラウンドで動かす](docs/setup.md#バックグラウンドで動かすrelay-start---background--status--stop)」）。人が手元で見ながら使うときは、`relay start`（フォアグラウンド。Ctrl-C で停止）でもかまいません。

- `make install` は `.build/release/relay` へのシンボリックリンクを `$(PREFIX)/bin/relay`（既定 `~/.local/bin/relay`）に作ります。`~/.local/bin` が PATH になければ追加してください。`make uninstall` はそのリンクがこのチェックアウトを指している場合だけ削除します。リポジトリを更新したら `make install` と `relay install` をやり直します。

## 最初の操作

ランナーと一緒に、操作を試すためのホストアプリ RelayRunnerHost がインストールされます。対象アプリの代わりに、起動・観察・操作・確認の流れを試せます。

```sh
relay launch host                                     # host は RelayRunnerHost のバンドル ID の別名
relay source --format compact --filter interactive   # 操作できる要素を 1 行 1 要素で確かめる
relay tap --id relay.input --timeout 3                # identifier で入力欄をタップ（現れるまで最大 3 秒待つ）
relay type "hello" --key return                       # 文字を入力して Return
relay find --id relay.submitted                       # 確定した文字列（label）を確かめる
relay screenshot --scale 1                            # 1 px = 1 pt に縮小して保存し、パスを出力
```

- 座標で操作する場合は、前面アプリの表示の向きでのポイント単位です（[docs/screen.md](docs/screen.md)）。
- `relay` を使わずに、`curl` などから HTTP で直接操作することもできます。トークンは `~/.relay/runner.json` にあります（[docs/http-api.md](docs/http-api.md)）。
- 要素の指定方法（`--id`・`--label`・`--type`・`--index`）と待ち方は [docs/elements.md](docs/elements.md) にあります。

## 実機の準備（要点）

実機では、`relay start` の前に次の準備が要ります。手順の詳細は [docs/setup.md の「実機」](docs/setup.md#実機) と「[Team ID（実機の署名）](docs/setup.md#team-id実機の署名)」を参照してください。

1. 端末で「デベロッパモード」を有効にし、USB で接続して Mac とペアリングする（`relay devices` で `connected` と表示される）
2. Xcode の Devices and Simulators で端末を準備完了にする（初回は開発用ディスクイメージが適用される）
3. 端末の 設定 > デベロッパ で「UI オートメーションを有効にする」をオンにする
4. Xcode でサインインして Apple Development 証明書を用意する（Team ID は証明書から自動で検出）
5. `relay doctor` で ✗ がないことを確かめてから `relay start` する。起動中は端末を手元に置き、パスコードを求められたら入力する

## よく使うコマンド

各コマンドの使い方は `relay --help` / `relay <command> --help` で表示できます。詳しくは [docs/cli.md](docs/cli.md) を参照してください。

| コマンド | 内容 |
| --- | --- |
| `relay install` / `relay uninstall` | Runner プロジェクトを `~/.relay/runner` にコピーする / 削除する |
| `relay doctor` | Xcode・Runner・端末・署名などの環境を確認する |
| `relay devices` | 実機とシミュレータを一覧表示する |
| `relay start [--background]` | ランナーをビルドして起動する（`--background` なら ready で戻る） |
| `relay status` / `relay stop` | 動いているランナーを確認する / 止める |
| `relay screenshot` | スクリーンショットを保存してパスを出力する（`--scale 1` で縮小） |
| `relay source` | 要素ツリーを取得する（`--format compact --filter interactive` で操作できる要素だけ） |
| `relay find` | セレクタに一致する要素を探す（`--timeout` で待つ、`--require` で必須にする） |
| `relay tap` / `relay press` / `relay swipe` | 座標か要素セレクタ（`--id`・`--label`・`--type`）でタッチ操作する |
| `relay type` / `relay key` | フォーカスのある要素に文字・特殊キーを入力する |
| `relay launch` / `relay terminate` | アプリを起動（前面化）する / 終了する |
| `relay button` / `relay orientation` | ハードウェアボタンを押す / 端末の向きを変える |
| `relay run`（実験的） | 1 行 1 手順のシナリオを順に実行する |
| `relay record start` / `relay record stop` | シミュレータか実機（USB 接続）の画面を MP4 に録画する / 止めて保存先を出力する（実機は初回にカメラの許可が要る） |
| `relay skill install` | コーディングエージェント向けのスキルを対象アプリのリポジトリなどに入れる |
| `relay config` | 設定（Team ID）を表示・変更する |

## うまくいかないとき

- まず `relay doctor`（シミュレータなら `relay doctor --simulator`）で環境を確かめます。✗ と ! の項目には直し方が 1 行添えてあります。
- ログは `~/.relay/logs/` にあります（`start-*.log`、`build-*.log`、`runner-*.log`）。`relay start --background` は失敗したときに原因とログの末尾を表示します。
- サブコマンドの終了コード（`3` = ランナーに届かない、`5` = busy、`6` = XCUI で失敗 など）は [docs/cli.md](docs/cli.md) にまとめています。
- 実機特有の問題（UI オートメーション、パスコード、ホームボタンなど）は [docs/limitations.md](docs/limitations.md) を参照してください。

## ドキュメント

| 文書 | 内容 |
| --- | --- |
| [docs/setup.md](docs/setup.md) | Runner の用意（`relay install`）、端末の選択、Team ID、環境の確認（`relay doctor`）、シミュレータ、バックグラウンドでの起動、実機 |
| [docs/cli.md](docs/cli.md) | CLI のサブコマンドと終了コード、接続先（runner.json）の探し方、シナリオの実行（`relay run`、実験的）、録画（`relay record`。シミュレータと USB 接続の実機）、エージェントスキル |
| [docs/http-api.md](docs/http-api.md) | HTTP API のエンドポイントとステータスコード、認証、同時リクエストと生存確認（`/ping`）、前面アプリ、文字入力と特殊キー |
| [docs/elements.md](docs/elements.md) | 要素ツリー（`/source`、compact、interactive）、要素セレクタ、待機（timeout） |
| [docs/screen.md](docs/screen.md) | 座標系と画面の向き、スクリーンショットの縮小 |
| [docs/design.md](docs/design.md) | アーキテクチャとファイル配置、タッチ合成の経路、計測したレイテンシ |
| [docs/limitations.md](docs/limitations.md) | 既知の制約 |
| [docs/private-api.md](docs/private-api.md) | ランナーが使う Apple の非公開 API の一覧と、使えないときの挙動 |
| [docs/development.md](docs/development.md) | 開発者向け: リポジトリ内での実行、ランナーの手動起動、検証用のホストアプリ |
| [skills/device-relay/](skills/device-relay/) | コーディングエージェント向けのスキル（`SKILL.md` と `reference.md`） |

## ライセンス

[LICENSE](LICENSE)（Apache License 2.0）を参照してください。
