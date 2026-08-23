import AppKit
import Foundation
import MetaphorSyphon
import metaphor

/// 交換台 — metaphor#792 で入れ替わった出力プラグインの配線を、盤面として見る作品。
///
/// 1 枚の最終フレームが分配バーから 4 口のジャックへ分岐する。各ジャックは出力プラグイン 1 本で、
/// **そのフレームで `post()` が実際に呼ばれた口だけランプが点く**。旧 `MetaphorOutputRegistry` は
/// 単一ファクトリで後勝ちに上書きしたので、複数の出力モジュールを同時に立てると片方が黙った。
/// この盤面はその「黙り」が絵として出る形をしている。
///
/// 盤面下段は交換手の記録簿で、`setup()` で 1 回だけ走る決定論的検査がそのまま並ぶ。
/// **数値の全文は `METAPHOR_PROBE=1` の frame.json と標準出力が一次記録**で、盤面は要約。
@main
final class Sketch0823Switchboard: Sketch {

    // MARK: 盤面の座標

    let trunkOrigin: (x: Float, y: Float) = (236, 158)
    let socketY: Float = 344
    let lampY: Float = 252

    // MARK: 状態

    let log = OutletLog.shared
    let syphonVersion = MetaphorSyphon.version
    private(set) var checks: [CheckResult] = []
    private(set) var jacks: [JackFace] = []
    /// Syphon サーバーの現況（`MetaphorRenderer.syphonOutput` 由来）。
    private(set) var syphonStatus = "—"
    /// 実配線に渡る要件と、そこから決まるレンダーループモードの再現。
    private(set) var wiring = "—"

    private let env = ProcessInfo.processInfo.environment
    private var trace = false
    private var shotsOnly = false
    private var framesDir: String?
    private var syphonNameCounter = 0
    /// レンダーループの実測用。この番号のフレームで自分のアプリを隠す。
    private var hideAtFrame: Int?
    private var hideArmed = false
    /// この番号のフレームで `stopSyphonServer()` を叩く（互換 facade の到達範囲を測る）。
    private var stopSyphonAtFrame: Int?
    private var stopArmed = false
    /// セカンダリウィンドウ（`SWITCHBOARD_WINDOW=1` のときだけ開く）。
    private var supervisor: SketchWindow?

    /// 対照実験の指定（`aperture` / `syphon` / `none`）。
    ///
    /// **空文字は未設定として扱う。** シェルから `VAR="${VAR:-}"` の形で渡すと空文字が入り、
    /// `!= nil` だけで見ると「1 本だけ」の枝へ落ちて全部が外れる（実際に一度これで嵌った）。
    /// metaphor-syphon が `METAPHOR_SYPHON_NAME` で取っているのと同じ規則。
    private static var solo: String? {
        guard let v = ProcessInfo.processInfo.environment["SWITCHBOARD_SOLO"], !v.isEmpty else { return nil }
        return v
    }

    // MARK: 起動時の provider 登録

    /// `SketchRunner` は `Sketch.init()` の**後**に provider を走査するので、
    /// ここで登録すれば実物の出力モジュール（ロード時に C コンストラクタから登録する
    /// metaphor-syphon）と同じ土俵に並べられる。
    init() {
        let solo = Self.solo
        let wantAperture = (solo == nil || solo == "aperture")
        let wantSilent = (solo == nil)
        let wantSyphon = (solo == nil || solo == "syphon")

        if wantAperture {
            MetaphorOutputProviders.register(TapProvider(
                id: "org.switchboard.provider.aperture",
                pluginID: Jack.aperture,
                requirements: []))
        }
        if wantSilent {
            MetaphorOutputProviders.register(SilentProvider())
        }
        if !wantSyphon {
            // metaphor-syphon は import しただけでロード時に自分を登録している。
            // 対照実験で外すのはこちらの仕事（unregister(id:) の実用例でもある）。
            MetaphorOutputProviders.unregister(id: "org.metaphor.syphon")
        }
    }

    // MARK: 設定

