import Foundation
import metaphor

// フレームを跨がないと測れない検査。
//
// `Instrument.swift` は閉じた数式で判定できるものだけを扱う。ここは逆に、**時計が進むこと・
// ループを止められること・入力が届くこと**という、1 フレームの中では確かめようのない層を見る。
//
// ループ制御（L 系）は `draw()` の中から触れない。`noLoop()` はレンダーループを止め、
// `redraw()` は `MTKView.draw()` を**同期的に**呼ぶので、`draw()` の中で呼ぶと再入する。
// なのでメインキューのタイマーから駆動する（作品の SPACE / ENTER と同じ経路）。

/// 入力注入で 1 件観測したときの記録。
struct InputRecord {
    let kind: String
    let frame: Int
    let mouseX: Float
    let mouseY: Float
    let pmouseX: Float
    let pmouseY: Float
    let isMousePressed: Bool
    let mouseButton: String
    let key: String
    let keyCode: Int
    let isKeyPressed: Bool
    let isKeyRepeat: Bool
    let scrollX: Float
    let scrollY: Float
}

@MainActor
final class Runtime {
    // MARK: - 判定の溜め場

    private(set) var verdicts: [Verdict] = []
    private var emitted = Set<String>()

    /// 新しい判定を 1 件確定する。同じ ID は 1 回だけ。
    private func emit(_ v: Verdict) {
        guard !emitted.contains(v.id) else { return }
        emitted.insert(v.id)
        verdicts.append(v)
        print(v.line)
        fflush(stdout)
    }

    /// 全部そろったかを外から見るための印。
    private(set) var finished = false

    // MARK: - T 系（時計）の観測

    /// 起動時の実時刻。`hour()` などと突き合わせる外部真値。
    private let bootDate = Date()
    private var lastFrameCount = 0
    private var frameCountJumps: [Int] = []
    private var deltaSum: Float = 0
    private var deltaMin: Float = .greatestFiniteMagnitude
    private var deltaMax: Float = 0
    /// 既定 60fps の窓と、`frameRate(30)` を掛けた窓の平均 dt。
    private var windowA: [Float] = []
    private var windowB: [Float] = []

    // MARK: - I 系（入力）の観測

    /// 前フレームの mouseX/Y。`pmouseX/Y` が「ちょうど 1 フレーム前」かを毎フレーム照合する。
    private var prevFrameMouse: (Float, Float)?
    private var pmouseChecked = 0
    private var pmouseMismatch = 0
    private var pmouseMismatchDetail: [String] = []
    /// 直近 6 フレームの mouse / pmouse。食い違ったときに前後を添えて出す
    /// （「何フレーム遅れているのか」は 1 フレームの値だけでは読めない）。
    private var mouseTrace: [String] = []
    private(set) var inputLog: [InputRecord] = []
    /// スクロールを観測したフレームと、その次のフレームの scrollY。
    private var scrollFrame: Int?
    private var scrollValue: Float?
    private var scrollNextValue: Float?
    /// 台本の受け入れ窓。READY-INPUT から、最後の scroll を観測するまで。
    private var armed = false
    private var scriptDone = false

    let injecting = ProcessInfo.processInfo.environment["ESCAPEMENT_INJECT"] == "1"

    // MARK: - フレームごとの観測

