import Foundation
import metaphor

/// 決定論的な自己検査。`setup()` で 1 回だけ走る。
///
/// **描画も時計も使わない。** 固定の刻み幅で `TweenManager.update` を叩くだけなので、
/// 実行のたびに同じ数値が出る（`tools/probe.sh check` を 2 回走らせて差分が無いことを見る）。
///
/// 重要な制約: **`Tween.update(_:)` は `internal`** で、ライブラリの外からは呼べない。
/// つまり利用者は `Tween` を単体で刻めず、必ず `TweenManager` 越しにしか進められない。
/// ここでも検査用に自前の `TweenManager()` を作って回す（既定の `tweenManager` は
/// `SketchContext.beginFrame` が毎フレーム叩くので、検査に混ぜると刻みが二重になる）。
@MainActor
enum Instrument {

    // MARK: - 共通の道具

    /// 直線のイージング。`t` をそのまま返すので、期待値を筆算で書ける。
    /// metaphor は 30 本のイージングを持つが `linear` は無い（`EasingFunction` は
    /// ただの `(Float) -> Float` なので、こう書けば足りる）。
    static let linear: EasingFunction = { $0 }

    /// 刻み幅は 2 の冪だけを使う。1/60 のような値は Float で累積すると誤差が乗り、
    /// 「境界をまたいだかどうか」の判定が刻み方に左右されてしまう。
    /// （その誤差そのものを見るのは `T12.stepIndependence`）
    static let dt64: Float = 1.0 / 64.0

    /// 自前のマネージャに 1 本だけ載せる。
    static func rig<T: Interpolatable>(_ tw: Tween<T>) -> TweenManager {
        let m = TweenManager()
        m.add(tw)
        return m
    }

    static func step(_ m: TweenManager, _ dt: Float, _ times: Int) {
        for _ in 0..<times { m.update(dt) }
    }

    /// 完了するまで刻んで、掛かった回数を返す。`limit` は無限リピートの保険。
    static func stepUntilComplete<T: Interpolatable>(
        _ m: TweenManager, _ tw: Tween<T>, dt: Float, limit: Int = 100_000
    ) -> Int {
        var n = 0
        while !tw.isComplete && n < limit {
            m.update(dt)
            n += 1
        }
        return n
    }

    // MARK: - 全体

    static func runAll() -> [Verdict] {
        var v: [Verdict] = []
        v.append(contentsOf: tweenChecks())
        v.append(contentsOf: managerChecks())
        v.append(contentsOf: interpolatableChecks())
        return v
    }

    // MARK: - T 系: Tween 単体

