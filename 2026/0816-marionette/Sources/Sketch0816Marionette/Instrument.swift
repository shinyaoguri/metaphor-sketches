import metaphor
import simd

// 検証器。
//
// 作品の見た目とは独立に、MetaphorPhysics / MetaphorSceneGraph の振る舞いを
// **決定論的に**測る。描画も時計も使わないので、実行するたびに同じ数値が出る。
// 結果は frame.json の `custom` に `check.<ID>` として載り、AI はスクリーン
// ショットではなくこの数値を一次証拠にできる（0816-adversary と同じ方針）。

/// 検査 1 件の結果。
struct Verdict {
    let id: String
    let passed: Bool
    /// 実測値。FAIL のとき何がどう違ったのかを人が読める形で残す。
    let detail: String

    var line: String { "\(passed ? "PASS" : "FAIL") \(detail)" }
}

/// 決定論的な検査の一式。`setup()` で 1 回だけ走らせる。
@MainActor
enum Instrument {
    static func runAll() -> [Verdict] {
        [
            timestepJitter(),
            velocityUnits(),
            restitutionRatio(),
            restitutionMechanism(),
            frictionEffect(),
            boundsEnergy(),
            stepGuards(),
            massRatio(),
            shapePairs(),
            constraintConvergence(),
            broadphaseCellSizeInvariance(),
            determinism(),
            chainSelfCollision(),
            drivenPendulum(),
            nodeTransformCache(),
            nodeHierarchyOps(),
            frustumCulling(),
            physicsNodeBridge(),
        ]
    }

    // MARK: - 物理: 時間刻み

    /// P1: フレーム時間が揺れても同じ結果になるか。
    ///
    /// `Physics2D` は `SketchSubsystem` として `update(deltaTime:)` で実フレーム時間を
    /// そのまま `step(dt)` に渡す。同じ 10 秒を「一定 1/60」と「1/120 と 1/40 の交互
    /// （平均 1/60）」で刻み、落下距離が一致するかを見る。
    static func timestepJitter() -> Verdict {
        func fall(_ steps: [Float]) -> Float {
            let world = Physics2D(cellSize: 50)
            world.setGravity(0, -1000)
            let body = world.addCircle(x: 0, y: 0, radius: 1)
            for dt in steps { world.step(dt, iterations: 0) }
            return body.position.y
        }

        let steady = fall(Array(repeating: 1.0 / 60.0, count: 600))
        // 平均は 1/60 のまま、刻みだけを揺らす（実フレームのジッタを模す）
        let jittered = fall((0..<600).map { $0 % 2 == 0 ? 1.0 / 120.0 : 1.0 / 40.0 })

        let ratio = steady != 0 ? jittered / steady : .nan
        // 積分が dt に対して素直なら比は 1 に近い
        let passed = abs(ratio - 1) < 0.05
        return Verdict(
            id: "P1.timestepJitter",
            passed: passed,
            detail: String(format: "steadyY=%.1f jitteredY=%.1f ratio=%.3f", steady, jittered, ratio)
        )
    }

    /// P2: `velocity` の単位は px/秒 か px/ステップ か。
    ///
    /// doc は「Verlet の位置差から導かれる速度」としか書かない。重力 1000 で
    /// ちょうど 1 秒落としたときの値が -1000（px/秒）に近いのか、
    /// -1000/60（px/ステップ）に近いのかを測る。
    static func velocityUnits() -> Verdict {
        let world = Physics2D(cellSize: 50)
        world.setGravity(0, -1000)
        let body = world.addCircle(x: 0, y: 0, radius: 1)
        for _ in 0..<60 { world.step(1.0 / 60.0, iterations: 0) }

        let measured = body.velocity.y
        let perSecond: Float = -1000
        let perStep: Float = -1000.0 / 60.0
        let looksPerSecond = abs(measured - perSecond) < abs(measured - perStep)

        return Verdict(
            id: "P2.velocityUnits",
            passed: looksPerSecond,
            detail: String(
                format: "velocity.y=%.4f  px/sec想定=%.2f  px/step想定=%.4f  → %@",
                measured, perSecond, perStep, looksPerSecond ? "px/sec" : "px/step"
            )
        )
    }

