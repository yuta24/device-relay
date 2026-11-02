# 要素ツリーと要素セレクタ

`/source` の要素ツリーと、`/tap`・`/press`・`/find` の要素セレクタ、要素の待機について説明します。全体の入口は [README](../README.md) です。

## 要素ツリー（/source）

`GET /source` は既定で JSON を返します（`format=json`）。`XCUIElement.snapshot()` で取得したツリーで、各要素は次のキーをすべて持ちます。

| キー | 内容 |
| --- | --- |
| `type` | `XCUIElement.ElementType` のケース名（`application`、`button`、`textField`、`staticText` など） |
| `identifier` / `label` | accessibilityIdentifier / ラベル（なければ空文字列） |
| `value` / `placeholder` | 値 / プレースホルダ（なければ `null`。値は文字列に変換） |
| `frame` | `{"x","y","width","height"}`。`/tap` と同じ、表示の向きでのポイント単位（小数点以下 3 桁） |
| `enabled` / `selected` | 有効か / 選択されているか |
| `hasFocus` | 公開 API の `hasFocus`。フォーカスエンジン（iPad のキーボード操作や tvOS）のフォーカスで、iPhone で入力中の欄でも `false` です |
| `hasKeyboardFocus` | キーボードのフォーカスがあるか（非公開の `-[XCElementSnapshot hasKeyboardFocus]`。使えなければ `null`） |
| `children` | 子要素の配列 |
| `truncated` | `maxDepth` で子要素を省いた要素にだけ付きます（`true`） |

実機の計算機での出力の抜粋（`children` の中身を省略。キーはソート順です）:

```json
{"bundleId":"com.apple.calculator","ok":true,"tree":{"children":[…],"enabled":true,
 "frame":{"height":852,"width":393,"x":0,"y":0},"hasFocus":false,"hasKeyboardFocus":false,"identifier":"",
 "label":"Calculator","placeholder":null,"selected":false,"type":"application","value":null}}
```

ツリーの中のボタン 1 つ:

```json
{"children":[],"enabled":true,"frame":{"height":36,"width":36,"x":20,"y":63},"hasFocus":false,
 "hasKeyboardFocus":false,"identifier":"SidebarButton","label":"History","placeholder":null,"selected":false,
 "type":"button","value":null}
```

- `maxDepth=<n>` で深さを制限します（`0` はルートだけ）。ただし XCTest は常にツリー全体を取得するので、短くなるのは応答の大きさだけで、時間はほとんど変わりません。`format=compact` と `filter` にも効きます（深さで切ったツリーを絞ります）。
- `format=text` は従来の `debugDescription` のテキストです。`filter` とは組み合わせられません（`400`）。
- 既定を JSON にしたのは、プログラムから扱う用途が主で、計測ではテキストより速かったためです（`debugDescription` はツリーの取得に加えて文字列の整形に時間がかかります）。テキストは人が読むとき用に残しています。
- 横向きでも `frame` は表示の向きの座標です（シミュレータの landscapeLeft / landscapeRight と実機の landscapeLeft で、`relay.input2` の frame の中心を `/tap` するとその欄にフォーカスが移ることを確認しました）。

### 1 行 1 要素の形式（format=compact）

`format=compact` は、要素を 1 行ずつ、深さに応じて 2 文字ずつ字下げしたテキストで返します。`debugDescription`（`format=text`）と違って JSON と同じスナップショットから作るので、JSON と同じくらい速く、大きさは JSON の 3 分の 1 ほどです。

```
application label="Settings" frame=0,0,402,874
  window frame=0,0,402,874
    ...
                  button label="General" id="com.apple.settings.general" frame=16,293,370,52
```

- 1 行は、`type`、空でない `label`・`id`（identifier）・`value`・`placeholder`（値は JSON の文字列。改行や `"` を含んでも 1 行に収まります）、`frame=x,y,width,height`（表示の向きのポイントを整数に丸めたもの）、立っているフラグ（`selected`、`focused`＝キーボードのフォーカス、`disabled`、`truncated`）の順です。名前はセレクタのオプション（`--type`・`--label`・`--id`・`--value`）に合わせています。

### 操作できる要素だけに絞る（filter=interactive）