    /// `draw()` の**先頭**で呼ぶ。判定はここでは出さない（描画を邪魔しない）。
    func observe(_ s: Sketch0816Escapement) {
        let f = s.frameCount

        // frameCount は 1 フレームにつき 1 だけ増えるか
        if lastFrameCount > 0 { frameCountJumps.append(f - lastFrameCount) }
        lastFrameCount = f

        let dt = s.deltaTime
        if f > 2 {
            deltaSum += dt
            deltaMin = min(deltaMin, dt)
            deltaMax = max(deltaMax, dt)
            // 60fps の窓と 30fps の窓。L 系（ループを止める）が始まる前に測り切る
            if (20...70).contains(f) { windowA.append(dt) }
            if (80...130).contains(f) { windowB.append(dt) }
        }

        // L5: `loop()` で再開した直後の deltaTime。止まっていた実時間がそのまま
        //     1 フレームぶんの dt として出てくると、積分している側が吹き飛ぶ
        if resumePending, f > resumeFrame {
            resumePending = false
            resumeDelta = dt
        }

        // pmouse は「ちょうど 1 フレーム前」か（doc がそう明言している）。
        // 数えるのは台本を流しているあいだだけ — 窓が開いているので、実物のマウスが
        // 上を通ると 1 フレームの途中でイベントが届き、こちらの読み取りとずれる
        if armed, !scriptDone {
            mouseTrace.append("f=\(f) m=(\(Approx.f(s.mouseX, 1)),\(Approx.f(s.mouseY, 1))) p=(\(Approx.f(s.pmouseX, 1)),\(Approx.f(s.pmouseY, 1)))")
            if mouseTrace.count > 6 { mouseTrace.removeFirst() }
        }
        if armed, !scriptDone, let prev = prevFrameMouse {
            pmouseChecked += 1
            if !Approx.eq(s.pmouseX, prev.0, 1e-4) || !Approx.eq(s.pmouseY, prev.1, 1e-4) {
                pmouseMismatch += 1
                if pmouseMismatchDetail.count < 3 {
                    pmouseMismatchDetail.append("[" + mouseTrace.joined(separator: " | ") + "]")
                }
            }
        }
        prevFrameMouse = (s.mouseX, s.mouseY)

        // スクロールは「そのフレームだけ」の量か。
        // 入力コールバックが見る frameCount は「注入が届いたフレーム」とは 1 ずれるので、
        // ここでは draw() 側から見た値だけで前後関係を組む
        if armed {
            if scrollFrame == nil, s.scrollY != 0 {
                scrollFrame = f
                scrollValue = s.scrollY
            } else if let sf = scrollFrame, f == sf + 1, scrollNextValue == nil {
                scrollNextValue = s.scrollY
            }
        }

        // 時計まわりの判定はフレーム番号で刻む
        switch f {
        case 71: s.frameRate(30)
        case 131:
            s.frameRate(60)
            emitFrameRate()
        case 140:
            emitClock(s)
        default: break
        }
    }

    // MARK: - T 系の判定