    /// P3: `restitution` は跳ね返り係数として効いているか。
    ///
    /// 反発係数 e の落下は、跳ね返りの頂点が元の高さの e² になるのが古典的な期待。
    static func restitutionRatio() -> Verdict {
        let world = Physics2D(cellSize: 50)
        world.setGravity(0, -1000)
        world.bounds = (min: SIMD2(-500, -100), max: SIMD2(500, 1000))

        let floor = world.addRect(x: 0, y: -50, width: 1000, height: 100)
        floor.isStatic = true
        floor.restitution = 0.9
        floor.friction = 0

        let dropHeight: Float = 300
        let ball = world.addCircle(x: 0, y: dropHeight, radius: 10)
        ball.restitution = 0.9
        ball.friction = 0

        // 1 度床に触れてから、次に接地するまでの最高到達点を跳ね返りの頂点とする。
        // 「接地直後の微小な上下」を頂点と読み違えないよう、再接地まで最大値を追う。
        let restY: Float = 10  // 半径 10 の球が床（上面 y = 0）に乗ったときの中心高さ
        var touched = false
        var apex: Float = 0
        for _ in 0..<6000 {
            world.step(1.0 / 240.0)
            let y = ball.position.y
            if !touched {
                if y <= restY + 1 { touched = true }
                continue
            }
            apex = max(apex, y)
            // 十分に上がってから再び接地したら、その山が 1 回目の跳ね返り
            if apex > restY + 10, y <= restY + 1 { break }
        }

        // 高さは床の上（静止位置）からの落差で測る
        let fell = dropHeight - restY
        let rose = max(0, apex - restY)
        let ratio = rose / fell
        let expected: Float = 0.9 * 0.9
        let passed = abs(ratio - expected) < 0.15
        return Verdict(
            id: "P3.restitution",
            passed: passed,
            detail: String(format: "e=0.9 落差=%.0f 跳ね上がり=%.1f ratio=%.3f 期待=%.3f", fell, rose, ratio, expected)
        )
    }

    /// P3b: 反発が効かないのは「重力下の跳ね返り方」の問題か、衝突応答そのものか。
    ///
    /// 重力を切り、床にちょうど接した球へ既知の下向き速度だけを与えて 1 ステップ進める。
    /// 反発係数 e なら速度は -v → +e·v に反転するのが期待。
    /// ここで反転しないなら、原因は落下のさせ方ではなく衝突応答の側にある。
    static func restitutionMechanism() -> Verdict {
        func bounceBack(approach v: Float) -> Float {
            let world = Physics2D(cellSize: 100)
            let floor = world.addRect(x: 0, y: -50, width: 400, height: 100)  // 上面 y = 0
            floor.isStatic = true
            floor.restitution = 0.9
            floor.friction = 0

            let ball = world.addCircle(x: 0, y: 10, radius: 10)  // ちょうど床に接している
            ball.restitution = 0.9
            ball.friction = 0
            ball.previousPosition = SIMD2(0, 10 + v)  // 1 ステップあたり v だけ下向き

            world.step(1.0 / 60.0)
            return ball.velocity.y
        }

        /// あらかじめ overlap だけ床にめり込ませ、ごく遅い接近速度で 1 ステップ進める。
        /// 反発が効いているなら結果は e·v（≈0.09）程度のはず。位置補正の押し戻しが
        /// そのまま速度になっているなら、overlap にほぼ等しい値が出る。
        func preOverlapped(overlap: Float) -> Float {
            let world = Physics2D(cellSize: 100)
            let floor = world.addRect(x: 0, y: -50, width: 400, height: 100)
            floor.isStatic = true
            floor.restitution = 0.9
            floor.friction = 0

            let ball = world.addCircle(x: 0, y: 10 - overlap, radius: 10)
            ball.restitution = 0.9
            ball.friction = 0
            ball.previousPosition = SIMD2(0, 10 - overlap + 0.1)

            world.step(1.0 / 60.0)
            return ball.velocity.y
        }

        /// 円どうしでも同じか（矩形固有の経路ではないことの確認）。
        func circleCircle(approach v: Float) -> Float {
            let world = Physics2D(cellSize: 100)
            let anchor = world.addCircle(x: 0, y: 0, radius: 20)
            anchor.isStatic = true
            anchor.restitution = 0.9
            anchor.friction = 0

            let ball = world.addCircle(x: 0, y: 30, radius: 10)  // ちょうど接触
            ball.restitution = 0.9
            ball.friction = 0
            ball.previousPosition = SIMD2(0, 30 + v)

            world.step(1.0 / 60.0)
            return ball.velocity.y
        }

        // 侵入量の大小で挙動が変わるかを見るため、接近速度を変えて測る
        let slow = bounceBack(approach: 0.5)
        let mid = bounceBack(approach: 4)
        let fast = bounceBack(approach: 20)
        let artifact = preOverlapped(overlap: 5)
        let round = circleCircle(approach: 4)
        // e = 0.9 なら、接近 4 に対して 3.6 まで跳ね返るのが期待
        let passed = mid > 4 * 0.9 * 0.5

        return Verdict(
            id: "P3b.restitutionMechanism",
            passed: passed,
            detail: String(
                format: "接触から接近 0.5→%.3f(期待0.45) 4.0→%.3f(期待3.60) 20.0→%.3f(期待18.00) / 円円 4.0→%.3f(期待3.60) / 5 めり込み+接近0.1→%.3f(反発なら0.09・位置補正の押し戻しなら≈5)",
                slow, mid, fast, round, artifact
            )
        )
    }

