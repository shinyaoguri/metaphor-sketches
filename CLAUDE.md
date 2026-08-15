# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリの位置づけ

実際のコンテンツ事例を溜めながら [metaphor](https://github.com/shinyaoguri/metaphor) /
[metaphor-cli](https://github.com/shinyaoguri/metaphor-cli) の動作を確認するスケッチブック。
**作品を作ること自体が上流ライブラリの検証**であり、作品が動いた時点では終わらない。

## 作品 1 つのライフサイクル

1. `metaphor new` で作品を作り、作品の README と `PROJECT_BRIEF.md` に**意図と想定する動作**を書く
2. **このリポジトリに検証 issue を 1 件立てる**（テンプレート: 作品の検証記録）。
   着手時に「**この作品で検証できる metaphor の API・機能**」を列挙する — 作品を作ることは
   API のカバレッジ選択なので、何を通すつもりかを先に決めてから実装に入る
3. metaphor-cli の MCP（`snapshot` / `build_status`）と人間の目視の両方で、想定どおりかを確認する
4. 結果を **API ごとに issue へ逐次追記**する。**動作確認の詳細はこのリポジトリの issue が一次記録**
5. そこで機能・仕様の問題が見つかったら **metaphor / metaphor-cli へ Issue を立てる**（上流 = 問題の報告先）
6. README の索引表を更新する（検証 issue と、踏んだ上流 Issue へのリンク）

**見た目を伴うものには必ず Gyazo で撮影した画像を添付する。** 動きが分からないと正誤を判定できないもの
（アニメーション・遷移・インタラクション・時間依存の描画）は GIF も撮る。リポジトリに画像はコミットせず
URL を貼る（撮影手順は gyazo-capture スキル）。これは本リポの issue でも上流への報告でも同じ。

運用方針（main 直 push・1 作品 1 コミット・独立リポへの昇格）は [README.md](README.md) の
「運用」節が正本。ここでは繰り返さない。

## 作業の入口

**スケッチの実装作業は作品ディレクトリで行う。** リポジトリ直下に `Package.swift` は無く、
各作品 `2026/<MMDD>-<作品名>/` が独立した SwiftPM パッケージ。

```bash
cd 2026/0816-adversary   # 以降はこのディレクトリで作業する
```

作品ディレクトリの `AGENTS.md`（同じディレクトリの `CLAUDE.md` が `@AGENTS.md` で import している）が
スケッチ作業の正本で、observe → edit → verify ループ・`metaphor` MCP ツール
（`snapshot` / `build_status` / `api_reference` / `input`）・`probe()` の使い方が書いてある。
**metaphor の API を書く前に必ずその作品の `api_reference` を引く**（理由は下記）。

## リポジトリ横断のコマンド

全作品の一括リビルド（metaphor 更新時の互換確認）:

```bash
find . -name Package.swift -maxdepth 3 -execdir swift build \;
```

新しい作品（テンプレートは 2d/3d/shader/live/audio-reactive/raytracing/syphon）:

```bash
metaphor new 0718-hello --path 2026 --template 2d
```

CI は無い。検証は手元のこの一括リビルドで行う。macOS 14+ と Metal が前提。

## 非自明な注意

- **作品ごとに metaphor のバージョンが違う**（0.7.0 の作品と 0.9.0 の作品が同居）。
  API・既定値・バグの有無が作品を跨いで変わるので、他の作品の `App.swift` を参考にするときは
  その作品が pin しているバージョンを確認する。`api_reference` はその作品の依存版を読むので安全
- **バージョンを実際に固定しているのは `Package.resolved`**。`Package.swift` は `from: "X.Y.Z"` で
  「次の major 未満」を許容する宣言であり、0.x では minor 更新にも破壊的変更が入りうる。
  互換確認の意図がない限り `swift package update` を走らせない
- **`metaphor watch` の高頻度ホットリロードで踏んだ穴がある** — ビューアが
  「新しいフレームを待機中…」から復帰しなくなる（[cli#139](https://github.com/shinyaoguri/metaphor-cli/issues/139)）、
  スケッチが SIGTERM で即死して Syphon サーバがゾンビとして残る
  （[#715](https://github.com/shinyaoguri/metaphor/issues/715)）。
  snapshot が古い・別物に見えるときは `build_status` で編集が通ったかをまず確認する
- **`fill(0–255)` と `Color`（0…1 正規化）が同一スケッチ内で混在する**。スケールの取り違えに注意
- `2026/0802-plugin-test` と `2026/0811-sketch-01` は `metaphor new` の雛形のまま未追跡で残っている
  （CLI のスモークテストの残骸）。コミット対象ではない

## コード内のコメント言語

生成される `App.swift` のコメントは日本語、`AGENTS.md` と各作品の `README.md` は英語という
分担が `metaphor new` のテンプレートで意図されている。コードを編集するときはコメントを日本語で書く。
