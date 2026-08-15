# 0815-salvage

沈んだ構造物から動力コアを回収して脱出する、3 ステージの 3D ゲーム。

metaphor の**作品駆動検証**（[Epic #414](https://github.com/shinyaoguri/metaphor/issues/414)）の **2 本目**。
1 本目 [`0815-strata`](../0815-strata/) が残した 2 つの宿題に答えるために作っている。

1. **シーンごとにアセットが入れ替わる型**にして
   [#571](https://github.com/shinyaoguri/metaphor/issues/571)「Scene = 寿命境界」の要否を判定する
   （1 本目はシーンがリソースを持たず、判定材料が出なかった）
2. **AI 単独制作実験**（ロードマップ決定 7）— 人間の目視に頼らず Probe で自己検証しながら作り、
   詰まりを全部ライブラリへ Issue として返す

## 遊び方

```bash
swift build && swift run          # 手で遊ぶ
SALVAGE_DEMO=1 swift run          # 自動操縦（無人で巡回する）
```

- `W A S D` / 矢印キー … 移動（慣性あり）
- `space` … 開始・決定
- `1` `2` `3` … ステージ直行（検証用）、`t` … タイトルへ
- `h` … HUD、`g` … パラメータ GUI

制限時間内にステージ上のコアを全部拾うと次のステージへ。障害物に当たるとライフが減り、
0 になるか時間切れで失敗。3 ステージ踏破で `SALVAGE COMPLETE`。

| シーン | 固有アセット | 内容 |
|---|---|---|
| `title` | なし（共有のみ） | ロゴとドローン |
| `hull` | `rock_hull.obj` / `floor_hull.png` / `amb_hull.wav` / `backdrop_hull.mp4` | 広い船体。障害はゆっくり |
| `reactor` | `pillar_reactor.obj` / `floor_reactor.png` / `amb_reactor.wav` | 柱が林立し、速い |
| `vent` | `shard_vent.obj` / `floor_vent.png` / `amb_vent.wav` | 破片が速く漂う |
| `result` | なし（共有のみ） | 回収数と踏破ステージ |

共有アセット（`drone.obj` / `core.obj` / `beacon.obj` / SE 2 本）は起動時に 1 度だけ読み、最後まで生かす。

## アセットは全部その場で生成している

```bash
python3 scripts/gen-assets.py     # 依存は標準ライブラリ + ffmpeg（動画のみ）
```

`.obj`（手続き生成のメッシュ）・`.png`（zlib で直書き）・`.wav`（`wave` で合成）・`.mp4`（ffmpeg）を
決定論的に生成し、`Sources/Sketch0815Salvage/Resources/` へコミットしている。
実行時生成にしないのは、**アセット経路そのもの**（ファイル → バンドル → `loadModel` /
`loadImage` / `loadSound` / `loadVideo`）がこの作品の検証対象だから。

`Package.swift` は `.copy("Resources")`（`.process` はサブディレクトリ構成を保証しない）。
参照は Examples と同じ `Bundle.module.path(forResource:ofType:inDirectory:)`。

## 寿命境界の設計（#571 の叩き台を作品側で書いたもの）

```
SceneDirector ──(切替)──> SceneScope ──(release)──> StageAssets.unload()
                                   └─ every() で登録した周期タスクも止まる
```

- `PlayScene.enter` が `StageAssets` を作り、**`scope.own(assets)` に預ける**
- `SceneDirector.go` は次のシーンへ移る前に `scope.release()` を呼ぶ
- `StageAssets.unload()` は **`stop()` してから参照を捨てる**。音と動画は参照を落とすだけでは
  止まらない（内部で AVAudioEngine / AVPlayer が回り続ける）
- ライブラリのキャッシュ（`loadModel(cache:)` / `loadImage(cache:)`）を使うと解放が効かなくなるため、
  既定は `cache: false`。`SALVAGE_ASSET_CACHE=1` で既定どおりに切り替えて比較できる

生存アセット数・ロード回数・解放回数は HUD 右下と Probe（`assetsLive` / `assetsLoads` /
`assetsFrees`）に出している。**ライブラリ側に「いま生きているアセット」を答える API が無い**ので、
作品側で数えている。

## 検証

```bash
bash scripts/shots.sh              # 全シーンの絵を Probe で 1 枚ずつ撮る
bash scripts/probe-snap.sh <label> # 実行中のスケッチから 1 フレーム + performance
bash scripts/soak.sh 1800 off      # 30 分ソーク（cache=off / library で比較）
```

環境変数（検証用の入口）:

| 変数 | 効果 |
|---|---|
| `SALVAGE_DEMO=1` | 自動操縦。無人でステージを巡回する |
| `SALVAGE_START=title\|hull\|reactor\|vent\|result` | 任意のシーンから起動する |
| `SALVAGE_ASSET_CACHE=1` | ライブラリのキャッシュを使う（既定は使わない） |
| `SALVAGE_PRIMITIVES=1` | 読み込んだ Mesh の代わりに組み込みプリミティブを描く |
| `SALVAGE_NO_CAMERA=1` / `SALVAGE_NO_SHADOWS=1` / `SALVAGE_POSTFX=none` | それぞれ切って切り分ける |
| `SALVAGE_SYPHON` / `SALVAGE_FULLSCREEN` / `SALVAGE_WIDTH` / `SALVAGE_HEIGHT` / `SALVAGE_WORKDIR` | 常設運用 |

`SALVAGE_START` と `SALVAGE_PRIMITIVES` は**この実験のために作品側へ開けた口**で、
「AI が自分で絵を確かめる」には（1）任意の状態から起動できること、（2）ライブラリ側と
アセット側を切り分けられること、の 2 つが要る、という所見でもある。

## 検証結果

### 各シーン（Probe で撮影・AI が判定）

| title | hull | reactor | vent | result |
|---|---|---|---|---|
| ![title](https://i.gyazo.com/9ec8e33ce84e9674ffe06039d2d4aae2.png) | ![hull](https://i.gyazo.com/61b240e1fddbea67acefa0d666f10129.png) | ![reactor](https://i.gyazo.com/023431cc410b3251af90aac9aacab4ff.png) | ![vent](https://i.gyazo.com/37aa69ed3ddfde9930d41ea3ca8e8b66.png) | ![result](https://i.gyazo.com/d2b8feb482c8b865bd14f7fbc7495a89.png) |

### ステージ遷移 = アセットの入れ替え

![hull から reactor への遷移](https://i.gyazo.com/6880d178fe5d0f61c2ecc4c5ed68689a.gif)

`hull` をクリアして `reactor` へ移る 6.4 秒（Probe の連続キャプチャ 64 フレーム・`every=6`）。
遷移の 1 フレームで `hull` のモデル・床テクスチャ・環境音・背景動画が解放され、
`reactor` の一式が読み込まれる。HUD 右下の `assets live / loads / frees` がそこで動くのが見える。

### 30 分ソーク（`cache=off`・自動操縦）

178 サンプル（1,799 秒・10 秒間隔）、Probe の応答 timeout 0 件。

| 指標 | 全体 | 前半 → 後半 |
|---|---|---|
| fps | mean 59.8（min 57.0 / max 60.5） | 59.8 → 59.8（±0.0） |
| frameTimeMs.mean | 16.8ms | 16.8 → 16.8 |
| frameTimeMs.max | mean 21.6ms（最大 67.4ms） | 21.8 → 21.4 |
| memoryMB | mean 464.8（min 416.3 / max 616.5） | 457.0 → 472.6（**+15.6MB**） |
| cpuPercent | mean 12.6% | 13.1 → 12.1 |
| アセットのロード時間 | mean 15.7ms（min 6.0 / max 29.8） | 16.4 → 15.1 |

- **47 周・238 シーン遷移・485 ロード / 477 解放**（差 8 = そのとき生きている共有 5 + ステージ 3）
- `assetsLive` は 5〜9 の間で振動し、**周回とともに増えない** = 解放は効いている
- メモリは 30 分で +15.6MB。ロード 485 回に対する増分としては小さく、単調増加でもない
- ただし **4〜5 分おきに +160MB のスパイク**（433 → 593MB）が 10〜20 秒出て戻る。
  同時に `frameTimeMs.max` も 40〜67ms へ伸びる。原因は未特定（1 本目 `0815-strata` では出なかった挙動）

### 対照: `cache=library`（7 分・42 サンプル）

ライブラリのキャッシュ（`loadModel(cache: true)` / `loadImage(cache: true)`）に任せた場合。

| 指標 | `cache=off`（30 分） | `cache=library`（7 分） |
|---|---|---|
| fps | 59.8 | 59.8 |
| memoryMB | mean 464.8（max 616.5・**+160MB のスパイクあり**） | mean 432.1（max 434.8・**スパイクなし**） |
| アセットのロード時間 | mean 15.7ms | mean 9.5ms（2 周目以降はキャッシュヒット） |
| 生存アセット | 5〜9 で振動 | 5〜9 で振動（**台帳上は**解放されるが実体はキャッシュに残る） |

**キャッシュを使うほうがメモリも時間も安定する**。`cache=off` のスパイクは、周回ごとの
解放 → 再確保のサイクルに起因すると見ている。一方でキャッシュは寿命境界を無効化するので、
ステージ数が増えるほど積み上がる（この作品は 3 ステージなので上限が小さい）。
**「シーンのスコープでキャッシュする」中間が無い**のが、#571 に書き戻した論点のひとつ。

## 制作ログ（AI 単独制作実験）

企画・実装・検証・記録をすべて AI（Claude Code）が行い、人間には**題材や実装方針を一度も
確認していない**（唯一の人間とのやり取りは、承認済みプランがリポジトリをまたいだ際の
plan-gate の扱い 1 回）。絵の確認は Probe のスナップショットを AI 自身が読んで判断した。

### 踏んだ穴

| 層 | 事象 | Issue |
|---|---|---|
| 3D | IBL が無いため `metallic` を上げると拡散が消え、埋める環境光が無く灰色に潰れる。機体を金属にしようとして 0.72 を指定したら「灰色の塊」になり、0.16 まで下げて初めて形が見えた | [#293](https://github.com/shinyaoguri/metaphor/issues/293) へ実需 |
| 3D | `emissive` / `specular` に 0..255 の 3 引数版が無く `fill` と書き味が揃わない | [#700](https://github.com/shinyaoguri/metaphor/issues/700) |
| 映像 | `VideoPlayer` を 3D のテクスチャとして貼れない。背景は 2D の書き割りで回避 | [#701](https://github.com/shinyaoguri/metaphor/issues/701) |
| 並行性 | `Sketch` の外にアセットを持つ型は `@MainActor` が要る。最初のビルドのエラー 14 件が全部これ | [#702](https://github.com/shinyaoguri/metaphor/issues/702) |
| 観測 | ゲームなので**状態に到達しないと絵が見られない**。`SALVAGE_START` と自動操縦を作品側に自作した | [#563](https://github.com/shinyaoguri/metaphor/issues/563) |

自分のバグ（ライブラリのせいではないもの）も記録しておく:

- **モデルの上下が逆**。metaphor の 3D は +Y が画面下なので、モデル空間で「上」に作った塔が
  地面へ潜った。`gen-assets.py` の書き出し時に Y と面の巻き順をまとめて反転して解決
- **カメラがプレイヤーを追っていなかった**（`player.pos * 0.55` のような中途半端な補間を書いた）
- **HUD が二重**（左上パネルと中央テキスト）。どちらも `stats` の数値には出ず、画像を見て気づいた
- **影が出ていないと思い込んだ**。`enableShadows()` を入れても床に影が見えず、
  「プリミティブに置換」「`camera()` を外す」「ライト 1 灯 + 低 ambient」「`shadowBias` を 1/25」と
  4 回切り分けた末、真因は**床テクスチャが暗すぎて落ちた影と見分けが付かなかった**こと。
  テクスチャの基調を中間調へ上げたら、どの条件でも影は最初から出ていたと分かった。
  この過程で作った切り分けスイッチ（`SALVAGE_PRIMITIVES` / `SALVAGE_NO_CAMERA` /
  `SALVAGE_KEY_LIGHT_ONLY` / `SALVAGE_SHADOW_BIAS` / `SALVAGE_SHADOW_DEBUG`）はそのまま残してある

  | 暗い床テクスチャを貼った状態（影が埋もれる） | 床のテクスチャを外した状態・既定 bias（影が見える） |
  |---|---|
  | ![影が見えない](https://i.gyazo.com/4aa1697f62930e60d1057d716e92eb65.png) | ![影が見える](https://i.gyazo.com/04de8bf6bda1b221c1514af247895982.png) |

  最終的にはテクスチャを貼ったまま基調を上げることで、両立させた（上の各シーンの絵）。
- **アセットを作り直しただけでは絵が変わらない**。リソースはビルド時にバンドルへコピーされるので、
  `gen-assets.py` を回したら `swift build` が要る（1 回これで「テクスチャを明るくしたのに変わらない」と混乱した）

### 数値で判る不具合と、画像を見ないと判らない不具合

| 判定 | 手段 |
|---|---|
| 真っ黒・描画されていない | `stats.contentFraction`（0.03〜0.05 = ほぼ空） |
| 暗すぎる | `stats.meanLuminance`（0.04 台 = 暗い / 0.13〜0.16 = 意図どおり） |
| アセットが読めていない | 作品側の `assetsLive` / `assetFailures` |
| **機体に見えない・紛れて見えない・上下が逆** | **画像を読む以外に無い** |

詳細は Epic #414 のコメントにまとめている。