    /// P3c: `friction` は接触面で横滑りを減速させるか。
    ///
    /// `friction` の処理は反発と同じ `applyCollisionResponse` の中にあり、
    /// 同じ入口ガードの後ろに置かれている。床の上を滑らせて横速度の残り方を比べる。
    static func frictionEffect() -> Verdict {
        func slide(friction: Float) -> Float {
            let world = Physics2D(cellSize: 100)
            world.setGravity(0, -1000)

            let floor = world.addRect(x: 0, y: -50, width: 4000, height: 100)
            floor.isStatic = true
            floor.friction = friction
            floor.restitution = 0

            let ball = world.addCircle(x: 0, y: 10, radius: 10)
            ball.friction = friction
            ball.restitution = 0
            ball.previousPosition = SIMD2(-8, 10)  // 1 ステップあたり 8 で右へ滑る

            for _ in 0..<60 { world.step(1.0 / 60.0) }
            return ball.velocity.x
        }

        let slippery = slide(friction: 0)
        let sticky = slide(friction: 1.0)
        // 摩擦が効いていれば、ざらざらの方が明確に遅くなるはず
        let passed = sticky < slippery * 0.8

        return Verdict(
            id: "P3c.friction",
            passed: passed,
            detail: String(format: "60 ステップ後の横速度 friction=0 → %.4f / friction=1 → %.4f", slippery, sticky)
        )
    }

    /// P4: `bounds` で壁に押し戻したとき、速度も殺されるか。
    ///
    /// クランプが位置だけを動かして `previousPosition` を据え置くと、壁の中に
    /// 速度が残り続ける（＝離した瞬間に飛び出す / エネルギーが消えない）。
    static func boundsEnergy() -> Verdict {
        let world = Physics2D(cellSize: 50)
        world.bounds = (min: SIMD2(-1000, -1000), max: SIMD2(100, 1000))

        let body = world.addCircle(x: 0, y: 0, radius: 10)
        // 1 ステップあたり 20 で右へ進む初速を与える
        body.previousPosition = SIMD2(-20, 0)

        var speedBefore: Float = 0
        for i in 0..<20 {
            if i == 3 { speedBefore = simd_length(body.velocity) }
            world.step(1.0 / 60.0)
        }
        // 壁（x = 100 - r = 90）に張り付いたあとの残留速度
        let speedAfter = simd_length(body.velocity)
        let stuckAtWall = abs(body.position.x - 90) < 0.001
        let passed = stuckAtWall && speedAfter < 0.5

        return Verdict(
            id: "P4.boundsEnergy",
            passed: passed,
            detail: String(
                format: "x=%.3f (壁=90) 速度 前=%.2f 後=%.2f", body.position.x, speedBefore, speedAfter
            )
        )
    }