    private func emitClock(_ s: Sketch0816Escapement) {
        // T1: millis() と time は同じ時計を見ているか（単位だけ違うはず）
        let ms = Float(millis())
        let t = s.time
        let ratioOK = Approx.rel(ms, t * 1000, 0.02)
        emit(Verdict(id: "T1.millisVsTime", passed: ratioOK,
            detail: "millis()=\(Int(ms)) time=\(Approx.f(t, 4))s → time*1000=\(Approx.f(t * 1000, 1))（許容 2%）"))

        // T2: frameCount は 1 フレームにつきちょうど 1 増えるか
        let jumps = Set(frameCountJumps)
        emit(Verdict(id: "T2.frameCount", passed: jumps == [1],
            detail: "\(frameCountJumps.count) フレームぶんの増分 = \(jumps.sorted())（期待 [1]）"))

        // T3: deltaTime の総和が time に一致するか。ずれるならどこかで時計が二重になっている
        let expected = t - deltaHead
        let ok = Approx.rel(deltaSum, expected, 0.05)
        emit(Verdict(id: "T3.deltaTimeSum", passed: ok,
            detail: "Σdt=\(Approx.f(deltaSum, 4))s 期待≈\(Approx.f(expected, 4))s / dt の範囲=[\(Approx.f(deltaMin, 5)),\(Approx.f(deltaMax, 5))]（許容 5%）"))

        // T4: 実時刻の関数群を Foundation と突き合わせる（外部真値）
        let cal = Calendar.current
        let now = Date()
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let got = (year(), month(), day(), hour(), minute(), second())
        let want = (c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        // 秒は観測のあいだに繰り上がりうるので 2 秒まで許す
        let sameDate = got.0 == want.0 && got.1 == want.1 && got.2 == want.2
        let sameClock = got.3 == want.3 && got.4 == want.4 && abs(got.5 - want.5) <= 2
        emit(Verdict(id: "T4.wallClock", passed: sameDate && sameClock,
            detail: "metaphor=\(got.0)-\(got.1)-\(got.2) \(got.3):\(got.4):\(got.5) / Foundation=\(want.0)-\(want.1)-\(want.2) \(want.3):\(want.4):\(want.5)"))

        // T5: 起動からの経過が実時間と合っているか（bootDate との比較）
        let wall = Float(now.timeIntervalSince(bootDate))
        emit(Verdict(id: "T5.timeVsWallClock", passed: Approx.rel(t, wall, 0.10),
            detail: "time=\(Approx.f(t, 3))s 実時間=\(Approx.f(wall, 3))s（setup 以降の差。許容 10%）"))
    }

    /// frame 3 までの dt は積算から外しているので、その分を time から引く。
    private var deltaHead: Float = 0
    func noteDeltaHead(_ v: Float) { deltaHead = v }

    private func emitFrameRate() {
        // T6: frameRate(30) が実際に刻みを変えるか
        guard windowA.count > 10, windowB.count > 10 else {
            emit(Verdict(id: "T6.frameRate", passed: false,
                detail: "サンプル不足 A=\(windowA.count) B=\(windowB.count)"))
            return
        }
        let a = windowA.reduce(0, +) / Float(windowA.count)
        let b = windowB.reduce(0, +) / Float(windowB.count)
        // 60 → 30 なら平均 dt は約 2 倍。1.5 倍を超えていれば「効いている」と見る
        let ok = b > a * 1.5
        emit(Verdict(id: "T6.frameRate", passed: ok,
            detail: "既定(60fps) 平均dt=\(Approx.f(a, 5))s(\(Approx.f(1 / a, 1))fps) → frameRate(30) 平均dt=\(Approx.f(b, 5))s(\(Approx.f(1 / b, 1))fps) / 比=\(Approx.f(b / a, 3))（期待 ~2）"))
    }

    // MARK: - L 系（ループ制御）

    private var loopPre = 0
    private var loopDuringFrame = 0
    private var loopTimeAtStop: Float = 0
    private var loopTimeWhileStopped: Float = 0
    private var resumePending = false
    private var resumeFrame = 0
    private var resumeDelta: Float?
    private var stoppedFor: Float = 0

    /// `setup()` から 1 回だけ呼ぶ。`draw()` の外（メインキュー）でループ制御を試す。
    ///
    /// T 系（時計）の窓を測り切ってから始める。止めているあいだの実時間が
    /// `deltaTime` の平均に混ざると、`frameRate()` の判定が意味を失う。
    func scheduleLoopChecks(_ s: Sketch0816Escapement) {
        let q = DispatchQueue.main

        q.asyncAfter(deadline: .now() + 5.0) { [weak self, weak s] in
            guard let self, let s else { return }
            self.loopPre = s.frameCount
            self.loopTimeAtStop = s.time
            s.noLoop()
        }

        q.asyncAfter(deadline: .now() + 5.6) { [weak self, weak s] in
            guard let self, let s else { return }
            self.loopDuringFrame = s.frameCount
            self.loopTimeWhileStopped = s.time

            // L1: noLoop() で本当に止まるか。
            //     0.6 秒 = 60fps なら 36 フレームぶん。実行中の 1 フレームが落ちきるのは
            //     許す（`noLoop()` はディスプレイリンクを止めるだけで、発行済みのフレームは
            //     取り消さない）が、2 枚以上進むなら止まっていない。
            let slipped = self.loopDuringFrame - self.loopPre
            self.emit(Verdict(id: "L1.noLoop", passed: slipped <= 1 && !s.isLooping,
                detail: "noLoop() 前 frameCount=\(self.loopPre) → 0.6 秒後=\(self.loopDuringFrame) 差=\(slipped)（60fps なら止めなければ +36。実行中の 1 枚が落ちるのは許容）/ isLooping=\(s.isLooping)（期待 false）"))

            // L2 の前段。redraw() は 1 フレームだけ進めるはず
            s.redraw()
        }

        q.asyncAfter(deadline: .now() + 6.0) { [weak self, weak s] in
            guard let self, let s else { return }
            let after = s.frameCount
            let delta = after - self.loopDuringFrame
            self.emit(Verdict(id: "L2.redraw", passed: delta == 1,
                detail: "redraw() 前=\(self.loopDuringFrame) 後=\(after) 増分=\(delta)（期待 1）"))

            // L3: 止めているあいだ time は進むのか（doc に記述が無いので実測を残す）
            let advanced = self.loopTimeWhileStopped - self.loopTimeAtStop
            self.emit(Verdict(id: "L3.clockWhileStopped", passed: advanced.isFinite,
                detail: "noLoop() 時 time=\(Approx.f(self.loopTimeAtStop, 4))s → 0.6 秒後=\(Approx.f(self.loopTimeWhileStopped, 4))s 差=\(Approx.f(advanced, 4))s（doc に規定なし。実測を記録する）"))

            s.loop()
        }

        q.asyncAfter(deadline: .now() + 6.6) { [weak self, weak s] in
            guard let self, let s else { return }
            let resumed = s.frameCount
            // L4: loop() で再開するか（0.6 秒で 10 フレーム以上進んでいれば動いている）
            let advanced = resumed - self.loopDuringFrame - 1
            self.emit(Verdict(id: "L4.loop", passed: advanced > 10 && s.isLooping,
                detail: "loop() 後 0.6 秒で +\(advanced) フレーム（期待 >10）/ isLooping=\(s.isLooping)（期待 true）"))
        }

        // ここから L5 / L6 の単独計測。上の一連は途中に redraw() を挟むので
        // 「止めていた実時間」が読みにくい。ここでは**止めて、何も描かず、再開する**だけ。
        q.asyncAfter(deadline: .now() + 7.0) { [weak self, weak s] in
            guard let self, let s else { return }
            self.stoppedFor = 0.8
            self.pauseStartTime = s.time
            s.noLoop()
        }

        q.asyncAfter(deadline: .now() + 7.8) { [weak self, weak s] in
            guard let self, let s else { return }
            self.resumeFrame = s.frameCount
            self.resumePending = true
            s.loop()
        }

        q.asyncAfter(deadline: .now() + 8.3) { [weak self, weak s] in
            guard let self, let s else { return }
            // L5: 再開直後の deltaTime。止まっていた実時間がそのまま 1 フレームぶんの dt に
            //     化けると、これを積分へ渡している側（Physics2D などの SketchSubsystem、
            //     Tween、自前の速度積分）は 50 倍近い刻みを 1 回だけ食う
            let d = self.resumeDelta ?? .nan
            let sane = d.isFinite && d < 0.1
            self.emit(Verdict(id: "L5.resumeDelta", passed: sane,
                detail: "\(Approx.f(self.stoppedFor, 1)) 秒止めて（間に redraw を挟まず）loop()。再開後 最初の deltaTime=\(Approx.f(d, 5))s / 1 フレームぶん=0.01667s（止まっていた実時間がそのまま渡っているなら ≈\(Approx.f(self.stoppedFor, 1))s になる）"))

            // L6: 止めているあいだ time は進まないので、実時間との差は開いたままになる。
            //     時計としての意味付けを実測で残す
            let elapsedClock = s.time - self.pauseStartTime
            self.emit(Verdict(id: "L6.clockGap", passed: elapsedClock.isFinite,
                detail: "noLoop 直前 time=\(Approx.f(self.pauseStartTime, 4))s → 再開 0.5 秒後 time=\(Approx.f(s.time, 4))s 差=\(Approx.f(elapsedClock, 4))s（実時間では約 1.3 秒経っている）"))

            self.afterLoopChecks(s)
        }
    }

    private var pauseStartTime: Float = 0

    /// L 系のあとに、入力があればその番へ渡す。無ければここで締める。
    private func afterLoopChecks(_ s: Sketch0816Escapement) {
        if injecting {
            armed = true
            print("[inject] READY-INPUT")
            fflush(stdout)
        } else {
            finish()
        }
    }

    // MARK: - I 系（入力）

    /// 入力コールバックから 1 件記録する。
    ///
    /// 記録するのは台本の窓のあいだだけ。窓ありモードなので、起動直後や台本の後に
    /// 実物のマウスがウィンドウ上を通ると、それも同じコールバックで届いてしまう。
    func record(_ kind: String, _ s: Sketch0816Escapement) {
        guard injecting, armed, !scriptDone else { return }
        let r = InputRecord(
            kind: kind,
            frame: s.frameCount,
            mouseX: s.mouseX, mouseY: s.mouseY,
            pmouseX: s.pmouseX, pmouseY: s.pmouseY,
            isMousePressed: s.isMousePressed,
            mouseButton: s.mouseButton.map { "\($0)" } ?? "nil",
            key: s.key.map { String($0) } ?? "nil",
            keyCode: s.keyCode.map { Int($0) } ?? -1,
            isKeyPressed: s.isKeyPressed,
            isKeyRepeat: s.isKeyRepeat,
            scrollX: s.scrollX, scrollY: s.scrollY
        )
        inputLog.append(r)
        print("[inject] \(kind) frame=\(r.frame) mouse=(\(Approx.f(r.mouseX, 1)),\(Approx.f(r.mouseY, 1))) pmouse=(\(Approx.f(r.pmouseX, 1)),\(Approx.f(r.pmouseY, 1))) pressed=\(r.isMousePressed) button=\(r.mouseButton) key=\(r.key) code=\(r.keyCode) keyPressed=\(r.isKeyPressed) repeat=\(r.isKeyRepeat) scroll=(\(Approx.f(r.scrollX, 1)),\(Approx.f(r.scrollY, 1)))")
        fflush(stdout)

        if kind == "scroll" {
            // 台本はここで終わり。以降のイベント（実物のマウス）は取らない。
            // scrollY が次フレームで 0 に戻るかを見てから判定する
            scriptDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.emitInput()
            }
        }
    }

