import AppKit
import Foundation
import MetalKit
import metaphor

/// 作品自身が持つ検査係。
///
/// 判定は真偽値ではなく **実測値を含む文字列**にする（`FAIL ... drift=48.2ms 期待<33.4`）。
/// 後から issue に貼るとき、数字がそのまま証拠になるため。判定は
/// `probe("check.<ID>", ...)` と標準出力の両方へ出す。
///
/// 検査を 2 段に分けてあるのは、**ウィンドウを作っては壊す検査が作品を壊すから**。
/// セカンダリウィンドウのカスケード位置は減らない静的カウンタで決まるので
/// （`SketchWindow.swift` の `windowCounter`）、検査でウィンドウを 6 枚開けば、
/// 本番の翼はその分だけ右下へずれて生まれる。常時実行するのは軽い検査だけにして、
/// 破壊的な検査は `TRIPTYCH_SELFTEST=1`（`tools/probe.sh check` が立てる）に隔離する。
@MainActor
final class Instrument {
    /// 判定結果。ID 順に並べて出す。probe には毎フレーム載せる。
    private(set) var results: [(id: String, verdict: String)] = []
    private var seen: Set<String> = []

    static let selfTestEnabled = ProcessInfo.processInfo.environment["TRIPTYCH_SELFTEST"] == "1"

    func emit(_ id: String, _ verdict: String) {
        guard !seen.contains(id) else { return }
        seen.insert(id)
        results.append((id, verdict))
        Log.line("[\(id)] \(verdict)")
    }

    func judge(_ id: String, _ ok: Bool, _ detail: String) {
        emit(id, "\(ok ? "PASS" : "FAIL") \(detail)")
    }

    // MARK: - AppKit 側から測る

    /// タイトルで NSWindow を引く。metaphor の公開 API はウィンドウの位置も実寸も返さないので、
    /// **AppKit から直接測る**。ここは metaphor の外側の道具。
    static func nsWindow(titled title: String) -> NSWindow? {
        NSApplication.shared.windows.first { $0.title == title }
    }

    static func origin(titled title: String) -> CGPoint? {
        nsWindow(titled: title)?.frame.origin
    }

    /// 生きている NSWindow の数。閉じた翼が解放されずに積み上がっていないかを見る。
    static var liveWindowCount: Int { NSApplication.shared.windows.count }

    // MARK: - W 群（軽い検査。毎回走る）

    /// 実際の翼を材料に、生成と設定の往復を確かめる。
    func checkWings(_ wings: [Wing], primary: SketchContext) {
        guard let first = wings.first else { return }

        let allOpen = wings.allSatisfy { $0.isOpen }
        judge("W1", allOpen && !wings.isEmpty,
              "createWindow → 翼 \(wings.count) 枚中 \(wings.filter { $0.isOpen }.count) 枚が isOpen")

        guard let w = first.window else {
            emit("W2", "SKIP 翼を作れなかった")
            return
        }
        let c = first.config
        let echoed = w.config
        let same = echoed.width == c.width && echoed.height == c.height
            && echoed.title == c.title && echoed.fps == c.fps
            && echoed.windowScale == c.windowScale && echoed.syphonName == nil
        judge("W2", same,
              "config の往復 w=\(echoed.width) h=\(echoed.height) fps=\(echoed.fps) "
              + "scale=\(fmt(echoed.windowScale, 2)) title=\"\(echoed.title)\"")

        let ctxW = w.context.width
        let ctxH = w.context.height
        judge("W3", ctxW == Float(c.width) && ctxH == Float(c.height),
              "context の寸法 = \(fmt(ctxW, 0))×\(fmt(ctxH, 0)) 期待=\(c.width)×\(c.height)"
              + "（ウィンドウ実寸 \(fmt(Float(c.width) * c.windowScale, 0))×"
              + "\(fmt(Float(c.height) * c.windowScale, 0)) ではなくテクスチャ空間）")

        var distinct = w.context !== primary && w.input !== primary.input
        for a in wings.compactMap({ $0.window }) where a !== w {
            distinct = distinct && a.context !== w.context && a.input !== w.input
        }
        judge("W4", distinct, "context / input が翼ごとにもプライマリとも別インスタンス")

        // syphonName を渡したときの renderLoopMode 自動昇格（doc の主張）は、
        // 昇格が setupRenderLoop 内のローカル変数で完結していて config に戻らない。
        emit("W6", "N/A `syphonName` 指定時の `.timer(fps:)` 自動昇格は公開 API から観測できない"
             + "（`window.config.renderLoopMode` は渡した値のまま。SketchWindow.setupRenderLoop の局所変数）")
    }

