# metaphor-sketches

[metaphor](https://github.com/shinyaoguri/metaphor) / [metaphor-cli](https://github.com/shinyaoguri/metaphor-cli) を実運用しながら作品を作るスケッチブック。
作品ごとに検証 issue を立てて動作確認を記録し、そこで使い勝手・動作の穴に気付いたら
各リポジトリへ Issue を立てて、下の索引にも残す。

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
- **作品ごとにこのリポジトリへ検証 issue を 1 件立てる**。作品の README に意図と想定する動作をまとめ、
  issue には**その作品で検証できる metaphor の API・機能**を着手時に列挙してから実装に入る
  （作品を作ること自体が API のカバレッジ選択になる）
- 確認は metaphor-cli の MCP（`snapshot` / `build_status`）と人間の目視の両方で行い、
  結果を API ごとに issue へ逐次追記する。**動作確認の詳細はこのリポジトリの issue が一次記録**
- **見た目を伴うものには必ず Gyazo で撮影した画像を添付する**。動きが分からないと正誤を判定できないもの
  （アニメーション・遷移・インタラクション・時間依存の描画）は GIF も撮る。リポジトリに画像はコミットしない
- そこで metaphor / metaphor-cli の機能・仕様の問題が見つかったら各リポジトリへ Issue を立て、
  検証 issue から番号でリンクする。**上流への報告にも同じ規則で証跡を添える**
- **索引には作品ごとにサムネを 1 枚だけ載せる**（動きがあるものは GIF）。索引は一覧のための場所で、
  何が分かったのかは検証 issue が持つ
- 公開したい作品・アセットが重い作品・長期に育てる作品は、独立リポジトリへ昇格させる（`git subtree split` で履歴ごと切り出せる）

## 索引

詳細は各作品の検証 issue が一次記録。踏んだ上流 Issue もそこから辿れる。

| | 作品 | 概要 | 記録 |
|---|---|---|---|
| <img src="https://i.gyazo.com/0a293c2427a904414343d08f2de7060b.png" width="200"> | [0718-hello](2026/0718-hello/)<br><sub>2d / metaphor 0.7.0</sub> | 一巡目。テンプレートを生成して scaffold → build → Probe まで通した | [#3](https://github.com/shinyaoguri/metaphor-sketches/issues/3) |
| <img src="https://i.gyazo.com/b8cd8829c4c1f2676a7497c150024914.gif" width="200"> | [0718-memory-stress](2026/0718-memory-stress/)<br><sub>3d / metaphor 0.7.0</sub> | フェーズ制のメモリ・性能ストレスハーネス。負荷を段階的に上げてリークと上限を測る | [#4](https://github.com/shinyaoguri/metaphor-sketches/issues/4) |
| <img src="https://i.gyazo.com/67fa650c3a168960b43d36b7b7170e95.gif" width="200"> | [0815-strata](2026/0815-strata/)<br><sub>2d→自作 3D / metaphor 0.9.0</sub> | 生成的な地形を 4 シーンで巡回する。カメラと OSC で駆動し、単体アプリ常設と Syphon 送出の両対応 | [#5](https://github.com/shinyaoguri/metaphor-sketches/issues/5) |
| <img src="https://i.gyazo.com/6880d178fe5d0f61c2ecc4c5ed68689a.gif" width="200"> | [0815-salvage](2026/0815-salvage/)<br><sub>3d→自作 3D / metaphor 0.9.0</sub> | 3 ステージの 3D ゲーム。シーンごとにモデル・床・環境音・背景動画が丸ごと入れ替わる。アセットは全て手続き生成 | [#6](https://github.com/shinyaoguri/metaphor-sketches/issues/6) |
| <img src="https://i.gyazo.com/3451456739c90c691832f32c1205c6e9.gif" width="200"> | [0815-lifegame](2026/0815-lifegame/)<br><sub>2d→自作 3D / metaphor 0.9.0</sub> | 三次元ライフゲーム。26 近傍・多状態のセルオートマトンを SF 調で。リロードを跨いで培養が続く | [#7](https://github.com/shinyaoguri/metaphor-sketches/issues/7) |
| <img src="https://i.gyazo.com/374ccabbdbafc33b37a7ff92d39e3fc3.png" width="200"> | [0816-adversary](2026/0816-adversary/)<br><sub>2d→検査盤 / metaphor 0.9.0</sub> | 敵対的仕様適合検査盤。6 面 55 検査を、スケッチ自身がピクセルを読み戻して判定する。FAIL が赤く残る画面が主題 | [#8](https://github.com/shinyaoguri/metaphor-sketches/issues/8) |
| <img src="https://i.gyazo.com/4dd6ed0ba0d872abb494c0d645da35fa.gif" width="200"> | [0816-marionette](2026/0816-marionette/)<br><sub>3d / metaphor 0.9.0</sub> | 2D の Verlet 物理を糸に、3D シーングラフを操り人形に見立てる。鎖・布・坑・群れの 4 場面 | [#10](https://github.com/shinyaoguri/metaphor-sketches/issues/10) |
| <img src="https://i.gyazo.com/9e4eb40f6c6df08cde11bbb2769d0352.gif" width="200"> | [0816-sounding](2026/0816-sounding/)<br><sub>audio-reactive / metaphor 0.9.0</sub> | 音で深さを測る。自分で合成した曲を解析し返し、その帯域でノイズの海底を彫って等深線の海図にする | [#11](https://github.com/shinyaoguri/metaphor-sketches/issues/11) |
| <img src="https://i.gyazo.com/2be4f90539137887610911cb4d0f17b2.gif" width="200"> | [0816-escapement](2026/0816-escapement/)<br><sub>2d / metaphor 0.9.0</sub> | スケルトン時計。数・イージング・波形・乱数・定数・時計・ループ制御・入力という「もっとも基本的な層」を、作品自身が数式と突き合わせる。切り分けは [0816-probe-frameloop](2026/0816-probe-frameloop/) | [#12](https://github.com/shinyaoguri/metaphor-sketches/issues/12) |
| <img src="https://i.gyazo.com/eec201c7aef60300c325748c4dd3c5aa.gif" width="200"> | [0816-gamut](2026/0816-gamut/)<br><sub>2d / metaphor 0.9.0</sub> | 光と絵の具。同じ 3 原色が、光として重なれば白へ、絵の具として重なれば黒へ向かう。両方の卓に効くはずの「薄め」つまみが片方だけ効かず、その非対称が絵にそのまま出る。切り分けは [0816-probe-blendalpha](2026/0816-probe-blendalpha/) | [#13](https://github.com/shinyaoguri/metaphor-sketches/issues/13) |
