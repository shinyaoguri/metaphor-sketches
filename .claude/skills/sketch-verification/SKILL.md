---
name: sketch-verification
description: "このスケッチブックで新しい作品を作りながら metaphor を検証する一連の手順 (何を作るか決める → 着手時に検証 issue を立てる → 検査を内蔵した作品を書く → 観測して切り分ける → 証跡を添えて記録する → 上流へ起票する)。Use when starting a new sketch in this repository, when asked to verify metaphor APIs through a work, or when recording verification results for an existing sketch."
---

作品を作ることがそのまま metaphor の検証になる、というのがこのリポジトリの前提
（ライフサイクルの全体像は [CLAUDE.md](../../../CLAUDE.md) と [README.md](../../../README.md) が正本）。
ここには**その手順を実際に回すときの順番と、踏んだ穴**だけを置く。

完走した実例は [issue #10](https://github.com/shinyaoguri/metaphor-sketches/issues/10)（`2026/0816-marionette`）。
迷ったらこの issue のコメントの並びをそのまま型として使う。

## 0. 順番を守る（ここが一番間違えやすい）

**`metaphor new` の直後、コードを 1 行も書く前に検証 issue を立てる。**

#10 では実装と計測を先に進めてしまい、ユーザーに指摘されるまで issue が無かった。
後から書き戻すと、**何を検証するつもりだったのか**（着手時の意図）と
**何が分かったのか**（結果）の区別が付かなくなる。issue が先だと、
API 表がそのまま作業の チェックリストになるという実利もある。

```bash
gh issue create --title "2026/<MMDD>-<名前> の検証記録" --label verification --body-file <本文>
```

本文は `.github/ISSUE_TEMPLATE/sketch-verification.md` の見出しに合わせる。
**「この作品で検証できる metaphor の API・機能」の表を、結果列を空にして先に埋める。**

## 1. 何を作るか決める

作品づくりは API のカバレッジ選択なので、まだ誰も通していない領域から選ぶ。

```bash
.claude/skills/sketch-verification/scripts/api-coverage.py            # 未使用をモジュール別に要約
.claude/skills/sketch-verification/scripts/api-coverage.py --list MPS # そのモジュールの未使用を全件
```

丸ごと手つかずのモジュールが 1 つ残っていれば、それを主題にするのが素直。
**橋渡しの API を持つモジュールは対で選ぶ**（例: MetaphorPhysics と MetaphorSceneGraph は
`Node.syncFromPhysics` で繋がっており、片方だけでは橋を検証できない）。

どの領域を狙うかは作品の意図に依るので、候補が複数あればユーザーに選んでもらう。

## 2. 検査を内蔵した作品を書く

**スクリーンショットではなく frame.json を一次証拠にする。**
`setup()` で 1 回だけ走る決定論的な検査群を作り、判定を `probe("check.<ID>", ...)` に出す
（`2026/0816-adversary/Harness.swift` と `2026/0816-marionette/Instrument.swift` が実例）。

- 描画も時計も使わない。**実行のたびに同じ数値が出る**こと
- 判定は真偽値ではなく**実測値を含む文字列**にする（`FAIL ... ratio=1.249 期待=1.000`）。
  後から issue に貼るとき、数字がそのまま証拠になる
- 標準出力にも出す。ソークのログや `swift run` の出力から拾える
- **`print` は `fflush(stdout)` とセットで**。パイプへ流すとブロックバッファされ、
  「動いていない」と誤診する（#10 で実際に一度誤診した）

作品自体は作品として成立させる。検査盤そのものを主題にする作り方もある（0816-adversary）。

実装の作法は作品ディレクトリの `AGENTS.md` が正本。**metaphor の API を書く前に必ず
その作品の `api_reference` を引く**（作品ごとに依存バージョンが違う）。

## 3. 走らせて観測する

`metaphor` MCP が使えないセッションもある。そのときは `swift build` と `swift run`、
それに作品側へ仕込んだ環境変数の口で足りる。#10 では次の 4 つを用意した。

| 環境変数 | 用途 |
|---|---|
| `MARIONETTE_SHOTS=1` | 場面ごとに 1 枚ずつ書き出し、巡回を短縮する |
| `MARIONETTE_TRACE=1` | ボディとノードのワールド座標を定期的に吐く |
| `MARIONETTE_FRAMES=<dir>` | GIF 用の連番 PNG を書き出す |
| `MARIONETTE_TRAP=<名前>` | **プロセスが落ちる既知の穴**を、頼んだときだけ再現する |

最後の口が要る理由: 落ちる API を検査に常時含めると**作品が起動しなくなる**。
v0.9.0 の `step(dt, iterations: -1)` がこれで、常時実行して起動不能になった。

書き出し API には非対称がある。**`saveFrame(_:)` は渡した名前に無条件で `~/Desktop/` を
前置する**ので絶対パスは無言で捨てられる（[metaphor#757](https://github.com/shinyaoguri/metaphor/issues/757)）。
`beginFrameRecord(directory:)` は絶対パスを尊重する。

## 4. 上流へ投げる前に切り分ける

**「ライブラリがおかしい」と思ったら、まず条件を 1 つだけ変えた対照実験を組む。**

#10 では鎖が水平を越えて振り切れたので拘束ソルバを疑ったが、単体振り子と 22 連の鎖に
同じ一様横力を掛けて比べたら 194 と 210（物理的な上限 ≈210）で、どちらも妥当だった。
原因は作品側の風が鎖の固有角振動数 √(g/L) を叩いていただけ。**誤報を出さずに済んだ。**

型:

- **最小構成で再現するか**（作品の文脈を剥がす。剥がして消えるなら自分の側）
- **単体 vs 複合**（要素 1 個と N 個で、片方だけが壊れるか）
- **同じ入力を刻み方だけ変える**（決定論・フレームレート依存の検出）
- **doc の期待値を数式で書き下す**（「なんとなく変」ではなく「期待 0.810 に対し実測 0.054」）

自分の検証コードを疑うことも同じくらい大事。#10 ではカリングの取りこぼしを 8 件検出したが、
**`screenZ` がカメラ背後を判別できない**（`clip.z / clip.w` なので `w<0` で符号が反転する）
のが原因で、自分の判定バグだった。`currentViewProjection` で自分でクリップ空間まで戻し
`clip.w > 0` を条件に入れたら 0 件になった。

上流へ出すときは**再現コードと実測表**を添える。既存 Issue の有無を先に見る:

```bash
gh issue list --repo shinyaoguri/metaphor --state all --search "<キーワード>"
```

**main で修正済みだが未リリース**というケースがある（v0.9.0 に対する
[#581](https://github.com/shinyaoguri/metaphor/issues/581) / [#504](https://github.com/shinyaoguri/metaphor/issues/504)）。
ローカルの metaphor チェックアウトと該当関数を diff して確かめてから書く。

## 5. 証跡を添える

見た目を伴うものには静止画、**動きが分からないと正誤を判定できないものには GIF も**。
手順は `gyazo-capture` スキルが正本。このリポジトリで効いた使い分け:

- **ウィンドウをそのまま撮る** → MCP の `gyazo_capture_and_upload_window`。トークン不要
- **手元のファイル（連番から作った GIF、`saveFrame` の出力）を上げる** → Gyazo Upload API。
  MCP にファイルを上げる口が無い
- GIF は `beginFrameRecord` が吐いた連番から ffmpeg で組む。画面収録と違い映り込みが無い

**1Password がロックされていると、`op read`（Gyazo トークン）と git のコミット署名が
両方とも無言で止まる。** 承認待ちを積み上げないよう再試行せず、ユーザーへロック解除を頼む。

添えるときは**撮影範囲と、どこを見てほしいか**を必ず本文に書く。
上流の Issue にも同じ規則で添える（#755 には pit の画像を追記した）。

## 6. ソーク

30 分の無人稼働で劣化とリークを見る。`2026/0816-marionette/tools/probe.sh soak 1800` が雛形
（release ビルド → 10 秒ごとに RSS と CPU を CSV へ → 前半平均と後半平均を比べる）。

生成物は `.probe-out/` に置き、**リポジトリにはコミットしない**。

## 7. 仕上げ

1. issue へ **API ごとに**結果を追記する（表の結果列を埋める）。動作確認の詳細はこの issue が一次記録
2. 見つけた問題を metaphor / metaphor-cli へ起票し、issue から番号でリンクする
3. README の索引表に 1 行足す（検証記録と踏んだ Issue へのリンク、実装側の学び）
4. 作品の README に、実測値と「コードを読む人向けの注意」を残す
5. 1 作品 1 コミットで main へ直 push（このリポジトリは PR レス運用）

Issue・PR へのコメントには署名を付ける（付け忘れはフックが差し戻す）。