    /// P5: `step` の入口ガードが doc どおりか。
    ///
    /// doc: 負値の `iterations` は step ごと捨てる / `dt == 0` は積分せず拘束だけ解く /
    /// `iterations == 0` は積分だけで拘束・衝突・境界を解かない。
    static func stepGuards() -> Verdict {
        var notes: [String] = []
        var skipped = ""
        var ok = true

        // 非有限・負の dt はワールドを動かさない
        let badSteps: [Float] = [.nan, -1.0 / 60.0, -.infinity]
        for dt in badSteps {
            let world = Physics2D(cellSize: 50)
            world.setGravity(0, -1000)
            let body = world.addCircle(x: 0, y: 0, radius: 1)
            world.step(dt)
            let moved = body.position != SIMD2(0, 0)
            if moved { ok = false; notes.append("dt=\(dt) で動いた") }
        }

        // 負の iterations。v0.9.0 には入口ガードが無く、内部の `0..<iterations` が
        // 逆順 Range となって **プロセスごと fatalError で落ちる**（[#581]。main では
        // `guard iterations >= 0` が入っているが v0.9.0 には未リリース）。
        // 常時走らせると作品が起動しないので、再現は環境変数で明示的に頼んだときだけ。
        if ProcessInfo.processInfo.environment["MARIONETTE_TRAP"] == "iterations" {
            let world = Physics2D(cellSize: 50)
            world.setGravity(0, -1000)
            let body = world.addCircle(x: 0, y: 0, radius: 1)
            world.step(1.0 / 60.0, iterations: -1)  // ここで落ちるのが v0.9.0 の実測
            if body.position != SIMD2(0, 0) { ok = false; notes.append("iterations=-1 で動いた") }
        } else {
            skipped = "iterations<0 は未実行（#581 のトラップ回避。MARIONETTE_TRAP=iterations で再現）"
        }

        // dt == 0 は積分せず拘束だけ解く
        do {
            let world = Physics2D(cellSize: 50)
            let a = world.addCircle(x: 0, y: 0, radius: 1)
            let b = world.addCircle(x: 200, y: 0, radius: 1)
            world.addConstraint(a, b, distance: 100)
            world.step(0)
            let distance = simd_length(b.position - a.position)
            if abs(distance - 100) > 1 { ok = false; notes.append(String(format: "dt=0 で拘束が解けず d=%.1f", distance)) }
        }

        // iterations == 0 は積分だけ（拘束を解かない）
        do {
            let world = Physics2D(cellSize: 50)
            let a = world.addCircle(x: 0, y: 0, radius: 1)
            let b = world.addCircle(x: 200, y: 0, radius: 1)
            world.addConstraint(a, b, distance: 100)
            world.step(1.0 / 60.0, iterations: 0)
            let distance = simd_length(b.position - a.position)
            if abs(distance - 200) > 0.001 { ok = false; notes.append(String(format: "iterations=0 で拘束が解けた d=%.1f", distance)) }
        }

        return Verdict(
            id: "P5.stepGuards",
            passed: ok,
            detail: (ok ? "dt<0 / NaN は捨て、dt=0 は拘束のみ、iterations=0 は積分のみ" : notes.joined(separator: " / "))
                + (skipped.isEmpty ? "" : "  ※ " + skipped)
        )
    }

    /// P6: 重なった 2 円を質量比どおりに押し分けるか。
    ///
    /// 質量 1 と 3 なら、軽い方が 3/4、重い方が 1/4 だけ動くのが期待。
    static func massRatio() -> Verdict {
        let world = Physics2D(cellSize: 50)
        let light = world.addCircle(x: 0, y: 0, radius: 10, mass: 1)
        let heavy = world.addCircle(x: 15, y: 0, radius: 10, mass: 3)
        world.step(1.0 / 60.0, iterations: 1)

        let lightMoved = abs(light.position.x - 0)
        let heavyMoved = abs(heavy.position.x - 15)
        let ratio = heavyMoved > 0 ? lightMoved / heavyMoved : .infinity
        let passed = abs(ratio - 3) < 0.2

        return Verdict(
            id: "P6.massRatio",
            passed: passed,
            detail: String(format: "軽=%.3f 重=%.3f 比=%.3f 期待=3.000", lightMoved, heavyMoved, ratio)
        )
    }

