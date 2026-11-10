# HTTP API

ランナーが端末上で提供する HTTP API の仕様です（エンドポイント、認証、同時リクエスト、前面アプリ、文字入力）。全体の入口は [README](../README.ja.md) です。

## エンドポイント

ベース URL は `http://<host>:8100`（以下の例はシミュレータ）。座標は「[座標系と画面の向き](screen.md#座標系と画面の向き)」で説明する、表示の向きでのポイント単位です。POST のボディは JSON です。すべてのリクエストに `Authorization: Bearer <token>` が必要です。

| メソッド / パス | ボディ / クエリ | 説明 |
| --- | --- | --- |
| `GET /ping` | – | 生存確認。busy ゲートもメインスレッドも通らずに即答します（`{"ok":true,"busy":<bool>,"busyForMs":<ms or null>,"runner":{…}}`）。詳しくは「生存確認（/ping）」と「ランナーの版（runner）」 |
| `GET /health` | – | 端末情報、表示の向きでの画面サイズ（points / scale）、`orientation`、`touchSynthesis`、文字入力の経路 `typeSynthesis`（「文字入力と特殊キー」）、`foreground`、表示の一覧 `displays` と前面アプリの表示 `display`（下の「表示が複数ある端末」）、ランナーの版 `runner`（下の「ランナーの版（runner）」） |
| `GET /foreground` | – | 前面アプリの `bundleId` と `pid`、取得経路 `source`（`private` / `fallback`）。詳しくは「前面アプリ」 |
| `GET /screenshot` | `?format=png\|jpeg&quality=0.05–1.0&maxSize=<px>&scale=<px/pt>`（既定は png、jpeg の既定 quality は 0.7。範囲外・数値以外の quality と、png への quality の指定は 400。`maxSize`・`scale` は省略時は縮小なし） | 画面全体のスクリーンショット（表示の向きに正規化済み）。`maxSize`・`scale` で端末側で縮小します。画像と座標の関係を `X-Relay-*` ヘッダーで返します。詳しくは「[スクリーンショットの縮小](screen.md#スクリーンショットの縮小)」 |
| `GET /source` | `?format=json\|text\|compact&filter=interactive&maxDepth=<n>&bundleId=`（既定は json、bundleId の既定は前面アプリ） | XCUI の要素ツリー。json は要素ごとの属性と frame、text は `debugDescription`、compact は 1 行 1 要素。`filter=interactive` で操作できる要素だけに絞ります。詳しくは「[要素ツリー（/source）](elements.md#要素ツリーsource)」 |
| `POST /tap` | `{"x":200,"y":120}`、または `{"element":{"identifier":"relay.input"}}` | タップ。`element` で要素を指定すると、その frame の中心をタップします（「[要素セレクタ](elements.md#要素セレクタ)」）。座標が画面の外なら `400`（下の「画面の外の座標」） |
| `POST /press` | `{"x":200,"y":120,"duration":1.0}`、または `{"element":{…},"duration":1.0}` | 長押し |
| `POST /find` | `{"element":{"type":"button"},"limit":20,"bundleId":"…","timeout":0}`（`limit`・`bundleId`・`timeout` は省略可） | セレクタに一致する要素の一覧（type / identifier / label / value / frame / enabled）。ツリー全体を読まずに要素を探せます（「[要素セレクタ](elements.md#要素セレクタ)」） |
| `POST /swipe` | `{"from":{"x":200,"y":700},"to":{"x":200,"y":200},"duration":0.3,"hold":0.05}` | スワイプ（ドラッグ）。`from`・`to` のどちらかが画面の外なら `400` |
| `POST /type` | `{"text":"hello","keys":["return"],"bundleId":"com.apple.Preferences"}`（`keys` と `bundleId` は省略可。`keys` があれば `text` は省略・空文字でも可。`text` が文字列以外なら `keys` があっても 400） | キーボードのフォーカスがある要素への文字入力。`text` の後に `keys` を順に送ります。対象の既定は前面アプリ |
| `POST /key` | `{"key":"return","bundleId":"…"}`（bundleId は省略可） | 特殊キー（`return` / `delete` / `space`）を 1 つ送ります。それ以外のキー名は 400。詳しくは「文字入力と特殊キー」 |
| `POST /button` | `{"name":"home"}`（`volumeUp` / `volumeDown` は実機のみ） | ハードウェアボタン。`home` は実機では画面下端からのスワイプで代用します（「[ホームと音量ボタン](device.md#ホームと音量ボタン)」を参照） |
| `POST /orientation` | `{"orientation":"portrait\|portraitUpsideDown\|landscapeLeft\|landscapeRight"}` | 端末の向き（`UIDeviceOrientation`）を設定 |
| `POST /launch` | `{"bundleId":"com.apple.Preferences"}` | アプリの起動・前面化（`activate()`）で、入っていないアプリの扱いは「[アプリの指定と起動](cli.md#アプリの指定と起動)」を参照してください。 |
| `POST /terminate` | `{"bundleId":"com.apple.Preferences"}` | アプリの終了。終了するまで `/launch` と同じだけ待ちます |
| `POST /shutdown` | – | ランナーを停止（テストメソッドから抜ける） |

`/launch` は、アプリが前面になるまで XCTest のアプリの状態の待ち時間（60 秒、戻せないランナーでは 120 秒）まで待ってから応答します。

**画面の外の座標**: `/tap`・`/press` の `x`・`y` と `/swipe` の `from`・`to` は、前面アプリの表示の向きでの画面（`/health` の `screen`）の中、つまり `0 ≤ x < screen.width` かつ `0 ≤ y < screen.height` でなければなりません（小数も可。`x = screen.width` は画面の外です）。外なら何も送らずに `400` と `{"ok":false,"code":"point_offscreen","error":"invalid field: x, y: (500, 100) is outside the screen, which is 402x874 points in portrait (0 <= x < 402, 0 <= y < 874; relay health shows the screen)"}` のように返します（`/swipe` では `from:` / `to:`）。以前は画面の外のタッチも `200` を返し、何も起きませんでした。`422`（XCUI で操作に失敗）ではなく `400` にしたのは、操作を試す前に値の範囲で判定でき、ほかの範囲外の値と同じ扱い（CLI では終了コード `7`）にするためです。画面は向きを変えると縦横が入れ替わるので、`relay orientation` の後は `/health` を読み直します。要素を指定したタップ（`element`）は、要素の frame の画面内の部分の中心に当たるので、この判定はありません（画面の外の要素は `422` の `offscreen`）。画面の大きさを SpringBoard から取れず `UIScreen` の値で代用している間（実機では 320×480 の互換モードの値になります）は、正しい座標を拒否しないよう判定を省きます。

`/tap` `/press` `/swipe` は `"mode": "private" | "xcui" | "auto"` を受け付けます（`auto` は省略と同じで、使えれば `private`。`relay` の `--mode` は `private` と `xcui` だけで、省略すると `auto` と同じになります）。応答の `mode` に実際に使った経路が入り、`/health` の `touchSynthesis` で端末側の既定経路がわかります。詳しくは「[タッチ合成の経路](design.md#タッチ合成の経路)」を参照してください。

### `/health` の応答

`/health` は、SpringBoard の frame から縦向きの画面サイズを、スクリーンショットのピクセル数から scale を求めます。xctrunner には起動画面の設定がなく、実機のランナー内の `UIScreen` が 320×480 の互換モードになるためです。

画面サイズと scale は初回だけ計測してキャッシュします。向きはリクエストのたびに読み直し、幅と高さに反映します（「[座標系と画面の向き](screen.md#座標系と画面の向き)」）。

前面アプリの取得のぶん遅くなります。計測値は「[計測したレイテンシ](design.md#計測したレイテンシ)」を参照してください。

`/health` の例（横向きの Safari が前面のとき）:

```json
{"coordinateSpace":"points","device":{"model":"iPhone","simulator":true,"systemVersion":"27.0"},
 "foreground":{"bundleId":"com.apple.mobilesafari","pid":42390,"source":"private"},"ok":true,
 "orientation":"landscapeLeft","runner":{"sourceHash":"<64 桁>","version":"0.7.0"},
 "screen":{"height":402,"scale":3,"width":874},"touchSynthesis":"private"}
```

**ランナーの版（runner）**: `/ping` と `/health` の成功時の応答には `runner` が入ります。`version` はランナーをビルドした relay のバージョン、`sourceHash` はビルドしたランナーのソースのハッシュ（SHA-256 の 16 進 64 桁）です。どちらもビルドのときに Info.plist に埋め込んだもので（docs/setup.md の「[ランナーの版](setup.md#ランナーの版ソースのハッシュ)」）、起動のしかたでは変わりません。relay を通さずにビルドしたランナーでは両方 `null` です。この版を返す前にビルドしたランナーには `runner` がないので、クライアントはないことも扱ってください。

**表示が複数ある端末**: iPhone Duo（外側と内側）では、`screen`・`/screenshot`・画面の外の判定・タッチ・要素の frame を、前面アプリが載っている表示に合わせます。`/health` には次のフィールドが加わります（既存のフィールドはそのままです）。

| フィールド | 内容 |
| --- | --- |
| `displays` | 表示の一覧。`id`（`xcrun devicectl device info displays` の `displayId`）、`width` / `height`（縦向きのポイント）、`scale`、`main`（`XCUIScreen.main` か）。表示が 1 つの端末では 1 件です。ワイヤレス（AirPlay）の表示は含めません。一覧を読めない場合はフィールドごと省きます |
| `display` | 前面アプリが載っている表示の `id`。表示が 1 つなら常にその ID、表示が複数あって判定できない場合は `null`（`screen` は main の表示の大きさで、タッチとスクリーンショットは `422`） |

内側を開いて設定アプリが前面のときの例:

```json
{"coordinateSpace":"points","device":{"model":"iPhone","simulator":true,"systemVersion":"27.2"},"display":3,
 "displays":[{"height":678,"id":1,"main":true,"scale":3,"width":466},{"height":951,"id":3,"main":false,"scale":3,"width":669}],
 "foreground":{"bundleId":"com.apple.Preferences","pid":69025,"source":"private"},"ok":true,
 "orientation":"landscapeRight","screen":{"height":669,"scale":3,"width":951},"touchSynthesis":"private"}
```

判定の方法、`xcui` 経路の制約、要件は「[表示が複数ある端末（iPhone Duo）](screen.md#表示が複数ある端末iphone-duo)」を参照してください。

### ステータスコードと curl の例

| コード | 意味 |
| --- | --- |
| `200` | 成功 |
| `400` | リクエスト不正（JSON、必須フィールド、値の範囲、画面の外の座標、数値フィールドへの数値以外（真偽値を含む）、負の値・数値以外・矛盾する `Content-Length`） |
| `401` | `Authorization: Bearer <token>` がない、または一致しない（`{"ok":false,"code":"unauthorized","error":"unauthorized"}`）。リクエストヘッダーの形式の判定（`400`・`413`・`431`・`501`）の次、ほかのどの判定よりも先に行います |
| `404` / `405` | 未知のパス / メソッド違い |
| `409` | 別のコマンドを実行中（`{"ok":false,"code":"busy","error":"busy"}`）。待たずにすぐ返ります。`/ping` と `/shutdown` 以外のすべてのエンドポイント（`/health` を含む）で起こります。詳しくは「同時リクエスト」 |
| `422` | XCUI 側で操作に失敗（エラーメッセージを JSON で返し、ランナーは動き続けます。どの失敗かは `code` でわかります）。`/type`・`/key` でキーボードのフォーカスがない場合は `no element has keyboard focus in <bundleId>`。表示が複数ある端末で前面アプリの表示を判定できない場合は `cannot tell which display <bundleId> is on …`、`xcui` の座標タッチが届かない表示やアプリでは `xcui touches can't reach … use mode private`（どちらも何も送りません）。`/tap`・`/press` の `element` で触れる要素が 1 つに決まらない場合は `reason`・`count`・`candidates` 付き（「[要素セレクタ](elements.md#要素セレクタ)」） |
| `413` / `431` | ボディが 16 MB を超える / リクエストヘッダーが 64 KB を超える |
| `500` | 内部エラー（JPEG エンコード失敗など） |
| `501` | `Transfer-Encoding` ヘッダーがある（値に関わらず。ボディは `Content-Length` でのみ受け付けます） |

エラーの本文は「[エラーの形式と code](#エラーの形式と-code)」の形です。`400`・`401`・`413`・`431`・`501` は、応答した後に接続を閉じます。リクエストは、接続を開いてから（keep-alive の場合は前の応答を返してから）30 秒以内に全体が届かないと、接続を閉じます。実行中のコマンドの時間はこの 30 秒に含めません。

```sh
R=http://127.0.0.1:8100
AUTH="Authorization: Bearer $(jq -r .token ~/.relay/runner.json)"
curl -s -H "$AUTH" $R/ping
curl -s -H "$AUTH" $R/health
curl -s -H "$AUTH" -o shot.png $R/screenshot
curl -s -H "$AUTH" -o shot.jpg "$R/screenshot?format=jpeg&quality=0.5"
curl -s -H "$AUTH" -D - -o small.png "$R/screenshot?scale=1"   # 402x874 px（1 px = 1 pt）。ヘッダーに X-Relay-*
curl -s -H "$AUTH" $R/foreground
curl -s -H "$AUTH" "$R/source?maxDepth=3" | jq .tree
curl -s -H "$AUTH" "$R/source?format=text&bundleId=com.apple.Preferences" | head
curl -s -H "$AUTH" "$R/source?format=compact&filter=interactive"
curl -s -H "$AUTH" -X POST $R/launch      -H 'Content-Type: application/json' -d '{"bundleId":"com.apple.Preferences"}'
curl -s -H "$AUTH" -X POST $R/tap         -H 'Content-Type: application/json' -d '{"x":200,"y":120}'
curl -s -H "$AUTH" -X POST $R/press       -H 'Content-Type: application/json' -d '{"x":200,"y":400,"duration":1.0}'
curl -s -H "$AUTH" -X POST $R/tap         -H 'Content-Type: application/json' -d '{"element":{"label":"General","type":"button"}}'
curl -s -H "$AUTH" -X POST $R/find        -H 'Content-Type: application/json' -d '{"element":{"type":"cell"},"limit":5}'
curl -s -H "$AUTH" -X POST $R/swipe       -H 'Content-Type: application/json' -d '{"from":{"x":200,"y":700},"to":{"x":200,"y":200}}'
curl -s -H "$AUTH" -X POST $R/type        -H 'Content-Type: application/json' -d '{"text":"hello"}'
curl -s -H "$AUTH" -X POST $R/type        -H 'Content-Type: application/json' -d '{"text":"example.com","keys":["return"]}'
curl -s -H "$AUTH" -X POST $R/key         -H 'Content-Type: application/json' -d '{"key":"delete"}'
curl -s -H "$AUTH" -X POST $R/button      -H 'Content-Type: application/json' -d '{"name":"home"}'
curl -s -H "$AUTH" -X POST $R/orientation -H 'Content-Type: application/json' -d '{"orientation":"landscapeLeft"}'
curl -s -H "$AUTH" -X POST $R/terminate   -H 'Content-Type: application/json' -d '{"bundleId":"com.apple.Preferences"}'
curl -s -H "$AUTH" -X POST $R/shutdown
```

## エラーの形式と code

成功以外の応答は、どのステータスでも次の形の JSON です。

```json
{"ok":false,"code":"no_keyboard_focus","error":"no element has keyboard focus in com.apple.Preferences"}
```

- `code` は機械向けの安定した文字列（snake_case）で、名前を変えることはありません。クライアントは英文の `error` ではなく `code` で分岐します。`error` は人向けの文で、文言は変わることがあります。
- `code` は「次に何をするか」が変わる単位です。1 つの code に複数の文言（ときには複数のステータス）が対応します。ステータスと code の対応は下の表のとおりで、ステータスは code を足す前から変えていません。
- 要素の解決の失敗には、ほかに `reason`・`count`・`candidates` が付きます（「[要素セレクタ](elements.md#要素セレクタ)」）。`reason` は code より細かい区別です。
- `code` がない応答は、code を返す前の古いランナーのものです。そのときはステータスで判断します。知らない `code` も同じく、ステータスで判断します。
- `app_not_installed`・`runner_unavailable`・`runner_timeout`・`runner_info_invalid`・`runner_bad_response`・`screenshot_save_failed` は `relay` が出す code で、ランナーは返しません（「[CLI](cli.md)」）。CLI は失敗のとき、ランナーの本文もこれらも、同じ形で stdout に出します。

| `code` | ステータス | 意味 | 推奨する対処 |
| --- | --- | --- | --- |
| `invalid_request` | 400 | ボディが JSON オブジェクトでない、必須フィールドがない、値の型・範囲が違う、対応外の値（キー名、ボタン名、`format` など） | `error` を読んでリクエストを直す。送り直しても同じ |
| `point_offscreen` | 400 | 座標が画面の外（「画面の外の座標」）。何も送っていない | `/health` の `screen` を読み直す（向きで縦横が入れ替わる） |
| `touch_mode_unavailable` | 400 / 422 | 指定した `mode` が使えない（400）、または選んだタッチの経路が対象の表示・アプリに届かない（422）。何も送っていない | `mode` を外す（auto）か、`error` が示す経路で送り直す |
| `http_malformed` | 400 / 501 | HTTP のリクエストそのものの不正（リクエスト行、文字コード、`Content-Length`、`Transfer-Encoding`） | クライアントを直す |
| `request_too_large` | 413 / 431 | ボディが 16 MB、リクエストヘッダーが 64 KB を超える | 小さくする |
| `unauthorized` | 401 | トークンがない・一致しない | runner.json を読み直す。古いファイルや別のランナーのものでないか確かめる |
| `busy` | 409 | 別のコマンドを実行中 | 待って再試行する（`/ping` の `busy` が `false` になってから） |
| `not_found` | 404 | 未知のパス | パスを直す。ドキュメントにあるパスなら、ランナーが古い（`relay start --rebuild`） |
| `method_not_allowed` | 405 | メソッド違い | メソッドを直す |
| `element_not_found` | 422 | セレクタに一致する要素がない、または `index` が範囲外（`reason` は `notFound` / `indexOutOfRange`） | 待つ（`timeout`）、前面アプリを確かめる、`/find`・`/source` で実際の値を確かめる |
| `element_ambiguous` | 422 | 2 つ以上一致して `index` がない（`reason` は `ambiguous`）。待たずに返る | `candidates` を見て条件か `index` を足す。待っても直らない |
| `element_not_hittable` | 422 | 要素はあるが触れない: frame が空、画面の外、`enabled: false`（`reason` は `emptyFrame` / `offscreen` / `disabled`） | スクロールする、前提の操作をする、画面を観察し直す |
| `no_keyboard_focus` | 422 | `/type`・`/key` でキーボードのフォーカスがある要素がない | 入力欄をタップしてから送り直す |
| `display_unknown` | 422 | 表示が複数ある端末で、前面アプリの表示を判定できない（どの表示も暗いなど）。何も送っていない | 画面の状態を利用者に確かめる |
| `window_position_unknown` | 422 | iPad で、アプリのウィンドウが画面のどこにあるかわからない（同じアプリのウィンドウが複数あるなど）。何も送っていない | ウィンドウを 1 つにするか、スクリーンショットから座標で指定する |
| `remote_view_position_unknown` | 422 | 要素を指定した `/tap`・`/press` で、選んだ要素が共有シート（別のプロセスが描くビュー）の中にあり、画面上の位置が決まらない（`reason: positionUnknown`）。何も送っていない（「[共有シートの中の要素](elements.md#共有シートの中の要素)」） | スクリーンショットで位置を確かめ、座標で指定する |
| `covered_by_other_app` | 422 | 要素を指定した `/tap`・`/press` で、対象アプリが前面のアプリの一覧になく、先頭が SpringBoard（システムの許可ダイアログ、コントロールセンターなどに覆われている）。何も送っていない。`bundleId`・`foreground`・`alert`（SpringBoard の alert の label か `null`）が付く（「[別のアプリに覆われているとき](elements.md#別のアプリに覆われているとき)」） | スクリーンショットか `/find`（`bundleId: com.apple.springboard`、`type: alert`）で確かめ、ダイアログなどを閉じてから送り直す |
| `touch_failed` | 422 / 500 | 合成したタッチが失敗した、時間内に終わらなかった、合成を始められなかった（500） | 1 回だけ再試行する。続くならランナーのログを見る |
| `typing_failed` | 422 / 500 | `/type`・`/key` で合成した入力が失敗した、時間内に終わらなかった（422）、合成を始められなかった（500） | `/find` の `value` で入った文字を確かめ、必要なら消してから送り直す |
| `xcui_failed` | 422 | XCUI が失敗を報告した（XCTest の issue、要素ツリーの取得の失敗など）。`error` に XCUI の文 | `error` を読み、前面アプリと画面を観察し直す |
| `internal_error` | 500 | ランナーの内部エラー（JPEG エンコードの失敗、終了処理中など） | 1 回だけ再試行する。続くならランナーのログを見る |

## 認証

- `relay start` は起動ごとに 32 バイトのランダムなトークン（`SecRandomCopyBytes`、hex 64 文字）を生成します。ランナーにはトークンそのものではなく、その SHA-256 だけを xcodebuild の環境変数 `TEST_RUNNER_RELAY_RUNNER_TOKEN_SHA256` で渡します（コマンドライン引数には載せません）。ランナーは提示されたトークンの SHA-256 を、保持しているハッシュと定数時間で比較します。
- ランナーは全エンドポイント（`/ping`、`/health`、`/shutdown` を含む）で `Authorization: Bearer <token>` を要求し、ない場合や一致しない場合は `401` を返します。比較は定数時間で行います。判定は HTTP キュー上で、リクエストヘッダーを読み終えた時点（ボディを読む前）に行い、`409` の busy 判定や `/ping` の応答よりも先です。未認証のリクエストからは busy 状態も処理時間もわからず、ボディを溜め込ませることもできません。
- 認証の前に処理するのはリクエストヘッダーの解析だけで、ヘッダーは 64 KB まで、リクエスト全体が届くまでは 30 秒までに制限しています。
- ready になると `relay start` は `{"url","token","udid"}` を `~/.relay/runner.json` にパーミッション 0600 で書き出し、stdout には `ready: <url>` とファイルの場所（`token: <path>`）だけを出します。トークンそのものは stdout に出しません（CI のログやターミナルの履歴に残りやすいため）。停止時にファイルを削除します。
- `relay bench` は `--url` と `--token` を受け付け、省略した分はランナー操作のコマンドと同じ探し方（`--runner`・`--session`・環境変数・`~/.relay/runner.json`）で見つけた `runner.json` から読みます。`relay start` 内部の `/health` 探索、`/ping` の生存確認、`/shutdown` もトークンを付けます。
- ランナーのログ（`relay-runner GET /health -> 200 1ms`、busy で弾いた `relay-runner GET /screenshot -> 409` など）には、メソッドとパスしか出しません。`/ping` は数秒おきに届くのでログに出しません。
- 脅威モデル: 同じネットワーク（Wi-Fi など）にいる第三者が、タップ、アプリの起動、スクリーンショットの取得をできないようにするためのものです。シミュレータのランナーは `127.0.0.1` だけで待ち受けるので、Mac の LAN 側のアドレスからは接続もできません（シミュレータは Mac とネットワークを共有するため、すべてのインターフェースで待ち受けると Mac の LAN に開いてしまいます）。実機のランナーはすべてのインターフェースで待ち受けますが、トークンがなければ何もできません。通信は平文の HTTP です。既定では、`relay` は CoreDevice トンネル（USB などの Mac と端末の間の経路）にしかトークンを送りません。`--allow-wifi` を付けると、Wi-Fi 上にもトークンと画面が平文で流れ、同じネットワークで盗聴できる相手には守れません。
- xcodebuild は `TEST_RUNNER_` 環境変数を xcresult（`relay start` では `~/.relay/build/…/TestData/port-<port>/Logs/Test/*.xcresult` で、ポートごとに新しい 3 個を残します。以前の relay は `~/Library/Developer/Xcode/DerivedData/RelayRunner-*/Logs/Test/` に作っていました）に記録します。ここに残るのはトークンの SHA-256 だけで、トークンは 256 ビットのランダム値なので、ハッシュから求めることはできず、ハッシュ自体をトークンとして送っても `401` になります。

## 同時リクエスト

コマンドは 1 つずつ実行します。実行中（タッチの完了待ちなどを含む）に別のリクエストが来ると、ランナーは HTTP キュー上で即座に `409 {"ok":false,"code":"busy","error":"busy"}` を返し、メインスレッドには入れません（実行中のコマンドの後ろに並ばせることはしません）。`/shutdown` だけは実行中でも受け付けてすぐ `200` を返し、実行中のコマンドが終わった時点でランナーが止まります。シミュレータで 3 秒の `/swipe` 中に `/health`・`/screenshot`・`/tap` を送ると、それぞれ 1–5 ms で 409 が返り、swipe 自体は 200 で完了しました。

409 が起きるのは、ゲートを通るリクエスト（`/ping` と `/shutdown` 以外のすべて。`/health` も含みます）が、別のゲートを通るリクエストの実行中に届いたときだけです。1 本のクライアントが応答を待ってから次を送る使い方では、自分のリクエスト同士は重なりません。ランナーは 409 を返すたびに `relay-runner GET /screenshot -> 409` の形でログに出します（`~/.relay/logs/runner-*.log`）。

### 生存確認（/ping）

以前は `relay start` が ready の後も 3 秒ごとに `/health` を送っていました。`/health` は他のコマンドと同じくゲートを通ってメインスレッドで実行される（前面アプリの取得を含み、実機で p50 約 16 ms）ため、利用者のリクエストとたまたま重なると、利用者側に 409 が返っていました。いまは生存確認に `GET /ping` を使います。

- `/ping` は HTTP キュー上で即答し、ゲートを取らず、メインスレッドにも入りません。コマンドの実行中でも `200` です。
- 応答は `{"ok":true,"busy":<bool>,"busyForMs":<ms or null>,"runner":{"version":…,"sourceHash":…}}` です（`runner` は「ランナーの版（runner）」）。`busy` はゲートを通ったコマンドが実行中かどうか、`busyForMs` はそのコマンドが受け付けられてからの経過ミリ秒（実行中でなければ `null`）です。
- 認証は他のエンドポイントと同じく必須で、`401` の判定が先なので、トークンなしでは busy 状態はわかりません。
- `/ping` はメインスレッドが止まっていても応答するので、「XCUI が動くこと」の確認にはなりません。そのため ready の判定（起動直後のアドレス探索）は、これまでどおり `/health` の `200` で行います。
- 生存確認では `200` だけを生存扱いにします（`/ping` は 409 を返さないので、409 は失敗として数えます）。`/ping` のない古いソースから作ったランナー（`/ping` より前に `relay install` したコピーなど。ソースが変われば relay は作り直すので、ほかの場合は起こりません）では `404` が返るので、`relay start` は警告を出して `/health` に切り替えます（この場合だけ 409 も生存扱いで、利用者側の 409 も起こりえます）。
- 利用者のクライアントも、`/ping` の `busy` が `false` になるのを見てから送れば、実行中のコマンドとの重なりによる 409 を避けられます（ただし、ほかのクライアントが先に入ることはあります）。

## 前面アプリ

`/type`・`/key`・`/source`・`/find` と、要素を指定した `/tap`・`/press` は、`bundleId` を省略すると前面アプリを対象にします。`/launch` を経由せずに手で切り替えたアプリ（ホーム画面のアイコン、ステータスバーの「◀ 戻る」、他アプリからの起動など）にも追従します。`GET /foreground` と `/health` の `foreground` で確認できます。

```json
{"bundleId":"com.apple.springboard","ok":true,"pid":35,"source":"private"}
```

| `source` | 仕組み |
| --- | --- |
| `private` | XCTest の非公開 API で、アクセシビリティ上アクティブなアプリを取得します（WebDriverAgent の `fb_activeApplication` と同じ方式）。ホーム画面では SpringBoard（`com.apple.springboard`）になります。iPad のウィンドウ表示では、画面にあるアプリと SpringBoard が並ぶので先頭を使います。Dock のフォルダのサービス（`com.apple.DocumentManager.DockFolderViewService`）は除きます |
| `fallback` | 非公開 API が使えない場合のほか、API があってもアプリを 1 つも取得できない場合や、取得で XCUI の失敗が記録された場合。最後に `/launch` したアプリが公開 API の `XCUIApplication.state` でまだ `runningForeground` ならそのアプリ、そうでなければ SpringBoard です。`pid` は `null` です。手で切り替えたアプリは判別できません |

`private` で使う非公開 API は「[非公開 API の一覧](private-api.md#前面アプリ)」にまとめています。クラスとセレクタは実行時に確認し、欠けていれば `fallback` になります。

`activeApplications` が返すのは通常 1 つです。アプリの切り替えの途中だけ 2 つ返ることがあり（実機で計算機 → RelayRunnerHost の切り替え直後に、切り替え先が先頭でした）、先頭のアプリを前面とみなします。ホーム画面に戻るジェスチャーの直後など、切り替えのアニメーション中は直前のアプリが返ることがあります。

確認した結果（シミュレータ iOS 27.0 と実機 iPhone 14 Pro iOS 26.7.1。いずれも `private`）:

| 状態 | シミュレータ | 実機 |
| --- | --- | --- |
| ホーム画面 | `com.apple.springboard` | `com.apple.springboard` |
| `/launch` したアプリ | RelayRunnerHost、設定（シミュレータには計算機がありません） | `com.apple.calculator`、RelayRunnerHost |
| relay を通さずに起動（`simctl launch` / `devicectl device process launch`） | `com.apple.mobilesafari`、`com.apple.Preferences`、RelayRunnerHost | `com.apple.calculator`、RelayRunnerHost |
| タッチで切り替え（ステータスバーの「◀ Calculator」をタップ） | – | `com.apple.calculator` |

`/health` は前面アプリの取得のぶん遅くなります（「[`/health` の応答](#health-の応答)」）。

要素を指定した `/tap`・`/press` は、タッチを送る直前にも一覧を読み直し、対象アプリが一覧になく先頭が SpringBoard なら何も送らずに `422`（`covered_by_other_app`）を返します（「[別のアプリに覆われているとき](elements.md#別のアプリに覆われているとき)」）。システムの許可ダイアログ・コントロールセンター・通知センターの表示中は、一覧が SpringBoard だけになります（シミュレータ iOS 27、実機 iOS 26.7.1）。

## 文字入力と特殊キー

- `/type {"text":"..."}` は前面アプリ（または `bundleId`）で、キーボードのフォーカスがある要素に入力します。入力欄をタップしてフォーカスを当ててから送ってください。
- 入力は XCTest の非公開 API で直接合成し、アプリがアイドルになるのを待ちません（「[文字入力の合成](private-api.md#文字入力の合成)」）。`/health` の `typeSynthesis` が `private` です。
- 非公開 API が使えないときと、表示が複数ある端末では、以前と同じ `XCUIElement.typeText` で入力し、`typeSynthesis` は `xcui` です。この経路は前後でアプリのアイドルを待つので、アイドルにならないアプリでは 3 分ほど busy になることがあります。
- `fallback`（非公開 API が使えない場合）では手で切り替えたアプリを判別できないので、`/type`・`/key` の `bundleId` を明示してください（「[前面アプリ](#前面アプリ)」）。
- 特殊キーは `POST /key {"key":"return"}`、または `/type` の `keys` 配列（`{"text":"abc","keys":["delete","return"]}`。`text` の後に順に送ります）で送ります。キー名は大文字小文字を区別せず、別名 `enter`（= return）、`backspace`（= delete）も使えます。
- 対応するキーは `return`・`delete`・`space` だけです。`tab` と `escape` は iPhone のソフトウェアキーボードにキーがなく、tab は `\t` の文字として入力され、escape は何も起きなかったため、外しました。対応していないキー名は、`/key` でも `keys` でも `400 {"ok":false,"code":"invalid_request","error":"invalid field: key: unsupported key 'tab' (expected return, delete, space)"}` を返し、何も入力しません。
- キーは `XCUIKeyboardKey` の文字（return は `\r`、delete は U+007F、space は ` `）として、`text` に続けて同じ経路で送ります。`typeKey(_:modifierFlags:)`（ハードウェアキーのイベント）も試しましたが、iPhone ではシミュレータ・実機とも space と tab しか届かず、return・delete・escape は何も起きませんでした。
- フォーカスがない場合は、XCUI の長いエラー文の代わりに `422 {"ok":false,"code":"no_keyboard_focus","error":"no element has keyboard focus in <bundleId>"}` を返します。何も入力しません。
- `private` では、タップした直後の入力欄がフォーカスを持つまで、最大 1 秒探してから `no_keyboard_focus` を返します（シミュレータで約 1.1–1.2 秒）。`xcui` では XCUI が待つため約 2–3 秒かかります。
- `private` の入力が時間内に終わらなければ、`422 {"ok":false,"code":"typing_failed",…}` を返して busy を解きます。時間は、10 秒に 1 文字（Unicode スカラー）0.1 秒とキー 1 つ 1 秒を足した長さです。
- `typing_failed` のときは入力の一部が入っていて、応答の後も残りが入り続けることがあります。`/find` の `value` で確かめてから送り直してください。

RelayRunnerHost の入力欄（`relay.input`）で確認した結果（シミュレータ・実機とも同じ。`tab`・`escape` は外す前の結果）:

| キー | 結果 |
| --- | --- |
| `text` | 入力されます（`hello world`） |
| `return` | `textFieldShouldReturn` が呼ばれ、入力が確定します。シミュレータの Safari のアドレスバーでもページが開きます |
| `delete` | 1 文字削除されます |
| `space` | 空白が入力されます |
| `tab`（対応外、400） | 1 行の入力欄に `\t` の文字として入力されました（次の入力欄にフォーカスは移らない。ソフトウェアキーボードに Tab キーがないため） |
| `escape`（対応外、400） | 何も起きませんでした（ソフトウェアキーボードに Esc キーがなく、キーイベントとしても届かない） |

1 回の `/key` は、シミュレータで約 0.26 秒、実機で約 0.66 秒でした。`/type` の `text` は、シミュレータで約 15 ms/文字（ASCII 1,000 文字で約 17 秒、日本語も同じくらい）かかり、応答は入力し終わってから返ります。長い文字列を送るクライアントは、その分 HTTP のタイムアウトを長くしてください（`relay type` は 1 文字 0.1 秒とキー 1 つ 1 秒を足します）。

`private` の `/type`（10 文字）は、ネイティブの入力欄で約 0.39–0.42 秒でした。`xcui`（`typeText`）では約 0.42–0.62 秒でした。
メインのランループが眠らない画面では、`private` は同じく約 0.40 秒で、`xcui` は約 141–181 秒 busy になりました（「[文字入力の経路](design.md#文字入力の経路)」）。

確かめた環境（`private`）: iPhone 17 シミュレータ、iOS 27.2、Xcode 27.2。ネイティブの入力欄、WKWebView と Safari のページの入力欄で、文字・`--stdin`・`return`・`delete`・`space` を確かめました。
