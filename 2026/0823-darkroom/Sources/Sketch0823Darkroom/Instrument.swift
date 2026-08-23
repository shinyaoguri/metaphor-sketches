import Foundation
import MetaphorSyphon
import metaphor

/// 暗室に据えた計器。**描画も時計も使わない決定論的な判定**を並べる。
///
/// 判定は真偽値ではなく**実測値を含む文字列**にする（`FAIL D8 drift=41.2ms 期待<16.7`）。
/// そのまま issue に貼れば数字が証拠になる。判定は `probe("check.<ID>", …)` と
/// 標準出力の両方へ出す（MCP が使えないセッションでも `swift run` の出力から拾えるように）。
///
/// **ここで測れないものは測れないと言う。** 現像後の絵は `loadPixels()` では読めない
/// （`D5` で実測する）ので、槽の効きの実測は外の `tools/syphon-read.sh` が担う。
@MainActor
final class Instrument {
    struct Result {
        let id: String
        /// `PASS` / `FAIL` / `LOOK`（人が見て決める）/ `N/A`（この起動では測れない）
        let verdict: String
        let detail: String
    }

    private(set) var results: [Result] = []

    fileprivate func record(_ id: String, _ verdict: String, _ detail: String) {
        results.append(Result(id: id, verdict: verdict, detail: detail))
        Log.line("\(verdict) \(id)  \(detail)")
    }

    // MARK: - D1 連動

    /// 3 窓が生きていて、**同じ状態の同じ瞬間**を描いているか。
    ///
    /// 槽は自分のレンダーループで回るので、プライマリと同じフレームを描いているとは限らない。
    /// ここで見るのは「槽が描いた時点でプライマリが置いていたフレーム番号」が、判定時点の
    /// プライマリのフレームからどれだけ遅れているか。60fps 同士なら数フレーム以内に収まるはず。
    func checkWindows(_ stations: [Station], room: Darkroom) {
        let open = stations.filter { $0.isOpen }.count
        guard open == stations.count else {
            record("D1", "FAIL", "開いている窓 \(open)/\(stations.count)")
            return
        }

        var lags: [String] = []
        var worst = 0
        for station in stations.dropFirst() {
            guard let meter = room.meters[station.bath.id] else {
                record("D1", "FAIL", "\(station.bath.id) の計測が無い（onDraw が走っていない）")
                return
            }
            guard meter.frames > 0 else {
                record("D1", "FAIL", "\(station.bath.id) が 1 フレームも描いていない")
                return
            }
            let lag = room.frame - meter.lastSharedFrame
            worst = max(worst, abs(lag))
            lags.append("\(station.bath.id)=\(lag)")
        }
        // 3 フレーム（50ms）まで許す。これを超えるなら「同じ瞬間」とは言えない。
        let verdict = worst <= 3 ? "PASS" : "FAIL"
        record("D1", verdict,
               "窓 \(open)/\(stations.count) / 共有フレームの遅れ \(lags.joined(separator: " ")) "
               + "最大=\(worst) 期待≤3")
    }

    // MARK: - D2 窓ごとの Syphon

    /// `SketchWindowConfig.plugins: [.syphon(name:)]` で**窓ごとに独立したサーバー**が立ったか。
    ///
    /// 作品自身が実名を読めるのは、槽に立会人プラグインを 1 人ずつ差してあるから
    /// （`Sketch` はレンダラーを公開しないので、`MetaphorRenderer.syphonOutput` の facade へは
    /// プラグイン経由でしか届かない）。
    func checkServers(_ stations: [Station]) {
        guard !Bath.anonymous else {
            record("D2", "N/A", "DARKROOM_ANON=1 のため名前は D4 で見る")
            return
        }
        var lines: [String] = []
        var bad = 0
        for station in stations {
            let id = station.bath.id
            let actual = Witness.all[id]?.syphonServerName
            let active = Witness.all[id]?.syphonActive ?? false
            let expected = station.bath.syphonName
            if actual != expected || !active { bad += 1 }
            lines.append("\(id)=\(actual ?? "(none)")\(active ? "" : "[停止]")")
        }
        let names = Set(stations.compactMap { Witness.all[$0.bath.id]?.syphonServerName })
        let distinct = names.count == stations.count
        let verdict = (bad == 0 && distinct) ? "PASS" : "FAIL"
        record("D2", verdict,
               "\(lines.joined(separator: " ")) / 相異なる名前 \(names.count)/\(stations.count)")
    }

    // MARK: - D3 環境変数のスコープ