    /// P7: 形状 4 ペア（円円・円矩・矩円・矩矩）すべてで重なりが解けるか。
    static func shapePairs() -> Verdict {
        var notes: [String] = []

        func overlapAfterSteps(_ build: (Physics2D) -> (PhysicsBody2D, PhysicsBody2D), _ label: String) {
            let world = Physics2D(cellSize: 200)
            let (a, b) = build(world)
            for _ in 0..<30 { world.step(1.0 / 60.0) }
            let d = simd_length(b.position - a.position)
            // どの組み合わせも中心距離 20 以上まで離れていれば重なりは解けている
            if d < 20 { notes.append(String(format: "%@ d=%.1f", label, d)) }
        }

        overlapAfterSteps({ w in
            (w.addCircle(x: 0, y: 0, radius: 20), w.addCircle(x: 8, y: 0, radius: 20))
        }, "円円")
        overlapAfterSteps({ w in
            (w.addCircle(x: 0, y: 0, radius: 20), w.addRect(x: 8, y: 0, width: 40, height: 40))
        }, "円矩")
        overlapAfterSteps({ w in
            (w.addRect(x: 0, y: 0, width: 40, height: 40), w.addCircle(x: 8, y: 0, radius: 20))
        }, "矩円")
        overlapAfterSteps({ w in
            (w.addRect(x: 0, y: 0, width: 40, height: 40), w.addRect(x: 8, y: 0, width: 40, height: 40))
        }, "矩矩")

        return Verdict(
            id: "P7.shapePairs",
            passed: notes.isEmpty,
            detail: notes.isEmpty ? "4 ペアすべて重なりが解けた" : "解けず: " + notes.joined(separator: " ")
        )
    }

    /// P8: 距離拘束が既定の反復回数で目標距離へ収束するか。
    static func constraintConvergence() -> Verdict {
        let world = Physics2D(cellSize: 50)
        let a = world.addCircle(x: 0, y: 0, radius: 1)
        let b = world.addCircle(x: 300, y: 0, radius: 1)
        let constraint = world.addConstraint(a, b, distance: 100)
        constraint.stiffness = 1

        world.step(1.0 / 60.0)
        let afterOne = simd_length(b.position - a.position)
        for _ in 0..<30 { world.step(1.0 / 60.0) }
        let afterMany = simd_length(b.position - a.position)

        let passed = abs(afterMany - 100) < 1
        return Verdict(
            id: "P8.constraintConverge",
            passed: passed,
            detail: String(format: "目標=100 1step後=%.1f 31step後=%.3f", afterOne, afterMany)
        )
    }

    /// P9: 空間ハッシュのセルサイズが答えを変えないか。
    ///
    /// ブロードフェーズは速度のための仕組みで、`cellSize` は結果に影響しないはず。
    /// セルが小さすぎる / 大きすぎるときにペアを取りこぼすと、ここで差が出る。
    static func broadphaseCellSizeInvariance() -> Verdict {
        func pile(cellSize: Float) -> [SIMD2<Float>] {
            let world = Physics2D(cellSize: cellSize)
            world.setGravity(0, -1000)
            world.bounds = (min: SIMD2(-200, 0), max: SIMD2(200, 2000))
            for i in 0..<60 {
                let column = Float(i % 10)
                let row = Float(i / 10)
                world.addCircle(x: -150 + column * 33, y: 60 + row * 42, radius: 16)
            }
            for _ in 0..<400 { world.step(1.0 / 120.0) }
            return world.bodies.map(\.position)
        }

        let small = pile(cellSize: 4)
        let tuned = pile(cellSize: 40)
        let huge = pile(cellSize: 4000)

        var worstSmall: Float = 0
        var worstHuge: Float = 0
        for i in tuned.indices {
            worstSmall = max(worstSmall, simd_length(small[i] - tuned[i]))
            worstHuge = max(worstHuge, simd_length(huge[i] - tuned[i]))
        }

        let passed = worstSmall < 1 && worstHuge < 1
        return Verdict(
            id: "P9.broadphaseCellSize",
            passed: passed,
            detail: String(format: "cellSize 4 との差=%.3f  4000 との差=%.3f（基準 40）", worstSmall, worstHuge)
        )
    }

    /// P10: 同じ初期条件のワールドは同じ軌跡を辿るか。
    static func determinism() -> Verdict {
        func pile() -> [SIMD2<Float>] {
            let world = Physics2D(cellSize: 50)
            world.setGravity(0, -900)
            world.bounds = (min: SIMD2(-200, 0), max: SIMD2(200, 2000))
            for i in 0..<40 {
                world.addCircle(x: -140 + Float(i % 8) * 40, y: 80 + Float(i / 8) * 45, radius: 18)
            }
            for _ in 0..<300 { world.step(1.0 / 120.0) }
            return world.bodies.map(\.position)
        }

        let first = pile()
        let second = pile()
        var worst: Float = 0
        for i in first.indices { worst = max(worst, simd_length(first[i] - second[i])) }

        return Verdict(
            id: "P10.determinism",
            passed: worst == 0,
            detail: String(format: "40 体 300 ステップ後の最大差=%.6f", worst)
        )
    }

