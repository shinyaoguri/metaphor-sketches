import Foundation
import metaphor

/// 0816-encore — 予約された動きだけでできた影絵劇場。
///
/// 舞台に 2 つの座組が並ぶ。振付（`Tween` の組み立て）も刻み方（フレームループ）も同じで、
/// **違いはアンコールのときに `tweenManager` へ登録し直すかどうかだけ**。
/// 1 公演目は見分けが付かない。アンコールを掛けると片方だけ役者が袖から出てこなくなる。
///
/// 裏では `Instrument` が同じ API を固定刻みで叩き、`PASS` / `FAIL` を出す。
/// 舞台に出る異常（出てこない役者）と、判定表の `FAIL M5.restartAfterComplete` は同じ現象。
@main
final class Sketch0816Encore: Sketch {
    var config: SketchConfig {
        SketchConfig(width: 1280, height: 720, title: "0816-encore")
    }

    // MARK: - 検査

    private var checks: [Verdict] = []
    private var frameChecks: [Verdict] = []
    private var frameChecksDone = false
    private var checkSummary = "self-check …"

    /// フレームループが本当に回すのか（M8）を見るための、既定の `tweenManager` に載る 1 本。
    private var autoDriven: Tween<Float>?
    /// `tween()` が start() まではしないこと（M9）を見るための、開始しない 1 本。
    private var neverStarted: Tween<Float>?
    private var countAfterSetup = 0

    // MARK: - 座組

    private var troupes: [Troupe] = []

    // MARK: - 観測の口

    private let shots = ProcessInfo.processInfo.environment["ENCORE_SHOTS"] == "1"
    private let trace = ProcessInfo.processInfo.environment["ENCORE_TRACE"] == "1"
    private let framesDir = ProcessInfo.processInfo.environment["ENCORE_FRAMES"]
    private let encoreLimit = ProcessInfo.processInfo.environment["ENCORE_ENCORES"].flatMap(Int.init)
    private var shotsTaken = Set<String>()
    private var lastTraceAt: Float = -1
    private var recording = false

    // MARK: - setup

    func setup() {
        frameRate(60)

        // 決定論的な検査（T / M / I 系）。自前の TweenManager を固定刻みで回すだけで、
        // 描画も時計も使わない。走らせるたびに同じ数値が出る。
        checks = Instrument.runAll()
        for v in checks { print(v.line) }
        fflush(stdout)

        // ここから先は既定の tweenManager に載る = SketchContext.beginFrame が毎フレーム叩く。
        let auto = tween(from: Float(0), to: Float(100), duration: 1.0, easing: Instrument.linear)
        auto.start()
        autoDriven = auto

        // tween() は「作って登録する」だけ。start() しなければ動かないし、除去もされない。
        neverStarted = tween(from: Float(0), to: Float(1), duration: 1.0, easing: Instrument.linear)

        // `tweenManager` は SketchContext のプロパティで、Sketch 側に素の別名は無い。
        // 触るには context 越しに書く（この 1 段が要ることも記録に残す）。
        countAfterSetup = context.tweenManager.count

        troupes = [
            Troupe(title: "座組 甲 — 預けたまま",
                   note: "アンコールは reset() → start() だけ",
                   readmitsOnEncore: false,
                   manager: context.tweenManager,
                   marks: Stage.marks(panel: 0), wings: Stage.wings(panel: 0)),
            Troupe(title: "座組 乙 — 呼び戻す",
                   note: "アンコールの前に tweenManager.add() で登録し直す",
                   readmitsOnEncore: true,
                   manager: context.tweenManager,
                   marks: Stage.marks(panel: 1), wings: Stage.wings(panel: 1)),
        ]
        for t in troupes { t.openHouse() }

        if let dir = framesDir {
            // beginFrameRecord は絶対パスを尊重する（saveFrame は ~/Desktop/ を前置してしまう）
            beginFrameRecord(directory: dir)
            recording = true
        }
    }

    // MARK: - draw

    func draw() {
        for t in troupes { t.advance(deltaTime) }
        runFrameChecks()
        handleEncore()

        Stage.drawHouse(self)
        for (i, t) in troupes.enumerated() {
            Stage.drawStage(self, troupe: t, panel: i)
            Stage.drawCueSheet(self, troupe: t, panel: i, broken: !t.readmitsOnEncore && t.performance > 1)
        }
        Stage.drawChrome(self, checkSummary: checkSummary, failed: failedIDs(),
                         tweenCount: context.tweenManager.count,
                         encoreHint: "SPACE でアンコール")

        publishProbes()
        handleShots()
        handleTrace()
    }

    func keyPressed() {
        // SPACE = 客席の拍手。両座に同時にアンコールを掛ける
        if keyCode == 49 { callEncore() }
    }

    // MARK: - アンコール

    private func callEncore() {
        for t in troupes { t.encore() }
    }

    /// 1 公演が終わったら自動で次を掛ける。無人で回しても劇場は巡り続ける。
    private func handleEncore() {
        guard let first = troupes.first, first.performanceFinished else { return }
        if let limit = encoreLimit, first.performance >= limit {
            print("[encore] \(limit) 公演で終了")
            fflush(stdout)
            if recording { endFrameRecord() }
            exit(0)
        }
        callEncore()
    }

