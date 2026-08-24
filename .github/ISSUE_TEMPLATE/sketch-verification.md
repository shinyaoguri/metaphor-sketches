---
name: 作品の検証記録
about: 作品 1 つにつき 1 件。想定した動作になっているかを確認し、結果を逐次記録する
title: '<年>/<MMDD>-<作品名> の検証記録'
labels: verification
---

## 作品

| | |
|---|---|
| パス | `2026/MMDD-name/` |
| テンプレート | 2d / 3d / shader / live / audio-reactive / raytracing / syphon |
| metaphor | `Package.resolved` の実バージョン |

## 意図・想定する動作

作品 README と `PROJECT_BRIEF.md` の要点。何をどう見せたいのか、どう動けば「想定どおり」なのか。

## この作品で検証できる metaphor の API・機能

**着手時に埋める。** 作品を作ること自体が API のカバレッジ選択なので、何を通すつもりかを先に決める。

| API / 機能 | 何を確かめるか | 結果 |
|---|---|---|
| 例: `drawInstanced(colors:)` | 1 draw call で 1 万インスタンスが破綻せず出るか | |
| 例: `saveState` | ホットリロードを跨いで状態が復元されるか | |
| 例: Syphon 送出 | 停止時にサーバが後始末されるか | |

## 確認方法

- MCP: `snapshot`（frame.json の `custom` に出す `probe()` 値 / blank warnings）、`build_status`
- 目視: ビューアで見る点、操作して確かめる点

## 確認結果

API ごとに「期待どおり」か「どう違ったか」を追記していく。

**見た目を伴うものには必ず Gyazo で撮影した画像を貼る。**
動きが分からないと正誤を判定できないもの（アニメーション・遷移・インタラクション・時間依存の描画）は
GIF も撮る。リポジトリに画像・GIF はコミットせず、Gyazo の URL を貼る。

## 見つかった問題

metaphor / metaphor-cli の機能・仕様の問題は各リポジトリへ Issue を立て、ここから番号でリンクする。
**上流へ報告するときも同じ規則で証跡（画像・GIF）を添える。**

- [ ] 

## Epic への含意

**作品を通し終えたら埋める。** 個別の穴を起票するだけでは、上流の設計判断（どの機能を作るか / まだ作らないか）
には届かない。この作品で得た所見が次のどれに効くかを書く。**効くものが無ければ「無し」と書く**（空欄で終えない）。

- 構造化支援 [metaphor#415](https://github.com/shinyaoguri/metaphor/issues/415) — シーン遷移 / cue リスト / スケジューラの実需:
- 現場運用 [metaphor#416](https://github.com/shinyaoguri/metaphor/issues/416) — マルチディスプレイ / キオスク / 自動復帰 / 自己監視の実需:
- 検討 Issue（[#563](https://github.com/shinyaoguri/metaphor/issues/563) 決定論・入力リプレイ / [#564](https://github.com/shinyaoguri/metaphor/issues/564) 視覚検証 / [#567](https://github.com/shinyaoguri/metaphor/issues/567) パラメータ探索 / [#568](https://github.com/shinyaoguri/metaphor/issues/568) Render Trace / [#570](https://github.com/shinyaoguri/metaphor/issues/570) Take / [#571](https://github.com/shinyaoguri/metaphor/issues/571) Scene の寿命境界 / [#573](https://github.com/shinyaoguri/metaphor/issues/573) `.app` 配布 / [#608](https://github.com/shinyaoguri/metaphor/issues/608) ローカル作品理解）— 採否の判断材料:

**反証も所見**。「この作品では要らなかった」は、機能を作らない根拠として同じだけ価値がある
（例: `0815-strata` / `0816-marionette` はどちらも #571 の寿命境界を必要としなかった）。