    static func tweenChecks() -> [Verdict] {
        var v: [Verdict] = []

        // T1: もっとも素朴な形。直線イージングなら中点と終点が筆算で出る。
        do {
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
            let m = rig(tw)
            tw.start()
            step(m, dt64, 32)  // elapsed = 0.5 ちょうど
            let mid = tw.value
            step(m, dt64, 32)  // elapsed = 1.0 で完了
            let end = tw.value
            let ok = Approx.eq(mid, 50) && Approx.eq(end, 100)
            v.append(Verdict(id: "T1.basic", passed: ok,
                             detail: "t=0.5 で \(Approx.f(mid)) 期待=50.0000 / 完了時 \(Approx.f(end)) 期待=100.0000"))
        }

        // T2: 状態の遷移。idle は「実行中でも完了でもない」。
        do {
            let tw = Tween(from: Float(0), to: Float(1), duration: 1.0, easing: linear)
            let m = rig(tw)
            let idle = (tw.isActive, tw.isComplete)
            tw.start()
            let started = (tw.isActive, tw.isComplete)
            step(m, dt64, 32)
            let mid = (tw.isActive, tw.isComplete)
            step(m, dt64, 32)
            let done = (tw.isActive, tw.isComplete)
            let ok = idle == (false, false) && started == (true, false)
                && mid == (true, false) && done == (false, true)
            v.append(Verdict(id: "T2.lifecycle", passed: ok,
                             detail: "(isActive,isComplete) idle=\(idle) start=\(started) 途中=\(mid) 完了=\(done)"
                                 + " 期待=(false,false)/(true,false)/(true,false)/(false,true)"))
        }

        // T2b: delay 待ちの Tween は、外から見て「まだ出番が来ていない」のか
        //      「そもそも出番が無い」のか区別できるか。
        //      0.9.0 では公開が isActive（= state == .running）と isComplete（= .complete）だけで、
        //      .delaying はどちらも false を返すので .idle と同じ見え方だった（metaphor#840 → #946）。
        //      0.14.0 で isWaiting（= .delaying）が足されたので、doc が約束する
        //      4 状態 × 3 プロパティの対応表どおりに全状態が一意に読めるかを見る。
        do {
            let waiting = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear).delay(2.0)
            let mw = rig(waiting)
            waiting.start()
            step(mw, dt64, 32)  // まだ delay 中

            let never = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
            let mn = rig(never)
            step(mn, dt64, 32)  // start() すらしていない

            let running = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
            let mr = rig(running)
            running.start()
            step(mr, dt64, 32)  // 本編の途中

            let done = Tween(from: Float(0), to: Float(100), duration: 0.25, easing: linear)
            let md = rig(done)
            done.start()
            step(md, dt64, 32)  // 完了済み

            func looks(_ t: Tween<Float>) -> String {
                "(\(t.isWaiting), \(t.isActive), \(t.isComplete))"
            }
            let waitingLooks = (waiting.isWaiting, waiting.isActive, waiting.isComplete)
            let neverLooks = (never.isWaiting, never.isActive, never.isComplete)
            let runningLooks = (running.isWaiting, running.isActive, running.isComplete)
            let doneLooks = (done.isWaiting, done.isActive, done.isComplete)
            let ok = waitingLooks == (true, false, false) && neverLooks == (false, false, false)
                && runningLooks == (false, true, false) && doneLooks == (false, false, true)
            v.append(Verdict(id: "T2b.delayingLooksIdle", passed: ok,
                             detail: "(isWaiting,isActive,isComplete) delay 待ち=\(looks(waiting))"
                                 + " / 未 start=\(looks(never)) / 実行中=\(looks(running))"
                                 + " / 完了=\(looks(done))。"
                                 + " 期待=(true,false,false)/(false,false,false)/(false,true,false)/(false,false,true)"
                                 + "（isWaiting が「袖で待っている」と「出番が無い」を分ける）"))
        }

        // T3: start() を呼ぶまでは、いくら刻んでも動かない。
        //     ここが「tween() は登録するが開始しない」の土台（→ M3 / M9）。
        do {
            let tw = Tween(from: Float(7), to: Float(99), duration: 1.0, easing: linear)
            let m = rig(tw)
            step(m, dt64, 600)
            let ok = Approx.eq(tw.value, 7) && !tw.isActive && !tw.isComplete
            v.append(Verdict(id: "T3.beforeStart", passed: ok,
                             detail: "600 回刻んでも value=\(Approx.f(tw.value)) 期待=7.0000"
                                 + " / isActive=\(tw.isActive) isComplete=\(tw.isComplete) 期待=false/false"))
        }

        // T4: delay の間は from に留まり、delay を超えた「余り」が本編へ持ち越される。
        //     1 回の update(0.75) で delay 0.5 を食い切り、残り 0.25 が本編に入るはず。
        do {
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear).delay(0.5)
            let m = rig(tw)
            tw.start()
            m.update(0.25)
            let during = tw.value
            m.update(0.25)  // ちょうど delay を食い切る（余り 0）
            let atBoundary = tw.value
            m.update(0.25)
            let after = tw.value