    var config: SketchConfig {
        SketchConfig(
            width: 1280, height: 800,
            title: "0823-switchboard",
            fps: 60,
            windowScale: 1.0,
            // あえて既定のまま。Syphon が externalRenderLoop を宣言するので、
            // 実配線では timer へ切り替わるはず（O3）。
            renderLoopMode: .displayLink,
            plugins: Self.configuredPlugins()
        )
    }

    /// `SketchConfig.plugins` から生えるぶん。provider 経由とは別の入口。
    private static func configuredPlugins() -> [PluginFactory] {
        let solo = solo
        var factories: [PluginFactory] = [
            // 出力ではない通常プラグイン。出力フェーズの境目を測る対照。
            PluginFactory { LineMonitorPlugin() }
        ]
        if solo == nil {
            // 出力プラグインだが requirements は空。「出力 = 常に timer」ではないことの確認も兼ねる。
            factories.append(PluginFactory { TapPlugin(id: Jack.ledger) })
        }
        if solo == nil || solo == "syphon" {
            factories.append(.syphon(name: "Switchboard"))
        }
        return factories
    }

    // MARK: setup

    func setup() {
        trace = env["SWITCHBOARD_TRACE"] == "1"
        shotsOnly = env["SWITCHBOARD_SHOTS"] == "1"
        framesDir = env["SWITCHBOARD_FRAMES"]
        hideAtFrame = env["SWITCHBOARD_HIDE_AT"].flatMap(Int.init)
        stopSyphonAtFrame = env["SWITCHBOARD_STOP_SYPHON_AT"].flatMap(Int.init)

        // 配線サマリは検査より**先**に取る。検査は provider の登録を一時的に触るので、
        // 後で取ると「この起動で実際に何が付いたか」ではなく検査後の状態を写してしまう。
        let summary = Inspector.wiringSummary(config: config)
        wiring = "requirements.rawValue=\(summary.requirements.rawValue) resolved=\(label(summary.resolved))"

        checks = Inspector.runAll()
        for check in checks { print(check.line) }

        jacks = buildJacks()
        for jack in jacks {
            print("jack\t\(jack.pluginID)\tpatched=\(jack.patched)\troute=\(jack.route)")
        }
        print("wiring\t\(wiring)")
        print("providers\t\(MetaphorOutputProviders.registered.map(\.id).joined(separator: ","))")
        fflush(stdout)

        if env["SWITCHBOARD_WINDOW"] == "1" { openSupervisorWindow() }
        if let dir = framesDir { beginFrameRecord(directory: dir) }
    }

    /// 盤面に並べる 4 口。`patched` は**実際にレンダラーへ付いたか**で決める
    /// （宣言しただけで付いていない口を「差さっている」と描かないため）。
    private func buildJacks() -> [JackFace] {
        let xs: [Float] = [320, 560, 800, 1040]
        return [
            JackFace(
                pluginID: Jack.aperture, title: "APERTURE",
                route: "provider → makeOutput()", x: xs[0],
                patched: plugin(id: Jack.aperture) != nil, evidence: .arrival),
            JackFace(
                pluginID: Jack.ledger, title: "LEDGER",
                route: "SketchConfig.plugins", x: xs[1],
                patched: plugin(id: Jack.ledger) != nil, evidence: .arrival),
            JackFace(
                pluginID: Jack.syphon, title: "SYPHON",
                route: ".syphon(name:) — 別パッケージ", x: xs[2],
                patched: plugin(id: Jack.syphon) != nil, evidence: .attachment),
            JackFace(
                pluginID: Jack.silent, title: "SILENT",
                route: "provider → nil", x: xs[3],
                patched: plugin(id: Jack.silent) != nil, evidence: .arrival),
        ]
    }

    private func label(_ mode: RenderLoopMode) -> String {
        switch mode {
        case .displayLink: return "displayLink"
        case .timer(let fps): return "timer(\(fps))"
        }
    }

    // MARK: draw

    func draw() {
        // 直前フレームの到着を確定させてから描く（draw() は post() より前に走る）。
        log.beginFrame(frameCount)
        refreshSyphonStatus()

        drawBoard()
        emitProbes()

        if trace { traceArrivals() }
        handleStopSyphonProbe()
        handleOcclusionProbe()
        handleExitConditions()
    }