`filter=interactive` は、ツリー全体の代わりに、エージェントが操作に使える要素だけを文書順の平らな一覧で返します。`format=json` なら `elements` の配列、`format=compact` なら 1 行 1 要素（字下げなし）です。

```json
{"bundleId":"com.apple.Preferences","count":12,"elements":[
 {"frame":{"height":52,"width":370,"x":16,"y":293.333},"identifier":"com.apple.settings.general","label":"General",
  "placeholder":null,"selected":false,"type":"button","value":null}, …],"filter":"interactive","ok":true}
```

```
button label="General" id="com.apple.settings.general" frame=16,293,370,52
searchField label="Search" placeholder="Search" frame=28,808,346,28
```

残す要素:

- 型が操作の対象になるもの: `button`、`cell`、`link`、`icon`（ホーム画面）、`tab`、`switch`、`toggle`、`slider`、`stepper`、`pickerWheel`、`textField`、`secureTextField`、`searchField`、`textView` など。`table` や `segmentedControl` などの入れ物は、中のボタンやセルが残るので外します。キーボードとそのキーは外します（文字入力は `/type`・`/key` で行います）
- identifier・label・placeholder のどれかを持つもの（セレクタで指定できるもの）。テキスト入力欄は何もなくても残します（`--type textField --index <n>` で指定できるため）
- 有効（`enabled`）で、frame が画面と重なり、タップ位置（`/tap` の要素指定と同じ、画面と重なる部分の中心）がキーボードの下にも、後に続くコントロールの下にもないもの
- 名前のないコントロール（label のないセルなど）は、その中のラベル付きの `staticText` を代わりに残します（中に名前付きのコントロールがあればそちらを残します）。テキストをタップするとそのコントロールに当たります

各要素は、セレクタに使う `type`・`identifier`・`label`・`value` と、`placeholder`、`frame`、`selected` を持ちます（子要素はありません）。`relay tap --type button --label General` や `--id` のように、そのままセレクタに使えます。

- 絞り込みはランナー（端末側）で行います。スナップショットの取得はどちらでも同じ時間がかかりますが、ランナーで絞れば JSON に変換して送るのが短い一覧だけで済み、curl などほかのクライアントからも使えます。判定は SwiftPM のテストで確かめられるよう、CLI と共有するソース（`Sources/relay/RunnerElementTree.swift`）に置いています。
- XCUI のスナップショットはヒット可能か（`isHittable`）を持たず、要素ごとに問い合わせると遅いので、重なりは近似で判定します。後に続く（＝手前に描かれる）コントロールがタップ位置を覆っていれば外します（iOS 27 の設定アプリでは、下部の検索バーに中心が隠れた最後のセルと、検索欄の中で重なった 2 つの Dictate ボタンの片方が外れます）。コントロールでないシートや覆いの下にある要素は外れません。
- 一覧から外れても、セレクタは全体のツリーから探します。`--label General` だけでは同じラベルの `staticText` にも一致して `ambiguous` になることがあるので、一覧の `type` も付けるか `--id` を使います。

取得時間（`curl` で 7 回の p50。シミュレータは iPhone 17 Pro / iOS 27.0、実機は iPhone 14 Pro / iOS 26.7.1。括弧内は応答の大きさ）:

| 対象 | json | text | json `maxDepth=3` |
| --- | ---: | ---: | ---: |
| シミュレータ: 設定（トップ） | 50 ms（37 KB） | 198 ms（17 KB） | 46 ms（0.9 KB） |
| シミュレータ: RelayRunnerHost（キーボードなし） | 10 ms（2.5 KB） | 22 ms（1.3 KB） | 10 ms（0.9 KB） |
| シミュレータ: RelayRunnerHost（キーボード表示中） | 25 ms（16 KB） | 86 ms（6 KB） | 24 ms（2.5 KB） |
| シミュレータ: ホーム画面（SpringBoard） | 43 ms（36 KB） | 161 ms（13 KB） | – |
| 実機: RelayRunnerHost（キーボード表示中） | 140 ms（16 KB） | 238 ms（6 KB） | 132 ms（2.7 KB） |
| 実機: 計算機 | 89 ms（10 KB） | 187 ms（4 KB） | 122 ms（1.6 KB） |
| 実機: ホーム画面（SpringBoard） | 194 ms（70 KB） | 589 ms（25 KB） | 182 ms（9 KB） |

