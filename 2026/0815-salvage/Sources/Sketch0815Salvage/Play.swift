import Foundation
import simd

/// 決定論的な乱数（ソークを再現できるようにする）。
struct Rng {
    private var state: UInt64

    init(seed: UInt64) { state = seed | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func float(_ lo: Float = 0, _ hi: Float = 1) -> Float {
        let v = Float(next() % 1_000_000) / 1_000_000
        return lo + (hi - lo) * v
    }
}

/// このフレームの入力（キーボードのポーリング結果、またはデモ操縦の出力）。
struct InputState {
    /// -1..1。x は右、z は奥（画面の奥へ進むのが -z）。
    var move: SIMD2<Float> = .zero
    var confirm = false
}

/// アリーナ上の物体。プレイヤー・コア・障害物で共有する最小の状態。
struct Body {
    var pos: SIMD3<Float>
    var vel: SIMD3<Float> = .zero
    var radius: Float
    var spin: Float = 0
    var spinSpeed: Float = 0
    var phase: Float = 0
    var alive = true
}

/// ゲームの 1 ステージ分の世界。
///
/// 当たり判定は球同士の距離だけ。物体は 25 個程度なので総当たりで足りる
/// （**3D 物理を使わずに済むか**を測るのもこの作品の目的のひとつ）。
@MainActor
final class World {
    let spec: StageSpec
    let arenaRadius: Float = 900
    let floorY: Float = 0
    /// 遊泳面。高さは -Y 方向（metaphor の 3D は +Y が画面下）。
    let swimY: Float = -70

    private(set) var player: Body
    private(set) var cores: [Body] = []
    private(set) var obstacles: [Body] = []
    private(set) var collected = 0
    private(set) var lives: Int
    private(set) var timeLeft: Float
    private(set) var invulnerable: Float = 0
    private(set) var outcome: Outcome = .running
    /// 直近フレームで起きたこと（音を鳴らすのは呼び出し側）。
    private(set) var events: [Event] = []

    enum Outcome { case running, cleared, failed }
    enum Event { case pickup, hit }

    private var rng: Rng
    private var elapsed: Float = 0

    init(spec: StageSpec, seed: UInt64, lives: Int) {
        self.spec = spec
        self.lives = lives
        self.timeLeft = spec.timeLimit
        self.rng = Rng(seed: seed)
        self.player = Body(pos: SIMD3(0, swimY, arenaRadius * 0.55), radius: 46)

        for _ in 0..<spec.coreCount {
            let a = rng.float(0, .pi * 2)
            let r = rng.float(260, arenaRadius * 0.92)
            cores.append(
                Body(
                    pos: SIMD3(cos(a) * r, swimY + rng.float(-60, 40), sin(a) * r),
                    radius: 42,
                    spinSpeed: rng.float(0.6, 1.4),
                    phase: rng.float(0, .pi * 2)
                ))
        }

        for _ in 0..<spec.obstacleCount {
            let a = rng.float(0, .pi * 2)
            let r = rng.float(150, arenaRadius * 0.9)
            let dir = rng.float(0, .pi * 2)
            let speed = spec.obstacleSpeed * rng.float(0.6, 1.25)
            obstacles.append(
                Body(
                    pos: SIMD3(cos(a) * r, swimY + rng.float(-90, 60), sin(a) * r),
                    vel: SIMD3(cos(dir) * speed, 0, sin(dir) * speed),
                    radius: spec.obstacleScale * 0.52,
                    spinSpeed: rng.float(-0.9, 0.9),
                    phase: rng.float(0, .pi * 2)
                ))
        }
    }

    var remainingCores: Int { cores.filter { $0.alive }.count }

