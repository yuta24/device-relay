# 非公開 API の一覧

ランナーが使っている Apple の非公開 API（XCTest の SPI）と、それが使えなくなったときの挙動をまとめます。全体の入口は [README](../README.ja.md) です。

## 全体の注意

- **予告なく変わります**: 非公開 API は、Xcode や iOS の更新で消えたり変わったりすることがあります。ランナーは Xcode や iOS の版では分岐せず、実行時にクラス・セレクタ・シンボルがあるかだけを確かめます。引数や戻り値の型だけが変わった場合は検出できず、そのときの挙動は決まっていません（Objective-C の例外も捕捉しません）。
- **対象アプリには何も入りません**: 非公開 API を使うのは、XCTest の UI テストバンドルとして端末上で動くランナー（`Runner/RelayRunnerUITests`）だけです。Mac 側の `relay` CLI は使いません。`Runner/` のコードやバンドルを対象アプリのターゲットに埋め込まないでください。App Store に提出するアプリに含めるものではありません。
- **動作を確認した版**: Xcode 27 と iOS 26.7.1 の実機、iOS 27.0 のシミュレータです。表示が複数ある端末の項目は、Xcode 27.2 と iOS 27.2 のシミュレータで確認しました。文字入力の合成は、Xcode 27.2 と iOS 27.2 のシミュレータ、iOS 26.7.1 の実機で確認しました。ほかの版は確認していません。下の API は、Xcode 27.2 の XCTest と XCUIAutomation の公開ヘッダに宣言がないことを確かめています（実体は `XCUIAutomation.framework` と `XCTAutomationSupport.framework` にあります）。
- **更新の後の確かめ方**: `/health` の `touchSynthesis` が `private`、`foreground.source` が `private` なら、タッチ合成と前面アプリの経路は使えています。文字入力の合成は、`/health` の `typeSynthesis` が `private` であることで確かめます。iPad のウィンドウの位置は、全画面でないウィンドウで `relay find --type window` の `window` が付くことで確かめます。要素のキーボードのフォーカスは、`/source` の `hasKeyboardFocus` が `null` でないことで確かめます。共有シートの入れ物は、iPhone で共有シートを開いて `relay find --label Copy --type cell` の frame がシートの中（縦向きなら画面の下のほう）にあることで確かめます。
- **無効にして試す**: ランナーの環境変数 `RELAY_DISABLE_PRIVATE_TOUCH=1`（タッチ合成）、`RELAY_DISABLE_PRIVATE_TYPING=1`（文字入力の合成）、`RELAY_DISABLE_PRIVATE_FOREGROUND=1`（前面アプリ）で、代わりの経路を試せます。xcodebuild と `relay start` には `TEST_RUNNER_` を前に付けて渡します（`TEST_RUNNER_RELAY_DISABLE_PRIVATE_TOUCH=1` など）。ほかの項目に無効にするスイッチはありません。

## 一覧