`format=compact` と `filter=interactive`（同じシミュレータ。curl で 7–9 回の p50。括弧内は要素数と応答の大きさ）:

| 対象 | json | text | compact | json `filter=interactive` | compact `filter=interactive` |
| --- | ---: | ---: | ---: | ---: | ---: |
| 設定（トップ） | 50 ms（167 要素、37 KB） | 210 ms（17 KB） | 50 ms（167 行、11 KB） | 48 ms（12 要素、2.3 KB） | 48 ms（12 行、1.0 KB） |
| ホーム画面（SpringBoard） | 87 ms（80 KB） | 412 ms（28 KB） | 83 ms（17 KB） | 83 ms（27 要素、4.6 KB） | 83 ms（1.6 KB） |
| RelayRunnerHost（入力欄にフォーカス） | 24 ms（14 KB） | 93 ms（5.6 KB） | 22 ms（3.3 KB） | 24 ms（3 要素、0.6 KB） | 25 ms（0.2 KB） |

時間はほぼスナップショットの取得で決まり、絞り込みや形式では変わりません（text だけは `debugDescription` の整形のぶん遅くなります）。

## 要素セレクタ

`/tap` と `/press` は、`x`・`y` の代わりに `element` で要素を指定できます。`/find` は同じセレクタで一致した要素の一覧を返します。

```json
{"element":{"identifier":"relay.input"}}
{"element":{"label":"History","type":"button"}}
{"element":{"type":"textField","index":1},"bundleId":"dev.yuta24.devicerelay.RelayRunnerHost","timeout":3}
```

| キー | 内容 |
| --- | --- |
| `element.identifier` / `element.label` / `element.value` | `/source` の同名の値との完全一致（大文字小文字も区別） |
| `element.type` | `/source` の `type` と同じケース名（`button`、`textField`、`cell` など）。知らない名前は `400` |
| `element.index` | 一致した要素のうち何番目を使うか（0 から。順序は `/source` の JSON と同じ文書順＝親が先の深さ優先） |
| `bundleId` | 対象アプリ。省略時は前面アプリ（`/source` と同じ） |
| `timeout` | 要素が現れるまで待つ秒数（0–10、既定 0 = 1 回だけ探す）。0.25 秒ごとにスナップショットを取り直します |
| `limit`（`/find` のみ） | 返す要素の上限（1–100、既定 20）。`count` は常に一致した総数で、上限で切った場合は `truncated: true` |

- 条件（`identifier`・`label`・`type`・`value`）は AND で組み合わせ、少なくとも 1 つ必要です。空文字列・文字列以外・未知のキー（`id` など）は `400` です。打ち間違いで条件が黙って消え、意図より広く一致するのを防ぐためです。
- 部分一致・正規表現は入れていません。完全一致なら同じセレクタが常に同じ要素を指し、一致の理由が説明しやすいためです。部分一致は複数一致が増え、`index` の意味が画面の内容で変わりやすくなります。曖昧な名前で探したいときは、`/find` を `type` などで絞って一覧から選び、その `identifier` や `index` を使ってください。
- 解決には `/source` と同じ `snapshot()` を使い、frame は表示の向きのポイント（`/tap` と同じ座標系）なので、横向きでもそのまま使えます。タップ位置は「frame と画面の重なる部分」の中心です（画面端で一部が切れたセルも、見えている部分の中心を押します）。タッチは座標指定と同じ経路（`private`、だめなら `xcui`。`mode` も同じ）で送ります。
- `x`・`y` と `element` を両方指定すると `400` です。

応答（`/tap`）には、実際に使った要素とタップ座標が入ります:

```json
{"bundleId":"dev.yuta24.devicerelay.RelayRunnerHost","element":{"enabled":true,
 "frame":{"height":34,"width":370,"x":16,"y":132},"identifier":"relay.input2","index":0,"label":"",
 "type":"textField","value":null},"mode":"private","ok":true,"point":{"x":201,"y":149}}
```

要素が 1 つに決まらない・触れない場合は `422` で、`reason`、一致した総数 `count`、候補（最大 5 件）`candidates` を返します。

