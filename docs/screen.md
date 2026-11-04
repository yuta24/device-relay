# 座標系とスクリーンショット

タップなどの座標系と画面の向き、スクリーンショットの縮小、表示が複数ある端末（iPhone Duo）の扱いについて説明します。全体の入口は [README](../README.md) です。

## 座標系と画面の向き

- 座標は **前面アプリの表示の向き（interface orientation）での、画面左上を原点とするポイント単位** です。縦向きなら 402×874、横向きなら 874×402 の範囲で指定します（iPhone 17 Pro の場合）。
- 画面の外の座標（`0 ≤ x < screen.width`、`0 ≤ y < screen.height` の外）への `/tap`・`/press`・`/swipe` は、何も送らずに `400` になります（「[画面の外の座標](http-api.md#エンドポイント)」）。縦向きの (500, 100) は iPhone 17 Pro では画面の外ですが、横向き（874×402）では中です。
- `/health` の `screen.width` / `screen.height` はこの向きでの値です。`orientation` は表示の向きを `/orientation` と同じ名前（`portrait` / `portraitUpsideDown` / `landscapeLeft` / `landscapeRight`）で返します。`/orientation landscapeLeft` の後は `"orientation":"landscapeLeft"` になります（UIKit の interface orientation としては `landscapeRight` にあたります。デバイスとインターフェースで左右の名前が逆になるためです）。
- 表示の向きは、端末の向き（`XCUIDevice.orientation`）と一致するとは限りません。横向きの iPhone でもホーム画面は縦のままですし、iPhone のアプリは `portraitUpsideDown` に回転しません。そのため、端末の向きではなく、リクエストのたびに前面アプリの向きを読み直します。`/orientation` を使わずに端末を手で回した場合や、アプリを切り替えた場合にも追従します。
- 向きの取得には非公開 API を使います（約 1 ms）。使えない場合は、スクリーンショットの向きで代用します（約 90 ms。「[表示の向き](private-api.md#表示の向き)」）。
- `/screenshot` の画素も表示の向きにそろえます。横向きなら幅 > 高さになり、`width = screen.width × scale`、`height = screen.height × scale` です。ただし iPhone 14 Pro 実機では、XCUI のスクリーンショット自体が 1178×2556 px で、393 pt × 3 = 1179 より短辺が 1 px 足りません（向きの正規化を入れる前から同じです）。XCUI のスクリーンショットは画素が常に縦向きで、回転は向きのメタデータとしてだけ付いているので、縦向き以外では描き直します。そのぶん時間が増えます（p50 で、シミュレータは png +50 ms・jpeg +7 ms、実機は png +30 ms・jpeg はほぼ変わらず）。
- `maxSize` / `scale` で縮小した画像では、画素 = ポイント × `X-Relay-Image-Scale` です（下の「スクリーンショットの縮小」）。タップなどの座標は、縮小してもポイントのままです。
- タッチ: `xcui` 経路では、XCTest が SpringBoard 基準の座標を表示の向きで解釈します。`private` 経路の合成イベントは `XCSynthesizedEventRecord` の向きの指定では座標が変換されない（縦向きの画面座標として扱われる）ため、ランナーが表示の向きの座標を縦向きの画面座標に変換し、`portrait` として送ります。どちらの経路でも同じ座標が同じ位置に当たります。

### スクリーンショットの縮小

`GET /screenshot` は、フル解像度（iPhone 17 Pro の縦向きで 1206×2622 px）のほかに、端末側で縮小した画像を返せます。エージェントに画像を渡すとき（転送量と画像のトークン）を減らすためのものです。

| クエリ | CLI | 内容 |
| --- | --- | --- |
| `maxSize=<px>` | `--max-size <px>` | 長辺をこの画素数以下にします（16 以上の整数） |
| `scale=<px/pt>` | `--scale <px/pt>` | 1 ポイントあたりの画素数をこの値以下にします（0.1–10。`/health` の `screen.scale` と同じ単位）。`scale=1` なら画像の画素とタップのポイントが一致します |

- 両方を指定すると、小さくなる方に合わせます（`--scale 1 --max-size 1024` なら、iPhone は 402×874、長辺が 1024 pt を超える iPad では 1024 px）。縦横比は保ち、拡大はしません（元の大きさ以上の指定や、端末の scale 以上の `scale` では縮小しません）。範囲外・数値以外は `400` です。
- 縮小は、表示の向きへの正規化と同じ 1 回の描画で行います（向きのメタデータつきの画像を、縮小後の大きさのキャンバスに描きます）。正規化の後に縮小すると、フル解像度で描き直してからもう一度描くことになり、縮小を先にしても向きを直す描画は別に要るので、1 回にまとめるのがいちばん速く、エンコーダーには小さな画像だけが渡ります。横向きでは正規化のための描き直しがもともと要るので、縮小した方がエンコードが軽いぶん速くなります。縦向きのフル解像度の png は XCUI の PNG をそのまま返す（描き直さない）ので、縦向きで縮小すると画像の展開と描画のぶん少し遅くなります（下の表）。
- 応答には、画像と座標の対応を示すヘッダーを付けます（縮小しないときも付きます）。

| ヘッダー | 内容 |
| --- | --- |
| `X-Relay-Image-Width` / `X-Relay-Image-Height` | 返した画像の画素数 |
| `X-Relay-Screen-Width` / `X-Relay-Screen-Height` | 表示の向きでの画面の大きさ（ポイント）。`/health` の `screen.width` / `height` と同じ値 |
| `X-Relay-Image-Scale` | 1 ポイントあたりの画素数（画像の幅 ÷ 画面の幅。小数点以下 3 桁）。フル解像度なら `/health` の `screen.scale`（実機では 1 px の差で 2.997 などになることがあります） |
| `X-Relay-Display` | 撮った表示の ID（`/health` の `display`）。表示が複数ある端末でだけ付きます（下の「[表示が複数ある端末](#表示が複数ある端末iphone-duo)」） |

- 画像上の位置 (px) をタップの座標にするには `X-Relay-Image-Scale` で割ります（`maxSize=1024` の縦向きなら 471×1024 px、402×874 pt、`1.172`。画像の (120, 375) は (102, 320) pt）。`/tap` などの座標は、縮小した画像でも常にポイントです。
- `relay screenshot --max-size` / `--scale` は、保存先のパスを stdout に 1 行出すのは変えずに（`-o -` なら画像だけを stdout に出します）、stderr に `relay: image 471x1024 px, screen 402x874 pt, 1.172 px/pt (tap in points: px / 1.172)` と出します。どちらも付けないときは、これまでどおりパスだけです。
- 既定（どちらも付けない）は、これまでどおりフル解像度です。画素 = ポイント × `screen.scale` という関係や、細部を確かめたい人やスクリプトの使い方を変えないためです。エージェントスキルでは `--scale 1` を勧め、細部が要るときだけフル解像度を使うように案内しています。

計測（iPhone 17 Pro シミュレータ、iOS 27.0。`curl` で 10 回の p50。縦は設定アプリのトップ、横は RelayRunnerHost の landscapeLeft）:

| リクエスト | 縦: 画像 | 縦: 時間 | 縦: 大きさ | 横: 時間 | 横: 大きさ |
| --- | --- | ---: | ---: | ---: | ---: |
| png（既定） | 1206×2622 | 68 ms | 289 KB | 94 ms | 81 KB |
| jpeg（q=0.7） | 1206×2622 | 82 ms | 207 KB | 83 ms | 104 KB |
| png `maxSize=1024` | 471×1024 | 88 ms | 85 KB | 83 ms | 24 KB |
| jpeg `maxSize=1024` | 471×1024 | 87 ms | 55 KB | 81 ms | 24 KB |
| png `scale=1` | 402×874 | 87 ms | 69 KB | 82 ms | 19 KB |
| jpeg `scale=1` | 402×874 | 86 ms | 43 KB | 83 ms | 19 KB |

画像のトークン（画素数に比例）は、`scale=1` でフル解像度の 9 分の 1 です。RelayRunnerHost の `maxSize=1024` の画像で、入力欄の位置を 1.172 で割った座標をタップすると、その欄にフォーカスが移ることを確かめました（縦向きの Password 欄 (236, 229) px → (201, 195) pt、横向きの Second field 欄 (512, 102) px → (437, 87) pt）。

## 表示が複数ある端末（iPhone Duo）

iPhone Duo には表示が 2 つあります。外側（cover。`XCUIScreen.main`）と内側（inner）で、点くのは使っている方だけです。ランナーは、前面アプリが載っている表示（以下「アプリの表示」）に合わせて動きます。そのための非公開 API は「[非公開 API の一覧](private-api.md)」にまとめています。

- **要件**: Xcode 27.1 以上と、iOS 27.1 以上の iPhone Duo（シミュレータ）。Xcode 27.2 と iOS 27.2 の iPhone Duo シミュレータで確かめました。Xcode 27.2 が既定の Xcode でなければ、`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer relay start --device "iPhone Duo"` のように、Xcode 27.2 の Developer ディレクトリを `DEVELOPER_DIR` で指定します（パスは Xcode を置いた場所に合わせます）。実機の Duo は確かめていません。
- **表示**: `/health` の `displays` に一覧（ID、縦向きのポイント、scale、`main`）を、`display` にアプリの表示の ID を返します。iPhone Duo のシミュレータでは、外側が ID 1（466×678 pt、main）、内側が ID 3（669×951 pt）です。ID は `xcrun devicectl device info displays --device <udid>` の `displayId` と同じです。内側はふつう横向きで使うので、内側にいるときの `screen` は 951×669、`orientation` は `landscapeRight` になります。表示が 1 つの端末でも、`displays` は 1 件、`display` はその ID です。一覧は端末に組み込まれた表示だけで、ワイヤレス（AirPlay）の表示は含めません（iPhone 14 Pro 実機の `XCUIScreen.screens` には `wireless, airplay` の表示も並んでいました。非公開の `-[XCUIScreen traits]` で見分けます）。
- **合わせるもの**: `/health` の `screen`、`/screenshot`（アプリの表示を撮ります。以前は内側を開いていても外側を撮り、真っ黒な画像が返りました）、画面の外の座標の判定、タッチ（`/tap`・`/press`・`/swipe`、要素指定を含む）、`/button home`、要素の frame（`/source`・`/find`・要素指定のタップ）。
- **判定**: アプリの window のスナップショットが持つ表示の ID（非公開の `-[XCElementSnapshot displayID]`）で決めます。SpringBoard は両方の表示に window を持つので、SpringBoard が前面のとき（ホーム画面）は、点いている表示で決めます（暗い表示のスクリーンショットは真っ黒です）。どちらでも決まらない場合（両方とも暗いなど）は、タッチとスクリーンショットを何も送らずに `422`（`cannot tell which display … is on`）にし、`/health` は `display` を `null`、`screen` を外側の大きさにします。ランナー自身のシーンの画面（`UIWindowScene.screen`）は、折りたたみを変えても追従しなかったので使いません。
- **タッチ**: `private` 経路は、合成イベントに表示の ID を付け（非公開の `-[XCSynthesizedEventRecord initWithName:displayID:interfaceOrientation:]`）、座標をその表示の縦向きのポイントに変換して送ります。外側にも ID を付けます。ID を付けないイベントは、内側には届かず、いったん開いてから閉じた後は外側にも届きませんでした。`xcui` 経路は、外側では従来どおり SpringBoard を基準にし、内側では前面アプリの最初の window を基準に、その原点からの差で送ります（SpringBoard やアプリの要素を基準にした座標は、成功を返して何も起きませんでした。内側では、アプリが回転して (282, 0) から始まる window になることがあります）。内側で SpringBoard が前面のときと、回転しないアプリ（縦向きの window のまま回転して表示されるもの）が前面のときは、`xcui` の座標タッチを何も送らずに `422` にします（`use mode private`）。
- **要素の frame**: SpringBoard のツリーからは、ほかの表示の window を除きます。回転するアプリ（設定など）の frame は表示の向きで返りますが、SpringBoard と回転しないアプリは、縦向きの window とその表示の縦向きの座標で返るので、表示の向きに変換します。どの要素の frame も `/tap` と `/screenshot` と同じ座標になります。`/source?format=text`（XCUI の `debugDescription`）は変換しません。
- **ホーム**: iPhone Duo のシミュレータでは、`XCUIDevice.press(.home)` がどちらの表示でも成功を返して何も起きないので、実機と同じくホームインジケーターのスワイプで代用します。
- **表示を指定するオプションはありません**: 点くのは 1 つだけで、暗い表示への操作やスクリーンショットには意味がないためです。アプリの表示は、`/health` の `display` とスクリーンショットの `X-Relay-Display` で確かめられます。
- **折りたたみの切り替え**: relay からはできません。Xcode の DeviceHub（`Xcode.app/Contents/Applications/DeviceHub.app`）で端末を選び、姿勢のコントロールで切り替えます。姿勢は Closed・Book・Open の 3 つです。切り替えた後は `/health` を読み直します。Closed から Open への切り替えでは、シミュレータが起動し直してランナーが止まることがありました（2 回）。そのときは `relay status` が失敗するので `relay start` し直します。ランナーが動き続けた切り替えでも、表示の一覧（大きさは姿勢で変わりません）と向き（リクエストごとに読み直します）は古くなりませんでした。`devicectl device info displays` の `active` は、シミュレータが起動し直した直後に古い値のままのことがあるので、点いている表示はスクリーンショットで確かめます。
- **姿勢と向き**: Closed・Book・Open のそれぞれで、`/orientation` を portrait・landscapeLeft・landscapeRight・portraitUpsideDown にして、ホーム画面・設定アプリ・RelayRunnerHost で確かめました（Xcode 27.2、iOS 27.2 のシミュレータ）。どの姿勢でも点く表示は 1 つで、両方が同時に点くことはありませんでした。`/orientation` は端末の向き（`XCUIDevice.orientation`）を変えますが、画面は回転しません。外側は portrait、内側は landscapeRight のままで、横向きに対応した RelayRunnerHost も回転しませんでした。`/health` の `orientation` と `screen` は、実際の表示の向きを返します。

| 姿勢 | 点く表示 | `/health`（4 つの向きとも） | スクリーンショット | タップ（private / xcui の座標・要素） | 画面外 | ホーム |
| --- | --- | --- | --- | --- | --- | --- |
| Closed | 外側（ID 1） | `display` 1、466×678、portrait | 外側の画像 | 設定・RelayRunnerHost・ホーム画面のすべてで届いた（ホーム画面の private の座標タップが 1 回だけ届かなかった） | 400 | 効いた |
| Open | 内側（ID 3） | `display` 3、951×669、landscapeRight | 内側の画像 | 設定・RelayRunnerHost（回転表示）で届いた。ホーム画面は private と要素で届き、xcui は 422 | 400 | 効いた |
| Book | 内側（ID 3） | Open と同じ | 内側の画像 | Open と同じ。設定アプリは配置が変わる（Accessibility の行の中心が (160, 332) から (227, 314) に）が、frame どおりに届いた | 400 | 効いた |

- **速さ**: 表示が 1 つの端末では、表示の一覧を最初に 1 回読むだけで、速さは変わりません（iPhone 17 Pro シミュレータの p50 で `/health` 8 → 9 ms、`/screenshot` 76 → 70 ms、`/tap` 295 → 290 ms）。iPhone Duo では、コマンドごとにアプリの表示を調べるぶん遅くなります（`relay health` で、設定アプリが前面なら約 0.15 秒、ホーム画面では約 0.4–0.5 秒）。要素を指定するコマンドは、要素を探すスナップショットで表示もわかるので、余分な調べはありません。
