import AppKit
import Foundation
import MetaphorSyphon
import metaphor

/// # 0823-darkroom — 暗室
///
/// 1 枚の原版が 3 つの現像槽を通り、**3 本の Syphon 線**で外へ出ていく。
///
/// | 窓 | 槽 | Syphon |
/// |---|---|---|
/// | A（プライマリ）| 素通し | `darkroom - A` |
/// | B（`createWindow`）| `MPSSobelEffect` — 輪郭だけ残す | `darkroom - B` |
/// | C（`createWindow`）| `MPSDilateEffect` + `MPSBlurEffect` — 太らせて眠らせる | `darkroom - C` |
///
/// **連動 = 3 窓が同じ 1 つの状態から同じ原版を描く。** 状態（`Darkroom`）は 1 つしかなく、
/// 窓ごとに違うのは現像槽だけ。だから 3 本の Syphon は**同じ瞬間の・違う顔**になる。
///
/// セカンダリ窓の Syphon は `SketchWindowConfig.plugins` の `.syphon(name:)` でしか生えない
/// （`METAPHOR_SYPHON_NAME` は provider が `case .window: return nil` で弾く）。
/// この作品はそこを含めて、3 本が**取り違えていないか・連動しているか**を外から数値で確かめる。
/// 判定表は [metaphor-sketches#25](https://github.com/shinyaoguri/metaphor-sketches/issues/25)。
@main
final class Sketch0823Darkroom: Sketch {
    var config: SketchConfig {
        SketchConfig(
            width: Int(Plate.width),
            height: Int(Plate.height),
            title: "0823-darkroom — \(Bath.primary.label)",
            fps: 60,
            windowScale: 0.32,
            plugins: [Bath.primary.syphonFactory, Witness.factory(bathID: Bath.primary.id)]
        )
    }

    private let room = Darkroom()
    private let instrument = Instrument()

    /// 槽 3 つ。先頭がプライマリ。
    private var stations: [Station] = []

    /// 検査の段取り。それぞれ 1 回だけ。
    private var didArrange = false
    private var didServerChecks = false
    private var didLifecycleClose = false
    private var didLifecycleReopen = false
    /// D11 — プライマリの Syphon を 1 回だけ止めてみる（`DARKROOM_STOPTEST=1`）。
    private let stopTest = ProcessInfo.processInfo.environment["DARKROOM_STOPTEST"] == "1"
    private var didStopTest = false
    private var didRebase = false
    private var didClockChecks = false
    private var didShots = false
    private var announcedDone = false

    /// D7 — この秒数でアプリを隠し、隠したあとも publish が続くかを見る（`DARKROOM_HIDE_AT`）。
    private let hideAt = ProcessInfo.processInfo.environment["DARKROOM_HIDE_AT"].flatMap(Float.init)
    private var didHide = false
    private var didHideJudge = false
    /// 隠す直前の、槽ごとの publish 回数。
    private var postsBeforeHide: [String: Int] = [:]

    private var lastTraceAt: Float = -99
    private let trace = ProcessInfo.processInfo.environment["DARKROOM_TRACE"] == "1"
    private let shots = ProcessInfo.processInfo.environment["DARKROOM_SHOTS"] == "1"
    private let framesDir = ProcessInfo.processInfo.environment["DARKROOM_FRAMES"]

    /// 検査の時刻割（秒）。**サーバーは attach 時に生えるが、窓の実寸と最初のフレームは
    /// 数フレーム待たないと確定しない**ので、読み取りは少し遅らせる。
    private let serversAt: Float = 4
    private let closeAt: Float = 10
    private let reopenAt: Float = 13
    /// **読み戻しを伴う検査が済んでから**クロックの基準を取り直す時刻。
    private let rebaseAt: Float = 15
    private let clocksAt: Float = 25
    private let shotsAt: Float = 20

    // MARK: - 立ち上げ