| `reason` | 条件 | `candidates` |
| --- | --- | --- |
| `notFound` | 一致なし | 空 |
| `ambiguous` | 2 件以上一致して `index` がない | 一致した要素（先頭 5 件） |
| `indexOutOfRange` | `index` が一致件数以上 | 一致した要素（先頭 5 件） |
| `emptyFrame` | 選んだ要素の frame の幅か高さが 0 | 選んだ要素 |
| `offscreen` | 選んだ要素の frame が画面と重ならない | 選んだ要素 |
| `disabled` | 選んだ要素が `enabled: false` | 選んだ要素 |

```json
{"candidates":[{"enabled":true,"frame":{"height":52,"width":370,"x":16,"y":380.333},
  "identifier":"com.apple.settings.general","index":0,"label":"General","type":"button","value":null},
 {"enabled":true,"frame":{"height":29,"width":101.667,"x":29.667,"y":392},"identifier":"","index":1,
  "label":"General","type":"staticText","value":null}],
 "count":2,"error":"2 elements match the selector; add conditions or an index","ok":false,"reason":"ambiguous"}
```

（設定アプリのトップでは「一般」のセルが `button` と、その中の `staticText` の 2 つとして見えるので、`{"label":"General","type":"button"}` のように型も指定します。）

`/find` の例（`{"element":{"type":"textField"}}`、RelayRunnerHost）:

```json
{"bundleId":"dev.yuta24.devicerelay.RelayRunnerHost","count":2,"elements":[
 {"enabled":true,"frame":{"height":34,"width":370,"x":16,"y":86},"identifier":"relay.input","index":0,"label":"","type":"textField","value":null},
 {"enabled":true,"frame":{"height":34,"width":370,"x":16,"y":132},"identifier":"relay.input2","index":1,"label":"","type":"textField","value":null}],
 "ok":true,"truncated":false}
```

`/find` は一致がなくても `200`（`count: 0`）です。`elements[].index` はそのまま `/tap` の `index` に使えます。`/find` に `index` を付けると、その 1 件だけ（範囲外なら空）を返します（`count` は一致した総数のままです）。

### 待機（timeout）

- `timeout` を付けると、`/tap`・`/press` は要素が触れる状態（`notFound`・`indexOutOfRange`・`emptyFrame`・`offscreen`・`disabled` 以外）になるまで、`/find` は 1 件以上一致するまで待ちます。期限を過ぎると最後の結果を返します（`/tap` は `422`、`/find` は `count: 0`）。`ambiguous` は待っても解消しにくいので、待たずにすぐ `422` を返します。
- 待っている間もスナップショットの失敗（アプリがまだ起動していないなど）は再試行します。
- 上限は 10 秒です。待っている間はコマンドが busy ゲートを持ち続けるので、ほかのリクエスト（`/health` を含む）は `409` になります（`/ping` は `busy: true` を返します）。長く待つ必要がある場合は、短い `timeout` で繰り返してください。
- `timeout` は「次のスナップショットを取るかどうか」の期限で、1 回のスナップショット自体は中断できません（「[既知の制約](limitations.md)」を参照）。

シミュレータで、RelayRunnerHost を終了した状態から `{"element":{"identifier":"relay.input2"},"bundleId":"…RelayRunnerHost","timeout":5}` を送り、1.5 秒後に `simctl launch` で起動すると、約 3.8 秒で 200 が返って `relay.input2` にフォーカスが移りました。待機中の `/ping` は `{"busy":true,"busyForMs":719}`、`/health` は `409` でした。

確認した結果（シミュレータ iPhone 17 Pro）:

- RelayRunnerHost: `relay.input` / `relay.input2` を identifier 指定・`{"type":"textField","index":1}` でタップすると、`/source` の `hasKeyboardFocus` がその欄に移りました（`private`・`xcui`、`/press` も同じ）。
- 横向き（landscapeLeft / landscapeRight）でも、identifier 指定のタップでフォーカスが移りました（`point` は 874×402 の座標で `{"x":437,"y":87}` など）。
- 設定: `{"label":"General","type":"button"}` → `{"label":"About","type":"button"}` と順にタップして「情報」画面に移りました。