| 項目 | 使えないとき | 応答での見分け方 |
| --- | --- | --- |
| [タッチ合成](#タッチ合成) | `xcui` に切り替え（`mode: private` は `400`） | `/health` の `touchSynthesis`、応答の `mode` |
| [表示を指定した合成タッチ](#表示を指定した合成タッチ) | 表示が複数ある端末だけ `xcui` に切り替え（`mode: private` は `400`） | 同上 |
| [文字入力の合成](#文字入力の合成) | `typeText` で入力（アイドル待ちが前後に入る） | `/health` の `typeSynthesis` |
| [要素のタッチ位置の確認](#要素のタッチ位置の確認) | 確認を省き、従来どおり送る | なし |
| [前面アプリ](#前面アプリ) | 最後に `/launch` したアプリか SpringBoard | `source: fallback`、`pid: null` |
| [キーボードのフォーカス](#キーボードのフォーカス) | 値なし | `hasKeyboardFocus: null` |
| [表示の向き](#表示の向き) | スクリーンショットの向きで代用（遅くなる） | なし |
| [表示の一覧](#表示の一覧) | main の表示だけで動く | `/health` の `displays`・`display` がない |
| [window の表示 ID](#window-の表示-id) | 点いている表示で判定（遅くなる） | 判定できなければ `display: null`、`display_unknown` |
| [ウィンドウの位置](#ウィンドウの位置) | 要素指定のタッチは何も送らずに `422`。全画面に見えるアプリはそのまま | `window_position_unknown`、`window: null` と `warning` |
| [共有シートの入れ物](#共有シートの入れ物) | 変換しない（中の要素の frame は相対座標のまま。要素指定のタッチは外れる） | なし |
| [アプリの状態の待ち時間](#アプリの状態の待ち時間) | 120 秒のまま | なし |

項目ごとの説明に「同じ方式のツール」を書いていなくても、ほかのツールが使っていないという意味ではありません。`code` の意味は「[エラーの形式と code](http-api.md#エラーの形式と-code)」を参照してください。

## 項目ごとの説明

### タッチ合成

- **API**: `XCPointerEventPath`（`-initForTouchAtPoint:offset:`、`-moveToPoint:atOffset:`、`-liftUpAtOffset:`）、`XCSynthesizedEventRecord`（`-initWithName:interfaceOrientation:`、`-addPointerEventPath:`）、`-[XCUIDevice eventSynthesizer]` が返すオブジェクトの `-synthesizeEvent:completion:`（completion は `^(BOOL, NSError *)`）。実装は `RelayTouchSynthesizer.m` です。
- **機能**: `/tap`・`/press`・`/swipe` の `private` 経路（既定）と、実機などの `/button home` のスワイプ。
- **公開 API では足りない理由**: `XCUICoordinate` のジェスチャーは、前後で対象アプリがアイドルになるのを待つので、タップ 1 回に 1–2 秒かかります（「[タッチ合成の経路](design.md#タッチ合成の経路)」）。
- **同じ方式のツール**: WebDriverAgent。

使えないときの挙動:

| 状況 | 挙動 |
| --- | --- |
| API が欠けていて、`mode` が省略か `auto` | `xcui` で送ります。応答の `mode` と `/health` の `touchSynthesis` が `xcui` になります。`/button home` は XCUI のドラッグになります（応答に `mode` はありません） |
| API が欠けていて、`mode: private` | 何も送らずに `400`、`touch_mode_unavailable` |
| 合成を始められない | `500`、`touch_failed` |
| 完了の callback がエラーを返した、または離す時刻の 10 秒後までに完了しない | `422`、`touch_failed` |

`touch_failed` のとき、同じリクエストを `xcui` で送り直すことはしません。

### 表示を指定した合成タッチ

- **API**: `-[XCSynthesizedEventRecord initWithName:displayID:interfaceOrientation:]`（Xcode 27.1 以上）。実装は `RelayTouchSynthesizer.m` です。
- **機能**: 表示が複数ある端末（iPhone Duo）の `private` 経路。表示が 1 つの端末では使いません。
- **公開 API では足りない理由**: 表示の ID を付けないイベントは内側の表示に届かず、いったん開いてから閉じた後は外側にも届きませんでした（「[表示が複数ある端末](screen.md#表示が複数ある端末iphone-duo)」）。
- **使えないとき**: 表示が複数ある端末では、`mode` の省略か `auto` で `xcui` になり、`/health` の `touchSynthesis` も `xcui` になります。`mode: private` は何も送らずに `400`、`touch_mode_unavailable` です。`xcui` が届かない場面（内側で SpringBoard か回転しないアプリが前面）は、何も送らずに `422`、`touch_mode_unavailable` です。

### 文字入力の合成

- **API**: `XCPointerEventPath`（`-initForTextInput`、`-typeText:atOffset:typingSpeed:shouldRedact:`）と、タッチ合成と同じ `XCSynthesizedEventRecord`・`-[XCUIDevice eventSynthesizer]`。実装は `RelayTextSynthesizer.m` です。
- **フォーカスの確認**: 合成した入力はフォーカスを確かめないので、送る前に述語 `hasKeyboardFocus == 1` で要素を探します（`typeText` と同じ問い合わせ）。属性は `-[XCElementSnapshot hasKeyboardFocus]` です。
- **機能**: 表示が 1 つの端末の `/type`・`/key`。速さは `typeText` の既定と同じ 1 秒 60 文字です。
- **公開 API では足りない理由**: `typeText` は入力の前後で対象アプリがアイドルになるのを待ちます。アイドルにならないアプリでは、この待ちで `/type` が 3 分ほど busy になりました（「[文字入力の経路](design.md#文字入力の経路)」）。
- **同じ方式のツール**: WebDriverAgent。

使えないときの挙動:

| 状況 | 挙動 |
| --- | --- |
| API か `hasKeyboardFocus` が欠けている、または表示が複数ある端末 | `typeText` で入力します。`/health` の `typeSynthesis` が `xcui` になります |
| フォーカスの問い合わせで XCUI の失敗が記録された（アプリが動いていないなど） | 何も入力せずに `422`、`xcui_failed` |
| 合成を始められない | 何も入力せずに `500`、`typing_failed` |
| 完了の callback がエラーを返した、または時間内に完了しない | `422`、`typing_failed`。入力の一部が入っていて、応答の後も残りが入り続けることがあります |

時間内の「時間」は「[文字入力と特殊キー](http-api.md#文字入力と特殊キー)」を参照してください。
`typing_failed` のとき、同じ入力を `typeText` で送り直すことはしません。表示が複数ある端末で合成した入力は、確かめていません。

### 要素のタッチ位置の確認

要素指定の `/tap`・`/press` は、押す点のアクセシビリティ要素を取得し、選んだ要素・その祖先・子孫とは別のコントロールに当たると確認できた場合だけ拒否します。

- **API**: `-[XCUIDevice accessibilityInterface]` が返すオブジェクトの `-hitTestElement:withPoint:error:`、スナップショットの `-accessibilityElement` と `-children`。実装は `RelayActiveApplication.m` です。セレクタの存在を実行時に確認します。
- **公開 API では足りない理由**: `frame` の中心が別の要素に重なることがあります。`isHittable` は、こちらで選んだ点に何があるかを返しません。
- **コントロールの判定**: `RunnerElementTree.interactiveTypes` を再利用します。名前や enabled による一覧の条件は使いません。`staticText`・`other`・`image`・`group` などの内容は、ラベルやセルへクリックを渡す場合があるため、拒否の根拠にしません。
- **使えないとき**: API が欠ける、nil・エラーが返る、返された要素がスナップショットにない場合は、確認を省き、従来どおり送ります。座標指定のタッチには使いません。
- **結果の整合性**: `com.apple.SafariViewService` の Close・Cancel では、点を含まない Address 要素が返ることがありました。返された要素の frame が点を含まない場合も、確認できないものとして送ります。
- **同じ方式のツール**: [WebDriverAgent の iOS 用インターフェース宣言](https://github.com/appium/WebDriverAgent/blob/master/PrivateHeaders/XCTest/XCAXClient_iOS.h)にも同じメソッドがあります。
- **一覧での利用**: `filter=interactive` では、後のコントロールの枠と重なる候補だけを同じ方法で確認します。別のコントロールに当たると確認できた候補だけを外します。確認できない候補は残します。

確かめた環境: Xcode 27.2、iPhone 17 Pro シミュレータ（iOS 27.0）、iPhone 14 Pro 実機（iOS 26.7.1）。iPad での hit test は確かめていません。

### 前面アプリ

- **API**: `-[XCUIDevice accessibilityInterface]` の `-activeApplications`（返る要素は `XCAccessibilityElement`。`-processIdentifier` で PID を得ます）、`-[XCUIDevice applicationMonitor]` の `-monitoredApplicationWithProcessIdentifier:`、`-[XCUIApplication bundleID]`。`accessibilityInterface` が返すのは `XCAXClient_iOS` ですが、ランナーが確かめるのはセレクタで、このクラス名は見ません。実装は `RelayActiveApplication.m` です。
- **選び方**: 一覧の先頭を使います。iPad のウィンドウ表示では、画面にあるアプリと SpringBoard が並びます（`["com.apple.mobilesafari","com.apple.springboard"]`）。Dock のフォルダのサービス `com.apple.DocumentManager.DockFolderViewService` は画面の大きさの window を持ち、先頭に来ることがある（ホーム画面や、アプリの操作の直後）ので、このバンドル ID だけを除きます。`com.apple.SafariViewService` のように見えているビューサービスは除きません。
- **機能**: `/foreground`、`/health` の `foreground`。`bundleId` を省略した `/type`・`/key`・`/source`・`/find`、要素を指定した `/tap`・`/press` の対象も、これで決めます。要素を指定した `/tap`・`/press` は、送る直前に、対象アプリが一覧になく先頭が SpringBoard でないかも確かめます（判定は `Sources/Relay/Shared/RunnerCoverage.swift`。「[別のアプリに覆われているとき](elements.md#別のアプリに覆われているとき)」）。
- **公開 API では足りない理由**: 公開 API の `XCUIApplication.state` は、バンドル ID がわかっているアプリの状態しか返しません。手で切り替えたアプリを知るには、アクティブなアプリの一覧が要ります。
- **使えないとき**: API が欠けているとき、アプリを 1 つも取得できないとき、取得で XCUI の失敗が記録されたときは、エラーにせず `source: fallback`、`pid: null` を返します。対象は、最後に `/launch` したアプリが `runningForeground` ならそのアプリ、そうでなければ SpringBoard です（「[前面アプリ](http-api.md#前面アプリ)」）。手で切り替えたアプリは判別できないので、`bundleId` を指定してください。要素を指定した `/tap`・`/press` の、覆われているかの確認もしません（以前と同じく送ります）。
- **同じ方式のツール**: WebDriverAgent の `fb_activeApplication`。

### キーボードのフォーカス

- **API**: `-[XCElementSnapshot hasKeyboardFocus]`。`XCUIElementSnapshot` のオブジェクトに KVC で問い合わせます。実装は `RelayRunnerUITests.swift` です。
- **機能**: `/source` の `hasKeyboardFocus` と、compact 形式の `focused`。
- **公開 API では足りない理由**: 公開 API の `hasFocus` はフォーカスエンジンのフォーカスで、iPhone で入力中の欄でも `false` です。
- **使えないとき**: `hasKeyboardFocus` が `null` になり、compact 形式に `focused` が出なくなります。エラーにはなりません。合成した入力は、フォーカスの確認にこの属性を使います。属性がなければ `typeText` で入力し、`no_keyboard_focus` は `typeText` の失敗から判定します（「[文字入力の合成](#文字入力の合成)」）。

### 表示の向き

- **API**: `-[XCUIApplication interfaceOrientation]`。SpringBoard の `XCUIApplication` に KVC で問い合わせます（前面アプリの向きが返ります）。実装は `RelayRunnerUITests.swift` です。
- **機能**: `/health` の `orientation` と `screen`、座標の変換と画面の外の判定、`/source` の `filter=interactive`。リクエストのたびに読みます。
- **公開 API では足りない理由**: 公開 API の `XCUIDevice.orientation` は端末の向きで、表示の向きとは一致しません（「[座標系と画面の向き](screen.md#座標系と画面の向き)」）。スクリーンショットの向きからも求められますが、約 1 ms に対して約 90 ms かかります。
- **使えないとき**: セレクタがない、値が読めない、`unknown` が返るときは、スクリーンショットの `UIImage.imageOrientation` で代用します。エラーにはならず、応答では見分けられません。遅くなるだけです。

### 表示の一覧

- **API**: `-[XCUIScreen displayID]`、`-[XCUIScreen bounds]`（ピクセル）、`-[XCUIScreen traits]`。KVC で読みます。実装は `RelayRunnerUITests.swift` です。
- **機能**: `/health` の `displays`・`display`、スクリーンショットの `X-Relay-Display`。表示が複数ある端末で、タッチとスクリーンショットの対象を決めます。
- **公開 API では足りない理由**: 公開 API の `XCUIScreen` には `screens`・`main` とスクリーンショットしかなく、表示の ID も大きさもわかりません。端末に組み込まれた表示とワイヤレス（AirPlay）の表示の区別もつきません。
- **使えないとき**:
  - `displayID` か `bounds` のセレクタがない場合: 表示は 1 つとして扱い、この結果をランナーが止まるまで保持します。`/health` の `displays`・`display` と `X-Relay-Display` はなくなります。すべて main の表示に送るので、iPhone Duo で内側を開いていても、エラーにはならず外側に送ります。
  - 値を読めない、または XCUI の失敗が記録された場合: そのコマンドだけ同じ扱いにして、次のコマンドで読み直します。
  - `traits` のセレクタがない場合: どの表示も端末に組み込まれたものとして数えます。
  - 一覧にあった表示が見つからなくなった場合: `/screenshot` は `422`、`display_unknown` です。

### window の表示 ID

- **API**: `-[XCElementSnapshot displayID]`。KVC で読みます。実装は `RelayRunnerUITests.swift` です。
- **機能**: 表示が複数ある端末で、前面アプリの表示を判定し、要素ツリーからほかの表示の window を除きます。表示が 1 つの端末では読みません。
- **公開 API では足りない理由**: 公開 API の `XCUIElementSnapshot` には、要素の表示を示す属性がありません。
- **使えないとき**: 点いている表示をスクリーンショットで探します（表示ごとに約 150 ms）。決まらなければ、タッチと `/screenshot` は何も送らずに `422`、`display_unknown` になり、`/health` の `display` は `null` です。ほかの表示の window は除けないので、ホーム画面の要素ツリーに暗い表示の要素が残り、セレクタがそれに一致することがあります。

### ウィンドウの位置

- **API**: SpringBoard の要素の識別子 `SBSwitcherWindow:` で始まるもの（アプリのウィンドウが入る window。iPad では `SBSwitcherWindow:Main`、iOS 27.1 の iPhone Duo を開いた状態では `SBSwitcherWindow:Unknown.main[3]` が観測されています）と `card:<バンドル ID>:sceneID:<シーン>`（ウィンドウ）。取得は公開 API の `XCUIElement.snapshot()` ですが、識別子は公開されていません。実装は `RelayRunnerUITests.swift` で、判定は `Sources/Relay/Shared/RunnerWindows.swift` です。
- **機能**: iPad で、要素の frame とタップ位置を画面の座標に変換します（「[iPad のウィンドウ表示](screen.md#ipad-のウィンドウ表示)」）。iPhone では読みません。
- **公開 API では足りない理由**: アプリの window 要素は常に `(0, 0)` から始まり、画面上の位置も表示の倍率もわかりません。ほかに比べたのは次のとおりです。クエリの `XCUIElement.frame` は表示の向きの値を返しますが、約 50–120 ms かかります（スナップショットは約 15 ms）。スクリーンショットとの照合は、画面の内容に左右されるうえ、遅くなります。
- **使えないとき**: `SBSwitcherWindow:` で始まる window が見つからないか、その先頭の window に `card:` がなければ、SpringBoard 全体を読み直します（約 35–55 ms）。一致する window が複数あっても、読むのは先頭だけです。先頭だけなら約 13 ms ですが、すべて読むと約 33 ms で、全体を読むのと変わらなくなるためです。全体を読み直せば、ほかの window の `card:` も見つかります。それでも `card:` がなく、アプリが画面より小さければ、要素指定のタッチは何も送らずに `422`、`window_position_unknown` で、`/find`・`/source` には `window: null` と `warning` が付きます。アプリが画面と同じ大きさなら全画面として扱うので、識別子が変わると、縮小表示のアプリ（`UIRequiresFullScreen`）だけは検出できずに外れます。形が合わない frame（縦横の倍率の差が 0.02 を超える）も `422` にします。

### 共有シートの入れ物

- **API**: 共有シートの要素の識別子 `ShareSheet.RemoteContainerView`。取得は公開 API の `XCUIElement.snapshot()` ですが、識別子は公開されていません。判定と変換は `Sources/Relay/Shared/RunnerRemoteViews.swift` です。
- **機能**: 共有シートの中の要素の frame とタップ位置を画面の座標に変換し、変換できない形のときは要素指定のタッチを止めます（「[共有シートの中の要素](elements.md#共有シートの中の要素)」）。
- **公開 API では足りない理由**: スナップショットには、要素が別のプロセスのビューの中にあることも、どこから相対座標になるかも出ません。どんな要素の下でも「(0, 0) から親と同じ大きさ」を相対座標の始まりとみなすと、アプリ自身の要素を誤って動かすおそれがあるので、入れ物を識別子で決めています。
- **使えないとき**: 識別子が変わると入れ物が見つからず、何も変換しません。中の要素の frame は相対座標のままで、要素指定のタッチは以前と同じく `ok: true` のまま外れます。応答では見分けられません。

### アプリの状態の待ち時間

- **API**: 関数 `_XCTSetApplicationStateTimeout`（`dlsym` で探します。実装は `RelayRunnerUITests.swift`）と、スキームがランナーに渡す起動引数 `-XCUIApplicationStateTimeout 120`。
- **機能**: パスコードを入力する時間を取るため、スキームのテストアクションで automation mode の有効化を 120 秒まで待つ引数を渡し、有効になったら `/launch`・`/terminate` の待ち時間を 60 秒に戻します（「[UI オートメーションとパスコード](device.md#ui-オートメーションとパスコード)」）。
- **公開 API では足りない理由**: 公開ヘッダに、この待ち時間を設定する API はありません。
- **使えないとき**: 関数がなければ 120 秒のままで、`/launch`・`/terminate` が最大 120 秒待ちます。エラーにはならず、応答では見分けられません。`relay launch` / `terminate` はどちらの場合も 30 + 120 秒まで応答を待ちます。起動引数が読まれなくなったことは検出しません。その場合は XCTest の既定の待ち時間になるはずで、パスコードの入力が間に合わないと起動が `Timed out while enabling automation mode.` で失敗します。

XCTest は、テストを始める前に端末の testmanagerd が automation mode を有効にするのを `XCUIApplicationStateTimeout`（既定 60 秒）だけ待ちます。
有効化後に待ち時間を戻すので、`/launch`・`/terminate` の通常の待ち時間は変わりません。

スキームは Runner のソースのハッシュに含まれるので、この引数のない古いビルドは `relay start` が自動で作り直します。
対象ファイルは「[ソースのハッシュの計算](development.md#ソースのハッシュの計算)」、再ビルドの条件は「[ランナーの版](setup.md#ランナーの版ソースのハッシュ)」を参照してください。

## 非公開 API ではないもの

次は公開 API です。名前や用途が近いので挙げておきます。

- `XCUIScreen.screens` / `XCUIScreen.main`、`XCUIElement.snapshot()` と `XCUIElementSnapshot`、`hasFocus`、`XCUIApplication.state`、`XCUICoordinate`。
- `relay record` が実機の録画で使う `kCMIOHardwarePropertyAllowScreenCaptureDevices`（macOS SDK の CoreMediaIO の公開ヘッダにあります）。
