# 要素ツリーと要素セレクタ

`/source` の要素ツリーと、`/tap`・`/press`・`/find` の要素セレクタ、要素の待機について説明します。全体の入口は [README](../README.ja.md) です。

## 要素ツリー（/source）

`GET /source` は既定で JSON を返します（`format=json`）。`XCUIElement.snapshot()` で取得したツリーで、各要素は次のキーをすべて持ちます。

| キー | 内容 |
| --- | --- |
| `type` | `XCUIElement.ElementType` のケース名（`application`、`button`、`textField`、`staticText` など） |
| `identifier` / `label` | accessibilityIdentifier / ラベル（なければ空文字列） |
| `value` / `placeholder` | 値 / プレースホルダ（なければ `null`。値は文字列に変換） |
| `frame` | `{"x","y","width","height"}`。`/tap` と同じ、表示の向きでのポイント単位（小数点以下 3 桁）。iPad のウィンドウ表示でも画面の座標です（「[iPad のウィンドウ表示](screen.md#ipad-のウィンドウ表示)」） |
| `enabled` / `selected` | 有効か / 選択されているか |
| `hasFocus` | 公開 API の `hasFocus`。フォーカスエンジン（iPad のキーボード操作や tvOS）のフォーカスで、iPhone で入力中の欄でも `false` です |
| `hasKeyboardFocus` | キーボードのフォーカスがあるか（非公開 API。使えなければ `null`。「[キーボードのフォーカス](private-api.md#キーボードのフォーカス)」） |
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
- `format=text` は従来の `debugDescription` のテキストです。`filter` とは組み合わせられません（`400`）。XCUI の値そのままなので、iPad のウィンドウ表示でも画面の座標に変換しません。
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

- 絞り込みはランナー（端末側）で行います。スナップショットの取得はどちらでも同じ時間がかかりますが、ランナーで絞れば JSON に変換して送るのが短い一覧だけで済み、curl などほかのクライアントからも使えます。判定は SwiftPM のテストで確かめられるよう、CLI と共有するソース（`Sources/Relay/Shared/RunnerElementTree.swift`）に置いています。
- 後に続くコントロールの frame がタップ位置を覆うときは、アクセシビリティの hit test で、別の要素に当たると確認できたものだけを外します。ラベルの大きな枠と重なる入力欄やボタン、hit test で確認できないものは残します。
- キーボード以外の、コントロールでない覆いの下にある要素は、一覧から外れないことがあります。要素指定のタッチは、送る前にも確認します（下の「[要素セレクタ](#要素セレクタ)」）。
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

上の表は hit test の追加前の値です。現在は、後のコントロールと重なる候補ごとに hit test を行うため、その回数によって時間が増えます（text は `debugDescription` の整形のぶん遅くなります）。

| 対象 | hit test 回数 | 追加前の中央値 | 追加後の中央値 |
| --- | ---: | ---: | ---: |
| 設定の一般 | 11 | 47.2 ms | 45.9 ms |
| Safari の確認ページ | 2 | 39.9 ms | 44.9 ms |

確かめた環境: Xcode 27.2、iPhone 17 Pro シミュレータ（iOS 27.0）、各 5 回。平均は一般 58.4→61.1 ms、Safari 55.6→46.4 ms でした。ばらつきがあるため、少ない回数の差は目安です。

## 要素セレクタ

`/tap` と `/press` は、`x`・`y` の代わりに `element` で要素を指定できます。`/find` は同じセレクタで一致した要素の一覧を返します。

```json
{"element":{"identifier":"relay.input"}}
{"element":{"label":"History","type":"button"}}
{"element":{"type":"textField","index":1},"bundleId":"com.example.app","timeout":3}
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
- ラベルは `/find`・`/source` の値をそのままコピーしてください。システムの許可ダイアログの `Don’t Allow` はアポストロフィが `’`（U+2019）で、ASCII の `'` を使った `relay tap --label "Don't Allow"` は一致しません。
- 解決には `/source` と同じ `snapshot()` を使い、frame は表示の向きのポイント（`/tap` と同じ座標系）なので、横向きでもそのまま使えます。タップ位置は「frame と画面の重なる部分」の中心です（画面端で一部が切れたセルも、見えている部分の中心を押します）。iPad のウィンドウでは、frame を画面の座標に変換したうえで、見えているウィンドウとの重なりの中心を押します。タッチは座標指定と同じ経路（`private`、だめなら `xcui`。`mode` も同じ）で送ります。
- `x`・`y` と `element` を両方指定すると `400` です。
- 要素指定のタッチは、送信前に中心の hit test を行います。同じスナップショット内で、選んだ要素でも、その祖先・子孫でもない要素に当たると確認できた場合だけ、何も送らず `422`、`element_point_covered`（`reason: pointCovered`）を返します。
- hit test の API がない、nil・エラーが返る、返された要素が取得済みのツリーにない場合は、従来どおり送ります。座標指定のタッチにはこの確認を行いません。
- hit test がタッチ点を含まない frame の要素を返した場合も、確認できないものとして従来どおり送ります。
- `pointCovered` の応答には、当たる要素の要約が `hit`（`type`・`label`・画面上の `frame`）に入ります。覆いを閉じるか、スクリーンショットで対象の位置を確かめて座標を指定してください。
- 隠れた要素を外す `/source?filter=interactive` の近似判定は「[操作できる要素だけに絞る](#操作できる要素だけに絞るfilterinteractive)」を参照してください。
- `/launch` の直後は、前面アプリの取得が切り替え前のアプリを返すことがあります。確実に対象を決めたい場合は `bundleId` を指定してください。

応答（`/tap`）には、実際に使った要素とタップ座標が入ります:

```json
{"bundleId":"dev.devicerelay.local.RelayRunnerHost","element":{"enabled":true,
 "frame":{"height":34,"width":370,"x":16,"y":132},"identifier":"relay.input2","index":0,"label":"",
 "type":"textField","value":null},"mode":"private","ok":true,"point":{"x":201,"y":149}}
```

iPad のウィンドウでは、応答（`/tap`・`/press`・`/find`・`/source` の JSON）に `window` が付きます。frame と `point` は変換した後の画面の座標です。

```json
{"bundleId":"dev.devicerelay.local.RelayRunnerHost","element":{"enabled":true,
 "frame":{"height":34,"width":343,"x":395,"y":152},"identifier":"relay.input2","index":0,"label":"",
 "type":"textField","value":null},"mode":"private","ok":true,"point":{"x":566.5,"y":169},
 "window":{"height":486,"scale":1,"width":375,"x":379,"y":72}}
```

ウィンドウの位置が決まらないときは、`/tap`・`/press` は何も送らずに `422`、`window_position_unknown` です。`/find`・`/source` は成功のままで、`window: null` と `warning` が付き、frame はウィンドウの中の座標です（「[iPad のウィンドウ表示](screen.md#ipad-のウィンドウ表示)」）。

要素が 1 つに決まらない・触れない場合は `422` で、`code`、`reason`、一致した総数 `count`、候補（最大 5 件）`candidates` を返します。`code`（「[エラーの形式と code](http-api.md#エラーの形式と-code)」）は次の行動ごとに `reason` をまとめたもので、`reason` はその詳細です。

| `reason` | `code` | 条件 | `candidates` |
| --- | --- | --- | --- |
| `notFound` | `element_not_found` | 一致なし | 空 |
| `ambiguous` | `element_ambiguous` | 2 件以上一致して `index` がない | 一致した要素（先頭 5 件） |
| `indexOutOfRange` | `element_not_found` | `index` が一致件数以上 | 一致した要素（先頭 5 件） |
| `emptyFrame` | `element_not_hittable` | 選んだ要素の frame の幅か高さが 0 | 選んだ要素 |
| `offscreen` | `element_not_hittable` | 選んだ要素の frame が画面（iPad のウィンドウでは、見えているウィンドウ）と重ならない | 選んだ要素 |
| `pointCovered` | `element_point_covered` | 押す点が別の要素に当たると確認できたため、何も送らなかった | 選んだ要素 |
| `disabled` | `element_not_hittable` | 選んだ要素が `enabled: false` | 選んだ要素 |
| `positionUnknown` | `remote_view_position_unknown` | 選んだ要素が共有シートの中にあり、画面上の位置が決まらない（「[共有シートの中の要素](#共有シートの中の要素)」）。何も送っていない | 選んだ要素 |

```json
{"candidates":[{"enabled":true,"frame":{"height":52,"width":370,"x":16,"y":380.333},
  "identifier":"com.apple.settings.general","index":0,"label":"General","type":"button","value":null},
 {"enabled":true,"frame":{"height":29,"width":101.667,"x":29.667,"y":392},"identifier":"","index":1,
  "label":"General","type":"staticText","value":null}],
 "code":"element_ambiguous","count":2,"error":"2 elements match the selector; add conditions or an index","ok":false,
 "reason":"ambiguous"}
```

（設定アプリのトップでは「一般」のセルが `button` と、その中の `staticText` の 2 つとして見えるので、`{"label":"General","type":"button"}` のように型も指定します。）

`/find` の例（`{"element":{"type":"textField"}}`、シミュレータの RelayRunnerHost）:

```json
{"bundleId":"dev.devicerelay.local.RelayRunnerHost","count":2,"elements":[
 {"enabled":true,"frame":{"height":34,"width":370,"x":16,"y":86},"identifier":"relay.input","index":0,"label":"","type":"textField","value":null},
 {"enabled":true,"frame":{"height":34,"width":370,"x":16,"y":132},"identifier":"relay.input2","index":1,"label":"","type":"textField","value":null}],
 "ok":true,"truncated":false}
```

`/find` は一致がなくても `200`（`count: 0`）です。`elements[].index` はそのまま `/tap` の `index` に使えます。`/find` に `index` を付けると、その 1 件だけ（範囲外なら空）を返します（`count` は一致した総数のままです）。

Safari の同じボタンを各 5 回押した CLI 応答の平均です。

| 環境 | hit test 追加前 | 追加後 |
| --- | ---: | ---: |
| シミュレータ | 374.0 ms | 382.8 ms |
| 実機 | 未計測 | 566.5 ms |

確かめた環境: Xcode 27.2、iPhone 17 Pro シミュレータ（iOS 27.0）の Safari・WKWebView・設定、iPhone 14 Pro 実機（iOS 26.7.1）の Safari・設定。iPad の hit test は確かめていません。

### 共有シートの中の要素

共有シート（`UIActivityViewController`）の中身は別のプロセスが描くビューです。アプリのスナップショットでは、入れ物の `ShareSheet.RemoteContainerView` と、その中で同じ frame を繰り返す数段のビューは画面の座標で返りますが、その下の中身は (0, 0) から始まる入れ物からの相対座標で返ります。以前は、iPhone 17 Pro シミュレータで y ≈ 745 に描かれた「Copy」のセルが y = 230 と返り、要素指定のタップは `ok: true` のままシートの外側に当たってシートが閉じるか、何も起きませんでした。

- **変換**: 中身が「(0, 0) から入れ物と同じ大きさ」の形なら、入れ物の原点を足して画面の座標にします（縦向きのシートが (9, 501) にあれば、「Copy」のセルは (20, 230) から (29, 731) になります）。対象は `/find`・`/source`（`format=text` を除く）の frame と、要素指定の `/tap`・`/press` の `frame`・`point` です。応答に足すフィールドはありません。iPad のウィンドウ表示や表示が複数ある端末では、この変換の後にウィンドウ・表示の変換をします。
- 入れ物は識別子 `ShareSheet.RemoteContainerView` で見分けます。識別子が変わると変換も位置の判定もされず、相対座標のままタッチが外れます。
- **タップ位置**: frame と入れ物（シート）の重なりの中心です。横にスクロールしてシートの外に出たセルは、シートの中に見えている部分を押し、見えていなければ `offscreen`（`element_not_hittable`）です。シートの外を押してシートを閉じてしまわないためです。
- **変換しないもの**: 入れ物が (0, 0) にあるとき（「More」で開く一覧のように画面全体を覆うとき）は、frame がそのまま画面の座標なので変えません。
- iPad のポップオーバー・シートでは、中身が大きさ 0 の要素 1 つだけで、中の要素はツリーに出ません（セレクタは `notFound`）。座標で押してください。
- **位置が決まらないとき**: 中身が上の形でない（大きさが違う、別の位置から始まる）ときは、どれだけずらせばよいかわからないので変換しません。そのときシートの中の要素への要素指定の `/tap`・`/press` は、何も送らずに `422`、`remote_view_position_unknown`（`reason: positionUnknown`）です（`timeout` の間は待ちます）。`/find`・`/source` は成功のままで、frame は返ったままの値、`warning` が付き、`format=compact` は先頭に `warning …` の行が付きます。スクリーンショットで位置を確かめて座標で押してください。シートの後ろのアプリの要素はこれまでどおりです。

```json
{"candidates":[{"enabled":true,"frame":{"height":134.333,"width":82,"x":19.667,"y":229.667},
  "identifier":"actionGroupCell","index":0,"label":"Copy","type":"cell","value":null}],
 "code":"remote_view_position_unknown","count":1,
 "error":"cannot tell where the elements inside ShareSheet.RemoteContainerView (9,501,384,364) are on the screen: its content (0,0,384,200) is not the container's size at (0, 0); nothing was sent. Touch by coordinates from a screenshot instead",
 "ok":false,"reason":"positionUnknown"}
```

- **ほかの別プロセスの画面**: 写真の選択（`PHPickerViewController`）は画面の座標で返るので変換しません（iPhone の全画面のシートと、iPad のシートで確かめました。iPad では読み込みの後に中身がツリーに出なくなります）。`SFSafariViewController` と `ASWebAuthenticationSession` の画面は `com.apple.SafariViewService` として扱います（「[別のアプリに覆われているとき](#別のアプリに覆われているとき)」）。
iPhone の縦・横で、変換した frame がスクリーンショットの位置と合い、要素指定の「Copy」でコピーされること（`completionWithItemsHandler` が `CopyToPasteboard`・`completed: true`）を確かめました。シミュレータでは「More」の一覧も確かめました。実機では共有先を押していません。

どの環境でもシートは内容に合わせた高さのカードで、上にスワイプしても広がらなかったので、広げた形は確かめていません。iPad では、全画面・ウィンドウ表示のどちらでも中身がツリーに出ませんでした。

位置が決まらないときの `422` は、実際の画面では起きる形が見つからず、ユニットテストだけで確かめています。

確かめた環境: iPhone 17 Pro シミュレータ（iOS 27.0）、iPhone 14 Pro（iOS 26.7.1）、iPad Pro 11 インチ シミュレータ（iOS 27.0）。

### 別のアプリに覆われているとき

要素を指定した `/tap`・`/press` は、タッチを送る直前に前面アプリの一覧（「[前面アプリ](http-api.md#前面アプリ)」の `private`）を読み直します。対象アプリ（`bundleId`。省略したときはリクエストの最初に決めた前面アプリ）が一覧になく、一覧の先頭が SpringBoard なら、何も送らずに `422`、`covered_by_other_app` を返します。システムの許可ダイアログ・コントロールセンター・通知センターは SpringBoard が描くので、表示中の一覧は SpringBoard だけになります。一方、アプリのスナップショットには後ろの要素が frame つきで残るので、以前はその座標にタッチを送り、`ok: true` のまま何も起きないか、同じ位置にあるダイアログのボタン（「Allow While Using App」「Don’t Allow」など）を押していました。

```json
{"alert":"Allow “RelayRunner” to use your location?","bundleId":"dev.devicerelay.local.RelayRunnerHost",
 "code":"covered_by_other_app",
 "error":"dev.devicerelay.local.RelayRunnerHost is covered by an alert (\"Allow “RelayRunner” to use your location?\"); nothing was sent",
 "foreground":"com.apple.springboard","ok":false}
```

- `bundleId` はタッチの対象アプリ、`foreground` は一覧の先頭（Dock のフォルダのサービスを除く。今は常に `com.apple.springboard`）、`alert` は SpringBoard の要素ツリーで最初に見つかった `alert` の label です。alert がなければ（コントロールセンター、通知センターなど）`null` です。alert は SpringBoard をスナップショットするので、止めたときにだけ探します。
- 一覧に対象がないときは、0.4 秒の間、0.05 秒ごとに読み直し、対象が一覧に戻ればそのまま送ります。ダイアログを閉じるタップの後、約 230 ms は SpringBoard だけが並ぶためで、閉じた直後のタップは止まりません。
- 判定しないもの: 対象が `com.apple.springboard` のとき（通知のバナーや音量 HUD は、アプリが前面のまま SpringBoard を指定して操作するため）、非公開 API が使えない（`source: fallback`）とき、座標を指定したタッチと `/swipe`（CLI の `swipe`。対象アプリがありません）。
- 止めるのは先頭が SpringBoard のときだけです。先頭がほかのアプリなら、対象が一覧になくても送ります。`SFSafariViewController` と `ASWebAuthenticationSession` の画面は別プロセスの `com.apple.SafariViewService` が描きますが、一覧にはそれを表示しているアプリだけが出ます。その要素は `--bundle-id com.apple.SafariViewService` でしか見えない（アプリの要素ツリーにも、`--bundle-id` なしにも出ない）ので、それを止めないためです。
- iPad のウィンドウ表示では、画面にあるアプリがすべて一覧に並びます（順序はフォーカスと一致しないことがありました）。そのため先頭でなくても、一覧にあれば送ります。対象のウィンドウが別のアプリに全面を覆われると一覧から外れますが、先頭はそのアプリなので、この一覧の判定では止めません。押す点は別に hit test で確認します（「[要素セレクタ](#要素セレクタ)」）。
- この一覧の判定では止めないもの: アプリ内のアラート、共有シート、写真の選択、キーボード、通知のバナー、音量 HUD（一覧はアプリだけ）。
- この一覧の判定では止めないもの: `SFSafariViewController`（全画面・`.pageSheet`）と `ASWebAuthenticationSession` の画面で、`--bundle-id com.apple.SafariViewService` を指定した Close・Reload などのタップ（一覧はアプリだけで、対象は一覧にない）。
- 止めるもの: 位置情報・通知の許可ダイアログ、コントロールセンター、通知センター、`ASWebAuthenticationSession` の「“…” Wants to Use “…” to Sign In」の確認ダイアログ（いずれも一覧は SpringBoard だけ）。
- バナーは前面アプリの一覧には出ません。押す点が別の要素に当たると確認できた場合は `element_point_covered` で止まります（「[要素セレクタ](#要素セレクタ)」）。
- ダイアログのボタンは、要素ツリーに出た直後にタップしても、`ok: true` のまま無視されることがあります。システムとアプリ内の両方で、シミュレータでは 0.2 秒後まで、実機では 0.2 秒未満に起きました。
- 写真の選択や共有シートの「More」の一覧も、出た直後に `--timeout` で待って押した Cancel・Done が無視されました。少し待ってから押すと効きました。
- 速さ: 一覧の読み取りは 1 回あたりシミュレータで 3–4 ms、実機で 7–9 ms です。止めないとき、要素指定のタップ（iPhone 17 Pro シミュレータの RelayRunnerHost に curl で 40 回）の中央値は、判定なしで 331.0 ms、判定ありで 330.9 ms と、差はばらつきに埋もれました。止めるときは読み直しと alert の探索のぶん、応答まで約 480 ms（シミュレータ）、約 670 ms（実機）かかります。

iPhone で、上の止めるもので止まり、止めないものとダイアログを閉じた直後で止まらないことを確かめました。通知センターと `.pageSheet` はシミュレータのみです。iPad のウィンドウ表示では一覧の中身だけを確かめています。

確かめた環境: iPhone 17 Pro シミュレータ（iOS 27）、iPhone 14 Pro（iOS 26.7.1）、iPad mini シミュレータ（iOS 26.5）。

### 待機（timeout）

- `timeout` を付けると、`/tap`・`/press` は要素が触れる状態（`notFound`・`indexOutOfRange`・`emptyFrame`・`offscreen`・`disabled` 以外）になるまで、`/find` は 1 件以上一致するまで待ちます。期限を過ぎると最後の結果を返します（`/tap` は `422`、`/find` は `count: 0`）。`ambiguous` は待っても解消しにくいので、待たずにすぐ `422` を返します。
- 待っている間もスナップショットの失敗（アプリがまだ起動していないなど）は再試行します。
- `bundleId` を省略したときの対象アプリは、リクエストの最初に前面アプリから 1 回だけ決まり、待っている間は判定し直しません。アプリが前面のときに `relay find --type alert --timeout 5` を送っても、待機中に出たシステムの許可ダイアログは見つかりません。これから出るダイアログは `relay find --type alert --bundle-id com.apple.springboard --timeout 5` で待ちます（「[システムの許可ダイアログ](#システムの許可ダイアログ)」）。`/tap`・`/press` も、待っている間にダイアログが出ると、ダイアログの後ろの要素を見つけてしまいます。ただし送る直前の確認（「[別のアプリに覆われているとき](#別のアプリに覆われているとき)」）で、何も送らずに `422` になります。
- 上限は 10 秒です。待っている間はコマンドが busy ゲートを持ち続けるので、ほかのリクエスト（`/health` を含む）は `409` になります（`/ping` は `busy: true` を返します）。長く待つ必要がある場合は、短い `timeout` で繰り返してください。
- `timeout` は「次のスナップショットを取るかどうか」の期限で、1 回のスナップショット自体は中断できません。
- 別プロセスのシート（設定の Apple Account のサインイン画面など）の表示中は、スナップショットが `Timed out while evaluating UI query` で失敗するまで約 3 分戻らないことがありました。`/source` も同じです。
- その間は busy ゲートを持ったままなので、ほかのリクエストは `409` になります。

シミュレータで、RelayRunnerHost を終了した状態から `{"element":{"identifier":"relay.input2"},"bundleId":"…RelayRunnerHost","timeout":5}` を送り、1.5 秒後に `simctl launch` で起動すると、約 3.8 秒で 200 が返って `relay.input2` にフォーカスが移りました。待機中の `/ping` は `{"busy":true,"busyForMs":719}`、`/health` は `409` でした。

確認した結果（シミュレータ iPhone 17 Pro）:

- RelayRunnerHost: `relay.input` / `relay.input2` を identifier 指定・`{"type":"textField","index":1}` でタップすると、`/source` の `hasKeyboardFocus` がその欄に移りました（`private`・`xcui`、`/press` も同じ）。
- 横向き（landscapeLeft / landscapeRight）でも、identifier 指定のタップでフォーカスが移りました（`point` は 874×402 の座標で `{"x":437,"y":87}` など）。
- 設定: `{"label":"General","type":"button"}` → `{"label":"About","type":"button"}` と順にタップして「情報」画面に移りました。

### システムの許可ダイアログ

マップの位置情報・通知の許可ダイアログの表示中は、前面アプリが SpringBoard になります。以下は relay 0.6.0 での確認結果です。

表示中の `relay foreground` は `com.apple.springboard`（`source: private`）を返します。

`--bundle-id` なしの `relay find --type alert` で見つかり、`label` に質問文（例: `Allow “Maps” to use your location?`）が入ります。

`relay source --format compact --filter interactive` はダイアログのボタンだけを返します。

```sh
relay find --type alert --bundle-id com.apple.springboard --timeout 5
relay source --format compact --filter interactive
relay tap --label "Allow While Using App"
```

最初のコマンドはこれから出るダイアログを待つ場合にも使えます。一致したことと質問文を確かめ、`source` で得たラベルからボタンを選びます。上のタップは約 0.5 秒で成功し、前面アプリは元のアプリに戻りました。

ダイアログが出ている間は、後ろのアプリを `--bundle-id com.apple.Maps` などで指定しないでください。`find`・`source --filter interactive` には後ろのアプリの要素が出ます。

それを `tap` すると、以前は `ok: true`・終了コード 0 のまま何も起きないか、同じ位置にあるダイアログのボタンが押されていました。

今は `tap`・`press` とも、何も送らずに `422`（`covered_by_other_app`、終了コード 6）で、応答の `alert` にダイアログの質問文が入ります（「[別のアプリに覆われているとき](#別のアプリに覆われているとき)」）。

確かめた環境: iPhone 17 Pro シミュレータ（iOS 27.2）。
