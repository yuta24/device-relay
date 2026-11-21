# 要素ツリーと要素セレクタ

`/source` の要素ツリーと、`/tap`・`/press`・`/pinch`・`/find`・`/adjust` の要素セレクタ、要素の待機について説明します。全体の入口は [README](../README.ja.md) です。

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
- 後に続くコントロールの frame がタップ位置を覆うときは、アクセシビリティの hit test で、別のコントロールに当たると確認できたものだけを外します。ラベルの大きな枠と重なる入力欄やボタン、hit test で確認できないものは残します。
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

`/tap` と `/press` は、`x`・`y` の代わりに `element` で要素を指定できます。`/find` は同じセレクタで一致した要素の一覧を返します。`/adjust` も同じセレクタでスライダーやピッカーのホイールを選びます（「[スライダーとピッカー（/adjust）](http-api.md#スライダーとピッカーadjust)」）。

`/pinch` も同じセレクタ・待機・frame変換・覆いの確認を使います。中心はframeの画面内の部分の中心で、`center` に返します。中心のhit testは2本の指全体の到達を保証しません。半径・modeの制約は[ピンチ](http-api.md#ピンチpinch)を参照してください。

```json
{"element":{"identifier":"relay.input"}}
{"element":{"label":"History","type":"button"}}
{"element":{"type":"textField","index":1},"bundleId":"com.example.app","timeout":3}
{"element":{"labelMatch":"^Remaining \\d+:\\d{2}$","type":"button"}}
```

| キー | 内容 |
| --- | --- |
| `element.identifier` / `element.label` / `element.value` | `/source` の同名の値との完全一致（大文字小文字も区別） |
| `element.type` | `/source` の `type` と同じケース名（`button`、`textField`、`cell` など）。知らない名前は `400` |
| `element.labelMatch` / `element.valueMatch` | label / value のどこかに一致する正規表現（「[正規表現で探す（labelMatch / valueMatch）](#正規表現で探すlabelmatch--valuematch)」）。正しくない式は `400` |
| `element.index` | 一致した要素のうち何番目を使うか（0 から。順序は `/source` の JSON と同じ文書順＝親が先の深さ優先）。`onscreen`・`hittable` を付けたときは、残った要素の中で数えます |
| `element.onscreen` / `element.hittable` | `true` で、画面の中にある要素だけ / 中心を押すとその要素に当たる要素だけを残します（「[画面の中・押せる要素だけに絞る（onscreen / hittable）](#画面の中押せる要素だけに絞るonscreen--hittable)」）。真偽値以外は `400` |
| `bundleId` | 対象アプリ。省略時は前面アプリ（`/source` と同じ） |
| `timeout` | 要素が現れるまで待つ秒数（0–10、既定 0 = 1 回だけ探す）。0.25 秒ごとにスナップショットを取り直します |
| `limit`（`/find` のみ） | 返す要素の上限（1–100、既定 20）。`count` は常に一致した総数で、上限で切った場合は `truncated: true` |
| `gone`（`/find` のみ） | `true` で、一致する要素がなくなるまで `timeout` の間待ちます（「[消えるのを待つ（gone）](#消えるのを待つgone)」）。`index` とは組み合わせられません |

- 条件（`identifier`・`label`・`type`・`value`・`labelMatch`・`valueMatch`）は AND で組み合わせ、少なくとも 1 つ必要です（`onscreen`・`hittable` だけでは足りません）。空文字列・文字列以外・未知のキー（`id` など）は `400` です。打ち間違いで条件が黙って消え、意図より広く一致するのを防ぐためです。
- `identifier`・`label`・`value` は完全一致です。変わるラベルや一部だけわかるラベルは、`labelMatch`・`valueMatch` の正規表現で探します（「[正規表現で探す](#正規表現で探すlabelmatch--valuematch)」）。`identifier` には正規表現はありません。
- ラベルは `/find`・`/source` の値をそのままコピーしてください。システムの許可ダイアログの `Don’t Allow` はアポストロフィが `’`（U+2019）で、ASCII の `'` を使った `relay tap --label "Don't Allow"` は一致しません。
- 解決には `/source` と同じ `snapshot()` を使い、frame は表示の向きのポイント（`/tap` と同じ座標系）なので、横向きでもそのまま使えます。タップ位置は「frame と画面の重なる部分」の中心です（画面端で一部が切れたセルも、見えている部分の中心を押します）。iPad のウィンドウでは、frame を画面の座標に変換したうえで、見えているウィンドウとの重なりの中心を押します。タッチは座標指定と同じ経路（`private`、だめなら `xcui`。`mode` も同じ）で送ります。
- `x`・`y` と `element` を両方指定すると `400` です。
- 要素指定のタッチは、送信前に中心の hit test を行います。同じスナップショット内で、選んだ要素でも、その祖先・子孫でもないコントロールに当たると確認できた場合だけ、何も送らず `422`、`element_point_covered`（`reason: pointCovered`）を返します。
- hit test の API がない、nil・エラーが返る、返された要素が取得済みのツリーにない場合は、従来どおり送ります。座標指定のタッチにはこの確認を行いません。
- hit test がタッチ点を含まない frame の要素を返した場合も、確認できないものとして従来どおり送ります。
- iPad のウィンドウ表示と画面が複数ある端末では、hit test の座標を確かめていないため、この確認を省きます。`--filter interactive` では、hit test を加える前と同じく、後のコントロールの frame に中心が入る候補を frame だけで外します。
- 拒否の対象は、ボタン・スイッチ・入力欄など、上の一覧で操作対象として挙げた型のコントロールです。`staticText`・`other`・`image`・`group` などの内容に当たる場合は送ります。ラベルの文字が、選んだチェックボックスやラジオへのクリックを受けることがあるためです。
- `pointCovered` の応答には、当たる要素の要約が `hit`（`type`・`label`・画面上の `frame`）に入ります。覆いを閉じるか、スクリーンショットで対象の位置を確かめて座標を指定してください。
- 隠れた要素を外す `/source?filter=interactive` の近似判定は「[操作できる要素だけに絞る](#操作できる要素だけに絞るfilterinteractive)」を、セレクタで見える要素・押せる要素だけを選ぶ方法は「[画面の中・押せる要素だけに絞る](#画面の中押せる要素だけに絞るonscreen--hittable)」を参照してください。
- `/launch` の直後は、前面アプリの取得が切り替え前のアプリを返すことがあります。確実に対象を決めたい場合は `bundleId` を指定してください。

応答（`/tap`）には、実際に使った要素とタップ座標が入ります:

```json
{"bundleId":"dev.devicerelay.local.RelayRunnerHost","element":{"enabled":true,
 "frame":{"height":34,"width":370,"x":16,"y":132},"identifier":"relay.input2","index":0,"label":"",
 "onscreen":true,"type":"textField","value":null},"mode":"private","ok":true,"point":{"x":201,"y":149}}
```

iPad のウィンドウでは、応答（`/tap`・`/press`・`/find`・`/source` の JSON）に `window` が付きます。frame と `point` は変換した後の画面の座標です。

```json
{"bundleId":"dev.devicerelay.local.RelayRunnerHost","element":{"enabled":true,
 "frame":{"height":34,"width":343,"x":395,"y":152},"identifier":"relay.input2","index":0,"label":"",
 "onscreen":true,"type":"textField","value":null},"mode":"private","ok":true,"point":{"x":566.5,"y":169},
 "window":{"height":486,"scale":1,"width":375,"x":379,"y":72}}
```

ウィンドウの位置が決まらないときは、`/tap`・`/press`・`/adjust` は何も送らずに `422`、`window_position_unknown` です。`/find`・`/source` は成功のままで、`window: null` と `warning` が付き、frame はウィンドウの中の座標です（「[iPad のウィンドウ表示](screen.md#ipad-のウィンドウ表示)」）。このとき `/find` の要素には `onscreen` を付けず、`onscreen`・`hittable` を付けた `/find` は `timeout` の間待ってから `422`、`window_position_unknown` です。

要素が 1 つに決まらない・触れない場合は `422` で、`code`、`reason`、一致した総数 `count`、候補（最大 5 件）`candidates` を返します。`code`（「[エラーの形式と code](http-api.md#エラーの形式と-code)」）は次の行動ごとに `reason` をまとめたもので、`reason` はその詳細です。

| `reason` | `code` | 条件 | `candidates` |
| --- | --- | --- | --- |
| `notFound` | `element_not_found` | 一致なし | 空 |
| `ambiguous` | `element_ambiguous` | 2 件以上一致して `index` がない | 一致した要素（先頭 5 件） |
| `indexOutOfRange` | `element_not_found` | `index` が一致件数以上 | 一致した要素（先頭 5 件） |
| `emptyFrame` | `element_not_hittable` | 選んだ要素の frame の幅か高さが 0 | 選んだ要素 |
| `offscreen` | `element_not_hittable` | 選んだ要素の frame が画面（iPad のウィンドウでは、見えているウィンドウ）と重ならない | 選んだ要素 |
| `pointCovered` | `element_point_covered` | 押す点が別のコントロールに当たると確認できたため、何も送らなかった | 選んだ要素 |
| `disabled` | `element_not_hittable` | 選んだ要素が `enabled: false` | 選んだ要素 |
| `positionUnknown` | `remote_view_position_unknown` | 選んだ要素が共有シートの中にあり、画面上の位置が決まらない（「[共有シートの中の要素](#共有シートの中の要素)」）。何も送っていない | 選んだ要素 |

```json
{"candidates":[{"enabled":true,"frame":{"height":52,"width":370,"x":16,"y":380.333},
  "identifier":"com.apple.settings.general","index":0,"label":"General","onscreen":true,"type":"button","value":null},
 {"enabled":true,"frame":{"height":29,"width":101.667,"x":29.667,"y":392},"identifier":"","index":1,
  "label":"General","onscreen":true,"type":"staticText","value":null}],
 "code":"element_ambiguous","count":2,"error":"2 elements match the selector; add conditions or an index","ok":false,
 "reason":"ambiguous"}
```

（設定アプリのトップでは「一般」のセルが `button` と、その中の `staticText` の 2 つとして見えるので、`{"label":"General","type":"button"}` のように型も指定します。）

`/find` の例（`{"element":{"type":"textField"}}`、シミュレータの RelayRunnerHost）:

```json
{"bundleId":"dev.devicerelay.local.RelayRunnerHost","count":2,"elements":[
 {"enabled":true,"frame":{"height":34,"width":370,"x":16,"y":86},"identifier":"relay.input","index":0,"label":"","onscreen":true,"type":"textField","value":null},
 {"enabled":true,"frame":{"height":34,"width":370,"x":16,"y":132},"identifier":"relay.input2","index":1,"label":"","onscreen":true,"type":"textField","value":null}],
 "ok":true,"truncated":false}
```

`/find` は一致がなくても `200`（`count: 0`）です。`elements[].index` はそのまま `/tap` の `index` に使えます（`onscreen`・`hittable` を付けたときは、同じものを付けた `/tap` の `index` です）。`/find` に `index` を付けると、その 1 件だけ（範囲外なら空）を返します（`count` は一致した総数のままです）。

要素（`/find` の `elements`、`/tap`・`/press` の `element`、失敗の `candidates`）の `onscreen` は、frame の一部が画面の中にあるかどうか（`true` / `false`）です。判定は下の `onscreen` と同じです。キーが増えただけなので、以前のスクリプトはそのまま読めます。`onscreen` のない応答は、それを知らない古いランナーのものか、位置の決まらない iPad のウィンドウです。

### 画面の中・押せる要素だけに絞る（onscreen / hittable）

`/find` は、見えているかどうかに関係なく、ツリー全体から文書順に一致を返します。モーダルのプレイヤーの下に残った画面の要素や、ページ式の画面の外のページの要素も一致します。`element` に次のどちらかを付けると、一致した要素から残すものを絞ります。CLI では `--onscreen` / `--hittable` です。

```sh
relay find --type staticText --hittable          # プレイヤーの下に隠れた画面の文字を外す
relay find --label "Page title" --onscreen       # 画面の外のページを外す
relay tap --label Play --type button --hittable  # 見えているほうの Play を押す
```

| キー | 残す要素 | 判定 |
| --- | --- | --- |
| `onscreen: true` | 画面の中にある要素 | frame の幅と高さが 0 でなく、frame（iPad のウィンドウでは見えているウィンドウ）と画面の重なりがある。タップが押す点がある、ということで、`offscreen`・`emptyFrame` にならないのと同じです |
| `hittable: true` | 画面の中にあり、押すと当たる要素 | `onscreen` に加えて、押す点（重なりの中心）の hit test が、その要素か子孫、またはその要素を含むコントロール（文字を含むセルやボタン）を返す |

- **順序と番号**: 並び順は変えません。絞り込みは一致した要素に、`index`・`limit`・待機（`timeout`・`gone`）の判定より前にかけます。`count`・`truncated`・`index` は残った要素で数えます。`relay find --label Play --hittable` の `index` 1 は、`relay tap --label Play --hittable --index 1` で押す要素です。
- **対象**: `/find`・`/tap`・`/press`・`/pinch`・`/adjust` のセレクタ全体です。`/tap` で 2 つ一致して `ambiguous` になる場面でも、`hittable` で手前の 1 つだけが残れば押せます。
- **`gone` と組み合わせたとき**: 「残る要素がなくなるまで待つ」になります。`onscreen` なら画面から外れるまで、`hittable` なら画面から外れるか、何かに覆われるまでです。ツリーから消えるまでではありません。
- **両方を付けたとき**: `hittable` は画面の中にあることも含むので、`hittable` と同じです。`false` は付けないのと同じです。
- **`enabled: false` の要素**: 外しません（押しても反応しない要素でも、見えていて当たれば残ります）。`/tap` は、これまでどおり `disabled` で止まります。
- **位置の決まらない要素**: 共有シートの中で位置が決まらない要素（`positionUnknown`）は、`onscreen: false` で、どちらでも外れます。
- **`onscreen` で残るもの**: 画面との重なりだけを見ます。画面より小さいスクロールビューの外にスクロールした行でも、frame が画面の中にあれば残ります。ほかの要素に覆われているかも見ません。そうした要素を外すには `hittable` を使います。
- **`hittable` で残るもの**: 判定は対象アプリの要素ツリーの中だけで行います。システムの許可ダイアログなど、別のプロセスの画面に覆われた要素は残ることがあります（確かめていません）。その要素へのタッチは、送る前の確認（「[別のアプリに覆われているとき](#別のアプリに覆われているとき)」）で止まります。
- **古いランナー**: `onscreen`・`hittable` を知らないランナーは、`element` の未知のキーとして `400` で拒否します（黙って無視はしません）。relay はこれを `runner_bad_response`（終了コード 8）にして、`relay start --rebuild` を案内します。

`hittable` の判定には、要素のタッチで使う hit test（「[要素セレクタ](#要素セレクタ)」の `element_point_covered`）と同じ API を使います。ただし向きが逆です。タッチの確認は「別のコントロールに当たったとわかったときだけ止める」もので、わからなければ送ります。`hittable` は「その要素に当たったとわかったときだけ残す」もので、次の場合は外します。

- hit test がその点で答えを返さない（エラー、ツリーにない要素を返す）。
- 別の枝の要素に当たる。プレイヤーの下の要素は、プレイヤーの入れ物（`other`）に当たりました。
- コントロールでない祖先（ウィンドウ、入れ物の `other`）に当たる。下の画面とプレイヤーを両方含む祖先に当たっても、下の要素が押せるとはいえないためです。

hit test そのものが使えないときは、要素を残しも外しもせず、`hittable` を付けたリクエストを `422`、`hit_test_unavailable` で返します（何も送りません）。残すと覆われた要素を押し、外すと `gone: true` や `element_not_found` を誤って返すためです。`onscreen` は hit test を使わないので、そのまま使えます。

| hit test が使えないとき | 理由 |
| --- | --- |
| iPad のウィンドウ表示（ウィンドウが画面の一部にある） | hit test の座標を確かめていない（タッチの確認も省いています） |
| 表示が複数ある端末（iPhone Duo） | 同上 |
| `RELAY_DISABLE_PRIVATE_HITTEST=1`、または非公開 API がない | hit test の結果がない |

hit test は、画面の中にある一致した要素だけに、1 件ずつかけます。`timeout` で待つ間は、スナップショットを取り直すたびにかけ直します。点は、ほかの hit test と同じく縦向きの座標に直してから渡します（「[要素のタッチ位置の確認](private-api.md#要素のタッチ位置の確認)」）。横向きで表示の向きの点のまま渡すと、どの要素にも当たらず、すべて外れました。

#### 確かめた結果

Xcode 27.2、iPhone 18 Pro シミュレータ（iOS 27.2）の RelayRunnerHost の `relay.visibility` の画面（「[検証用のホストアプリ](development.md#検証用のホストアプリ)」）で確かめました。プレイヤーは、子のビューコントローラとして画面の上に重ねたものです。

| 場面 | コマンド | 結果 |
| --- | --- | --- |
| プレイヤーの下の文字 | `find --type staticText --label "Now playing"` | 2 件（手前とプレイヤーの下）。どちらも `onscreen: true` |
| 同上 | 上に `--hittable` | 1 件（手前の `relay.player.nowPlaying`） |
| 同じラベルのボタン | `tap --label Play --type button` | `422`、`element_ambiguous`（2 件） |
| 同上 | 上に `--hittable` | 手前の `relay.player.play` を押した |
| 下の画面のボタンを待つ | `find --id relay.play --hittable --gone --timeout 2` | すぐ `gone: true`（ツリーには残っている） |
| `--index` と `--limit` | `find --label Play --hittable --index 1` / `--limit 1` | `count: 2` のうち `index` 1（手前のボタンの中の文字）/ 先頭 1 件と `truncated: true` |
| 画面の外のページ | `find --label "Page title"` | 3 件。`onscreen` は `true`・`false`・`false` |
| 同上 | 上に `--onscreen` | 1 件。横にスワイプした後は 2 ページ目の 1 件 |
| 見えているページのボタン | `tap --label Select --type button --onscreen` | 見えているページのボタンを押した。2 ページ目でも同じ |
| hit test を無効にしたランナー | `find --label Play --hittable` | `422`、`hit_test_unavailable`（終了コード 6）。`--onscreen` は使えた |
| 横向き（`landscapeLeft`・`landscapeRight`） | プレイヤーありの `find --label Play --hittable`、なしの `find --label Item --hittable` | 縦向きと同じく手前の 2 件 / 画面の中の 70 件すべて（プレイヤーありは 0 件） |
| 設定アプリのトップ | `find --type cell --hittable` | 11 件のうち 10 件。外れた 1 件は、画面下の検索欄の下にある（`--filter interactive` でも外れる） |

`--hittable` にかかる時間です（100 件の文字が一致する画面、5 回の中央値、CLI の往復を含む）。

| 条件 | 絞り込みなし | `--onscreen` | `--hittable` |
| --- | ---: | ---: | ---: |
| プレイヤーなし（100 件残る） | 54 ms | 55 ms | 120 ms |
| プレイヤーあり（0 件残る） | 58 ms | – | 99 ms |

hit test は 1 件あたり約 0.5 ms でした。実機と iPad では確かめていません。

確かめた範囲（iOS 27.2 シミュレータ）では、`.overFullScreen` で表示したモーダル（`relay.presentPlayer`）は下の画面がツリーから外れ、絞り込まなくても手前の要素だけが一致しました。下の要素が並んだのは、ビューを重ねて表示した画面です。ほかの表示のしかたや iOS の版では確かめていません。

Safari の同じボタンを各 5 回押した CLI 応答の平均です。

| 環境 | hit test 追加前 | 追加後 |
| --- | ---: | ---: |
| シミュレータ | 374.0 ms | 382.8 ms |
| 実機 | 未計測 | 566.5 ms |

確かめた環境: Xcode 27.2、iPhone 17 Pro シミュレータ（iOS 27.0）の Safari・WKWebView・設定、iPhone 14 Pro 実機（iOS 26.7.1）の Safari・設定。iPad の hit test は確かめていません。

### 正規表現で探す（labelMatch / valueMatch）

`labelMatch` と `valueMatch` は、label と value を正規表現で探します。数字や時刻が入って変わるラベル（`Remaining 3:42`、`12 items`）、一部だけわかる長いラベル、大文字と小文字だけが違うラベルを選べます。CLI では `--label-match <regex>` と `--value-match <regex>` です。

```sh
relay tap --label-match '^Remaining \d+:\d{2}$' --type button   # 変わる時刻
relay find --label-match 'items$' --onscreen                      # 終わりだけわかる
relay tap --label-match '(?i)^play$' --type button --hittable     # 大文字と小文字を区別しない
relay find --type textField --value-match '^$'                    # 値が空の入力欄
```

- **一致のしかた**: 文字列のどこかに一致すれば一致です（部分一致）。全体と一致させるときは `^` と `$` を書きます。
- **方言**: `NSRegularExpression`（ICU）を、オプションなしで使います。CLI とランナーは同じコードで式を作ります。
- **オプション**: 式の中に書きます。`(?i)` で大文字と小文字を区別しません。`(?s)` で `.` が改行にも一致し、`(?m)` で `^`・`$` が各行の始めと終わりに一致します。そのための印（`--ignore-case` など）はありません。
- **改行を含むラベル**: オプションなしでは、`.` は改行に一致せず、`^`・`$` はラベル全体の始めと終わりにだけ一致します。`$` は、末尾の改行 1 つの前にも一致します。
- **値のない要素**: value が `null` の要素は、空文字列として扱います（`--format compact` と同じ）。`--value-match '^$'` で、値が空か `null` の要素を選べます。label はもともと文字列で、ないときは空文字列です。
- **組み合わせ**: ほかの条件・`index`・`onscreen`・`hittable`・`limit`・`gone` とは、完全一致の条件と同じに組み合わせます。`/find`・`/tap`・`/press`・`/pinch`・`/adjust` と、`relay run` の手順で使えます。
- **同じ属性の完全一致と同時に**: `label` と `labelMatch`（`value` と `valueMatch`）を両方付けると `400` です（CLI は終了コード 2）。`--label` を残したまま `--label-match` を足した、という間違いを黙って AND にしないためです。完全一致は `^...$` で書けます。
- **正しくない式**: CLI はランナーに送る前に確かめ、終了コード 2 にします（`--label-match: not a valid regular expression …`）。ランナーも確かめて `400`、`invalid_request` を返します。空文字列も `400` です。
- **長さと時間の上限**: 式は 1000 文字までです。スナップショットごとに、ツリーのすべての label・value に式をかけて 1 秒を超えたら、待たずに `400`、`invalid_request` です（CLI は終了コード 7）。`(a+)+$` のように後戻りが限りなく増える式で、ランナーが止まらないようにするためです。
- **失敗の応答**: `element_not_found`・`element_ambiguous` などの応答と `candidates` は、完全一致のときと同じです。候補の `label`・`value` を見て、式を締めるか `--type`・`--index` を足してください。
- **古いランナー**: `labelMatch`・`valueMatch` を知らないランナーは、未知のキーとして `400` で拒否します（黙って無視はしません）。relay はこれを `runner_bad_response`（終了コード 8）にして、`relay start --rebuild` を案内します。

#### 確かめた結果

Xcode 27.2、iPhone 18 Pro シミュレータ（iOS 27.2）の RelayRunnerHost で確かめました。`relay.countdown` は、ラベルが 1 秒ごとに減るボタンです（「[検証用のホストアプリ](development.md#検証用のホストアプリ)」）。

| 場面 | コマンド | 結果 |
| --- | --- | --- |
| 変わる時刻 | `tap --label-match '^Remaining \d+:\d{2}$'` | `element_ambiguous`（ボタンとその中の文字の 2 件）。終了コード 6 |
| 同上 | 上に `--type button` | `Remaining …` のボタンを押した。value は `taps: 1` になった |
| 部分一致 | `find --label-match Remain --type button` | 1 件（`relay.countdown`） |
| 全体一致 | `find --label-match '^Remain$'` | 0 件 |
| 大文字と小文字 | `find --label-match '^play$'` / `'(?i)^PLAY$'` | 0 件 / 2 件（`Play` のボタンとその中の文字） |
| `--hittable` | プレイヤーありの `tap --label-match '(?i)^play$' --type button --hittable` | 手前の `relay.player.play` を押した。`--hittable` なしでは 4 件が一致 |
| 同上 | プレイヤーありの `tap --label-match '^Remaining' --type button --hittable` | `element_not_found`（プレイヤーの下）。`--onscreen` では 1 件 |
| `--onscreen` と `--index` | `find --label-match '^Page' --onscreen` / `--index 2` | 1 件（1 ページ目）/ `count: 3` のうち 3 ページ目 |
| `--gone` | `relay.showToast` の後に `find --label-match '(?i)^TOAST$' --gone --timeout 5 --require` | `gone: true`。終了コード 0 |
| 値が空 | 入力欄の画面で `find --type textField --value-match '^$'` | 空の `relay.input`・`relay.input2` の 2 件 |
| 正しくない式 | `find --label-match '('` | 終了コード 2。ランナーには送らない |
| 同上（HTTP で直接） | `/find` に `{"labelMatch":"("}`・`label` と `labelMatch` の両方・1001 文字の式 | どれも `400`、`invalid_request` |
| 後戻りの多い式 | `relay.notes` に `a` 40 文字と `b` を入れて `find --value-match '(a+)+$'` | 約 1.1 秒で `400`、`invalid_request`（終了コード 7）。その後もランナーは応答した |
| `relay run` | 上の `tap`・`find --gone` を手順にしたもの | 5 手順すべて成功 |
| 古いランナー | – | 確かめていません（単体テストで、拒否の応答を偽の通信に返させて確かめた） |

要素の多い画面（`relay.visibility` の `Item` 100 件が一致する画面）でかかる時間です。10 回の中央値で、CLI の往復を含みます。

| 条件 | 絞り込みなし | `--hittable` |
| --- | ---: | ---: |
| `--label Item`（完全一致） | 58 ms | 131 ms |
| `--label-match '^Item$'` | 61 ms | 133 ms |
| `--label-match '(?i)item'` | 61 ms | – |

正規表現による差は、測った範囲ではばらつきの中でした。実機と iPad では確かめていません。

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

要素を指定した `/tap`・`/press` と `/adjust` は、タッチを送る（値を設定する）直前に前面アプリの一覧（「[前面アプリ](http-api.md#前面アプリ)」の `private`）を読み直します。対象アプリ（`bundleId`。省略したときはリクエストの最初に決めた前面アプリ）が一覧になく、一覧の先頭が SpringBoard なら、何も送らずに `422`、`covered_by_other_app` を返します。システムの許可ダイアログ・コントロールセンター・通知センターは SpringBoard が描くので、表示中の一覧は SpringBoard だけになります。一方、アプリのスナップショットには後ろの要素が frame つきで残るので、以前はその座標にタッチを送り、`ok: true` のまま何も起きないか、同じ位置にあるダイアログのボタン（「Allow While Using App」「Don’t Allow」など）を押していました。

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
- iPad のウィンドウ表示では、画面にあるアプリがすべて一覧に並びます（順序はフォーカスと一致しないことがありました）。そのため先頭でなくても、一覧にあれば送ります。対象のウィンドウが別のアプリに全面を覆われると一覧から外れますが、先頭はそのアプリなので、この一覧の判定では止めません。
- iPad のウィンドウ表示では押す点の hit test も省くため、別のウィンドウに覆われた点へのタッチを止められません（「[要素セレクタ](#要素セレクタ)」）。
- この一覧の判定では止めないもの: アプリ内のアラート、共有シート、写真の選択、キーボード、通知のバナー、音量 HUD（一覧はアプリだけ）。
- この一覧の判定では止めないもの: `SFSafariViewController`（全画面・`.pageSheet`）と `ASWebAuthenticationSession` の画面で、`--bundle-id com.apple.SafariViewService` を指定した Close・Reload などのタップ（一覧はアプリだけで、対象は一覧にない）。
- 止めるもの: 位置情報・通知の許可ダイアログ、コントロールセンター、通知センター、`ASWebAuthenticationSession` の「“…” Wants to Use “…” to Sign In」の確認ダイアログ（いずれも一覧は SpringBoard だけ）。
- バナーは前面アプリの一覧には出ません。押す点が別のコントロールに当たると確認できた場合は `element_point_covered` で止まります（「[要素セレクタ](#要素セレクタ)」）。
- ダイアログのボタンは、要素ツリーに出た直後にタップしても、`ok: true` のまま無視されることがあります。システムとアプリ内の両方で、シミュレータでは 0.2 秒後まで、実機では 0.2 秒未満に起きました。
- 写真の選択や共有シートの「More」の一覧も、出た直後に `--timeout` で待って押した Cancel・Done が無視されました。少し待ってから押すと効きました。
- 速さ: 一覧の読み取りは 1 回あたりシミュレータで 3–4 ms、実機で 7–9 ms です。止めないとき、要素指定のタップ（iPhone 17 Pro シミュレータの RelayRunnerHost に curl で 40 回）の中央値は、判定なしで 331.0 ms、判定ありで 330.9 ms と、差はばらつきに埋もれました。止めるときは読み直しと alert の探索のぶん、応答まで約 480 ms（シミュレータ）、約 670 ms（実機）かかります。

iPhone で、上の止めるもので止まり、止めないものとダイアログを閉じた直後で止まらないことを確かめました。通知センターと `.pageSheet` はシミュレータのみです。iPad のウィンドウ表示では一覧の中身だけを確かめています。

確かめた環境: iPhone 17 Pro シミュレータ（iOS 27）、iPhone 14 Pro（iOS 26.7.1）、iPad mini シミュレータ（iOS 26.5）。

### 待機（timeout）

- `timeout` を付けると、`/tap`・`/press`・`/adjust` は要素が触れる状態（`notFound`・`indexOutOfRange`・`emptyFrame`・`offscreen`・`disabled` 以外）になるまで、`/find` は 1 件以上一致するまで待ちます。期限を過ぎると最後の結果を返します（`/tap` は `422`、`/find` は `count: 0`）。`ambiguous` は待っても解消しにくいので、待たずにすぐ `422` を返します。
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

### 見えるまでスクロール（scroll）

`find`・`tap`・`press`・`adjust` のセレクタに `--scroll <方向>` を付けると、ランナー内で「探す → スワイプ → 探す」を繰り返します。まだ作られていない一覧のセルも、スクロールで現れれば見つけられます。CLI とランナーの間は 1 要求です。`relay run` の手順でも同じ書き方を使えます。

```sh
relay tap --id relay.scroll.row42 --scroll down
relay tap --id relay.scroll.row3 --scroll up
relay tap --id relay.scroll.tile15 --scroll right --in relay.scroll.horizontal --timeout 40 --max-swipes 20
relay find --label Item42 --type cell --scroll down --max-swipes 20 --timeout 40 --require
```

- **方向**: コンテンツのどちらを探すかを `up` / `down` / `left` / `right` で指定します。指が動く向きは逆です。CLI では方向が必須、HTTP では省略時に `down` です。
- **見つかった条件**: 要素の全体が入れ物の見えている矩形に収まったときだけ見つかったとみなします。一部だけ見えている要素は、`find` でもスワイプ 0 回の時点でも見つかったとはみなさず、探索を続けます。そのうえで、`find` は画面内（`onscreen`）、`--hittable` を付けた場合は到達可能な要素です。`tap`・`press`・`adjust` は常に `hittable` と同じ判定を使い、`--onscreen` との併用は CLI では終了コード 2、HTTP では 400 で断ります。判定できない環境（非公開 API がない、配置された iPad ウィンドウ、表示が複数など）では `hit_test_unavailable` で止まり、`onscreen` への暗黙の切り替えはしません。
- **端に少し見える要素**: 要素全体が入れ物の見えている矩形に収まるまで、最後の移動量を小さく補正します。行き過ぎたときは逆向きにも補正します。入れ物より大きい要素は、全体が収まらないため見つかったとはみなしません。
- **入れ物**: 画面内で有効な `scrollView`・`table`・`collectionView`・`textView` のうち、見えている面積が最大のもの（同面積ならツリー順の先頭）を使います。入れ物を明示しなければ、すでに条件を満たす要素は画面全体から探し、入れ物の外でもスワイプ 0 回で成功します。画面外のセルの子が表示中の座標を返す場合に備え、親のセル・入れ物のクリップも考慮します。
- **明示する入れ物**: CLI の `--in <identifier>` は入れ物の accessibilityIdentifier を指定します。対象の要素もその入れ物の中だけで探します。複数一致は `element_ambiguous`、入れ物が見つからなければ `element_not_found` です。HTTP の `scroll.in` は属性セレクタのオブジェクトです（`index`・`onscreen`・`hittable` は指定できません）。
- **スワイプ**: 入れ物と画面・親のスクロール領域の重なりから、キーボード・ナビゲーションバー・タブバー・ツールバー・ステータスバーを避ける矩形を選びます。通常は長さの 65% を 0.5 秒で動かし、終点で 0.15 秒止めてから離します。移動の最後の 10% は速度を落とし、離した後に最大 0.2 秒待ちます。その入れ物の表示内容が 0.1 秒間隔で 2 回続けて変わらなくなるまで、探索の期限内で最大 2 秒確かめます。長いアイドル待ちを避けるため、非公開のタッチ合成が使えない環境や `--mode xcui` は断ります。
- **回数と時間**: `--max-swipes` は既定 10、1–30 回。`--scroll` がある場合の `--timeout` は探索全体の時間で、既定 20 秒、0–60 秒です（`0` は初回の確認だけ）。通常の、スクロールしない `--timeout`（0–10 秒）とは異なります。探索が終わった後に、別の待機はしません。CLI は探索の期限をまたぐ最後の合成タッチの猶予と、press / adjust の処理時間を加え、その上で 30 秒待ちます。
- **停止条件**: 見つかった、回数上限、時間切れ、または 2 回続けてスワイプ後の表示内容が変わらない場合です。最後は端とみなしますが、端の検出は要素の属性と矩形の比較なので、同じ表示が続く一覧では上限も使ってください。スクロール中に選択の順序が変わるため、`--index` と `--gone` は併用できません。
- **応答**: `swipes` は試みたスワイプ数（失敗した合成を含む）、`scrollStop` は `found` / `edge` / `maxSwipes` / `timeout` / `failed` です。`found` は探索成功の印で、その後の tap / adjust 自体の成功は `ok` で確かめます。探索の上限や端まで行っても見つからない場合は、`find` の `--require` の有無によらず `422`、`element_not_found`（CLI の終了コード 6）です。
- **古いランナー**: `scroll` を無視して応答に `swipes` がない、または未知の `scroll` として断るランナーは `runner_bad_response`（終了コード 8）になります。`relay start --rebuild` で作り直してください。古いランナーがスクロールを無視した操作を既に行っている場合があるので、画面を確認してから送り直してください。

#### スクロール探索を確かめた結果

iPhone 14 Pro 実機（iOS 26.7.3、Xcode 27.2、2026-11-16）の RelayRunnerHost で、下の順に各 1 回確認しました。縦は100行の UITableView、横は40タイルの UICollectionView です。時間は CLI の起動から戻るまでで、直前の場面の位置を引き継いでいます。横方向は `--timeout 40 --max-swipes 20`、ない要素の探索は `--timeout 60 --max-swipes 30`、それ以外は表の指定以外は既定値です。

| 場面 | 結果 | swipes | 時間 |
| --- | --- | ---: | ---: |
| 下端に一部だけ見える Row 13 を tap | 成功 | 2 | 5884 ms |
| 下の Row 42 を tap（down） | 成功 | 5 | 13838 ms |
| Row 3 へ戻って tap（up） | 成功 | 4 | 11215 ms |
| 横の Tile 15 を tap（right、`--in`） | 成功 | 10 | 26746 ms |
| 横の Tile 2 へ戻って tap（left、`--in`） | 成功 | 7 | 18836 ms |
| 表示済みの Row 3 を tap（`--in`） | 成功 | 0 | 603 ms |
| 画面外の Row 42 の子ラベルを find | 成功 | 4 | 10866 ms |
| Row 50 を press（`--duration 0.1`） | 成功 | 2 | 5996 ms |
| ない要素を下の端まで find（Row 50 付近から） | 終了コード 6、`element_not_found`、`edge` | 10 | 27952 ms |
| Row 1 を上へ探す（`--max-swipes 1`） | 終了コード 6、`element_not_found`、`maxSwipes` | 1 | 2998 ms |
| Row 1 を上へ探す（`--timeout 0`） | 終了コード 6、`element_not_found`、`timeout` | 0 | 355 ms |
| `relay run` の tap 手順で Row 75 へ戻る | 成功 | 1 | 3624 ms |
| 別の検証画面の表示済みスライダーを adjust | 成功（目標 0.7、実測位置 0.718） | 0 | 2200 ms |

成功した tap / press は、ホストの `relay.scroll.status` が指定した行・タイルを示すことも確認しました。画面外のセルの子ラベルに表示中の位置が返る場合も、親セルのクリップによりスワイプ 0 回での誤った成功にはならず、実際に表示されてから find が成功しました。
`relay run` は、スクロールして押す手順の後で `selected: row 75` を find する2手順が成功しています。adjust は表示済みのスライダーで、スクロール後の adjust や pickerWheel は今回の実機確認には含めていません。

### 消えるのを待つ（gone）

`/find` に `"gone": true` を付けると、セレクタに一致する要素がなくなるまで待ちます。読み込みの表示が消える、シートやアラートが閉じる、を待つためのものです。CLI では `relay find <セレクタ> --gone --timeout <秒>` です。

```sh
relay tap --label OK --type button
relay find --type alert --gone --timeout 5 --require
```

- **消えたとみなす条件**: 要素ツリーに一致する要素が 1 つもないことです。`gone` のない `/find` の `count: 0` と同じ判定で、frame は見ません。
- 画面の外にある要素、frame が空の要素も「ある」と数えます。ハードウェアキーボードをつないだシミュレータのキーボード（`keyboard`）は、画面の下（y = 891 など）でツリーに残るので、消えません。
- 見た目で判断したいときは、`onscreen`（画面から外れるまで）か `hittable`（画面から外れるか覆われるまで）を付けます（「[画面の中・押せる要素だけに絞る](#画面の中押せる要素だけに絞るonscreen--hittable)」）。
- **応答**: `/find` と同じ形に `gone`（`true` / `false`）が付きます。待つ時間（`timeout`、0–10 秒）や busy の扱いは、上の「[待機（timeout）](#待機timeout)」と同じです。
- `timeout` の間に消えなくても `200` で、`gone: false` と、残っている要素（`count`・`elements`）を返します。
- `relay find --gone --require` は、そのとき終了コード 6 で、`code` は `element_still_present` です（relay が判定します。ランナーは返しません）。
- 最初から一致しない要素は、待たずにすぐ `gone: true` です。
- **組み合わせ**: `index` とは組み合わせられません（`400`、CLI は終了コード 2）。ほかの要素が消えると、同じ番号が別の要素を指すためです。`limit` は残っている要素の一覧に効きます。
- **対象アプリ**: `bundleId` を省略したときは、`timeout` と同じく最初に前面アプリから 1 回だけ決めます。システムの許可ダイアログは `bundleId: com.apple.springboard` で待ちます。
- 待っている間に対象アプリの要素ツリーが取れないと（アプリが終了したなど）、取れるまで待ち、期限を過ぎると `422`、`xcui_failed` です。
- `gone` を知らない古いランナーは、`gone` を無視して要素が現れるのを待ちます。応答に `gone` がないとき、`relay find --gone` は `runner_bad_response`（終了コード 8）で失敗します。

アラートなどを閉じるタップの後に `--gone --require` を置くと、タップが無視されて閉じなかったことにも気づけます（「[別のアプリに覆われているとき](#別のアプリに覆われているとき)」）。シミュレータで、表示の直後に押した OK が無視されたとき、`gone: false` で終了コード 6 になりました。

確かめた結果（iPhone 18 Pro シミュレータ、RelayRunnerHost）:

| 場面 | 結果 |
| --- | --- |
| `relay.showToast` で出した `relay.toast`（1.5 秒後にビューから外す） | タップの直後から待って約 1.4 秒で `gone: true` |
| 消えない要素（`relay.input`、`--timeout 2 --require`） | 約 2.1 秒で `gone: false`、終了コード 6、`element_still_present` |
| 最初からない要素（`--timeout 5`） | 約 60 ms で `gone: true` |
| アプリ内のアラート（`relay.inAppAlert`）の OK を押した後 | 約 60 ms で `gone: true`（タップの応答の時点でツリーから消えていた） |
| 位置情報の許可ダイアログ（`--bundle-id com.apple.springboard`）の「Allow Once」を押した後 | 約 70 ms で `gone: true`。その直後の `relay foreground` はまだ `com.apple.springboard` |
| 入力欄のフォーカス中に `relay.overlay` で全画面の画面を出したときのキーボード（ハードウェアキーボードをつないでいて、画面の外にあった） | 約 70 ms で `gone: true` |
| `relay terminate host` の後に `--bundle-id host` で待つ（`--timeout 2` / なし） | 約 2.1 秒 / 約 40 ms で `422`、`xcui_failed`（`… is not running`） |

アラートを閉じた直後に `gone: true` になっても、前面アプリが元のアプリに戻るまで約 230 ms かかることがあります。続く要素指定の `tap` は、その間を待ってから送ります（「[別のアプリに覆われているとき](#別のアプリに覆われているとき)」）。

上の表の環境: iPhone 18 Pro シミュレータ（iOS 27.2、Xcode 27.2）。

実機でも、iPhone 14 Pro（iOS 26.7.3、Xcode 27.2）の RelayRunnerHost で次を確認しました（2026-11-16、各 1 回、時間は CLI の呼び出しから戻るまで）:

| 場面 | 結果 | 時間 |
| --- | --- | --- |
| `relay.showToast` を押し、`relay.toast --gone --timeout 5 --require` | `gone: true`、終了コード 0 | 1432 ms |
| 消えない `relay.input --gone --timeout 2 --require` | `gone: false`、終了コード 6、`element_still_present` | 2129 ms |
| 最初からない要素に `--gone --timeout 5 --require` | `gone: true`、終了コード 0 | 120 ms |

トーストは、待機を測る前に、表示中の同じセレクタで `find --require` が一致することも確認しました。上のシミュレータの表にあるアラート・システムの許可ダイアログ・キーボードの消失・アプリ終了後の待機は、今回の実機検証には含めていません。

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