    /// ウィンドウの位置。**祭壇画として左右に翼を置けるか。**
    func checkPlacement(_ wings: [Wing], primaryTitle: String) {
        let primary = Self.origin(titled: primaryTitle)
        var lines: [String] = []
        if let p = primary { lines.append("中央=(\(Int(p.x)),\(Int(p.y)))") }
        for wing in wings {
            if let o = Self.origin(titled: wing.config.title) {
                lines.append("\(wing.panel.name)=(\(Int(o.x)),\(Int(o.y)))")
            }
        }
        // 位置を指定する API が無いので「左翼が中央より左にある」は偶然にしか成り立たない。
        var laidOut = false
        if let p = primary,
           let l = Self.origin(titled: wings.first?.config.title ?? "") {
            laidOut = l.x < p.x
        }
        judge("W7", laidOut,
              "SketchWindowConfig に位置指定が無く、既定は 30px カスケードのみ。実位置 "
              + lines.joined(separator: " ") + "（左翼が中央の左に来ていれば PASS）")
    }

    /// 翼のウィンドウ中央を押したら、テクスチャ座標の中央が返るか。
    ///
    /// 実際にクリックしなくても、公開されている `viewToTextureCoordinates` を
    /// ウィンドウの実寸で呼べば同じ経路を通せる（`MetaphorMTKView` がやっているのと同じ計算）。
    func checkPointerMapping(_ wings: [Wing]) {
        guard let wing = wings.first, let w = wing.window else {
            emit("S4", "SKIP 翼が無い")
            return
        }
        guard let nsw = Self.nsWindow(titled: wing.config.title),
              let view = nsw.contentView as? MTKView, view.bounds.width > 0
        else {
            emit("S4", "SKIP MTKView をまだ取れない")
            return
        }
        let p = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let (tx, ty) = w.context.renderer.viewToTextureCoordinates(
            viewPoint: p, viewSize: view.bounds.size, drawableSize: view.drawableSize
        )
        let ex = Float(wing.config.width) / 2
        let ey = Float(wing.config.height) / 2
        let err = max(abs(tx - ex), abs(ty - ey))
        judge("S4", err < 1.0,
              "windowScale=\(fmt(wing.config.windowScale, 2)) の翼で、ウィンドウ中央 "
              + "(\(fmt(Float(view.bounds.midX), 0)),\(fmt(Float(view.bounds.midY), 0))) pt → "
              + "テクスチャ (\(fmt(tx)),\(fmt(ty))) 期待=(\(fmt(ex)),\(fmt(ey))) 誤差=\(fmt(err, 2))px")
    }

    /// 翼で起きた入力が、その翼だけに届くか。
    ///
    /// 実際にマウスを動かさなくても、AppKit のイベントキューへ**本物の `NSEvent` を積めば**
    /// 同じ配送経路（`NSApp` → 対象ウィンドウ → `MetaphorMTKView` → その窓の `InputManager`）を通せる。
    /// ビューの `mouseDown(with:)` を直接呼ぶと配送そのものを飛ばしてしまうので、`postEvent` を使う。
    ///
    /// 2 手に分かれる: `postClicks` で積んで、次のフレームに `judgeClicks` で読む
    /// （積んだイベントはランループが回ってから配送されるため）。
    private var beforeClick: [String: SIMD2<Float>] = [:]

    func postClicks(_ wings: [Wing], primary: SketchContext) {
        beforeClick["primary"] = SIMD2(primary.input.mouseX, primary.input.mouseY)
        for wing in wings {
            guard let w = wing.window else { continue }
            beforeClick[wing.panel.name] = SIMD2(w.input.mouseX, w.input.mouseY)
        }
        // 左翼だけを叩く。中央と右翼は動かないままのはず。
        // **同じ合成イベントをプライマリにも 1 発投げる**（対照）。プライマリも動かなければ、
        // 「翼に届かない」のではなく「合成イベントがそもそも配送されない」= ハーネスの限界。
        if let target = wings.first { click(titled: target.config.title) }
        click(titled: primaryTitle)
    }

    /// 判定に使うプライマリのタイトル。`postClicks` の対照用。
    var primaryTitle = ""