    /// `METAPHOR_SYPHON_NAME` が**セカンダリには効かない**か。
    ///
    /// metaphor-syphon の `SyphonOutputProvider.resolveOutputName` は `case .window: return nil`。
    /// つまり環境変数で立つのはプライマリの 1 本だけのはず。ただしこの作品は
    /// プライマリにも `.syphon(name:)` を宣言しているので、**環境変数ぶんはもう 1 本**になる
    /// （同じ窓に 2 本立つのかどうかもここで見える）。
    func checkEnvironmentScope(_ stations: [Station]) {
        guard let envName = ProcessInfo.processInfo.environment["METAPHOR_SYPHON_NAME"],
              !envName.isEmpty
        else {
            record("D3", "N/A", "METAPHOR_SYPHON_NAME 未設定（tools/probe.sh env で当てる）")
            return
        }
        let secondaries = stations.dropFirst().compactMap { Witness.all[$0.bath.id]?.syphonServerName }
        let leaked = secondaries.filter { $0 == envName }
        let primaryName = Witness.all[Bath.primary.id]?.syphonServerName ?? "(none)"
        let verdict = leaked.isEmpty ? "PASS" : "FAIL"
        record("D3", verdict,
               "env=\(envName) / セカンダリ=\(secondaries.joined(separator: ",")) "
               + "（env 名を名乗ったもの \(leaked.count) 件・期待 0）/ プライマリ=\(primaryName)")
    }

    // MARK: - D4 名前を省略したとき

    /// `.syphon()`（名前省略）を窓に渡すと何を名乗るか。
    ///
    /// doc の主張は「`SketchWindowConfig.plugins` 経由では `Sketch` が無いのでプロセス名」。
    /// **3 窓が同じ名前を名乗ることになる**ので、Syphon サーバーが 3 本立つのか 1 本に潰れるのかを
    /// 実測する。潰れるなら metaphor 側ではなく Syphon 側の挙動なので、切り分けてから上流へ出す。
    func checkAnonymousNames(_ stations: [Station]) {
        guard Bath.anonymous else {
            record("D4", "N/A", "DARKROOM_ANON=1 のときだけ測る")
            return
        }
        let processName = ProcessInfo.processInfo.processName
        var lines: [String] = []
        for station in stations {
            let id = station.bath.id
            lines.append("\(id)=\(Witness.all[id]?.syphonServerName ?? "(none)")")
        }
        let names = Set(stations.compactMap { Witness.all[$0.bath.id]?.syphonServerName })
        // ここは PASS/FAIL を作品が決めない（Syphon 側の仕様と混ざる）。実測だけ残す。
        record("D4", "LOOK",
               "\(lines.joined(separator: " ")) / 相異なる名前 \(names.count) 種 "
               + "/ プロセス名=\(processName) → 外から実際に何本見えるかは tools/syphon-read.sh で数える")
    }

    // MARK: - D5 読み戻しはどの段か

    /// `loadPixels()` が返すのは**現像前**か**現像後**か。
    ///
    /// 実装上は `renderer.textureManager.colorTexture`（ポストエフェクト適用前）を読むので、
    /// 槽の効きは作品自身では読めないはず。**これが本当なら、3 本が別物であることの実測は
    /// 外の受け手にしか置けない**（この作品が `tools/syphon-read.sh` を持つ理由そのもの）。
    ///
    /// 判定は「輪郭槽（sobel）の窓で読み戻したウェッジの平均輝度」が、
    /// 原版の期待値どおりなら**現像前**、大きく下がっていれば**現像後**。
    func checkReadbackStage(primary: SketchContext, stations: [Station], room: Darkroom) {
        guard room.phase.bathsEngaged else {
            record("D5", "N/A", "いまは停止工程で槽が外れている")
            return
        }
        guard let edge = stations.first(where: { $0.bath.recipe.expectedLumaDirection == "<" }),
              let ctx = edge.context
        else {
            record("D5", "N/A", "輪郭槽の窓が無い")
            return
        }

        let expected = Plate.wedgeExpectedLuma
        let onPlate = Self.wedgeLuma(primary)
        let onEdge = Self.wedgeLuma(ctx)

        // 原版側がまず期待どおりでないなら、読み戻しそのものを疑う（自分の検査バグの検出）。
        guard abs(onPlate - expected) < 12 else {
            record("D5", "FAIL",
                   "原版のウェッジが期待から外れている 実測=\(fmt(onPlate, 1)) 期待=\(fmt(expected, 1))"
                   + " — 読み戻しか原版の描画を疑う")
            return
        }

        let stage = abs(onEdge - onPlate) < 12 ? "現像前" : "現像後"
        record("D5", "LOOK",
               "loadPixels は\(stage)を返す 原版=\(fmt(onPlate, 1)) 輪郭槽=\(fmt(onEdge, 1))"
               + " 期待(原版)=\(fmt(expected, 1)) — 現像後の実測は tools/syphon-read.sh")
    }