    func update(dt: Float, input: InputState) {
        events.removeAll(keepingCapacity: true)
        guard outcome == .running else { return }

        elapsed += dt
        timeLeft = max(0, timeLeft - dt)
        invulnerable = max(0, invulnerable - dt)

        // プレイヤー: 入力を加速度として与え、減衰で止める（慣性のある浮遊感）
        let accel: Float = 1500
        let drag: Float = 2.4
        var v = player.vel
        v.x += input.move.x * accel * dt
        v.z += input.move.y * accel * dt
        v *= max(0, 1 - drag * dt)
        let maxSpeed: Float = 380
        let speed = simd_length(SIMD2(v.x, v.z))
        if speed > maxSpeed {
            let k = maxSpeed / speed
            v.x *= k
            v.z *= k
        }
        player.vel = v
        player.pos += v * dt
        // 上下のゆらぎ（見た目だけ。当たり判定は XZ 距離で行う）
        player.pos.y = swimY + sin(elapsed * 1.6) * 8

        // アリーナの縁で押し戻す
        let planar = SIMD2(player.pos.x, player.pos.z)
        let dist = simd_length(planar)
        if dist > arenaRadius - player.radius {
            let n = planar / max(dist, 0.0001)
            let clamped = (arenaRadius - player.radius) * n
            player.pos.x = clamped.x
            player.pos.z = clamped.y
            player.vel.x *= -0.35
            player.vel.z *= -0.35
        }

        for i in obstacles.indices {
            var o = obstacles[i]
            o.pos += o.vel * dt
            o.spin += o.spinSpeed * dt
            o.pos.y = swimY + sin(elapsed * 0.8 + o.phase) * 24
            let p = SIMD2(o.pos.x, o.pos.z)
            let d = simd_length(p)
            if d > arenaRadius - o.radius {
                let n = p / max(d, 0.0001)
                let reflected = SIMD2(o.vel.x, o.vel.z) - 2 * simd_dot(SIMD2(o.vel.x, o.vel.z), n) * n
                o.vel.x = reflected.x
                o.vel.z = reflected.y
                let clamped = (arenaRadius - o.radius) * n
                o.pos.x = clamped.x
                o.pos.z = clamped.y
            }
            obstacles[i] = o
        }

        for i in cores.indices where cores[i].alive {
            cores[i].spin += cores[i].spinSpeed * dt
            cores[i].pos.y = swimY + sin(elapsed * 1.2 + cores[i].phase) * 26
            if planarDistance(cores[i].pos, player.pos) < cores[i].radius + player.radius {
                cores[i].alive = false
                collected += 1
                events.append(.pickup)
            }
        }

        if invulnerable <= 0 {
            for o in obstacles
            where planarDistance(o.pos, player.pos) < o.radius + player.radius * 0.8 {
                lives -= 1
                invulnerable = 1.6
                events.append(.hit)
                // 弾き返す（同じ障害物で連続ヒットしないように）
                let away = normalizedPlanar(player.pos - o.pos)
                player.vel.x = away.x * 520
                player.vel.z = away.z * 520
                break
            }
        }

        if remainingCores == 0 {
            outcome = .cleared
        } else if lives <= 0 || timeLeft <= 0 {
            outcome = .failed
        }
    }

    /// デモ操縦: 最寄りのコアへ向かい、近い障害物からは離れる。
    ///
    /// 30 分ソークを人手なしで回すために要る。ステアリングは 2 本のベクトルの
    /// 合成だけ — ここが破綻するようならゲーム側の難度設定が悪い、と読む。
    func demoInput() -> InputState {
        var steer = SIMD2<Float>.zero

        if let target = cores.filter({ $0.alive })
            .min(by: { planarDistance($0.pos, player.pos) < planarDistance($1.pos, player.pos) })
        {
            let to = normalizedPlanar(target.pos - player.pos)
            steer += SIMD2(to.x, to.z)
        }

        for o in obstacles {
            let d = planarDistance(o.pos, player.pos)
            let danger = o.radius + player.radius + 190
            if d < danger {
                let away = normalizedPlanar(player.pos - o.pos)
                let weight = (danger - d) / danger * 2.4
                steer += SIMD2(away.x, away.z) * weight
            }
        }

        // 縁に張り付かないよう中心へ寄せる
        let planar = SIMD2(player.pos.x, player.pos.z)
        let dist = simd_length(planar)
        if dist > arenaRadius * 0.82 {
            steer -= planar / max(dist, 0.0001) * 1.5
        }

        let length = simd_length(steer)
        if length > 1 { steer /= length }
        return InputState(move: steer, confirm: false)
    }

    private func planarDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_length(SIMD2(a.x - b.x, a.z - b.z))
    }

    private func normalizedPlanar(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let planar = SIMD2(v.x, v.z)
        let length = simd_length(planar)
        guard length > 0.0001 else { return SIMD3(0, 0, -1) }
        return SIMD3(planar.x / length, 0, planar.y / length)
    }
}
