# 座標系とスクリーンショット

タップなどの座標系と画面の向き、スクリーンショットの縮小について説明します。全体の入口は [README](../README.md) です。

## 座標系と画面の向き

- 座標は **前面アプリの表示の向き（interface orientation）での、画面左上を原点とするポイント単位** です。縦向きなら 402×874、横向きなら 874×402 の範囲で指定します（iPhone 17 Pro の場合）。
- 画面の外の座標（`0 ≤ x < screen.width`、`0 ≤ y < screen.height` の外）への `/tap`・`/press`・`/swipe` は、何も送らずに `400` になります（「[画面の外の座標](http-api.md#エンドポイント)」）。縦向きの (500, 100) は iPhone 17 Pro では画面の外ですが、横向き（874×402）では中です。
- `/health` の `screen.width` / `screen.height` はこの向きでの値です。`orientation` は表示の向きを `/orientation` と同じ名前（`portrait` / `portraitUpsideDown` / `landscapeLeft` / `landscapeRight`）で返します。`/orientation landscapeLeft` の後は `"orientation":"landscapeLeft"` になります（UIKit の interface orientation としては `landscapeRight` にあたります。デバイスとインターフェースで左右の名前が逆になるためです）。
- 表示の向きは、端末の向き（`XCUIDevice.orientation`）と一致するとは限りません。横向きの iPhone でもホーム画面は縦のままですし、iPhone のアプリは `portraitUpsideDown` に回転しません。そのため、端末の向きではなく、リクエストのたびに前面アプリの向きを読み直します。`/orientation` を使わずに端末を手で回した場合や、アプリを切り替えた場合にも追従します。
- 向きの取得には非公開の `-[XCUIApplication interfaceOrientation]` を使います（SpringBoard 経由で呼んでも前面アプリの向きが返り、約 1 ms）。使えない場合は、スクリーンショットの `UIImage.imageOrientation` で代用します（約 90 ms）。
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