    /// ステップウェッジ帯の平均輝度（0…255）を読み戻す。
    ///
    /// 段の境目を避けて各段の中央だけを拾う。段の輝度は `i/(steps-1)` なので、
    /// 平均は `Plate.wedgeExpectedLuma` と一致するはず（**metaphor を呼ばずに解ける値**）。
    private static func wedgeLuma(_ ctx: SketchContext) -> Float {
        ctx.loadPixels()
        let stepW = Int(Plate.width) / Plate.wedgeSteps
        let y = Int(Plate.height - Plate.wedgeHeight / 2)
        var sum: Float = 0
        var n: Float = 0
        for i in 0..<Plate.wedgeSteps {
            let x = i * stepW + stepW / 2
            let c = ctx.get(x, y)
            sum += (c.r + c.g + c.b) / 3 * 255
            n += 1
        }
        return n > 0 ? sum / n : 0
    }

    // MARK: - D6 開閉

    /// 窓を閉じたら Syphon サーバーも畳まれるか。
    ///
    /// `SketchWindow.close()` → `renderer.shutdown()` → プラグインの `onDetach()` →
    /// `SyphonOutput.stop()` という順のはず。立会人の `detached` と、サーバーの `isActive` を見る。
    func closeForLifecycle(_ stations: [Station]) {
        guard let last = stations.last, !last.isPrimary else {
            record("D6", "N/A", "閉じられるセカンダリが無い")
            return
        }
        let id = last.bath.id
        let before = Witness.all[id]?.syphonServerName ?? "(none)"
        last.close()

        let witness = Witness.all[id]
        let detached = witness?.detached ?? false
        let stillActive = witness?.syphonActive ?? false
        record("D6a", detached && !stillActive ? "PASS" : "FAIL",
               "\(id) を閉じた 閉前=\(before) / onDetach=\(detached) / サーバー生存=\(stillActive)"
               + "（期待: onDetach=true 生存=false）")
    }

    /// 閉じた窓を開き直したら、サーバーも同じ名前で立ち直るか。
    ///
    /// 0816-triptych（metaphor 0.9.0）では開き直しのたびに窓が (30, −30) px ずつ歩き、
    /// **当て木なしでは開き直しの瞬間にプロセスが落ちた**（[metaphor#835](https://github.com/shinyaoguri/metaphor/issues/835)）。
    /// この作品は 0.13.0 で当て木を持たないので、**ここまで到達していること自体が回帰の判定**になる。
    func reopenForLifecycle(
        _ stations: [Station], room: Darkroom, make: (SketchWindowConfig) -> SketchWindow?
    ) {
        guard let last = stations.last, !last.isPrimary else { return }
        let id = last.bath.id
        last.open(with: make, room: room)

        let witness = Witness.all[id]
        let name = witness?.syphonServerName
        let active = witness?.syphonActive ?? false
        let expected = Bath.anonymous ? name : last.bath.syphonName
        let ok = last.isOpen && active && name == expected
        record("D6b", ok ? "PASS" : "FAIL",
               "\(id) を開き直した 窓=\(last.isOpen) / サーバー=\(name ?? "(none)")"
               + " / 生存=\(active)（期待: \(expected ?? "同名") が立ち直る）")
    }

    // MARK: - D8 クロック

    /// 窓ごとの時計がどれだけ離れるか。
    ///
    /// セカンダリは自分のレンダーループと時計を持つ。**生成タイミングによる一定のオフセットは
    /// 当然**なので、初回の差を基準にしてそこからの変化（drift）を見る。
    /// 0816-triptych（0.9.0）の実測は 10–17 ms だった。
    func checkClocks(_ room: Darkroom, stations: [Station], elapsed: Float) {
        var lines: [String] = []
        var worst: Float = 0
        for station in stations.dropFirst() {
            guard let meter = room.meters[station.bath.id] else { continue }
            worst = max(worst, meter.driftMs)
            lines.append("\(station.bath.id): offset=\(fmt(meter.offsetMs, 1))ms"
                         + " drift=\(fmt(meter.driftMs, 1))ms frames=\(meter.frames)")
        }
        guard !lines.isEmpty else {
            record("D8", "N/A", "計測できた槽が無い")
            return
        }
        // 共有時計の更新粒度（60fps = 16.7ms）を超えるずれは、絵の上でも見えるはず。
        let verdict = worst < 16.7 ? "PASS" : "LOOK"
        record("D8", verdict,
               "\(lines.joined(separator: " / ")) / 最大 drift=\(fmt(worst, 1))ms"
               + " 期待<16.7ms（60fps 1 フレーム）/ 基準を取り直してからの経過=\(fmt(elapsed, 1))s")
    }