    private func click(titled title: String) {
        guard let nsw = Self.nsWindow(titled: title), let view = nsw.contentView else { return }
        let p = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: nsw.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            NSApplication.shared.postEvent(e, atStart: false)
        }
    }

    func judgeClicks(_ wings: [Wing], primary: SketchContext) {
        guard let target = wings.first, let w = target.window else {
            emit("S5", "SKIP 翼が無い")
            return
        }
        let hit = SIMD2(w.input.mouseX, w.input.mouseY)
        let ex = Float(target.config.width) / 2
        let ey = Float(target.config.height) / 2
        let landed = abs(hit.x - ex) < 1 && abs(hit.y - ey) < 1

        let pNow = SIMD2(primary.input.mouseX, primary.input.mouseY)
        let pWas = beforeClick["primary"] ?? pNow
        let primaryMoved = pNow != pWas

        var othersMoved: [String] = []
        for wing in wings.dropFirst() {
            guard let o = wing.window else { continue }
            let now = SIMD2(o.input.mouseX, o.input.mouseY)
            if now != (beforeClick[wing.panel.name] ?? now) { othersMoved.append(wing.panel.name) }
        }

        // 対照が先。プライマリにも同じ合成イベントを投げてあるので、そちらも動いていなければ
        // 「翼へ届かない」ではなく「合成イベントがそもそも配送されない」（＝この検査では測れない）。
        if !landed && !primaryMoved {
            emit("S5", "N/A 合成 NSEvent が中央にも翼にも届かない（`NSApp.postEvent` は"
                 + "アプリが非アクティブだと配送されない）。**この検査では入力の分離を測れない**。"
                 + " 構造上は各 `MetaphorMTKView` が自分の `renderer.input` にだけ流し、"
                 + "グローバルなイベント監視も無い（W4 で別インスタンスであることは確認済み）。実操作での確認は人手")
            return
        }

        judge("S5", landed && !primaryMoved && othersMoved.isEmpty,
              "左翼の中央へ NSEvent を 1 発。左翼の mouse=(\(fmt(hit.x)),\(fmt(hit.y))) 期待=(\(fmt(ex)),\(fmt(ey)))"
              + " / 中央は \(primaryMoved ? "動いた (\(fmt(pNow.x)),\(fmt(pNow.y)))" : "動かず")"
              + " / 他の翼で動いたもの \(othersMoved.isEmpty ? "無し" : othersMoved.joined(separator: ","))")
    }

    /// プライマリのウィンドウが在るか（`METAPHOR_VIEWER=1` のヘッドレスとの噛み合わせ）。
    func checkHeadlessBoundary(primaryTitle: String) {
        let headless = ProcessInfo.processInfo.environment["METAPHOR_VIEWER"] == "1"
        let hasPrimary = Self.nsWindow(titled: primaryTitle) != nil
        let titles = NSApplication.shared.windows.map { $0.title }.filter { !$0.isEmpty }
        emit("B1", "\(headless ? "ヘッドレス(METAPHOR_VIEWER=1)" : "通常起動")"
             + " / プライマリ NSWindow=\(hasPrimary ? "有" : "無")"
             + " / 実ウィンドウ \(NSApplication.shared.windows.count) 枚 [\(titles.joined(separator: ", "))]")
    }

    // MARK: - S 群（時計と継ぎ目。走らせてから判定する）

    /// 中央と翼の時計がどれだけ離れていくか。
    ///
    /// 生成タイミングの差でできる**一定のオフセット**は当然あるので、初回の差を基準にして
    /// そこからのずれ（drift）を見る。速い光の帯は 480px/s で走るので、drift はそのまま
    /// 継ぎ目での跳び幅（px）に読み替えられる。
    func checkClocks(_ stage: Stage, elapsed: Float) {
        let bandSpeed = World.width / World.bandCycle  // 480 px/s
        for (name, meter) in stage.meters.sorted(by: { $0.key < $1.key }) {
            let jumpPx = meter.driftMs / 1000 * bandSpeed
            // 1 フレーム（60fps で 16.7ms）ぶんの取りこぼしは共有時計の更新粒度で必ず出る。
            // 2 フレーム = 33.4ms を超えたら「揃っていない」と読む。
            judge("S1.\(name)", meter.driftMs < 33.4,
                  "\(fmt(elapsed, 0))s 時点 drift=\(fmt(meter.driftMs, 1))ms 期待<33.4 "
                  + "(初回オフセット \(fmt(meter.offsetMs, 1))ms / 直近差 \(fmt(meter.lastDeltaMs, 1))ms)")
            emit("S3.\(name)",
                 "継ぎ目での光の帯の跳び = drift × 480px/s = \(fmt(jumpPx, 1))px")
        }
    }

    /// fps 指定が翼ごとに効いているか。左翼 30fps / 右翼 60fps なので frameCount 比は ≈0.5。
    func checkFrameRates(_ stage: Stage, wings: [Wing], elapsed: Float) {
        guard wings.count >= 2,
              let slow = stage.meters[wings[0].panel.name],
              let fast = stage.meters[wings[1].panel.name],
              fast.frames > 0
        else {
            emit("S2", "SKIP 翼が 2 枚そろっていない")
            return
        }
        let ratio = Float(slow.frames) / Float(fast.frames)
        let slowFps = Float(slow.frames) / elapsed
        let fastFps = Float(fast.frames) / elapsed
        // 期待値は config から出す（連番の書き出し中は 3 枚とも同じ fps に落としているため、
        // 0.5 を決め打ちにすると本題と関係ないところで FAIL になる）。
        let expected = Float(wings[0].config.fps) / Float(wings[1].config.fps)
        judge("S2", abs(ratio - expected) < 0.12,
              "fps \(wings[0].config.fps)/\(wings[1].config.fps) の翼で frameCount 比 = "
              + "\(slow.frames)/\(fast.frames) = \(fmt(ratio, 3)) "
              + "期待≈\(fmt(expected, 3))（実測 \(fmt(slowFps, 1))fps / \(fmt(fastFps, 1))fps、"
              + "\(fmt(elapsed, 0))s 平均）")
    }

    // MARK: - L 群 + W5（破壊的。TRIPTYCH_SELFTEST=1 のときだけ）

    /// 破壊的な検査は **1 フレームに 1 手ずつ**進める。
    ///
    /// まとめて `setup()` の中で開閉すると **プロセスが SIGSEGV で落ちる**。
    /// これは作品側の書き方の問題ではなく metaphor 側の穴で、
    /// [0816-probe-windowclose](../0816-probe-windowclose/) が最小構成で切り分けてある
    /// （開いたのと同じ runloop ターンで閉じると 6/6 で落ち、`isReleasedWhenClosed = false`
    /// を外から立てると 3/3 で落ちない → metaphor#TBD）。
    /// フレームを跨げば落ちないので、検査もフレームを跨ぐ形に組む。
    private var step = 0
    private var batch: [SketchWindow] = []
    private var revived: SketchWindow?
    private var closureProbe: SketchWindow?
    private var cascadeOrigins: [CGPoint] = []

    private(set) var selfTestDone = false

    /// `draw()` から毎フレーム呼ぶ。全ステップを終えたら `selfTestDone` が立つ。
    func stepSelfTest(
        make: (SketchWindowConfig) -> SketchWindow?,
        closeAll: () -> Void
    ) {
        guard !selfTestDone else { return }
        defer { step += 1 }

        switch step {
        case 0:
            Log.line("--- 自己検査（破壊的。TRIPTYCH_SELFTEST=1。1 フレーム 1 手） ---")
            batch = (0..<4).compactMap { i in
                make(SketchWindowConfig(width: 320, height: 240,
                                        title: "triptych-probe-\(i)", windowScale: 0.4))
            }

        case 1:
            judge("W5", batch.count == 4 && batch.allSatisfy { $0.isOpen },
                  "4 枚同時生成 → 非nil \(batch.count)/4、isOpen \(batch.filter { $0.isOpen }.count)/4")
            closeAll()

        case 2:
            judge("L3a", batch.allSatisfy { !$0.isOpen },
                  "closeAllWindows() → isOpen が残っているのは \(batch.filter { $0.isOpen }.count)/4 枚")
            revived = make(SketchWindowConfig(width: 320, height: 240,
                                              title: "triptych-probe-revive", windowScale: 0.4))

        case 3:
            judge("L3b", revived?.isOpen == true,
                  "closeAllWindows() の後に createWindow が再び成功するか → "
                  + "\(revived == nil ? "nil" : "非nil")")
            revived?.close()

        case 4:
            if let w = revived {
                let afterFirst = w.isOpen
                w.close()  // 二重 close が落ちないこと
                judge("L1", !afterFirst && !w.isOpen,
                      "close() → isOpen=\(afterFirst)、二重 close() 後 isOpen=\(w.isOpen)、クラッシュ無し")
            }
            closureProbe = make(SketchWindowConfig(width: 240, height: 180,
                                                   title: "triptych-probe-closure", windowScale: 0.4))

        case 5:
            closureProbe?.close()

        case 6:
            // L2: 閉じた後の draw(_:) と onDraw(_:) の非対称。
            // クロージャが保持されるかどうかを canary の解放で見る（drawClosure は private だが、
            // 「保持されたか」なら外から測れる）。
            if let w = closureProbe {
                final class Canary {}
                var c1: Canary? = Canary()
                weak let weak1 = c1
                w.draw { [c1] _ in _ = c1 }
                c1 = nil
                let drawDropped = weak1 == nil

                var c2: Canary? = Canary()
                weak let weak2 = c2
                w.onDraw { [c2] _ in _ = c2 }
                c2 = nil
                let onDrawKept = weak2 != nil

                judge("L2", drawDropped && onDrawKept,
                      "閉じた翼で draw(_:) はクロージャを捨てた=\(drawDropped) / "
                      + "onDraw(_:) は保持した=\(onDrawKept)（doc の非対称どおりなら両方 true）")
            }
            closureProbe = nil

        // L5: 開閉を繰り返したときのカスケード位置。位置を指定する API が無いので、
        // 「同じ config で作り直したウィンドウが同じ場所に出るか」で見る。
        // 開く手と閉じる手を別フレームに分ける（同じターンで開閉すると落ちるため）。
        case 7, 9, 11:
            let i = (step - 7) / 2
            let title = "triptych-probe-cascade-\(i)"
            if let w = make(SketchWindowConfig(width: 320, height: 240,
                                               title: title, windowScale: 0.4)) {
                if let o = Self.origin(titled: title) { cascadeOrigins.append(o) }
                cascadeClosing = w
            }

        case 8, 10, 12:
            cascadeClosing?.close()
            cascadeClosing = nil

        case 13:
            if cascadeOrigins.count == 3 {
                let d1 = CGPoint(x: cascadeOrigins[1].x - cascadeOrigins[0].x,
                                 y: cascadeOrigins[1].y - cascadeOrigins[0].y)
                let d2 = CGPoint(x: cascadeOrigins[2].x - cascadeOrigins[1].x,
                                 y: cascadeOrigins[2].y - cascadeOrigins[1].y)
                let stable = abs(d1.x) < 1 && abs(d1.y) < 1 && abs(d2.x) < 1 && abs(d2.y) < 1
                judge("L5", stable,
                      "同じ config で 3 回開き直した位置 "
                      + cascadeOrigins.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " → ")
                      + " / 1 回あたり (\(Int(d1.x)),\(Int(d1.y))) → (\(Int(d2.x)),\(Int(d2.y))) 期待=(0,0)")
            } else {
                emit("L5", "SKIP ウィンドウ位置を \(cascadeOrigins.count)/3 しか取れなかった")
            }
            closeAll()

        default:
            batch = []
            revived = nil
            selfTestDone = true
            Log.line("--- 自己検査ここまで ---")
        }
    }

    private var cascadeClosing: SketchWindow?

    // MARK: - W8（落ちうる退化 config。頼まれたときだけ）

    /// `TRIPTYCH_TRAP=<名前>` で 1 つだけ再現する。
    ///
    /// **落ちうる入力を常時実行すると作品が起動しなくなる**（#10 で
    /// `step(dt, iterations: -1)` を常時実行して起動不能にした前例）。
    static func runTrap(_ name: String, make: (SketchWindowConfig) -> SketchWindow?) {
        Log.line("[W8] trap=\(name) を再現する")
        let config: SketchWindowConfig
        switch name {
        case "zero":
            config = SketchWindowConfig(width: 0, height: 0, title: "trap-zero")
        case "negative":
            config = SketchWindowConfig(width: -640, height: -480, title: "trap-negative")
        case "huge":
            config = SketchWindowConfig(width: 65_536, height: 65_536, title: "trap-huge")
        case "scalezero":
            config = SketchWindowConfig(width: 640, height: 480, title: "trap-scalezero",
                                        windowScale: 0)
        default:
            Log.line("[W8] 未知の trap 名: \(name)（zero / negative / huge / scalezero）")
            return
        }
        let w = make(config)
        Log.line("[W8] trap=\(name) → \(w == nil ? "nil を返した" : "非nil を返した (isOpen=\(w!.isOpen))")")
    }
}