    /// Syphon の現況。`Sketch` からレンダラーは見えないので、
    /// 出力プラグインが `onAttach(renderer:)` で掴んだ参照を通す。
    private func refreshSyphonStatus() {
        guard let output = log.renderer?.syphonOutput else {
            syphonStatus = "no server"
            return
        }
        syphonStatus = output.isActive ? (output.serverName ?? "(unnamed)") : "stopped"
    }

    private func emitProbes() {
        for check in checks {
            probe("check.\(check.id)", "\(check.passed ? "PASS" : "FAIL") \(check.detail)")
        }
        probe("outlets.settledFrame", log.settledFrame)
        probe("outlets.order", log.settled.map(\.id).joined(separator: ","))
        probe("outlets.outputPhaseIsLast", outputPhaseIsLast())
        for jack in jacks {
            let short = jack.title.lowercased()
            probe("outlets.\(short).patched", jack.patched)
            probe("outlets.\(short).total", log.totals[jack.pluginID] ?? 0)
        }
        probe("syphon.status", syphonStatus)
        probe("wiring", wiring)
        probe("providers", MetaphorOutputProviders.registered.map(\.id).joined(separator: ","))
        if supervisor != nil { probe("window.total", log.windowTotal) }
    }

    /// 出力プラグインの `post()` が、通常プラグインすべての後に来ているか。
    private func outputPhaseIsLast() -> Bool {
        guard let firstOutput = log.settled.firstIndex(where: { $0.isOutput }) else {
            // 出力が 1 本も無いフレームは判定対象外（真偽としては「破れていない」）。
            return true
        }
        return !log.settled[firstOutput...].contains { !$0.isOutput }
    }

    private func traceArrivals() {
        let order = log.settled
            .map { "\($0.order + 1):\($0.id)\($0.isOutput ? "[out]" : "")" }
            .joined(separator: " ")
        print("trace\tframe=\(log.settledFrame)\t\(order)")
        fflush(stdout)
    }

    // MARK: 操作

    func keyPressed() {
        guard let key else { return }
        switch key {
        case "s", "S": toggleSyphonServer()
        case "r", "R": renameSyphonServer()
        default: break
        }
    }

    /// `MetaphorRenderer.startSyphonServer(name:)` / `stopSyphonServer()`（互換 facade）を実際に叩く。
    private func toggleSyphonServer() {
        guard let renderer = log.renderer else { return }
        if renderer.syphonOutput?.isActive == true {
            renderer.stopSyphonServer()
            print("syphon\tstopped")
        } else {
            renderer.startSyphonServer(name: "Switchboard")
            print("syphon\tstarted as Switchboard")
        }
        fflush(stdout)
        jacks = buildJacks()
    }

    /// `SyphonOutput.rename(_:)`。サーバーを立て直さずに名前だけ貼り替える。
    private func renameSyphonServer() {
        guard let output = log.renderer?.syphonOutput else { return }
        syphonNameCounter += 1
        let name = "Switchboard-\(syphonNameCounter)"
        output.rename(name)
        print("syphon\trenamed to \(name)")
        fflush(stdout)
    }

    // MARK: セカンダリウィンドウ（監督卓）

    /// `SketchWindowConfig.plugins` は metaphor#792 M1 で入った口。
    /// **セカンダリウィンドウには環境変数（`METAPHOR_SYPHON_NAME`）が当たらない**設計なので、
    /// 窓ごとの出力はここで宣言するしかない。それが実際に効くかを見る。
    private func openSupervisorWindow() {
        let cfg = SketchWindowConfig(
            width: 520, height: 240,
            title: "SUPERVISOR",
            fps: 60,
            windowScale: 1.0,
            plugins: [
                PluginFactory { WindowTapPlugin() },
                .syphon(name: "Switchboard-Supervisor"),
            ])
        guard let window = createWindow(cfg) else {
            print("window\tcreateWindow が nil を返した")
            fflush(stdout)
            return
        }
        supervisor = window
        window.onDraw { [weak self] ctx in self?.drawSupervisor(ctx) }
        print("window\topened\ttitle=\(cfg.title)\tplugins=\(cfg.plugins.count)")
        fflush(stdout)
    }

