import Foundation
import metaphor

/// # 0816-triptych — 三連祭壇画
///
/// 中央パネル（プライマリウィンドウ）と左右の翼パネル（セカンダリウィンドウ）に、
/// **1 つの連続した横長の世界**を分けて描く。行列がその世界を左から右へ渡り、
/// 太陽が 90 秒で 1 周し、光の帯が 6 秒で走り抜ける。祭壇画の翼が開閉するように、
/// 翼ウィンドウは 42 秒ごとに閉じてまた開く。
///
/// 判定の核は**継ぎ目**にある。3 枚の板が同じ世界の同じ時刻を映しているなら、
/// 行列も光の帯も継ぎ目で途切れずに渡る。metaphor のセカンダリウィンドウは 1 枚ごとに
/// 独立したレンダラー・レンダーループ・時計を持つので、これは自明ではない。
///
/// **ウィンドウの位置を指定する API が無い**ので、3 枚は人が並べる。各パネルは自分が
/// 世界のどこを映しているかを額の中に書いてあり、下辺には世界座標の目盛りが走っている。
/// 並べたときに目盛りが連続していれば、継ぎ目は合っている。
@main
final class Sketch0816Triptych: Sketch {
    static let title = "0816-triptych — 中央"

    var config: SketchConfig {
        SketchConfig(width: Int(Altar.centerWidth), height: Int(World.height), title: Self.title)
    }

    private let stage = Stage()
    private let instrument = Instrument()
    private var wings: [Wing] = []

    /// 検査の段取り。それぞれ 1 回だけ走る。
    private var didDeferredChecks = false
    private var didTimingChecks = false
    private var didShots = false
    private var didPostClicks = false
    private var didJudgeClicks = false
    private var announcedDone = false

    /// 翼が開いた時刻。開くまでは負。
    private var openedAt: Float = -1
    private var lastTraceAt: Float = -99
    private let trace = ProcessInfo.processInfo.environment["TRIPTYCH_TRACE"] == "1"
    private let shots = ProcessInfo.processInfo.environment["TRIPTYCH_SHOTS"] == "1"
    private let framesDir = ProcessInfo.processInfo.environment["TRIPTYCH_FRAMES"]

    /// 検査を締める時刻。ここまでは走らせないと S 群（時計・fps）が測れない。
    private let timingAt: Float = 12
    private let deferredAt: Float = 2
    private let shotsAt: Float = 6

    func setup() {
        // 連番を書き出すときは 3 枚とも 20fps へ落とす（Altar.recordingFPS と揃える）。
        frameRate(Altar.recordingFPS ?? 60)
        stage.marchers = World.makeMarchers()
        // 灯を 2 つだけ最初から置いておく（クリックしなくても「灯る」が見える）。
        // 継ぎ目 x=800 / x=2080 をまたぐ位置に置いてあるので、灯りが 2 枚の板に跨がる。
        stage.addLantern(SIMD2(760, World.horizon - 96))
        stage.addLantern(SIMD2(2120, World.horizon - 72))

        Log.line("[metaphor] 0816-triptych / 世界幅 \(Int(World.width))px = 翼 \(Int(Altar.wingWidth))"
                 + " + 中央 \(Int(Altar.centerWidth)) + 翼 \(Int(Altar.wingWidth))")

        // 落ちうる退化 config は頼まれたときだけ。ここで return して作品を組まない。
        if let trapName = ProcessInfo.processInfo.environment["TRIPTYCH_TRAP"] {
            Instrument.runTrap(trapName, make: { [weak self] in self?.makeWindow($0) })
            Log.line("self-check 完了")
            return
        }

        wings = Altar.makeWings()

        // 破壊的な検査は本番の翼より先に済ませる。閉じたウィンドウのぶんだけカスケードが
        // 進むので、後に回すと本番の翼が右下へずれて生まれる（それ自体が L5 の主題）。
        // ただし **setup() の中で開閉すると落ちる**ので、検査は draw() でフレームを跨いで進める。
        if !Instrument.selfTestEnabled {
            raiseAltar()
        }
    }

