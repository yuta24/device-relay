# 非公開 API の一覧

ランナーが使っている Apple の非公開 API（XCTest の SPI）と、それが使えなくなったときの挙動をまとめます。全体の入口は [README](../README.md) です。

## 全体の注意

- **予告なく変わります**: 非公開 API は、Xcode や iOS の更新で消えたり変わったりすることがあります。ランナーは Xcode や iOS の版では分岐せず、実行時にクラス・セレクタ・シンボルがあるかだけを確かめます。引数や戻り値の型だけが変わった場合は検出できず、そのときの挙動は決まっていません（Objective-C の例外も捕捉しません）。
- **対象アプリには何も入りません**: 非公開 API を使うのは、XCTest の UI テストバンドルとして端末上で動くランナー（`Runner/RelayRunnerUITests`）だけです。Mac 側の `relay` CLI は使いません。`Runner/` のコードやバンドルを対象アプリのターゲットに埋め込まないでください。App Store に提出するアプリに含めるものではありません。
- **動作を確認した版**: Xcode 27 と iOS 26.7.1 の実機、iOS 27.0 のシミュレータです。表示が複数ある端末の項目は、Xcode 27.2 と iOS 27.2 のシミュレータで確認しました。ほかの版は確認していません。下の API は、Xcode 27.2 の XCTest と XCUIAutomation の公開ヘッダに宣言がないことを確かめています（実体は `XCUIAutomation.framework` と `XCTAutomationSupport.framework` にあります）。
- **更新の後の確かめ方**: `/health` の `touchSynthesis` が `private`、`foreground.source` が `private` なら、タッチ合成と前面アプリの経路は使えています。iPad のウィンドウの位置は、全画面でないウィンドウで `relay find --type window` の `window` が付くことで確かめます。要素のキーボードのフォーカスは、`/source` の `hasKeyboardFocus` が `null` でないことで確かめます。
- **無効にして試す**: ランナーの環境変数 `RELAY_DISABLE_PRIVATE_TOUCH=1`（タッチ合成）と `RELAY_DISABLE_PRIVATE_FOREGROUND=1`（前面アプリ）で、代わりの経路を試せます。xcodebuild と `relay start` には `TEST_RUNNER_` を前に付けて渡します（`TEST_RUNNER_RELAY_DISABLE_PRIVATE_TOUCH=1` など）。ほかの項目に無効にするスイッチはありません。

## 一覧

