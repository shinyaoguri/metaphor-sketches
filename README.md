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
| [2026/0718-hello](2026/0718-hello/) | 2d | 0.5.3 | scaffold→build→Probe 検証 green。installer 残骸でテンプレートが古く生成される問題を発見 → [cli#69](https://github.com/shinyaoguri/metaphor-cli/issues/69)、.gitignore に `.metaphor/` が無い → [cli#70](https://github.com/shinyaoguri/metaphor-cli/issues/70) |
