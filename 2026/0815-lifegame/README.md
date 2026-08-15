# 0815-lifegame

三次元ライフゲーム。暗い宇宙に浮かぶ立方体の培養槽の中で、細胞群が生まれ・群体になり・崩れていく。
生死は 3D セルオートマトン（26 近傍・多状態）で決まり、表示強度を実時間で補間して滑らかに明滅する。
作品の意図・仕組みは [PROJECT_BRIEF.md](PROJECT_BRIEF.md) を参照。

- ルール: `pyroclastic` / `amoeba` / `445` / `coral` / `architecture` / `crystal`
  （表記は `生存 / 誕生 / 状態数`。切り替えると、そのルールが育つ初期条件へ揃えて蒔き直す）
- 操作: マウス移動で視点、`SPACE` 一時停止、`R` 蒔き直し、`N` 1 世代進める
- 調整: `@Param`（`metaphor mcp` の `set_param` か `gui.params()`）で格子サイズ・ステップ間隔・
  Bloom・トーラス境界・表面のみ描画などを再ビルドなしに変更できる

A metaphor sketch generated with:

```bash
metaphor new 0815-lifegame --template 2d
```

## Run

```bash
metaphor watch --viewer   # live-reload window (recommended while iterating)
swift run                 # plain SwiftPM run, no metaphor-cli needed
```

The sketch entry point is `Sources/Sketch0815Lifegame/App.swift`.

## AI-assisted iteration

This project ships ready for AI-assisted development. `.mcp.json` is included, so
Claude Code / Cursor / VS Code auto-connect to the `metaphor` MCP server and can
observe the running sketch (`snapshot`), check builds (`build_status`), and read the
API (`api_reference`). Start with `AGENTS.md`, and keep the creative target in
`PROJECT_BRIEF.md`.

`.mcp.json` launches the `metaphor` CLI found on your `PATH` — check that
`which metaphor` resolves (otherwise the MCP connection fails silently).

## Feedback

Found a bug or something confusing — in the library, the CLI, or the docs? Please
report it casually, however small:
[metaphor issues](https://github.com/shinyaoguri/metaphor/issues) ·
[metaphor-cli issues](https://github.com/shinyaoguri/metaphor-cli/issues)
