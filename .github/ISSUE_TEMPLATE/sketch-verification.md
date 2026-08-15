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
