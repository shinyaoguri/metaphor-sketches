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
- fps 計測時は App Nap に注意（metaphor v0.6.0 以降はライブラリが既定で抑止
  — [metaphor#266](https://github.com/shinyaoguri/metaphor/issues/266)。本スケッチ自前の assertion は v0.6.0 bump 時に削除）

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

## 2026-07-19 の再検証（metaphor 0.6.0 / release / M系）

- v0.6.0 がライブラリ既定で App Nap を抑止するようになった
  （[metaphor#269](https://github.com/shinyaoguri/metaphor/pull/269)）ため、
  本スケッチ自前の activity assertion を削除して再実行（起動 8 秒後にウィンドウを背面化）
- 背面のまま全フェーズ 60fps を維持 — ライブラリ既定抑止で回帰なし。
  bigGeometry のみ 40fps（[metaphor#268](https://github.com/shinyaoguri/metaphor/issues/268)
  の既知水準）、thermal=nominal
- メモリ挙動は 0.5.3 時と同傾向: リークなし（2 周目 ≒ 1 周目、終了 443MB）、
  pixels 経路の常駐（[metaphor#267](https://github.com/shinyaoguri/metaphor/issues/267)）も同水準で残存

## Feedback

Found a bug or something confusing — in the library, the CLI, or the docs? Please
report it casually, however small:
[metaphor issues](https://github.com/shinyaoguri/metaphor/issues) ·
[metaphor-cli issues](https://github.com/shinyaoguri/metaphor-cli/issues)