    /// 祭壇を立てる（翼を開き、軽い検査を当て、必要なら連番の書き出しを始める）。
    private func raiseAltar() {
        openWings()
        openedAt = time

        instrument.checkWings(wings, primary: context)
        instrument.checkHeadlessBoundary(primaryTitle: Self.title)

        if let dir = framesDir {
            beginFrameRecord(directory: dir + "/center", pattern: "frame_%05d.png")
            for (i, wing) in wings.enumerated() {
                wing.window?.context.beginFrameRecord(
                    directory: dir + "/wing-\(i)", pattern: "frame_%05d.png"
                )
            }
            Log.line("[連番] \(dir) へ書き出す")
        }
    }

    func draw() {
        // 共有時計。中央がここで進め、翼は自分のレンダーループからこれを読む。
        stage.clock = time

        World.render(into: context, panel: Altar.center, clock: time, stage: stage)

        if Instrument.selfTestEnabled && !instrument.selfTestDone {
            instrument.stepSelfTest(
                make: { [weak self] in self?.makeWindow($0) },
                closeAll: { [weak self] in self?.closeAllWindows() }
            )
            if instrument.selfTestDone { raiseAltar() }
            return
        }
        guard openedAt >= 0 else { return }

        updateWingSchedule()
        runChecks()
        emitProbes()
        traceIfNeeded()
    }

    /// 翼が開いてからの経過秒。検査の時刻はすべてこれで測る
    /// （自己検査に何フレームかかったかに judgement が引きずられないように）。
    private var since: Float { openedAt < 0 ? 0 : time - openedAt }

    func mouseClicked() {
        let wx = Altar.center.origin + mouseX
        stage.addLantern(SIMD2(wx, mouseY))
        Log.line("[入力] 中央クリック → 中央ローカル (\(fmt(mouseX)), \(fmt(mouseY))) / 世界 x=\(fmt(wx))")
    }

    /// `w` で翼の開閉を手で切り替える（並べ直したいときのため）。
    func keyPressed() {
        guard key == "w" else { return }
        if wings.contains(where: { $0.isOpen }) {
            closeWings()
        } else {
            openWings()
        }
    }

    // MARK: - 翼の開閉

    /// この作品でセカンダリウィンドウを作る唯一の口。
    ///
    /// `createWindow` の直後に当て木を当てる（`WindowCrashWorkaround`）。当て木なしだと
    /// 翼を閉じてから開き直した瞬間にプロセスが落ちるので、開閉が構成そのものである
    /// この作品は成立しない。
    private func makeWindow(_ config: SketchWindowConfig) -> SketchWindow? {
        let w = createWindow(config)
        if w != nil { WindowCrashWorkaround.applyToAllWindows() }
        return w
    }

    private func openWings() {
        for wing in wings {
            wing.open(with: { [weak self] in self?.makeWindow($0) }, stage: stage)
        }
        Log.line("[翼] 開 \(wings.filter { $0.isOpen }.count)/\(wings.count) 枚"
                 + "（t=\(fmt(stage.clock, 1))s）")
    }

    /// 左翼 → 中央 → 右翼 の順に並べ直す。開き直すたびにカスケードで散るので毎回当てる。
    private func arrangeAltar() {
        let order = [wings.first?.config.title, Self.title, wings.dropFirst().first?.config.title]
            .compactMap { $0 }
        guard let rect = AltarArrangement.apply(order: order) else { return }
        Log.line("[配置] 3 枚を並べた 撮影範囲(左下原点)=(\(Int(rect.minX)),\(Int(rect.minY)))"
                 + " \(Int(rect.width))×\(Int(rect.height))")
    }

    private func closeWings() {
        for wing in wings { wing.close() }
        Log.line("[翼] 閉（t=\(fmt(stage.clock, 1))s）")
    }