    // MARK: - D10 槽の効き（期待の宣言）

    /// 槽ごとに「読み戻したときどちらへ動くはず」かを表にして残す。
    ///
    /// **実測はここではできない**（`D5` のとおり `loadPixels` は現像前を返す）。
    /// 外の受け手が同じ表と突き合わせられるよう、期待だけを判定行として置いておく。
    func checkFilterExpectations(_ stations: [Station]) {
        let table = stations.map { s in
            "\(s.bath.id)\(s.bath.recipe.expectedLumaDirection)原版"
        }.joined(separator: " ")
        record("D10", "N/A",
               "期待 \(table) / 実測は tools/syphon-read.sh（受け手側で平均輝度・エッジ率・針の角度を読む）")
    }
}

// MARK: - D7 隠しても出続けるか

extension Instrument {
    /// アプリを隠したあとも publish が続いたか。
    ///
    /// Syphon の `SyphonOutputProvider` は `.externalRenderLoop` を宣言するので、
    /// `.displayLink` のスケッチはタイマー駆動へ切り替わるはず（= 不可視でも止まらない）。
    /// **セカンダリ窓でもこの promotion が効くか**が見たい点。0816-triptych の `W6` は
    /// 「promotion が `window.config` に届かない」までしか観測できていなかった。
    func checkOcclusion(_ stations: [Station], before: [String: Int], seconds: Float) {
        var lines: [String] = []
        var stalled: [String] = []
        for station in stations {
            let id = station.bath.id
            guard station.isOpen else { continue }
            let now = Witness.all[id]?.posts ?? 0
            let delta = now - (before[id] ?? 0)
            lines.append("\(id)=+\(delta)")
            // 60fps × 4 秒 ≈ 240 フレーム。1 割も進まないなら止まっているとみなす。
            if delta < 24 { stalled.append(id) }
        }
        let verdict = stalled.isEmpty ? "PASS" : "FAIL"
        record("D7", verdict,
               "隠して \(fmt(seconds, 0))s の publish 増分 \(lines.joined(separator: " "))"
               + " 期待≥24（60fps の 1 割）/ 止まった槽=\(stalled.isEmpty ? "なし" : stalled.joined(separator: ","))")
    }
}

// MARK: - D11 同じ id の Syphon が 2 本並んだとき

extension Instrument {
    /// **宣言 `.syphon(name:)` と `METAPHOR_SYPHON_NAME` が両方あるとき**、
    /// 互換 facade（`syphonOutput` / `stopSyphonServer`）はどちらを掴むか。
    ///
    /// 2 本立つこと自体は仕様（`PluginFactory.syphon(name:)` の doc に
    /// 「環境変数はこのファクトリとは独立に、もう 1 本のサーバーをその名前で立てます」とある）。
    /// ただし `SyphonPlugin.id` は固定文字列なので、レンダラーには**同じ pluginID が 2 つ**並ぶ。
    /// metaphor 本体はこれを検出して警告する（`addPlugin: a plugin with id ... is already
    /// registered; plugin(id:)/removePlugin(id:) will only reach the first one`）ので、
    /// facade は片方しか掴めない ＝ **`stopSyphonServer()` を呼んでも 1 本残る**はず。
    ///
    /// ここでは「止める前に何を名乗っていたか」「1 回止めたあと何が残るか」を記録する。
    /// 実際に何本残ったかは外から数える（`tools/syphon-servers.sh`）。
    func checkStopFacade(_ stations: [Station]) {
        guard ProcessInfo.processInfo.environment["METAPHOR_SYPHON_NAME"] != nil else {
            record("D11", "N/A", "METAPHOR_SYPHON_NAME 未設定（tools/probe.sh stoptest で当てる）")
            return
        }
        guard let witness = Witness.all[Bath.primary.id], let renderer = witness.renderer else {
            record("D11", "N/A", "プライマリのレンダラーを掴めていない")
            return
        }
        let before = witness.syphonServerName ?? "(none)"
        renderer.stopSyphonServer()
        let after = witness.syphonServerName ?? "(none)"
        record("D11", "LOOK",
               "stopSyphonServer() の前=\(before) → 後=\(after)"
               + " / 宣言は \(Bath.primary.syphonName)、env は "
               + "\(ProcessInfo.processInfo.environment["METAPHOR_SYPHON_NAME"] ?? "-")"
               + " — 残った本数は tools/syphon-servers.sh で数える")
    }
}