    func setup() {
        // 連番を書き出すときは 3 枚とも 20fps へ落とす。
        // **PNG を毎フレーム書くと 3 枚が目標 fps を落とし、落ち方が枚数ごとに違う**ので、
        // フレーム番号で並べた GIF に「本当は無い継ぎ目」が出る（0816-triptych で踏んだ）。
        if framesDir != nil { frameRate(Bath.recordingFPS) }

        stations = [Station(bath: Bath.primary)]
        Log.line("[metaphor] 0823-darkroom / 原版 \(Int(Plate.width))×\(Int(Plate.height))"
                 + " / 槽 \(Bath.all.count) 本"
                 + (Bath.anonymous ? " / DARKROOM_ANON=1（名前を省略して .syphon() で立てる）" : ""))

        for bath in Bath.secondaries {
            let station = Station(bath: bath)
            station.open(with: { [weak self] in self?.createWindow($0) }, room: room)
            stations.append(station)
        }

        // プライマリの槽は素通しだが、他の窓と同じ手順を通すために同じ口から入れる。
        Bathhouse.apply(phase: room.phase, to: context, bath: Bath.primary)
        stations[0].appliedPhase = room.phase

        let opened = stations.filter { $0.isOpen }.count
        Log.line("[窓] \(opened)/\(stations.count) 枚（A はプライマリ）")

        if let dir = framesDir {
            beginFrameRecord(directory: dir + "/A", pattern: "frame_%05d.png")
            for station in stations.dropFirst() {
                station.window?.context.beginFrameRecord(
                    directory: dir + "/" + station.bath.id, pattern: "frame_%05d.png"
                )
            }
            Log.line("[連番] \(dir) へ 3 枚ぶん書き出す")
        }
    }

    // MARK: - 毎フレーム

    func draw() {
        // 共有時計。プライマリがここで進め、槽は自分のレンダーループからこれを読む。
        room.clock = time
        room.frame = frameCount

        let phase = Phase.at(time)
        if phase != room.phase {
            room.phase = phase
            Log.line("[工程] \(phase.name)"
                     + (phase.bathsEngaged ? "" : "（槽を外す — 3 窓とも原版に戻る）"))
        }

        // プライマリの槽。工程が変わった瞬間だけ入れ替える（毎フレーム置き換えない）。
        if stations[0].appliedPhase != room.phase {
            Bathhouse.apply(phase: room.phase, to: context, bath: Bath.primary)
            stations[0].appliedPhase = room.phase
        }

        Plate.render(into: context, bath: Bath.primary, room: room)

        runChecks()
        emitProbes()
        traceIfNeeded()
    }

    // MARK: - 検査の段取り