    /// P11: 鎖の隣り合うリンクが重なっていると、拘束と衝突が押し合って自励振動しないか。
    ///
    /// `Physics2D` には衝突フィルタ（レイヤ / 除外ペア）が無いので、拘束で繋いだ隣どうしも
    /// 必ず衝突判定される。半径の和が拘束距離を超えると、拘束は縮めようとし衝突は離そうとして
    /// 毎反復で押し合う。静止しているはずの鎖が暴れるなら、そこがエネルギー源になる。
    static func chainSelfCollision() -> Verdict {
        /// 22 リンクの鎖を 4 秒ぶら下げ、（ピンからの距離, 総運動エネルギー）を返す。
        func hang(bobRadius: Float, spacing: Float) -> (reach: Float, energy: Float) {
            let world = Physics2D(cellSize: 60)
            world.setGravity(0, -1500)

            var previous: PhysicsBody2D?
            var bob: PhysicsBody2D?
            let linkCount = 22
            for link in 0..<linkCount {
                let isBob = link == linkCount - 1
                let body = world.addCircle(
                    x: 0, y: -Float(link) * spacing,
                    radius: isBob ? bobRadius : 7,
                    mass: isBob ? 5 : 1
                )
                if let previous {
                    world.addConstraint(previous, body, distance: spacing).stiffness = 1
                } else {
                    world.pin(body, x: 0, y: 0)
                }
                previous = body
                if isBob { bob = body }
            }

            // 風は加えない。真下に垂れたまま静止しているのが正解
            for _ in 0..<480 { world.step(1.0 / 120.0, iterations: 18) }

            var energy: Float = 0
            for body in world.bodies where !body.isStatic {
                let v = body.velocity
                energy += 0.5 * body.mass * simd_dot(v, v)
            }
            let reach = simd_length(bob?.position ?? .zero)
            return (reach, energy)
        }

        let ideal = Float(21) * 26
        let overlapping = hang(bobRadius: 21, spacing: 26)  // 錘 21 + 隣 7 = 28 > 26 → 重なる
        let clear = hang(bobRadius: 12, spacing: 26)        // 12 + 7 = 19 < 26 → 重ならない
        // 無風で垂らしただけなので、どちらも静止（エネルギー ≈ 0）が期待
        let passed = overlapping.energy < 1 && clear.energy < 1
        return Verdict(
            id: "P11.chainSelfCollision",
            passed: passed,
            detail: String(
                format: "理想長=%.0f / 隣と重なる錘: 到達=%.0f 運動E=%.1f / 重ならない錘: 到達=%.0f 運動E=%.1f",
                ideal, overlapping.reach, overlapping.energy, clear.reach, clear.energy
            )
        )
    }

