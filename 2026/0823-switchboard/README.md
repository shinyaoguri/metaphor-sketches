# 0823-switchboard

A retro telephone switchboard. One final frame fans out from a distribution bar into several
jacks; **a jack's lamp lights only on the frames its output plugin actually received**.

This sketch exists to exercise the output-plugin wiring that metaphor
[#792](https://github.com/shinyaoguri/metaphor/issues/792) replaced in v0.11.0–v0.13.0
(`MetaphorOutputProviders` / `MetaphorOutputProvider` / `MetaphorOutputContext` /
`PluginRequirements` / `RenderLoopMode.resolve`, plus Syphon moving to the separate
[metaphor-syphon](https://github.com/shinyaoguri/metaphor-syphon) package).

The verification record is
[metaphor-sketches#23](https://github.com/shinyaoguri/metaphor-sketches/issues/23) — read that
for what was confirmed and what was filed upstream.

```bash
swift run                      # 交換台が開く
tools/probe.sh cycle           # 決定論的検査 14 件を frame.json から抜く
tools/removed-api.sh           # 削除された 4 API がビルド不能であることを確かめる
tools/syphon-servers.sh        # いま立っている Syphon サーバーを列挙する
```

## 盤面の読み方

| 見えるもの | 意味 |
|---|---|
| ランプが点る | その出力プラグインが**直前のフレーム**で `post()` を受けた |
| ランプが消えて赤い輪 | コードは差さっているのにフレームが来ていない（= 上書きされた・繋がっていない） |
| コードが無く、プラグが脇に転がっている | provider が `makeOutput(context:)` で `nil` を返した口 |
| `ORDER OF post()` の帯 | 直前フレームの到着順。仕切りより右が出力フェーズ |
| `LOG BOOK` | `setup()` で 1 回だけ走る決定論的検査。行にマウスを乗せると実測値の全文 |

**SYPHON の口だけランプの根拠が違う。** Syphon の `post()` はこちらから計測できないので、
この口は「プラグインが付いているか」で点す（毎フレームの点滅ではない）。表示している名前は
`MetaphorRenderer.syphonOutput?.serverName` の実値。

## 操作

| キー | 効果 |
|---|---|
| `S` | Syphon サーバーを止める / 立て直す（`stopSyphonServer()` / `startSyphonServer(name:)`） |
| `R` | サーバー名を貼り替える（`SyphonOutput.rename(_:)`） |

## 観測の口（MCP が無いセッション用）

| 環境変数 | 用途 |
|---|---|
| `SWITCHBOARD_TRACE=1` | `post()` の到着順を毎フレーム標準出力へ |
| `SWITCHBOARD_SHOTS=1` | 90 フレーム目に `output/board.png` を書いて終了 |
| `SWITCHBOARD_FRAMES=<dir>` | 連番 PNG を 360 フレームぶん書いて終了（GIF 用） |
| `SWITCHBOARD_SOLO=<id>` | provider を 1 本だけにする対照実験（`aperture` / `syphon` / `none`） |
| `SWITCHBOARD_WINDOW=1` | セカンダリウィンドウ（監督卓）も開く。`SketchWindowConfig.plugins` の確認用 |
| `SWITCHBOARD_HIDE_AT=<frame>` | そのフレームで自分を最小化し、5 秒後に何フレーム進んだかを出す |
| `SWITCHBOARD_STOP_SYPHON_AT=<frame>` | そのフレームで `stopSyphonServer()` を叩く |
| `SWITCHBOARD_HIDE_HOW=hide` | 最小化ではなくアプリを隠す |

## 実測（metaphor 0.13.0 / metaphor-syphon 0.2.0、macOS 15.6 / Apple Silicon）

- **provider は 3 本同時に登録しても全部残り、登録順も保つ**（旧 `MetaphorOutputRegistry` の後勝ちは解消）
- 出力フェーズの順序は毎フレーム `line.monitor` → `tap.aperture[out]` → `tap.ledger[out]`
- `.syphon(name:)` / `SketchWindowConfig.plugins` / `METAPHOR_SYPHON_NAME` の 3 経路から
  **1 プロセスで 3 つの Syphon サーバー**が立ち、SIGTERM で 3 つとも消える（`tools/syphon-servers.sh` で確認）
- 削除された `SketchConfig(syphon:)` / `syphonName:` / `SketchWindowConfig(syphonName:)` /
  `MetaphorOutputRegistry` は 4 件ともビルド不能。素の `import metaphor` は `Syphon.xcframework` を引かない
- ソーク 180 秒 / 18 サンプルで RSS は横ばい（数値は検証 issue）

## コードを読む人向けの注意

- **`Sketch` はレンダラーを公開していない**（`context` は internal）。metaphor-syphon の互換 facade
  （`MetaphorRenderer.syphonOutput` / `startSyphonServer` / `stopSyphonServer`）へは、
  **出力プラグインの `onAttach(renderer:)` で掴んだ参照を通すしか届かない**。
  `OutletLog.renderer` がその 1 本
- **`draw()` は `post()` より前に走る**。盤面が描いているのは常に 1 フレーム前の到着記録で、
  `OutletLog.beginFrame(_:)` が前フレームを確定させてから新しいフレームを開ける
- **`Inspector` の検査は provider の登録を一時的に触る。** `MetaphorSyphon.enable()` は登録を
  復活させるので、S3 は前後の状態を元に戻す。配線サマリ（`wiring`）は検査より**先**に取る
  — 後で取ると検査後の状態を写してしまう（一度これで誤った値を出した）
- 盤面の 4 口目（SILENT）は `plugin(id:)` が `nil` を返すことで「差さっていない」と描く。
  provider が登録されていることと、この起動で出力を返すことは**別**