    private func runChecks() {
        // **録画中は検査を走らせない。**
        // - `loadPixels()`（D5）は GPU 待ちでフレームを落とす → 窓ごとに枚数が食い違う
        // - 窓の開閉（D6）は窓ごと作り直すので、`beginFrameRecord` の設定も一緒に消える
        //   （実測: C だけ 76 枚。閉じるまでのぶんしか録れていなかった）
        // 録画は「作品を見せる」ためのモードなので、判定はふつうの起動（tools/probe.sh cycle）で取る。
        guard framesDir == nil else {
            if !announcedDone {
                announcedDone = true
                Log.line("[連番] 録画中のため検査は走らせない（判定は tools/probe.sh cycle で取る）")
            }
            return
        }

        // 3 枚を横に並べる（位置 API が無いので AppKit で置く）。窓の実寸は最初のフレームが
        // 出るまで確定しないので、検査と同じタイミングまで待ってから当てる。
        if !didArrange && time > serversAt {
            didArrange = true
            let order = stations.map { $0.isPrimary
                ? "0823-darkroom — \(Bath.primary.label)"
                : $0.bath.windowConfig().title }
            if let rect = Arrangement.apply(order: order) {
                Log.line("[配置] 3 枚を並べた 撮影範囲(左下原点)=(\(Int(rect.minX)),\(Int(rect.minY)))"
                         + " \(Int(rect.width))×\(Int(rect.height))")
            }
        }

        if !didServerChecks && time > serversAt {
            didServerChecks = true
            instrument.checkWindows(stations, room: room)
            instrument.checkServers(stations)
            instrument.checkEnvironmentScope(stations)
            instrument.checkAnonymousNames(stations)
            instrument.checkReadbackStage(primary: context, stations: stations, room: room)
        }

        // D6 — 閉じる → サーバーが消えるか → 開き直して復活するか。
        // 1 回だけ。受け手（MadMapper 等）を長く待たせないよう、C だけを畳む。
        if didServerChecks && !didLifecycleClose && time > closeAt {
            didLifecycleClose = true
            instrument.closeForLifecycle(stations)
        }
        if didLifecycleClose && !didLifecycleReopen && time > reopenAt {
            didLifecycleReopen = true
            instrument.reopenForLifecycle(
                stations, room: room, make: { [weak self] in self?.createWindow($0) }
            )
        }

        if shots && !didShots && time > shotsAt {
            didShots = true
            // saveFrame(_:) の出力先は metaphor 0.10 以降 <project>/output/ 配下。
            saveFrame("darkroom-A.png")
            for station in stations.dropFirst() {
                station.window?.context.saveFrame("darkroom-\(station.bath.id).png")
            }
            Log.line("[shots] output/ へ 3 枚書き出した"
                     + "（B が輪郭・C が肉付きになっていれば槽が効いている）")
        }

        // D11 — 同じ pluginID の Syphon が 2 本並んだとき、facade はどちらを掴むか。
        if stopTest, didServerChecks, !didStopTest, time > closeAt - 2 {
            didStopTest = true
            instrument.checkStopFacade(stations)
        }

        // D8 の下ごしらえ。ここまでの検査（loadPixels の GPU 待ち・窓の開閉）が作ったずれを
        // 判定に持ち込まないよう、基準を取り直してから測り始める。
        if didLifecycleReopen && !didRebase && time > rebaseAt {
            didRebase = true
            for meter in room.meters.values { meter.rebase() }
            Log.line("[D8] t=\(fmt(time, 1))s でクロックの基準を取り直した（検査の自己影響を落とす）")
        }

        if didRebase && !didClockChecks && time > clocksAt {
            didClockChecks = true
            instrument.checkClocks(room, stations: stations, elapsed: time - rebaseAt)
            instrument.checkFilterExpectations(stations)
        }

        // D7 — 隠しても publish が続くか。`.externalRenderLoop` が効いていれば
        // レンダーループはタイマー駆動になり、不可視でも止まらないはず。
        if let at = hideAt, !didHide, time > at {
            didHide = true
            postsBeforeHide = Dictionary(
                uniqueKeysWithValues: stations.map { ($0.bath.id, Witness.all[$0.bath.id]?.posts ?? 0) }
            )
            NSApplication.shared.hide(nil)
            Log.line("[occlude] t=\(fmt(time, 1))s でアプリを隠した"
                     + " posts=\(postsBeforeHide.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
        if didHide, !didHideJudge, let at = hideAt, time > at + 4 {
            didHideJudge = true
            instrument.checkOcclusion(stations, before: postsBeforeHide, seconds: 4)
        }

        if didClockChecks && !announcedDone && (hideAt == nil || didHideJudge) {
            announcedDone = true
            Log.line("--- 判定 \(instrument.results.count) 件 ---")
            for r in instrument.results { Log.line("\(r.verdict) \(r.id)  \(r.detail)") }
            Log.line("外から 3 本を読む: tools/syphon-read.sh")
            Log.line("self-check 完了")
        }
    }

    private func emitProbes() {
        for r in instrument.results {
            probe("check.\(r.id)", "\(r.verdict) \(r.detail)")
        }
        probe("phase", room.phase.name)
        probe("windows.open", stations.filter { $0.isOpen }.count)
        for station in stations {
            let id = station.bath.id
            probe("syphon.\(id)", Witness.all[id]?.syphonServerName ?? "(none)")
            probe("posts.\(id)", Witness.all[id]?.posts ?? 0)
            if let meter = room.meters[id] {
                probe("drift.\(id).ms", meter.driftMs)
                probe("frames.\(id)", meter.frames)
            }
        }
    }

    private func traceIfNeeded() {
        guard trace, time - lastTraceAt >= 2 else { return }
        lastTraceAt = time
        var parts = ["t=\(fmt(time, 2))s", "A frame=\(frameCount)", "工程=\(room.phase.name)"]
        for station in stations {
            let id = station.bath.id
            let w = Witness.all[id]
            var s = "\(id): posts=\(w?.posts ?? 0) syphon=\(w?.syphonServerName ?? "-")"
            if let meter = room.meters[id] {
                s += " frames=\(meter.frames) Δ=\(fmt(meter.lastDeltaMs, 1))ms"
                    + " drift=\(fmt(meter.driftMs, 1))ms"
            }
            parts.append(s)
        }
        Log.line("[trace] " + parts.joined(separator: " | "))
    }
}

// MARK: - 槽 1 つぶんの持ち物

/// 槽 = 窓 + そこに立つ Syphon + いま適用している工程。
///
/// プライマリも同じ型で扱う（`window` が `nil` なのがプライマリ）。開閉のたびに
/// `window` だけが作り直され、`bath` は変わらない。
@MainActor
final class Station {
    let bath: Bath
    private(set) var window: SketchWindow?
    /// この窓に最後に適用した工程。`nil` ならまだ一度も入れていない。
    var appliedPhase: Phase?

    init(bath: Bath) {
        self.bath = bath
    }

    /// プライマリか（プライマリは `createWindow` で作らないので `window` を持たない）。
    var isPrimary: Bool { bath.id == Bath.primary.id }

    var isOpen: Bool { isPrimary ? true : (window?.isOpen ?? false) }

    /// この槽が描く先。プライマリだけは呼び出し側が `context` を渡す。
    var context: SketchContext? { window?.context }

    /// 窓を開き、この槽ぶんの描画クロージャを据える。
    @discardableResult
    func open(with make: (SketchWindowConfig) -> SketchWindow?, room: Darkroom) -> SketchWindow? {
        guard !isPrimary, window?.isOpen != true else { return window }
        guard let w = make(bath.windowConfig()) else {
            Log.line("[窓] \(bath.label) を開けなかった")
            return nil
        }
        window = w
        appliedPhase = nil

        let bath = self.bath
        let meter = BathMeter()
        room.meters[bath.id] = meter

        // `onDraw(_:)` は 1 回据えれば毎フレーム走る（毎フレーム設定し直す必要はない）。
        w.onDraw { [weak self, weak room] ctx in
            guard let room else { return }
            meter.sample(
                own: ctx.time, ownFrameCount: ctx.frameCount,
                shared: room.clock, sharedFrame: room.frame
            )
            // 工程が変わった瞬間だけ槽を入れ替える。**自分のレンダーループの中で触る**
            // （別ループから他の窓の PostEffect 列を差し替えない）。
            if let self, self.appliedPhase != room.phase {
                Bathhouse.apply(phase: room.phase, to: ctx, bath: bath)
                self.appliedPhase = room.phase
            }
            // 針の角度は共有時計だけで決まる。DARKROOM_CLOCK=own のときだけ自分の時計を使う
            // （連動が壊れた状態を見るための対照）。
            let saved = room.clock
            if room.useOwnClock { room.clock = ctx.time }
            Plate.render(into: ctx, bath: bath, room: room)
            room.clock = saved
        }
        return w
    }

    func close() {
        window?.close()
        window = nil
        appliedPhase = nil
    }
}