    /// P12: 一様な横向きの力に対して、振り子が物理的に妥当な振れ幅で応えるか。
    ///
    /// 全ボディに `applyForce(gust * mass)` を掛けるのは、重力に横成分を足すのと同じ。
    /// 重力 1500 に横 280 なら実効重力は 10.6° 傾くので、静止状態から始めた振り子の
    /// 振れ幅は最大でもその 2 倍（≈21°）に収まるはず。単体の振り子と 22 連の鎖を
    /// 同じ条件で回して、鎖側だけが暴れるのか、振り子の時点で暴れるのかを分ける。
    static func drivenPendulum() -> Verdict {
        /// - Parameter links: 1 なら単体振り子、22 なら鎖。長さは常に 546。
        func swing(links: Int, damping: Float) -> Float {
            let world = Physics2D(cellSize: 600)
            world.setGravity(0, -1500)
            let length: Float = 546
            let spacing = length / Float(links)

            var previous: PhysicsBody2D?
            var bob: PhysicsBody2D?
            for link in 0...links {
                let isBob = link == links
                // 衝突は切り分けの邪魔なので、半径を十分小さくして触れさせない
                let body = world.addCircle(x: 0, y: -Float(link) * spacing, radius: 1, mass: isBob ? 5 : 1)
                if let previous {
                    world.addConstraint(previous, body, distance: spacing).stiffness = 1
                } else {
                    world.pin(body, x: 0, y: 0)
                }
                previous = body
                if isBob { bob = body }
            }

            var widest: Float = 0
            let fixed: Float = 1.0 / 120.0
            for step in 0..<960 {  // 8 秒
                // 一定の横向き加速度 280（重力の 18.7%）だけを掛ける
                for body in world.bodies where !body.isStatic {
                    body.applyForce(SIMD2(280 * body.mass, 0))
                }
                world.step(fixed, iterations: 18)
                if damping > 0 {
                    for body in world.bodies where !body.isStatic {
                        body.previousPosition += (body.position - body.previousPosition) * damping
                    }
                }
                widest = max(widest, abs(bob?.position.x ?? 0))
                _ = step
            }
            return widest
        }

        // 実効重力の傾き 10.6°、静止から始めた振れ幅の上限はその 2 倍 ≈ 21° → 546·sin(21°) ≈ 196
        let limit: Float = 210
        let single = swing(links: 1, damping: 0)
        let singleDamped = swing(links: 1, damping: 0.012)
        let chain = swing(links: 22, damping: 0)
        let chainDamped = swing(links: 22, damping: 0.012)

        let passed = single < limit && chain < limit
        return Verdict(
            id: "P12.drivenPendulum",
            passed: passed,
            detail: String(
                format: "横 280 / 重力 1500（実効傾き 10.6°、上限 ≈%.0f）: 単体=%.0f 単体+減衰=%.0f 22連=%.0f 22連+減衰=%.0f",
                limit, single, singleDamped, chain, chainDamped
            )
        )
    }

    // MARK: - シーングラフ

    /// S1: 親を動かしたとき、子の `worldTransform` キャッシュが無効化されるか。
    static func nodeTransformCache() -> Verdict {
        let parent = Node(name: "parent")
        let child = Node(name: "child")
        parent.addChild(child)

        parent.position = SIMD3(10, 0, 0)
        child.position = SIMD3(5, 0, 0)
        // 先に読んでキャッシュを温める
        let before = translation(of: child.worldTransform)

        parent.position = SIMD3(20, 0, 0)
        let afterMove = translation(of: child.worldTransform)

        parent.setRotation(y: .pi / 2)
        let afterRotate = translation(of: child.worldTransform)

        let movedOK = simd_length(afterMove - SIMD3(25, 0, 0)) < 0.001
        // Y 90° 回転で子のローカル +X は世界の -Z へ回る
        let rotatedOK = simd_length(afterRotate - SIMD3(20, 0, -5)) < 0.001
        let passed = simd_length(before - SIMD3(15, 0, 0)) < 0.001 && movedOK && rotatedOK

        return Verdict(
            id: "S1.transformCache",
            passed: passed,
            detail: String(
                format: "初期=(%.1f,%.1f,%.1f) 親移動後=(%.1f,%.1f,%.1f) 親回転後=(%.2f,%.2f,%.2f)",
                before.x, before.y, before.z,
                afterMove.x, afterMove.y, afterMove.z,
                afterRotate.x, afterRotate.y, afterRotate.z
            )
        )
    }

    /// S2: 階層操作（追加・検索・削除）と親参照の後始末。
    static func nodeHierarchyOps() -> Verdict {
        var notes: [String] = []

        let root = Node(name: "root")
        let mid = Node(name: "mid")
        let leaf = Node(name: "leaf")
        root.addChild(mid)
        mid.addChild(leaf)

        if root.find("leaf") !== leaf { notes.append("find が孫を返さない") }
        if root.find("missing") != nil { notes.append("find が存在しない名前を返した") }
        if leaf.parent !== mid { notes.append("parent が繋がっていない") }

        // 付け替えたとき、元の親から外れるか
        let other = Node(name: "other")
        root.addChild(other)
        other.addChild(leaf)
        if mid.children.contains(where: { $0 === leaf }) { notes.append("付け替えで元の親に残った") }
        if leaf.parent !== other { notes.append("付け替えで parent が更新されない") }

        root.removeChild(mid)
        if mid.parent != nil { notes.append("removeChild で parent が nil にならない") }
        if root.find("mid") != nil { notes.append("removeChild 後も find が拾う") }

        root.removeAllChildren()
        if !root.children.isEmpty { notes.append("removeAllChildren が空にしない") }

        return Verdict(
            id: "S2.hierarchyOps",
            passed: notes.isEmpty,
            detail: notes.isEmpty ? "追加・検索・付け替え・削除すべて期待どおり" : notes.joined(separator: " / ")
        )
    }

