# 0718-memory-stress

metaphor のメモリ・性能ストレスハーネス。負荷の種類をフェーズで切り替えながら、
自プロセスの phys_footprint（`task_vm_info`）を毎フレーム記録し、フェーズ別サマリを
stdout と Probe（`stress.*`）へ報告する。

## 実行

```bash
swift build -c release
.build/release/Sketch0718MemoryStress
```

環境変数:

- `METAPHOR_STRESS_PHASES` — フェーズ列をカンマ区切りで上書き（同名複数可）。
  利用可能: `warmup` `shapes2d` `shapes3d` `bigGeometry` `text` `pixels` `postfx` `cooldown`
- `METAPHOR_STRESS_CYCLES` — 周回数（既定 2）

例: pixels 経路だけを 2 周検証する

```bash
METAPHOR_STRESS_PHASES="warmup,pixels,cooldown" METAPHOR_STRESS_CYCLES=2 \
  .build/release/Sketch0718MemoryStress
```

## 読み方

- **フェーズ内 slope**（前半平均 → 後半平均）: そのフェーズ固有の蓄積
- **周回間比較**: 2 周目が 1 周目と同水準なら「経路初回確保の常駐プール（有界）」、
  周回ごとに増えるなら「解放されない蓄積（リーク疑い）」
- 最終周の cooldown は外部 `leaks` 検査が完走できるよう 1500 フレーム
- fps 計測時は App Nap に注意（本スケッチは activity assertion で抑止済み）

## 2026-07-18 の結果（metaphor 0.5.3 / release / M系）

- **リークなし**: 2 周比較で無限蓄積なし（1 周目終了 447MB ≒ 2 周目終了 447MB）。
  warmup 320MB → 全経路通過後 450MB の増分は経路初回確保の常駐プール（有界）
- **App Nap**: assertion なしだと thermal=nominal のまま全体が 30〜40fps に間引かれ、
  CPU バウンドの bigGeometry は 6.3fps まで悪化（切り分けに二分探索が必要だった）
  → [metaphor#266](https://github.com/shinyaoguri/metaphor/issues/266)
- **pixels 経路 +145MB 常駐 @720p**（フレームバッファの約 40 倍。周回で増えないが過大）
  → [metaphor#267](https://github.com/shinyaoguri/metaphor/issues/267)
- **9 万 vertex()/フレームは 40fps 上限**（CPU 律速、安定再現）
  → [metaphor#268](https://github.com/shinyaoguri/metaphor/issues/268)
- text（CJK 6,000 種巡回）のグリフキャッシュは 1 周目 +6〜10MB 形成後、2 周目は
  増えない（有界・健全）

## Feedback

Found a bug or something confusing — in the library, the CLI, or the docs? Please
report it casually, however small:
[metaphor issues](https://github.com/shinyaoguri/metaphor/issues) ·
[metaphor-cli issues](https://github.com/shinyaoguri/metaphor-cli/issues)
