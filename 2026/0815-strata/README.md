# 0815-strata

地層が **隆起 → 浸食 → 露出 → 沈静** を繰り返す生成的地形。無人でも自律的に巡回し続ける。

metaphor の作品駆動検証（[metaphor#414](https://github.com/shinyaoguri/metaphor/issues/414)）の
リファレンス作品。「29 行のスケッチ」ではなく **複数シーン + 複数入力 + 30 分無人稼働** を
満たす 1 本を作り切り、その過程で踏んだ穴をライブラリへ返すのが目的。
絵そのものと同じくらい、下の「踏んだ穴」節が成果物。

| シーン | 内容 | |
|---|---|---|
| `formation` | 地形が立ち上がり、稜線が伸びる | ![formation](https://i.gyazo.com/e47bf2fb8a482cd7f4f049c90475ff7b.png) |
| `erosion` | 谷が刻まれ、彩度が抜けて寒色へ寄る | ![erosion](https://i.gyazo.com/757b48dd81029376b70bd33821516f78.png) |
| `strata` | 段丘化して地層の縞が主役になる | ![strata](https://i.gyazo.com/62c8544ccd0ac60b47ca4f04f6974696.png) |
| `dormant` | 遠景をゆっくり周回する低負荷シーン | ![dormant](https://i.gyazo.com/2d76e84c63151de1ce3d8add71626bee.png) |

遷移（`strata` → `dormant`）:

![strata から dormant への遷移](https://i.gyazo.com/67fa650c3a168960b43d36b7b7170e95.gif)

撮影範囲: Probe の連続キャプチャ（スケッチの描画そのもの。他アプリ・通知は含まない）。
意図: OSC で `/scene 3` を送った直後の約 5.3 秒。段丘（`terrace`）が均され、カメラが引き、
色温度が寒色へ寄るまでが**シーンごとの分岐ではなく profile の補間 1 本**で起きていることを見てほしい。
左上の HUD の `transition` が 0→100% に進む。

## 動かす

```bash
swift run            # 手早く見る（カメラ入力は効かない。下記「踏んだ穴 4」）
metaphor watch       # ライブビューア + ホットリロード（Syphon 経由で受信）
./scripts/make-app.sh release && open -n .build/strata.app --env "STRATA_WORKDIR=$PWD"
                     # 常設運用に近い形。カメラ入力が効くのはこれだけ
```

### 操作

| キー | 動作 |
|---|---|
| `space` | 次のシーンへ |
| `1`〜`4` | シーンを直接指定 |
| `r` | 地形の静的成分を作り直す |
| `h` / `g` | HUD / パラメータ GUI の表示切替 |

### 環境変数

| 変数 | 既定 | 意味 |
|---|---|---|
| `STRATA_SYPHON` | 無効 | `1` で Syphon 出力（名前を書けばその名前） |
| `STRATA_FULLSCREEN` | 無効 | `1` で全画面起動 |
| `STRATA_WORKDIR` | — | `.metaphor/` の置き場。**`.app` 起動では必須**（cwd が `/` になる） |
| `STRATA_GRID` | 128 | ハイトフィールドの一辺の頂点数 |
| `STRATA_HOLD` | 90 | 各シーンの保持秒数 |
| `STRATA_TRANSITION` | 6 | 遷移にかける秒数 |
| `STRATA_OSC_PORT` | 9000 | OSC 受信ポート |
| `STRATA_POSTFX` | 全部 | `none` / `bloom,vignette,grade` から選ぶ（切り分け用） |
| `STRATA_NO_CAMERA` | 無効 | `1` でカメラを開かない |

### OSC

```bash
python3 scripts/osc-send.py /scene 2              # index か名前でシーン指定
python3 scripts/osc-send.py /scene/next
python3 scripts/osc-send.py /param/elevationScale 1.4
python3 scripts/osc-send.py /regenerate
python3 scripts/osc-send.py /ping
```

`/param/<name>` は Parameter Store へ直接書く。GUI のスライダ・AI エージェント
（`.metaphor/params/set-request.json`）と**同じストアの対称なクライアント**になっていて、
レンジのクランプはストア側が受け持つ。

## 構造

```
Sources/Sketch0815Strata/
  App.swift          Sketch 本体。config / 入力の取り回し / 描画の各段 / Probe 出力
  Terrain.swift      DynamicMesh のハイトフィールド（16,384 頂点 / 32,258 三角形）
  Scenes.swift       SceneProfile（値の束）+ 4 シーン + 手書きの SceneDirector
  CameraSense.swift  カメラを「センサ」として使う（輝度・動き量）
  OSCControl.swift   OSC を「外部からの演出指示」として受ける
```

設計上の要点:

- **地形は静的成分と動的成分を分ける**。多層ノイズ（地形・稜線・浸食チャンネル）は
  生成時に一度だけ計算し、毎フレームは「静的成分をシーンの profile で合成し直す」だけ。
  16k 頂点 × 60fps で fBm を引き直すと CPU が律速する
- **シーンは描画コードの分岐ではなく profile（値の束）**。遷移は 2 つの profile の補間で行う。
  地形を 2 枚描いてクロスフェードすると頂点更新が倍になるため
- **入力が死んでも作品は止まらない**。カメラの権限が無くても、OSC のポートが埋まっていても、
  自律タイマーで巡回し続ける（常設で「入力が死んだ日に真っ黒」は許されない）

## 検証

```bash
./scripts/probe-snap.sh <label>          # 実行中スケッチから 1 フレーム + performance
./scripts/soak.sh 1800 out.csv           # 30 分の無人稼働ソーク → CSV → 判定
python3 scripts/soak-report.py out.csv   # CSV の読み直しだけ
```

ソークは 10 秒ごとに Probe へ 1 リクエストを出して `performance`（fps / frameTimeMs /
memoryMB / cpuPercent / thermalState）を CSV へ積み、並行して OSC を流す。
`performance` は**単一フレーム経路にしか載らない**（metaphor の `CONTRACT.md` 契約点 4）ので、
連続キャプチャではなく request 方式にしてある。

### 30 分無人稼働の結果

2026-08-15 / metaphor v0.9.0 / M シリーズ Mac / `.app` 起動・1920×1080・Syphon 出力あり・
カメラ入力あり・OSC 駆動あり。10 秒ごとに 177 サンプル（1,796 秒）。

| 指標 | 全体 | 前半 → 後半 |
|---|---|---|
| fps | mean 60.0（min 59.9 / max 60.1） | 60.0 → 60.0（Δ -0.0） |
| frameTimeMs.mean | 16.7ms | 16.7 → 16.7 |
| frameTimeMs.max | mean 17.5ms（最大 27.0ms） | 17.6 → 17.4 |
| memoryMB | mean 686.5（min 643.2 / max 694.6） | 683.7 → 689.2（Δ **+5.5MB**） |
| cpuPercent | mean 49.9%（1 コア = 100%） | 49.2 → 50.5 |
| thermalState | 全サンプル `nominal` | — |

- **fps 劣化なし**。30 分間 60fps を維持し、前半後半の差は測定誤差の範囲
- **メモリは有界**。起動直後 643MB から 10 分ほどで 685MB 前後へ立ち上がり、そこで頭打ち。
  後半 15 分の増加は +5.5MB で、傾きはほぼ寝ている（経路初回確保の常駐プールであって
  解放されない蓄積ではない、という読み）
- **入力は 30 分間死なない**。カメラ 18,061 サンプル（毎フレームではなく 6 フレームに 1 回）、
  OSC 220 メッセージ、Probe の応答 timeout 0 件
- **巡回は止まらない**。シーン切替 29 回（自律タイマー + OSC の二重駆動）。
  4 シーンとも出現している（formation 71 / strata 63 / erosion 22 / dormant 21 サンプル）

690MB という常駐量そのものは、1920×1080 のオフスクリーン + Syphon + カメラ + 16k 頂点の
毎フレーム再確保（[metaphor#686](https://github.com/shinyaoguri/metaphor/issues/686)）を
考えれば妥当な水準。**増え続けないこと**が無人稼働の合否なので、そこは満たしている。

再現:

```bash
./scripts/soak.sh 1800 out.csv
```

## 踏んだ穴

作品を作り切る過程で見つかった、ライブラリ／CLI 側の穴。**回避策で握り潰さず、
作品側にコメントとして残したうえで Issue にしている**（これが本作の主目的）。

1. **`VignetteEffect` の `intensity` は「強度」ではなく「黒に落ちきる半径」で、しかも値が大きいほど弱い。**
   シェーダは `smoothstep(intensity, intensity - smoothness, dist)`、`dist` は中心 0 〜 隅 0.707。
   既定の `intensity: 0.5` では画面の大半が真っ黒になる。ドキュメントは「エフェクト強度」と
   書いてあるので、素直に 0.4 を渡すと絵が消える。作品側では素直な 0..1 の強度で持ち、
   `1.2 - strength * 0.55` で半径へ写している（`App.swift` の `applyPostEffects`）

2. **PBR が単灯では物理的に暗い。** 直接光は `albedo / π` で入り、IBL のフォールバックも
   `ambientColor * albedo` だけ。加えて `directionalLight` に強度引数が無く固定 1.0 なので、
   キーライト 1 灯だとどう調整しても沈む。作品側はキー + フィル + リムの 3 灯 + 高めの
   ambient で成立させている

3. **ポストエフェクトは HUD にも一律で掛かり、UI だけ外せない。** 上記 1 と重なると
   「HUD が消えたのはコードのバグか、ポストのせいか」が切り分けられない。
   作品側は `STRATA_POSTFX` で個別に落とせるようにして切り分けた

4. **`swift run` の実行ファイルではカメラ（TCC）の許可が取れない。**
   `metaphor new` が作るのは素の SwiftPM 実行ファイルで `.app` ではないため、
   macOS は許可ダイアログを出さず `AVCaptureDevice.authorizationStatus` は
   `notDetermined` のまま動かない。**それでも `CaptureDevice.isAvailable` は `true` を返し、
   フレームが 1 枚も来ないまま無言で失敗する**。`scripts/make-app.sh` で
   `Info.plist`（`NSCameraUsageDescription`）付きの `.app` に包むと `authorized` になり
   フレームが流れ出す

5. **`.app` 化の経路が用意されていない。** 4 の回避に必要な `Info.plist` / 署名 /
   `Syphon.framework` の同梱（`@rpath` は実行ファイルの隣を見る）は全部自前。
   常設運用（ログイン項目・クラッシュ後の自動復帰・Dock からの起動）は `.app` が前提なので、
   単体アプリとして展示するなら誰もがここを通る

6. **`.app` から起動すると cwd が `/` になり、Probe と Parameter Store の置き場が壊れる。**
   どちらも cwd 相対のファイル契約なので、作品側に `STRATA_WORKDIR` を足して
   `changeCurrentDirectoryPath` する羽目になった

7. **`DynamicMesh` に in-place 更新の経路が無い。** `ensureBuffers()` は dirty なら
   毎回 `device.makeBuffer(bytes:)` で確保し直す。頂点だけ動かしても、一度も変わらない
   インデックスバッファ（96,774 要素）まで毎フレーム作り直される

8. **構造層（Scene / 遷移 / cue / スケジューラ）が無い。** `SceneDirector` は
   保持タイマー・遷移の進行・外部指定の受け口を全部手書き（`Scenes.swift` に 70 行ほど）。
   4 シーンで 70 行なので、作品ごとに毎回書き直すことになる

9. **現場層が無い。** マルチディスプレイ指定（`NSScreen`）・常時最前面・スリープ抑止・
   クラッシュ後の自動復帰・GPU コマンドバッファのエラー検知・自己監視 API のいずれも
   ライブラリに無い。本作は「無人稼働で fps とメモリが劣化しないか」を Probe を外から
   叩いて測ったが、**作品自身がそれを読んで degrade する**ことはできない

Probe から自己申告している値（`scene` / `sceneSwitches` / `uptimeSec` / `cameraAuthorization` /
`cameraSamples` / `oscMessages` / `worstFrameMs` 等）は、9 の穴を作品側で埋めた分。

## AI 協調

`.mcp.json` を同梱しているので、このディレクトリで Claude Code を開けば
`snapshot` / `capture_sequence` / `build_status` / `api_reference` がそのまま使える。
`AGENTS.md` と `PROJECT_BRIEF.md` も参照。

## フィードバック

ライブラリ・CLI・ドキュメントの不具合や分かりにくさは気軽に:
[metaphor issues](https://github.com/shinyaoguri/metaphor/issues) ·
[metaphor-cli issues](https://github.com/shinyaoguri/metaphor-cli/issues)