    /// S3: フラスタムカリングが「見えているものを消さず、見えないものを消す」か。
    ///
    /// ニア平面の抽出を OpenGL 規約（z ∈ [-1, 1]）でやると、カメラ**背後**の
    /// 物体が生き残る。Metal 規約（z ∈ [0, 1]）で抽出できているかをここで見る。
    static func frustumCulling() -> Verdict {
        let view = float4x4(lookAt: SIMD3(0, 0, 500), center: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
        let projection = float4x4(perspectiveFov: .pi / 3, aspect: 16.0 / 9.0, near: 1, far: 4000)
        let planes = SceneRenderer.extractFrustumPlanes(from: projection * view)

        func box(_ center: SIMD3<Float>, _ half: Float = 20) -> AABB {
            AABB(min: center - SIMD3(repeating: half), max: center + SIMD3(repeating: half))
        }

        var notes: [String] = []
        if planes.count != 6 { notes.append("平面が \(planes.count) 枚") }
        // 視野の真ん中は見えていなければならない
        if !box(SIMD3(0, 0, 0)).intersects(frustum: planes) { notes.append("正面を誤って消した") }
        // カメラの背後は消えなければならない
        if box(SIMD3(0, 0, 1500)).intersects(frustum: planes) { notes.append("背後が消えない") }
        // 遠すぎるものは消えなければならない
        if box(SIMD3(0, 0, -5000)).intersects(frustum: planes) { notes.append("ファー外が消えない") }
        // 大きく横へ外れたものは消えなければならない
        if box(SIMD3(4000, 0, 0)).intersects(frustum: planes) { notes.append("横外が消えない") }
        // 境界をまたぐものは残らなければならない（保守的な判定）
        if !box(SIMD3(0, 0, 480), 60).intersects(frustum: planes) { notes.append("ニアをまたぐ箱を消した") }

        return Verdict(
            id: "S3.frustumCulling",
            passed: notes.isEmpty,
            detail: notes.isEmpty ? "正面/背後/遠方/側方/境界またぎ すべて期待どおり" : notes.joined(separator: " / ")
        )
    }

    /// S4: 2D 物理と 3D ノードを繋ぐ橋の座標対応。
    ///
    /// `syncFromPhysics` は XY を素通しし Z を保つ、`syncToPhysics` は書き戻して
    /// 速度を殺す、という doc どおりか。**2D 側の Y の向きは呼び出し側の取り決め**で、
    /// 橋は変換しない（＝重力の符号は 3D の Y 上向きに合わせる必要がある）。
    static func physicsNodeBridge() -> Verdict {
        var notes: [String] = []

        let world = Physics2D(cellSize: 50)
        let body = world.addCircle(x: 10, y: -20, radius: 5)

        let node = Node(name: "bridge")
        node.position = SIMD3(0, 0, 7)
        node.syncFromPhysics(body)
        if node.position != SIMD3(10, -20, 7) {
            notes.append("syncFromPhysics=(\(node.position.x),\(node.position.y),\(node.position.z))")
        }

        // 落下方向の対応: 重力を -Y にすれば 3D でも下へ落ちる
        world.setGravity(0, -1000)
        for _ in 0..<30 { world.step(1.0 / 60.0, iterations: 0) }
        node.syncFromPhysics(body)
        if node.position.y >= -20 { notes.append("重力 -Y でノードが下がらない") }

        // 書き戻しは速度を殺す（テレポート用途）
        node.position = SIMD3(1, 2, 3)
        node.syncToPhysics(body)
        if body.position != SIMD2(1, 2) { notes.append("syncToPhysics の位置が違う") }
        if simd_length(body.velocity) != 0 { notes.append("syncToPhysics 後も速度が残る") }

        return Verdict(
            id: "S4.physicsBridge",
            passed: notes.isEmpty,
            detail: notes.isEmpty ? "XY 素通し / Z 保持 / 書き戻しで速度リセット" : notes.joined(separator: " / ")
        )
    }

    // MARK: - 補助

    private static func translation(of matrix: float4x4) -> SIMD3<Float> {
        SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }
}