    // MARK: - フレームループ側の検査（M8 / M9 / M10）

    private func runFrameChecks() {
        guard !frameChecksDone, time >= 2.0,
              let auto = autoDriven, let idle = neverStarted else { return }
        frameChecksDone = true

        frameChecks.append(Verdict(
            id: "M8.autoRegisteredByFrameLoop",
            passed: auto.isComplete && Approx.eq(auto.value, 100),
            detail: "tween() 産を start() → \(Approx.f(time)) 秒後に isComplete=\(auto.isComplete)"
                + " 値 \(Approx.f(auto.value)) 期待=true/100.0000（既定の tweenManager をフレームループが叩く）"))

        frameChecks.append(Verdict(
            id: "M9.tweenDoesNotAutoStart",
            passed: !idle.isActive && !idle.isComplete && Approx.eq(idle.value, 0),
            detail: "tween() したまま start() しない 1 本: isActive=\(idle.isActive)"
                + " isComplete=\(idle.isComplete) 値 \(Approx.f(idle.value)) 期待=false/false/0.0000"))

        // 完了した auto は除去されるが、未 start の idle は残る。
        // 座組ぶんの Tween も載っているので、そこを差し引いた「余り」を見る。
        let troupeTweens = troupes.reduce(0) { $0 + 2 + $1.entrances.count * 3 }
        let leftover = context.tweenManager.count - troupeTweens
        frameChecks.append(Verdict(
            id: "M10.unstartedRetainedAcrossFrames",
            passed: leftover == 0,
            detail: "setup 直後 count=\(countAfterSetup) → \(Approx.f(time)) 秒後 count=\(context.tweenManager.count)"
                + "（うち座組ぶん \(troupeTweens)、余り \(leftover)）。"
                + " 完了した 1 本は外れるが、未 start の 1 本は残る（期待は余り 0）"))

        for v in frameChecks { print(v.line) }
        let all = checks + frameChecks
        let failed = all.filter { !$0.passed }
        if !failed.isEmpty {
            print("FAIL 一覧: " + failed.map(\.id).joined(separator: " "))
        }
        print("self-check 完了 \(all.count - failed.count)/\(all.count) PASS")
        fflush(stdout)
    }

    private func failedIDs() -> [String] {
        (checks + frameChecks).filter { !$0.passed }.map(\.id)
    }

    // MARK: - 観測

    private func publishProbes() {
        let all = checks + frameChecks
        checkSummary = all.isEmpty ? "self-check …"
            : "self-check \(all.filter(\.passed).count)/\(all.count) PASS"
        for v in all { probe("check.\(v.id)", v.detail) }

        probe("tweenManager.count", context.tweenManager.count)
        for (i, t) in troupes.enumerated() {
            probe("troupe\(i).performance", t.performance)
            probe("troupe\(i).elapsed", t.elapsed)
            probe("troupe\(i).curtainOpen", t.curtainOpen)
            // 立ち位置へ到達しているか。壊れた座組はアンコール以降ずっと 0 になる
            for j in t.entrances.indices {
                probe("troupe\(i).actor\(j).onstage", t.entrances[j].isComplete)
                probe("troupe\(i).actor\(j).active", t.entrances[j].isActive)
            }
        }
    }

    /// 場面ごとに 1 枚ずつ。巡回を待たずに絵を確かめるための口。
    private func handleShots() {
        guard shots, let t = troupes.first else { return }
        let scene: String?
        switch (t.performance, t.elapsed) {
        case (1, 7.0...7.2): scene = "encore-act1"        // 1 公演目、役者が出そろったところ
        case (1, 13.6...13.8): scene = "encore-bow"       // 会釈
        case (2, 7.0...7.2): scene = "encore-encore"      // アンコール。片方だけ出てこない
        default: scene = nil
        }
        guard let name = scene, !shotsTaken.contains(name) else { return }
        shotsTaken.insert(name)
        // saveFrame(_:) は渡した名前に無条件で ~/Desktop/ を前置する（metaphor#757）。
        // 引き取りは tools/probe.sh 側で行う
        saveFrame("\(name).png")
        print("[shot] \(name).png")
        fflush(stdout)
        if name == "encore-encore" {
            print("self-check 完了(shots)")
            fflush(stdout)
        }
    }

    /// 進行表を stdout へ。MCP が無いセッションでも状態を追える。
    private func handleTrace() {
        guard trace else { return }
        guard time - lastTraceAt >= 1.0 else { return }
        lastTraceAt = time
        var cols: [String] = []
        for t in troupes {
            let onstage = t.entrances.filter(\.isComplete).count
            let active = t.entrances.filter(\.isActive).count
            cols.append("\(t.title.prefix(6)) 公演\(t.performance) t=\(String(format: "%5.1f", t.elapsed))"
                + " 幕=\(String(format: "%.2f", t.curtainOpen)) 出=\(onstage)/\(t.entrances.count)"
                + " RUN=\(active)")
        }
        print("[trace] count=\(context.tweenManager.count)  " + cols.joined(separator: "  |  "))
        fflush(stdout)
    }
}
