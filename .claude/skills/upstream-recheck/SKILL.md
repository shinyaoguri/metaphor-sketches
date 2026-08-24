---
name: upstream-recheck
description: "上流 (metaphor / metaphor-cli) で報告した Issue が直ったかを、こちらの作品の自己検査で再検証し、検証 issue と上流へ書き戻して、開いている PR なら approve するまでの手順。Use when an upstream issue reported from this repository has been closed or fixed, when a new metaphor release appears, when asked whether a reported problem is fixed, or on the weekly upstream check."
---

作品を作って上流へ Issue を出すところまではこのリポジトリの型になっているが、
**出したあとが繋がっていない**。上流で直っても、こちらの検証 issue は「壊れている」と
書かれたまま止まる。それを閉じるための手順。

輪はこう。**検知 → 再検証 → 両方へ報告 → 開いている PR なら approve → 台帳を更新。**

## 台帳が中心

`verification/upstream.json` が全部の起点。上流 Issue 1 件 = 1 エントリで、
**判定手段（oracle）**と**報告時の実測（baseline）**、**直近の再検証（recheck）**を持つ。

- `oracle.kind: "check"` — 作品の自己検査 ID。機械判定できる
- `oracle.kind: "manual"` — 目視や個別手順。`how` に「何を見れば直ったと言えるか」を書く

`sketches` には作品ごとの判定コマンドと、その出力から `PASS` / `FAIL` を拾う正規表現を持たせる
（marionette は標準出力、adversary は frame.json 経由と、出し方が違うため）。

**同じ作品でも検査 ID ごとに出し方が違うことがある。** そのときはエントリ側の
`oracle.verdictCommand` / `oracle.verdictPattern` で上書きする（省略時は `sketches` の設定）。
例: escapement の `I3.pmouse` は入力注入が要るので `tools/probe.sh check` には出ず、
`tools/probe.sh input` で出る。`recheck.py` は必要なコマンドだけを追加で走らせて結果をまとめる。

**上流へ Issue を出したら、その場で台帳へ追加する。** 後からでは baseline が思い出せない。

## 1. 検知

```bash
.claude/skills/upstream-recheck/scripts/upstream-status.py         # 再検証が要るものだけ
.claude/skills/upstream-recheck/scripts/upstream-status.py --all   # 台帳の全件
```

「要る」の判定は 2 つだけ。**閉じているのに未再検証** / **再検証の後に閉じ直された**。

**修正がリリース済みか main 止まりか**も出る。ここが重要で、作品はリリースに pin されているので、
main 止まりのものは `--metaphor-path` でローカルのチェックアウトに差し替えないと確かめられない。
実際 2026-08-16 時点では、直っている修正のほとんどが main 止まりだった。

## 2. 再検証

```bash
.claude/skills/upstream-recheck/scripts/recheck.py 2026/0816-adversary --metaphor-path ~/Repos/metaphor
.claude/skills/upstream-recheck/scripts/recheck.py 2026/0816-marionette --release v0.10.0
.claude/skills/upstream-recheck/scripts/recheck.py 2026/0816-marionette             # 差し替えず現状を測る
```

`swift package edit` で依存を差し替え、ビルドして判定コマンドを走らせ、
**必ず `unedit` で戻す**（中断・失敗・Ctrl-C でも戻す）。pin（`version` / `revision`）は
変わらないので、再検証しても作品は報告時のバージョンのまま。

ただし `Package.resolved` の **`originHash` だけが書き換わることがある**（SwiftPM が
依存グラフの由来を再計算するため）。pin が変わっていなければ意味のある差分ではないので、
`git checkout <作品>/Package.resolved` で捨ててよい。**pin まで変わっていたら捨てずに調べる。**

出るもの:

- 検査ごとの **報告時 → 今回** と、`★ 直った` / `!! 退行` / `変化なし`
- 盤全体の集計（`summary.*`）。**直した箇所の隣で退行していないか**を同じ実行で見る
- ビルドが通らなければそこで停止。**破壊的変更はここで出る**

`manual` のものは台帳の `how` に従って人が確かめる。

### 差し替えても直らないとき

approve しない。**再現条件を添えて上流へ差し戻す。** 「まだ FAIL のままで、実測はこれ」と、
検査 ID と数値をそのまま書く。

## 3. 両方へ報告する

報告先は 2 つ。**こちらの検証 issue（一次記録）**と、**上流の Issue / PR**。

書くこと:

- 差し替えた対象（タグ or コミット SHA）と、判定に使った検査 ID
- **報告時と今回の実測を並べた表**
- リリース済みか main 止まりか
- 見た目が変わるものなら画像（`gyazo-capture` スキル）

**数字は測ったものだけ書く。** 過去の記録と食い違ったら、憶測で埋めずに
「記録は X、今日の実測は Y、内訳が残っていないので確定できない」と書く
（issue #8 で実際にこれが起きた）。

## 4. PR を通す

**開いている PR なら `gh pr review --approve`** に検証結果を添える。

```bash
gh pr review <番号> --repo shinyaoguri/metaphor --approve --body-file <検証結果>
```

**merge はしない。** マージを起点にリリース自動化（タグ・publish）が走るので、
そこは人間の判断に残す。

修正が**すでにマージ済み**のことも多い（気付くのが後になるため）。その場合は approve は無意味なので、
Issue 側へ検証結果をコメントする。

## 5. 台帳を更新してコミットする

`recheck` を埋める。`at` は再検証した日、`against` は差し替えた対象、`verdict` は結果。

破壊的変更で作品側の前提が変わったら、**作品のコードとコメントも直す**。
例: metaphor#757 の修正は `fix(Export)!` で `saveFrame` の既定の保存先が変わるので、
リリースが出たら marionette の README とコード注記が古くなる。

## 週次の自動巡回

`upstream-status.py` を週 1 回走らせて、再検証が要るものがあれば知らせるタスクを登録してある。
起点はこれと、手動でこのスキルを呼ぶことの両方。

## 判定手段が無い項目を減らす

`manual` は再検証のたびに人手が要る。**新しく Issue を出すときは、可能なかぎり
自己検査に落としてから出す**（`sketch-verification` スキルの「検査を内蔵する」）。

metaphor#757 は最初 `manual` にしかできなかったが、`saveFrame` を一時ディレクトリへ書いて
ファイルの実在を見る検査（`E1.saveFramePath`）を足したことで、以後は 1 コマンドで判定できるようになった。
**フレームを跨ぐ必要がある検査は `setup()` に置けない**ので、フレーム番号で駆動する
遅延判定として書く（`Sketch0816Marionette.runDeferredChecks()` が実例）。