| 項目 | 使えないとき | 応答での見分け方 |
| --- | --- | --- |
| [タッチ合成](#タッチ合成) | `xcui` に切り替え（`mode: private` は `400`） | `/health` の `touchSynthesis`、応答の `mode` |
| [表示を指定した合成タッチ](#表示を指定した合成タッチ) | 表示が複数ある端末だけ `xcui` に切り替え（`mode: private` は `400`） | 同上 |
| [前面アプリ](#前面アプリ) | 最後に `/launch` したアプリか SpringBoard | `source: fallback`、`pid: null` |
| [キーボードのフォーカス](#キーボードのフォーカス) | 値なし | `hasKeyboardFocus: null` |
| [表示の向き](#表示の向き) | スクリーンショットの向きで代用（遅くなる） | なし |
| [表示の一覧](#表示の一覧) | main の表示だけで動く | `/health` の `displays`・`display` がない |
| [window の表示 ID](#window-の表示-id) | 点いている表示で判定（遅くなる） | 判定できなければ `display: null`、`display_unknown` |
| [ウィンドウの位置](#ウィンドウの位置) | 要素指定のタッチは何も送らずに `422`。全画面に見えるアプリはそのまま | `window_position_unknown`、`window: null` と `warning` |
| [アプリの状態の待ち時間](#アプリの状態の待ち時間) | 120 秒のまま | なし |

項目ごとの説明に「同じ方式のツール」を書いていなくても、ほかのツールが使っていないという意味ではありません。`code` の意味は「[エラーの形式と code](http-api.md#エラーの形式と-code)」を参照してください。

## 項目ごとの説明

### タッチ合成

- **API**: `XCPointerEventPath`（`-initForTouchAtPoint:offset:`、`-moveToPoint:atOffset:`、`-liftUpAtOffset:`）、`XCSynthesizedEventRecord`（`-initWithName:interfaceOrientation:`、`-addPointerEventPath:`）、`-[XCUIDevice eventSynthesizer]` が返すオブジェクトの `-synthesizeEvent:completion:`（completion は `^(BOOL, NSError *)`）。実装は `RelayTouchSynthesizer.m` です。
- **機能**: `/tap`・`/press`・`/swipe` の `private` 経路（既定）と、実機などの `/button home` のスワイプ。
- **公開 API では足りない理由**: `XCUICoordinate` のジェスチャーは、前後で対象アプリがアイドルになるのを待つので、タップ 1 回に 1–2 秒かかります（「[既知の制約](limitations.md)」）。
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

### 前面アプリ

- **API**: `-[XCUIDevice accessibilityInterface]` の `-activeApplications`（返る要素は `XCAccessibilityElement`。`-processIdentifier` で PID を得ます）、`-[XCUIDevice applicationMonitor]` の `-monitoredApplicationWithProcessIdentifier:`、`-[XCUIApplication bundleID]`。`accessibilityInterface` が返すのは `XCAXClient_iOS` ですが、ランナーが確かめるのはセレクタで、このクラス名は見ません。実装は `RelayActiveApplication.m` です。
- **選び方**: 一覧の先頭を使います。iPad のウィンドウ表示では、画面にあるアプリと SpringBoard が並びます（`["com.apple.mobilesafari","com.apple.springboard"]`）。Dock のフォルダのサービス `com.apple.DocumentManager.DockFolderViewService` は画面の大きさの window を持ち、先頭に来ることがある（ホーム画面や、アプリの操作の直後）ので、このバンドル ID だけを除きます。`com.apple.SafariViewService` のように見えているビューサービスは除きません。
- **機能**: `/foreground`、`/health` の `foreground`。`bundleId` を省略した `/type`・`/key`・`/source`・`/find`、要素を指定した `/tap`・`/press` の対象も、これで決めます。
- **公開 API では足りない理由**: 公開 API の `XCUIApplication.state` は、バンドル ID がわかっているアプリの状態しか返しません。手で切り替えたアプリを知るには、アクティブなアプリの一覧が要ります。
- **使えないとき**: API が欠けているとき、アプリを 1 つも取得できないとき、取得で XCUI の失敗が記録されたときは、エラーにせず `source: fallback`、`pid: null` を返します。対象は、最後に `/launch` したアプリが `runningForeground` ならそのアプリ、そうでなければ SpringBoard です（「[前面アプリ](http-api.md#前面アプリ)」）。手で切り替えたアプリは判別できないので、`bundleId` を指定してください。
- **同じ方式のツール**: WebDriverAgent の `fb_activeApplication`。

### キーボードのフォーカス

- **API**: `-[XCElementSnapshot hasKeyboardFocus]`。`XCUIElementSnapshot` のオブジェクトに KVC で問い合わせます。実装は `RelayRunnerUITests.swift` です。
- **機能**: `/source` の `hasKeyboardFocus` と、compact 形式の `focused`。
- **公開 API では足りない理由**: 公開 API の `hasFocus` はフォーカスエンジンのフォーカスで、iPhone で入力中の欄でも `false` です。
- **使えないとき**: `hasKeyboardFocus` が `null` になり、compact 形式に `focused` が出なくなります。エラーにはなりません。`/type`・`/key` の `no_keyboard_focus` は `typeText` の失敗から判定するので、この API には依存しません。

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

- **API**: SpringBoard の要素の識別子 `SBSwitcherWindow:` で始まるもの（アプリのウィンドウが入る window。iPad では `SBSwitcherWindow:Main`、iOS 27.1 の iPhone Duo を開いた状態では `SBSwitcherWindow:Unknown.main[3]` が観測されています）と `card:<バンドル ID>:sceneID:<シーン>`（ウィンドウ）。取得は公開 API の `XCUIElement.snapshot()` ですが、識別子は公開されていません。実装は `RelayRunnerUITests.swift` で、判定は `Sources/relay/RunnerWindows.swift` です。
- **機能**: iPad で、要素の frame とタップ位置を画面の座標に変換します（「[iPad のウィンドウ表示](screen.md#ipad-のウィンドウ表示)」）。iPhone では読みません。
- **公開 API では足りない理由**: アプリの window 要素は常に `(0, 0)` から始まり、画面上の位置も表示の倍率もわかりません。ほかに比べたのは次のとおりです。クエリの `XCUIElement.frame` は表示の向きの値を返しますが、約 50–120 ms かかります（スナップショットは約 15 ms）。スクリーンショットとの照合は、画面の内容に左右されるうえ、遅くなります。
- **使えないとき**: `SBSwitcherWindow:` で始まる window が見つからないか、その先頭の window に `card:` がなければ、SpringBoard 全体を読み直します（約 35–55 ms）。一致する window が複数あっても、読むのは先頭だけです。先頭だけなら約 13 ms ですが、すべて読むと約 33 ms で、全体を読むのと変わらなくなるためです。全体を読み直せば、ほかの window の `card:` も見つかります。それでも `card:` がなく、アプリが画面より小さければ、要素指定のタッチは何も送らずに `422`、`window_position_unknown` で、`/find`・`/source` には `window: null` と `warning` が付きます。アプリが画面と同じ大きさなら全画面として扱うので、識別子が変わると、縮小表示のアプリ（`UIRequiresFullScreen`）だけは検出できずに外れます。形が合わない frame（縦横の倍率の差が 0.02 を超える）も `422` にします。

### アプリの状態の待ち時間

- **API**: 関数 `_XCTSetApplicationStateTimeout`（`dlsym` で探します。実装は `RelayRunnerUITests.swift`）と、スキームがランナーに渡す起動引数 `-XCUIApplicationStateTimeout 120`。
- **機能**: automation mode の有効化を 120 秒まで待ち、有効になったら `/launch`・`/terminate` の待ち時間を 60 秒に戻します（「[既知の制約](limitations.md)」の automation mode の項）。
- **公開 API では足りない理由**: 公開ヘッダに、この待ち時間を設定する API はありません。
- **使えないとき**: 関数がなければ 120 秒のままで、`/launch`・`/terminate` が最大 120 秒待ちます。エラーにはならず、応答では見分けられません。`relay launch` / `terminate` はどちらの場合も 30 + 120 秒まで応答を待ちます。起動引数が読まれなくなったことは検出しません。その場合は XCTest の既定の待ち時間になるはずで、パスコードの入力が間に合わないと起動が `Timed out while enabling automation mode.` で失敗します。

## 非公開 API ではないもの

次は公開 API です。名前や用途が近いので挙げておきます。

- `XCUIScreen.screens` / `XCUIScreen.main`、`XCUIElement.snapshot()` と `XCUIElementSnapshot`、`hasFocus`、`XCUIApplication.state`、`XCUICoordinate`。
- `relay record` が実機の録画で使う `kCMIOHardwarePropertyAllowScreenCaptureDevices`（macOS SDK の CoreMediaIO の公開ヘッダにあります）。