            let tw2 = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear).delay(0.5)
            let m2 = rig(tw2)
            tw2.start()
            m2.update(0.75)  // delay 0.5 + 本編 0.25 を 1 回で
            let carried = tw2.value

            let ok = Approx.eq(during, 0) && Approx.eq(atBoundary, 0)
                && Approx.eq(after, 25) && Approx.eq(carried, 25)
            v.append(Verdict(id: "T4.delay", passed: ok,
                             detail: "delay 中 \(Approx.f(during)) 境界 \(Approx.f(atBoundary)) 直後 \(Approx.f(after))"
                                 + " 期待=0/0/25 / 余りの持ち越し update(0.75) で \(Approx.f(carried)) 期待=25.0000"))
        }

        // T5: repeatCount(3) はちょうど 3 周ぶん。周の境目で value は from へ戻る。
        do {
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear).repeatCount(3)
            let m = rig(tw)
            tw.start()
            let steps = stepUntilComplete(m, tw, dt: dt64)
            let ok = steps == 192 && Approx.eq(tw.value, 100)
            v.append(Verdict(id: "T5.repeatCount", passed: ok,
                             detail: "完了まで \(steps) 刻み 期待=192 (=64×3) / 最終値 \(Approx.f(tw.value)) 期待=100.0000"))
        }

        // T6: repeatCount(0) は無限。1 万周ぶん叩いても完了しない = cancel() 以外で止まらない。
        do {
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear).repeatCount(0)
            let m = rig(tw)
            tw.start()
            step(m, 1.0, 10_000)  // 1 刻み = ちょうど 1 周
            let stillRunning = tw.isActive && !tw.isComplete && m.count == 1
            tw.cancel()
            m.update(dt64)
            let stopped = tw.isComplete && m.count == 0
            v.append(Verdict(id: "T6.repeatInfinite", passed: stillRunning && stopped,
                             detail: "1 万周後 isActive=\(tw.isActive) count=1 / cancel 後 isComplete=\(tw.isComplete)"
                                 + " count=\(m.count) 期待=true/0"))
        }

        // T7: yoyo は「周ごとに向きが反転する」。偶数周で終われば from に、奇数周なら to に着地する。
        do {
            let even = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear).yoyo().repeatCount(2)
            let me = rig(even)
            even.start()
            _ = stepUntilComplete(me, even, dt: dt64)

            let odd = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear).yoyo().repeatCount(3)
            let mo = rig(odd)
            odd.start()
            _ = stepUntilComplete(mo, odd, dt: dt64)

            let ok = Approx.eq(even.value, 0) && Approx.eq(odd.value, 100)
            v.append(Verdict(id: "T7.yoyoFinalValue", passed: ok,
                             detail: "repeat=2 の最終値 \(Approx.f(even.value)) 期待=0.0000 (from へ戻る)"
                                 + " / repeat=3 は \(Approx.f(odd.value)) 期待=100.0000"))
        }

        // T8: yoyo() だけ呼んで repeatCount を指定しないと、周が 1 回しか無いので往復しない。
        //     doc の「各サイクルでアニメーション方向が反転します」からは読み取れない組み合わせ。
        do {
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear).yoyo()
            let m = rig(tw)
            tw.start()
            var peak: Float = 0
            var steps = 0
            while !tw.isComplete && steps < 1000 {
                m.update(dt64)
                steps += 1
                peak = max(peak, tw.value)
            }
            // 往復するなら 128 刻み掛かって from へ戻るはず。実際は 64 刻みで to に着地する。
            let noRoundTrip = steps == 64 && Approx.eq(tw.value, 100)
            v.append(Verdict(id: "T8.yoyoWithoutRepeat", passed: noRoundTrip,
                             detail: "yoyo() 単独は往復しない: \(steps) 刻みで完了 期待=64 (往復なら 128)"
                                 + " / 最終値 \(Approx.f(tw.value)) 期待=100.0000 (from へ戻らない)"))
        }

        // T9: 実行中の cancel。doc どおり onComplete は呼ばれず、値はその場で凍る。
        do {
            var fired = false
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
                .onComplete { fired = true }
            let m = rig(tw)
            tw.start()
            step(m, dt64, 32)
            let atCancel = tw.value
            tw.cancel()
            step(m, dt64, 200)
            let ok = Approx.eq(tw.value, atCancel) && tw.isComplete && !tw.isActive && !fired && m.count == 0
            v.append(Verdict(id: "T9.cancel", passed: ok,
                             detail: "cancel 時 \(Approx.f(atCancel)) → 200 刻み後 \(Approx.f(tw.value)) (凍結)"
                                 + " / onComplete 発火=\(fired) 期待=false / isComplete=\(tw.isComplete) count=\(m.count)"))
        }

        // T10: 実行中の reset。値は from へ戻り、idle（実行中でも完了でもない）に落ちる。
        do {
            let tw = Tween(from: Float(5), to: Float(105), duration: 1.0, easing: linear)
            let m = rig(tw)
            tw.start()
            step(m, dt64, 32)
            let before = tw.value
            tw.reset()
            let afterReset = tw.value
            step(m, dt64, 200)
            let stillIdle = tw.value
            let ok = Approx.eq(before, 55) && Approx.eq(afterReset, 5) && Approx.eq(stillIdle, 5)
                && !tw.isActive && !tw.isComplete
            v.append(Verdict(id: "T10.reset", passed: ok,
                             detail: "reset 前 \(Approx.f(before)) → 直後 \(Approx.f(afterReset)) 期待=5.0000"
                                 + " / さらに 200 刻みでも \(Approx.f(stillIdle)) (idle は進まない)"
                                 + " / isActive=\(tw.isActive) isComplete=\(tw.isComplete)"))
        }

        // T11: 1 フレームが極端に長引いたとき（ホットリロード・GC・ブレークポイント）。
        //      duration の 10.5 倍を 1 回で渡すと、10 周ぶんを消化して半周ぶん残るはず。
        do {
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear).repeatCount(20)
            let m = rig(tw)
            tw.start()
            m.update(10.5)
            let afterBig = tw.value
            let notDone = !tw.isComplete
            m.update(9.5)  // 残り 10 周ぶん = ちょうど完了
            let ok = Approx.eq(afterBig, 50) && notDone && tw.isComplete && Approx.eq(tw.value, 100)
            v.append(Verdict(id: "T11.hugeDelta", passed: ok,
                             detail: "update(10.5) で \(Approx.f(afterBig)) 期待=50.0000 (10 周消化+半周)"
                                 + " isComplete=\(!notDone) 期待=false"
                                 + " / さらに update(9.5) で isComplete=\(tw.isComplete) 値 \(Approx.f(tw.value))"))
        }

        // T12: 刻み幅を変えても同じ時刻に着地するか（フレームレート依存の検出）。
        //      2 の冪でない 1/60・1/240 をわざと使う。`elapsed += dt` を Float で積むので、
        //      ちょうど duration に届かず**必ず 1 フレーム余計に掛かる**かどうかを見る。
        //      フレーム刻みである以上「duration 丁度で終われない」のは当たり前だが、
        //      理想の刻み数（60 / 240）で終わるか +1 になるかは別の話。
        do {
            let a = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
            let ma = rig(a)
            a.start()
            let na = stepUntilComplete(ma, a, dt: 1.0 / 60.0)

            let b = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
            let mb = rig(b)
            b.start()
            let nb = stepUntilComplete(mb, b, dt: 1.0 / 240.0)

            let ta = Float(na) / 60.0
            let tb = Float(nb) / 240.0
            let ok = na == 60 && nb == 240
            v.append(Verdict(id: "T12.stepIndependence", passed: ok,
                             detail: "60fps: \(na) 刻み = \(Approx.f(ta, 6)) 秒（理想 60 / 誤差 \(Approx.f((ta - 1) * 100, 2))%）"
                                 + " / 240fps: \(nb) 刻み = \(Approx.f(tb, 6)) 秒（理想 240 / 誤差 \(Approx.f((tb - 1) * 100, 2))%）"
                                 + " / Float の累積が duration に僅かに届かず 1 フレーム遅れる"))
        }

        // T12b: その 1 フレームの遅れが**周を重ねて積もるのか**。
        //       `elapsed -= duration` は超過分を持ち越すので、理屈のうえでは自己補正するはず。
        //       積もるなら長回しで無視できない誤差になるので、ここを分けて測る。
        do {
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear).repeatCount(10)
            let m = rig(tw)
            tw.start()
            let steps = stepUntilComplete(m, tw, dt: 1.0 / 60.0)
            let ideal = 600
            let drift = steps - ideal
            // 毎周 1 フレームずつ積もるなら 610、自己補正するなら 600〜601。
            let selfCorrecting = drift <= 1
            v.append(Verdict(id: "T12b.repeatDrift", passed: selfCorrecting,
                             detail: "10 周を 60fps で: \(steps) 刻み（理想 \(ideal)、差 \(drift)）。"
                                 + " 毎周積もるなら 610。超過分は elapsed -= duration で持ち越されるので自己補正する"))
        }

        // T13: duration: 0。init が max(0.001, …) にクランプするので、
        //      普通のフレーム時間なら 1 刻みで完了する（0 除算にも無限ループにもならない）。
        do {
            let tw = Tween(from: Float(0), to: Float(100), duration: 0, easing: linear)
            let m = rig(tw)
            tw.start()
            m.update(dt64)
            let ok = tw.isComplete && Approx.eq(tw.value, 100)
            v.append(Verdict(id: "T13.zeroDuration", passed: ok,
                             detail: "duration:0 → 1 刻み(1/64 秒)で isComplete=\(tw.isComplete) 値 \(Approx.f(tw.value))"
                                 + " 期待=true/100.0000 (0.001 秒へクランプ)"))
        }

        // T13b: そのクランプ値と無限リピートの組み合わせ。while が dt/0.001 回まわるので、
        //       刻みが大きいほど 1 フレームの費用が線形に膨らむ（落ちはしないが効く）。
        do {
            let tw = Tween(from: Float(0), to: Float(100), duration: 0, easing: linear).repeatCount(0)
            let m = rig(tw)
            tw.start()
            m.update(10.0)  // 0.001 秒周期 × 10 秒 = 内部で 1 万周
            let ok = !tw.isComplete && tw.isActive
            v.append(Verdict(id: "T13b.zeroDurationInfinite", passed: ok,
                             detail: "duration:0 + repeatCount(0) に update(10.0) → 内部で約 10000 周を消化。"
                                 + " isActive=\(tw.isActive) isComplete=\(tw.isComplete)。"
                                 + " 費用は dt/0.001 に比例して伸びる（dt=10 で 1 万回）"))
        }

        // T17: 壊れた刻みを 1 回だけ食わせる。deltaTime を自前で計算していると起こりうる。
        //      NaN は `elapsed += dt` で伝播し、`while elapsed >= duration` も
        //      `min(elapsed/duration, 1.0)` も NaN 相手には false / NaN を返す。
        //      → 値が NaN のまま二度と完了せず、マネージャからも外れない（恒久的に居座る）。
        do {
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
            let m = rig(tw)
            tw.start()
            step(m, dt64, 16)
            m.update(Float.nan)
            let poisoned = tw.value
            step(m, dt64, 600)  // 10 秒ぶん刻んでも戻らない
            let recovered = tw.value.isFinite
            v.append(Verdict(id: "T17.nanDelta", passed: recovered,
                             detail: "update(NaN) 直後の値 \(Approx.f(poisoned))、その後 600 刻みでも \(Approx.f(tw.value))。"
                                 + " isComplete=\(tw.isComplete) count=\(m.count)。"
                                 + " NaN が elapsed に入ると完了判定が二度と真にならず、除去もされない"))
        }

        // T18: 負の刻み。時計を巻き戻した・自前で dt を計算した、で起こりうる。
        do {
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
            let m = rig(tw)
            tw.start()
            step(m, dt64, 32)     // 50 まで進める
            let before = tw.value
            m.update(-0.75)       // 大きく巻き戻す（elapsed = -0.25）
            let after = tw.value
            // from を下回れば外挿されている（0 未満）。クランプされていれば 0 以上に留まる。
            let clampedToRange = after >= -0.0001
            v.append(Verdict(id: "T18.negativeDelta", passed: clampedToRange,
                             detail: "50 まで進めてから update(-0.75) → \(Approx.f(before)) から \(Approx.f(after))。"
                                 + " elapsed が負になると t も負になり from を下回って外挿される"))
        }

        // T14: from == to。差が 0 なので補間しても NaN は出ない。
        do {
            let tw = Tween(from: Float(42), to: Float(42), duration: 1.0, easing: linear)
            let m = rig(tw)
            tw.start()
            step(m, dt64, 32)
            let mid = tw.value
            _ = stepUntilComplete(m, tw, dt: dt64)
            let ok = mid.isFinite && Approx.eq(mid, 42) && Approx.eq(tw.value, 42)
            v.append(Verdict(id: "T14.fromEqualsTo", passed: ok,
                             detail: "途中 \(Approx.f(mid)) 完了 \(Approx.f(tw.value)) 期待=どちらも 42.0000 (NaN/Inf なし)"))
        }

        // T15: delay と repeatCount の組み合わせ。delay が初回だけか毎周かは doc に無い。
        //      delay 0.5 + duration 1.0 を 0.25 刻みで:
        //        初回だけなら 2 + 4×3 = 14 刻み / 毎周なら 2 + (2+4)×3 - 2 = 18 刻み
        do {
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
                .delay(0.5).repeatCount(3)
            let m = rig(tw)
            tw.start()
            let steps = stepUntilComplete(m, tw, dt: 0.25)
            let onceOnly = steps == 14
            v.append(Verdict(id: "T15.delayThenRepeat", passed: onceOnly,
                             detail: "完了まで \(steps) 刻み(0.25 秒) → delay は初回のみ(=14)。毎周なら 18。"
                                 + " doc に記述が無いので実測を記録"))
        }

        // T16: 最終周の値は easing を通さず to へ直接代入される。
        //      「t=1 で必ず 1 を返す」わけではないイージング（ここでは定数 0.5）を使うと分かる。
        do {
            let half: EasingFunction = { _ in 0.5 }
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: half)
            let m = rig(tw)
            tw.start()
            step(m, dt64, 32)
            let running = tw.value   // easing を通る = 50
            step(m, dt64, 32)
            let final = tw.value     // 直接代入 = 100
            let ok = Approx.eq(running, 50) && Approx.eq(final, 100)
            v.append(Verdict(id: "T16.easingEndpoint", passed: ok,
                             detail: "定数 0.5 のイージングで 実行中 \(Approx.f(running)) 期待=50.0000"
                                 + " / 完了時 \(Approx.f(final)) 期待=100.0000 (easing を経由せず to へ直代入)"))
        }

        return v
    }

    // MARK: - M 系: TweenManager

    static func managerChecks() -> [Verdict] {
        var v: [Verdict] = []

        // M1: 登録で増え、完了した回の update で自動的に減る。
        do {
            let m = TweenManager()
            let empty = m.count
            let a = Tween(from: Float(0), to: Float(1), duration: 1.0, easing: linear)
            let b = Tween(from: Float(0), to: Float(1), duration: 4.0, easing: linear)
            m.add(a); m.add(b)
            let two = m.count
            a.start(); b.start()
            step(m, dt64, 64)      // a が完了する回
            let afterA = m.count
            step(m, dt64, 192)     // b も完了
            let afterB = m.count
            let ok = empty == 0 && two == 2 && afterA == 1 && afterB == 0
            v.append(Verdict(id: "M1.countAddRemove", passed: ok,
                             detail: "count 空=\(empty) add×2=\(two) a 完了後=\(afterA) b 完了後=\(afterB)"
                                 + " 期待=0/2/1/0"))
        }

        // M2: clear は登録を切るだけ。Tween 自身は running のまま取り残される。
        do {
            let m = TweenManager()
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
            m.add(tw)
            tw.start()
            step(m, dt64, 32)
            let atClear = tw.value
            m.clear()
            let cleared = m.count
            step(m, dt64, 200)
            let ok = cleared == 0 && Approx.eq(tw.value, atClear) && tw.isActive && !tw.isComplete
            v.append(Verdict(id: "M2.clear", passed: ok,
                             detail: "clear 後 count=\(cleared) 期待=0 / 値は \(Approx.f(atClear)) のまま(\(Approx.f(tw.value)))"
                                 + " / **isActive=\(tw.isActive) のまま残る**（clear は Tween を止めない）"))
        }

        // M3: start() されない Tween は complete にならないので、update をいくら回しても
        //     除去されない。tween() は @discardableResult で「作って登録するが開始しない」ため、
        //     戻り値を捨てた瞬間に cancel() する手段も無くなる = 恒久的な滞留。
        do {
            let m = TweenManager()
            for _ in 0..<600 {  // 60fps で 10 秒ぶん、毎フレーム 1 本作った想定
                m.add(Tween(from: Float(0), to: Float(1), duration: 1.0, easing: linear))
            }
            let created = m.count
            step(m, dt64, 600)
            let afterFrames = m.count
            // 望ましい姿は「開始されないまま溜まり続けない」こと。実測が 600 のままなら滞留。
            let drains = afterFrames < created
            v.append(Verdict(id: "M3.unstartedNeverRemoved", passed: drains,
                             detail: "未 start の Tween を 600 本登録 → 600 刻み後も count=\(afterFrames) (登録時 \(created))。"
                                 + " isComplete にならないので除去されず、参照を捨てると cancel() もできない = 滞留"))
        }

        // M4: 同じ Tween を 2 回登録すると 1 フレームで 2 回進む。
        //     tween() 産（自動登録済み）をうっかり tweenManager.add すると 2 倍速になる。
        do {
            let m = TweenManager()
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
            m.add(tw); m.add(tw)
            tw.start()
            step(m, dt64, 32)  // 本来 0.5 秒ぶん = 50 のはず
            let doubled = tw.value
            let ok = Approx.eq(doubled, 100) || tw.isComplete
            v.append(Verdict(id: "M4.doubleRegistration", passed: ok,
                             detail: "2 回 add して 32 刻み(0.5 秒相当) → 値 \(Approx.f(doubled)) isComplete=\(tw.isComplete)。"
                                 + " 1 回登録なら 50.0000。二重登録は等速でなく 2 倍速になる"))
        }

        // M5: **本命**。完了した Tween はマネージャから外される。その後 start() しても
        //     もう誰も update を呼ばないので、値は from に戻ったまま永久に固まる。
        //     Tween.update(_:) は internal なので、利用者側に回避手段が無い。
        do {
            let m = TweenManager()
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
            m.add(tw)
            tw.start()
            _ = stepUntilComplete(m, tw, dt: dt64)
            let afterFirst = tw.value
            let countAfterFirst = m.count

            tw.start()  // アンコール
            step(m, dt64, 200)
            let afterEncore = tw.value
            let replayed = Approx.eq(afterEncore, 100)

            v.append(Verdict(id: "M5.restartAfterComplete", passed: replayed,
                             detail: "1 公演目の最終値 \(Approx.f(afterFirst)) / 完了で count=\(countAfterFirst)。"
                                 + " その後 start() して 200 刻み → 値 \(Approx.f(afterEncore)) 期待=100.0000。"
                                 + " isActive=\(tw.isActive) のまま from に凍る（除去済みで誰も update しない）"))
        }

        // M6: onComplete の中で clear() を呼ぶ。update は配列のコピーを回すので、
        //     同じ回のうちは後続の Tween も 1 回だけ進んでしまう。
        do {
            let m = TweenManager()
            let a = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
            let b = Tween(from: Float(0), to: Float(100), duration: 10.0, easing: linear)
            var bAtClear: Float = -1
            a.onComplete { [weak b] in
                bAtClear = b?.value ?? -1
                m.clear()
            }
            m.add(a); m.add(b)
            a.start(); b.start()
            step(m, dt64, 64)          // a が完了して clear が走る回
            let bJustAfter = b.value
            let countAfter = m.count
            step(m, dt64, 200)
            let bLater = b.value
            let ok = countAfter == 0 && Approx.eq(bLater, bJustAfter)
            v.append(Verdict(id: "M6.clearInsideOnComplete", passed: ok,
                             detail: "clear した回の b: ハンドラ時点 \(Approx.f(bAtClear)) → 回の終わり \(Approx.f(bJustAfter))"
                                 + " (コピーを回すので同じ回はもう 1 歩進む)。count=\(countAfter)"
                                 + " / その後 200 刻みでも \(Approx.f(bLater)) で停止"))
        }

        // M7: onComplete の中で次の Tween を登録して繋ぐ（幕間の連鎖）。これは成立するはず。
        do {
            let m = TweenManager()
            let a = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: linear)
            let b = Tween(from: Float(100), to: Float(200), duration: 1.0, easing: linear)
            a.onComplete {
                m.add(b)
                b.start()
            }
            m.add(a)
            a.start()
            step(m, dt64, 64)          // a 完了 → b が登録される
            let countAfterChain = m.count
            step(m, dt64, 64)          // b が完走
            let ok = countAfterChain == 1 && b.isComplete && Approx.eq(b.value, 200)
            v.append(Verdict(id: "M7.addInsideOnComplete", passed: ok,
                             detail: "a 完了の回に b を add → count=\(countAfterChain) 期待=1 (a は除去、b は残る)"
                                 + " / さらに 64 刻みで b.isComplete=\(b.isComplete) 値 \(Approx.f(b.value)) 期待=200.0000"))
        }

        return v
    }

    // MARK: - I 系: Interpolatable

    static func interpolatableChecks() -> [Verdict] {
        var v: [Verdict] = []

        // I1〜I5: 既定の準拠 5 種。t=0/0.5/1 で端と中点。
        do {
            let a = Float.interpolate(from: 0, to: 10, t: 0)
            let b = Float.interpolate(from: 0, to: 10, t: 0.5)
            let c = Float.interpolate(from: 0, to: 10, t: 1)
            let ok = Approx.eq(a, 0) && Approx.eq(b, 5) && Approx.eq(c, 10)
            v.append(Verdict(id: "I1.float", passed: ok,
                             detail: "t=0/0.5/1 → \(Approx.f(a))/\(Approx.f(b))/\(Approx.f(c)) 期待=0/5/10"))
        }
        do {
            let m = SIMD2<Float>.interpolate(from: .init(0, 10), to: .init(10, 30), t: 0.5)
            let ok = Approx.eq(m.x, 5) && Approx.eq(m.y, 20)
            v.append(Verdict(id: "I2.simd2", passed: ok,
                             detail: "t=0.5 → (\(Approx.f(m.x)), \(Approx.f(m.y))) 期待=(5, 20)"))
        }
        do {
            let m = SIMD3<Float>.interpolate(from: .init(0, 0, 0), to: .init(2, 4, 8), t: 0.25)
            let ok = Approx.eq(m.x, 0.5) && Approx.eq(m.y, 1) && Approx.eq(m.z, 2)
            v.append(Verdict(id: "I3.simd3", passed: ok,
                             detail: "t=0.25 → (\(Approx.f(m.x)), \(Approx.f(m.y)), \(Approx.f(m.z))) 期待=(0.5, 1, 2)"))
        }
        do {
            let m = SIMD4<Float>.interpolate(from: .init(0, 0, 0, 0), to: .init(1, 2, 3, 4), t: 0.5)
            let ok = Approx.eq(m.x, 0.5) && Approx.eq(m.w, 2)
            v.append(Verdict(id: "I4.simd4", passed: ok,
                             detail: "t=0.5 → (\(Approx.f(m.x)), \(Approx.f(m.y)), \(Approx.f(m.z)), \(Approx.f(m.w)))"
                                 + " 期待=(0.5, 1, 1.5, 2)"))
        }
        do {
            // Color は 0…1 正規化。α も一緒に補間されるか。
            let m = Color.interpolate(from: Color(r: 0, g: 0, b: 0, alpha: 0),
                                      to: Color(r: 1, g: 0.5, b: 0.25, alpha: 1), t: 0.5)
            let ok = Approx.eq(m.r, 0.5) && Approx.eq(m.g, 0.25) && Approx.eq(m.b, 0.125) && Approx.eq(m.a, 0.5)
            v.append(Verdict(id: "I5.color", passed: ok,
                             detail: "t=0.5 → rgba(\(Approx.f(m.r)), \(Approx.f(m.g)), \(Approx.f(m.b)), \(Approx.f(m.a)))"
                                 + " 期待=(0.5, 0.25, 0.125, 0.5) / α も補間される"))
        }

        // I6: doc は「概念的に 0.0…1.0 にクランプされます」と書くが、実装はクランプしない。
        //     0…1 を外れるイージング（easeOutBack 等）と組むと to を越えて外挿される。
        do {
            let direct = Float.interpolate(from: 0, to: 100, t: 1.5)
            let clamped = Approx.eq(direct, 100)

            // Tween 越しにも起きるか。easeOutBack は t<1 で 1 を越える。
            let tw = Tween(from: Float(0), to: Float(100), duration: 1.0, easing: easeOutBack)
            let m = rig(tw)
            tw.start()
            var peak: Float = 0
            for _ in 0..<64 {
                m.update(dt64)
                peak = max(peak, tw.value)
            }
            let overshoots = peak > 100.0001
            // doc どおり（クランプされる）なら PASS。実装がそうでないなら FAIL として実測を残す。
            //
            // 注意: **これは実装ではなく doc の側の問題**。クランプしないからこそ
            // easeOutBack / easeOutElastic の「行き過ぎて戻る」表現が成立する。
            // 直すべきは protocol コメントの「クランプされます」という記述のほう。
            v.append(Verdict(id: "I6.outOfRange", passed: clamped,
                             detail: "interpolate(0→100, t=1.5) = \(Approx.f(direct))。doc は「t（0.0〜1.0）」"
                                 + "「概念的に 0.0...1.0 にクランプされます」と書くが実装はクランプしない。"
                                 + " Tween + easeOutBack の最大値 \(Approx.f(peak)) → to を越える=\(overshoots)。"
                                 + " 挙動のほうが正しい（オーバーシュート表現に必要）ので doc 側の記述の問題"))
        }

        // I7: 自作型を準拠させて Tween に載せる。位置・傾き・扇の開きが 1 本の予約で揃って動く。
        do {
            let wing = Silhouette(x: -120, y: 420, lean: 0.35, open: 0)
            let mark = Silhouette(x: 640, y: 400, lean: 0, open: 1)
            let tw = Tween(from: wing, to: mark, duration: 1.0, easing: linear)
            let m = rig(tw)
            tw.start()
            step(m, dt64, 32)
            let mid = tw.value
            step(m, dt64, 32)
            let end = tw.value
            let ok = Approx.eq(mid.x, 260) && Approx.eq(mid.y, 410)
                && Approx.eq(mid.lean, 0.175) && Approx.eq(mid.open, 0.5)
                && end == mark
            v.append(Verdict(id: "I7.customType", passed: ok,
                             detail: "Tween<Silhouette> t=0.5 → x=\(Approx.f(mid.x)) y=\(Approx.f(mid.y))"
                                 + " lean=\(Approx.f(mid.lean)) open=\(Approx.f(mid.open))"
                                 + " 期待=(260, 410, 0.1750, 0.5000) / 完了時に to と一致=\(end == mark)"))
        }

        return v
    }
}