    /// 祭壇画の開閉。42 秒で 1 巡（開 30 秒 → 閉 12 秒）。
    ///
    /// 開閉を主題に据えてあるのは、放っておくだけでライフサイクルとリークの経路を
    /// 通し続けるため。ソークはこの巡回が最低 2 巡入る秒数で回す。
    private func updateWingSchedule() {
        // 検査を締める前に翼が閉じると S 群が測れないので、それまでは開けたままにする。
        guard since > timingAt + 1 else { return }
        let wantOpen = Altar.shouldBeOpen(at: since)
        let isOpen = wings.contains { $0.isOpen }
        if wantOpen && !isOpen {
            openWings()
            arrangeAltar()
        } else if !wantOpen && isOpen {
            closeWings()
        }
    }

    // MARK: - 検査の段取り

    private func runChecks() {
        if !didDeferredChecks && since > deferredAt {
            didDeferredChecks = true
            // ウィンドウの実寸と drawable は最初のフレームが出るまで確定しないので、
            // 位置と座標変換の検査はここまで遅らせる。
            // **並べる当て木を当てる前に**測る（metaphor 自身の配置を記録に残すため）。
            instrument.checkPlacement(wings, primaryTitle: Self.title)
            instrument.checkPointerMapping(wings)
            arrangeAltar()
        }

        // 入力の分離は「積む」「読む」の 2 手（積んだ NSEvent はランループが回ってから届く）。
        if didDeferredChecks && !didPostClicks && since > deferredAt + 1 {
            didPostClicks = true
            instrument.primaryTitle = Self.title
            instrument.postClicks(wings, primary: context)
        }
        if didPostClicks && !didJudgeClicks && since > deferredAt + 2 {
            didJudgeClicks = true
            instrument.judgeClicks(wings, primary: context)
        }

        if shots && !didShots && since > shotsAt {
            didShots = true
            // saveFrame(_:) は渡した名前に無条件で ~/Desktop/ を前置する（metaphor#757）。
            // 絶対パスを渡すと無言で捨てられるので、ファイル名だけ渡す。
            saveFrame("triptych-center.png")
            for (i, wing) in wings.enumerated() {
                wing.window?.context.saveFrame("triptych-wing-\(i).png")
            }
            Log.line("[S6] ~/Desktop/triptych-center.png と triptych-wing-*.png を書き出した"
                     + "（翼のファイルが翼の絵になっていれば PASS）")
        }

        if !didTimingChecks && since > timingAt {
            didTimingChecks = true
            instrument.checkClocks(stage, elapsed: since)
            instrument.checkFrameRates(stage, wings: wings, elapsed: since)
        }

        if didTimingChecks && !announcedDone {
            announcedDone = true
            Log.line("--- 判定 \(instrument.results.count) 件 ---")
            for r in instrument.results { Log.line("[\(r.id)] \(r.verdict)") }
            Log.line("self-check 完了")
        }
    }

    private func emitProbes() {
        for r in instrument.results { probe("check.\(r.id)", r.verdict) }
        probe("wings.open", wings.filter { $0.isOpen }.count)
        probe("lanterns", stage.lanterns.count)
        for (name, meter) in stage.meters {
            probe("drift.\(name).ms", meter.driftMs)
            probe("frames.\(name)", meter.frames)
        }
    }

    private func traceIfNeeded() {
        guard trace, time - lastTraceAt >= 2 else { return }
        lastTraceAt = time
        // NSWindow の総数も出す。開閉を繰り返して増え続けるなら、閉じた翼が解放されていない。
        var parts = ["t=\(fmt(time, 2))s", "中央 frame=\(frameCount)",
                     "NSWindow=\(Instrument.liveWindowCount)"]
        for (name, meter) in stage.meters.sorted(by: { $0.key < $1.key }) {
            parts.append("\(name): frames=\(meter.frames) own=\(fmt(meter.lastOwnTime, 2))s "
                         + "Δ=\(fmt(meter.lastDeltaMs, 1))ms drift=\(fmt(meter.driftMs, 1))ms")
        }
        for wing in wings {
            if let o = Instrument.origin(titled: wing.config.title) {
                parts.append("\(wing.panel.name)@(\(Int(o.x)),\(Int(o.y)))")
            }
        }
        Log.line("[trace] " + parts.joined(separator: " | "))
    }
}