    /// 台本（`tools/probe.sh input` が流す JSON Lines）と突き合わせて I 系を確定する。
    private func emitInput() {
        func first(_ kind: String, _ n: Int = 0) -> InputRecord? {
            inputLog.filter { $0.kind == kind }.dropFirst(n).first
        }

        // I1: SketchConfig.plugins 経由で登録した InputInjectionPlugin が、
        //     窓ありモード（素の swift run）でも stdin を読むか
        let kinds = inputLog.map(\.kind)
        let expected = ["mouseMoved", "mouseMoved", "mousePressed", "mouseReleased",
                        "keyPressed", "keyPressed", "keyReleased", "scroll"]
        emit(Verdict(id: "I1.injectionPlugin", passed: kinds == expected,
            detail: "観測したイベント列=\(kinds) / 台本=\(expected)"))

        // I2: 注入した座標がそのまま mouseX/mouseY に出るか（キャンバス座標系）
        if let m1 = first("mouseMoved"), let m2 = first("mouseMoved", 1) {
            let ok = Approx.eq(m1.mouseX, 300, 0.5) && Approx.eq(m1.mouseY, 200, 0.5)
                && Approx.eq(m2.mouseX, 500, 0.5) && Approx.eq(m2.mouseY, 400, 0.5)
            emit(Verdict(id: "I2.mousePosition", passed: ok,
                detail: "注入 (300,200)→観測 (\(Approx.f(m1.mouseX, 1)),\(Approx.f(m1.mouseY, 1))) / 注入 (500,400)→観測 (\(Approx.f(m2.mouseX, 1)),\(Approx.f(m2.mouseY, 1)))"))
        }

        // I3: pmouse がちょうど 1 フレーム前か。
        //     台本のあいだの全フレームで照合したうえに、実際に動いた 2 回の遷移も当てる
        //     （静止フレームだけだと素通りしてしまう）。
        //
        //     v0.9.0 では動いた直後の 1 フレームだけ 2 フレーム前を指す（= FAIL）。
        //     これは metaphor#522 で、main では `InputManager.endFrame()` の追加（PR #534）
        //     により修正済み・未リリース。A/B は 2026/0816-probe-frameloop が持つ。
        let transitionOK: Bool
        if let m1 = first("mouseMoved"), let m2 = first("mouseMoved", 1) {
            transitionOK = Approx.eq(m2.pmouseX, m1.mouseX, 0.5) && Approx.eq(m2.pmouseY, m1.mouseY, 0.5)
        } else {
            transitionOK = false
        }
        emit(Verdict(id: "I3.pmouse", passed: pmouseMismatch == 0 && pmouseChecked > 20 && transitionOK,
            detail: "台本中 \(pmouseChecked) フレームで照合し食い違い \(pmouseMismatch) 件（期待 0。既知 = metaphor#522、main で修正済み・v0.9.0 では未リリース）/ 動かした次の観測で pmouse=前位置 → \(transitionOK)"
                + (pmouseMismatchDetail.isEmpty ? "" : " / 食い違ったフレームの前後: " + pmouseMismatchDetail.joined(separator: " ; "))))

        // I4: ボタンの押下状態
        if let down = first("mousePressed"), let up = first("mouseReleased") {
            let ok = down.isMousePressed && down.mouseButton == "left" && !up.isMousePressed
            emit(Verdict(id: "I4.mouseButton", passed: ok,
                detail: "mouseDown 時 pressed=\(down.isMousePressed) button=\(down.mouseButton)（期待 true/left）/ mouseUp 時 pressed=\(up.isMousePressed)（期待 false）"))
        }

        // I5: キーの文字とコード。UP 定数（126）を注入している
        if let k = first("keyPressed"), let u = first("keyReleased") {
            let ok = k.keyCode == Int(UP) && k.isKeyPressed && !u.isKeyPressed
            emit(Verdict(id: "I5.key", passed: ok,
                detail: "注入 code=\(UP)(UP) chars=\"^\" → keyCode=\(k.keyCode) key=\(k.key) isKeyPressed=\(k.isKeyPressed) / keyUp 後 isKeyPressed=\(u.isKeyPressed)"))
        }

        // I6: オートリピートのフラグが伝わるか
        if let plain = first("keyPressed"), let rep = first("keyPressed", 1) {
            let ok = !plain.isKeyRepeat && rep.isKeyRepeat
            emit(Verdict(id: "I6.keyRepeat", passed: ok,
                detail: "1 回目 isKeyRepeat=\(plain.isKeyRepeat)（期待 false）/ repeat:true の注入で isKeyRepeat=\(rep.isKeyRepeat)（期待 true）"))
        }

        // I7: scroll はそのフレームだけの量か（`updateFrame()` がフレーム頭で 0 に戻す規約）
        let seen = scrollValue ?? .nan
        let next = scrollNextValue ?? .nan
        emit(Verdict(id: "I7.scroll", passed: Approx.eq(seen, 3, 0.01) && Approx.eq(next, 0, 0.01),
            detail: "注入 dy=3 → draw() が見た scrollY=\(Approx.f(seen, 3)) / その次のフレーム=\(Approx.f(next, 3))（期待 3 → 0）"))

        finish()
    }

    /// 静的な検査（`Instrument`）も含めた全件を返す口。App が挿す。
    var allVerdicts: (() -> [Verdict])?

    private func finish() {
        guard !finished else { return }
        finished = true
        let all = allVerdicts?() ?? verdicts
        let failed = all.filter { !$0.passed }
        if !failed.isEmpty {
            print("FAIL 一覧: " + failed.map(\.id).joined(separator: " "))
        }
        print("self-check 完了 \(all.count - failed.count)/\(all.count) PASS")
        fflush(stdout)
    }
}