    /// 監督卓。主盤のランプだけを抜き出した小さな窓。
    private func drawSupervisor(_ ctx: SketchContext) {
        ctx.background(Palette.panelDeep.0, Palette.panelDeep.1, Palette.panelDeep.2)
        ctx.noStroke()
        ctx.fill(Palette.brass.0, Palette.brass.1, Palette.brass.2)
        ctx.textSize(14)
        ctx.text("SUPERVISOR", 24, 40)
        ctx.textSize(10)
        ctx.fill(Palette.inkDim.0, Palette.inkDim.1, Palette.inkDim.2)
        ctx.text("SketchWindowConfig.plugins から生えた出力: \(log.windowTotal) frames", 24, 60)

        for (i, jack) in jacks.enumerated() {
            let x = 60 + Float(i) * 110
            let lit = jack.evidence == .arrival ? log.lit(jack.pluginID) : jack.patched
            ctx.fill(lit ? Palette.lampOn.0 : Palette.lampOff.0,
                     lit ? Palette.lampOn.1 : Palette.lampOff.1,
                     lit ? Palette.lampOn.2 : Palette.lampOff.2)
            ctx.circle(x, 140, 34)
            ctx.fill(Palette.inkDim.0, Palette.inkDim.1, Palette.inkDim.2)
            ctx.textSize(10)
            ctx.textAlign(.center, .baseline)
            ctx.text(jack.title, x, 180)
            ctx.textAlign(.left, .baseline)
        }
    }

    /// `stopSyphonServer()` がどこまで届くかの実測。
    ///
    /// `plugin(id:)` / `removePlugin(id:)` は同じ `pluginID` の**最初の 1 本**にしか届かない
    /// （metaphor の `MetaphorRenderer` が警告で言っているとおり）。provider 経由と
    /// `.syphon(name:)` 経由で 2 本生えた状態では、何本が止まるのかを数える。
    private func handleStopSyphonProbe() {
        guard let at = stopSyphonAtFrame, !stopArmed, frameCount >= at else { return }
        stopArmed = true
        log.renderer?.stopSyphonServer()
        print("stopSyphon\tcalled at frame=\(frameCount)\tremaining plugin(id:)=\(plugin(id: Jack.syphon) != nil)")
        fflush(stdout)
    }

    // MARK: レンダーループの実測

    /// 自分のアプリを隠して、フレームが進み続けるかを**実時間で**測る。
    ///
    /// `.displayLink` 駆動ならウィンドウが見えない間は描画が止まり、`.timer(fps:)` 駆動なら
    /// 回り続ける。Syphon（`externalRenderLoop`）の有無で結果が変わるはず、というのが O3。
    /// 経過時間に `time` を使うと、止まったときに永久に待つので実時間で測る。
    private func handleOcclusionProbe() {
        guard let at = hideAtFrame, !hideArmed, frameCount >= at else { return }
        hideArmed = true
        let atHide = frameCount
        let how = env["SWITCHBOARD_HIDE_HOW"] ?? "miniaturize"
        print("occlude\thidden\tframe=\(atHide)\thow=\(how)\twiring=\(wiring)")
        fflush(stdout)
        switch how {
        case "hide": NSApplication.shared.hide(nil)
        default: NSApplication.shared.windows.first?.miniaturize(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            let advanced = self.frameCount - atHide
            print("occlude\tafter5s\tadvanced=\(advanced)\t≈\(advanced / 5) fps")
            fflush(stdout)
            NSApplication.shared.unhide(nil)
            NSApplication.shared.windows.first?.deminiaturize(nil)
            self.finish()
        }
    }

    // MARK: 終了条件（無人観測用）

    private func handleExitConditions() {
        if shotsOnly, frameCount == 90 {
            saveFrame("output/board.png")
        }
        if shotsOnly, frameCount >= 92 {
            finish()
        }
        if framesDir != nil, frameCount >= 360 {
            endFrameRecord()
            finish()
        }
    }

    private func finish() {
        fflush(stdout)
        // draw() の中から terminate すると進行中のフレームを掴んだまま落ちる。
        // 次のランループまで送って、フレームが畳まれてから終える。
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }
}
