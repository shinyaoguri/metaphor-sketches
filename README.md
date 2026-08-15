# metaphor-sketches

[metaphor](https://github.com/shinyaoguri/metaphor) / [metaphor-cli](https://github.com/shinyaoguri/metaphor-cli) を実運用しながら作品を作るスケッチブック。
使い勝手・動作の穴に気付いたら、その場で各リポジトリへ Issue を立て、下の索引にも記録する。

## 構成

```
<年>/<MMDD>-<作品名>/   # 各作品は metaphor new が生成する自己完結 SwiftPM パッケージ
```

作品ディレクトリはそれぞれ独立にビルド・実行でき、`Package.swift` が当時の metaphor バージョンに pin される。
metaphor 更新時の互換確認は全作品の一括リビルドで行える:

```bash
find . -name Package.swift -maxdepth 3 -execdir swift build \;
```

## 新しい作品

```bash
metaphor new 0718-hello --path 2026 --template 2d   # 2d/3d/shader/live/audio-reactive/raytracing/syphon
cd 2026/0718-hello
metaphor watch    # ライブビューア + ホットリロード（単発実行は metaphor run）
```

各作品には `.mcp.json`（`metaphor mcp .`）が生成されるので、作品ディレクトリで Claude Code を開けばそのまま AI 協調（観測 → 編集 → 再観測）ができる。

## 運用

- **main 直 push**（PR レス）。実験の摩擦を最小にするため、ライブラリ側の GitHub Flow とは意図的に変えている
- 1 作品 1 コミットを目安に、作品の追記・改変は自由
- metaphor / metaphor-cli の不具合・使いにくさは各リポジトリへ Issue を立て、索引の「気付き」列に残す
- 公開したい作品・アセットが重い作品・長期に育てる作品は、独立リポジトリへ昇格させる（`git subtree split` で履歴ごと切り出せる）

## 索引

| 作品 | テンプレート | metaphor | 気付き / 踏んだ Issue |
|---|---|---|---|
| [2026/0718-hello](2026/0718-hello/) | 2d | 0.7.0 | scaffold→build→Probe 検証 green。installer 残骸でテンプレートが古く生成される問題を発見 → [cli#69](https://github.com/shinyaoguri/metaphor-cli/issues/69)、.gitignore に `.metaphor/` が無い → [cli#70](https://github.com/shinyaoguri/metaphor-cli/issues/70)（いずれも v0.4.0 で解決済み）。v0.7.0 bump 時に frame.json `performance`（[#271](https://github.com/shinyaoguri/metaphor/issues/271)）の軽負荷対照を確認（60fps・cpuPercent が初回=起動平均→区間平均に切替） |
| [2026/0815-strata](2026/0815-strata/) | 2d→自作 3D | 0.9.0 | **作品駆動検証（[#414](https://github.com/shinyaoguri/metaphor/issues/414)）のリファレンス作品**。生成的地形を 4 シーンで巡回、入力はカメラ + OSC、単体アプリ常設と Syphon 送出の両対応。30 分無人稼働を通過。踏んだ穴: `VignetteEffect` の intensity が半径で意味が逆 → [#684](https://github.com/shinyaoguri/metaphor/issues/684)、`CaptureDevice` が権限未定でも `isAvailable=true` でフレーム 0 → [#685](https://github.com/shinyaoguri/metaphor/issues/685)、`DynamicMesh` が毎フレーム再確保 → [#686](https://github.com/shinyaoguri/metaphor/issues/686)、ライトに intensity が無く PBR 単灯が沈む → [#687](https://github.com/shinyaoguri/metaphor/issues/687)、`.app` 起動で cwd が `/` になり `.metaphor/` が壊れる → [#688](https://github.com/shinyaoguri/metaphor/issues/688) / [cli#133](https://github.com/shinyaoguri/metaphor-cli/issues/133)。既存の検討 Issue [#573](https://github.com/shinyaoguri/metaphor/issues/573) / [#571](https://github.com/shinyaoguri/metaphor/issues/571) へ実測を書き戻し |
| [2026/0815-salvage](2026/0815-salvage/) | 3d→自作 3D | 0.9.0 | **作品駆動検証の 2 本目 = AI 単独制作実験（[#414](https://github.com/shinyaoguri/metaphor/issues/414)）**。3 ステージの 3D ゲームで、シーンごとにモデル / 床テクスチャ / 環境音 / 背景動画が丸ごと入れ替わる（[#571](https://github.com/shinyaoguri/metaphor/issues/571) の寿命境界を判定するための型）。アセットは全部 `gen-assets.py` で手続き生成。30 分ソークで 47 周・485 ロード / 477 解放・fps 60 維持。踏んだ穴: IBL が無く metallic が死に機能 → [#293](https://github.com/shinyaoguri/metaphor/issues/293) へ実需、`emissive` に 3 引数版が無い → [#700](https://github.com/shinyaoguri/metaphor/issues/700)、動画を 3D テクスチャに貼れない → [#701](https://github.com/shinyaoguri/metaphor/issues/701)、`Sketch` 外の型に `@MainActor` が要る → [#702](https://github.com/shinyaoguri/metaphor/issues/702) |
| [2026/0718-memory-stress](2026/0718-memory-stress/) | 3d | 0.7.0 | フェーズ制メモリ/性能ストレスハーネス。リークなしを確認。App Nap で fps 1/6 → [#266](https://github.com/shinyaoguri/metaphor/issues/266)（v0.6.0 のライブラリ既定抑止で解決、bump 時に再検証済み）、pixels 経路 +145MB 常駐 → [#267](https://github.com/shinyaoguri/metaphor/issues/267)、9万頂点/フレーム 40fps 上限 → [#268](https://github.com/shinyaoguri/metaphor/issues/268)。v0.7.0 の frame.json `performance`（[#271](https://github.com/shinyaoguri/metaphor/issues/271)）をフェーズ横断 65 サンプルで検証: memoryMB は自前 task_vm_info 計測と一致（差 ≤0.2MB）、fps=40 が #268 の release 実測・自己計測と三者一致、#267 の常駐も +141MB として再観測、起動直後の fps/frameTimeMs 省略も仕様どおり |
