import metaphor
import simd

// 4 つの場面。
//
// どれも「2D の物理ワールドが 3D のシーングラフを操る」という同じ仕掛けの変奏で、
// 通す API の重心だけが違う。
//
//   chain  拘束とピン、親ノードの回転（worldTransform の合成）
//   cloth  格子拘束の規模とブロードフェーズ負荷
//   pit    形状混在の衝突、反発・摩擦、境界、実行中のボディ増減
//   swarm  AABB とフラスタムカリング

/// 拘束を線で描くのを本体へ委ねるための窓口。
@MainActor
protocol LinkPainter: AnyObject {
    /// 拘束のペアをローカル座標の線として描く。
    func paintLinks(_ pairs: [(PhysicsBody2D, PhysicsBody2D)], color: Color, weight: Float)
}

/// 使い回すメッシュ。全ノードで 1 枚を共有し、大きさはノードの `scale` で変える。
struct MeshKit {
    let cell: Mesh?
    let brick: Mesh?
}

/// 決定論的な擬似乱数。作品を毎回同じ形にするため `random()` は使わない。
struct Seeded {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float((state >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
    }

    mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * next() }
}

@MainActor
protocol Stage: AnyObject {
    var name: String { get }
    var rig: Rig { get }
    /// フラスタムカリングを効かせる場面か。
    var usesCulling: Bool { get }
    /// 物理を進める前に力を加える。
    func drive(time: Float, wind: Float)
    /// 場面ごとのカメラ。
    func camera(time: Float, orbit: Float) -> (eye: SIMD3<Float>, center: SIMD3<Float>)
}

extension Stage {
    var usesCulling: Bool { false }
}

// MARK: - chain

/// 吊り下げた鎖と錘。ピンと距離拘束、そして平面ごと回る親ノード。
@MainActor
final class ChainStage: Stage {
    let name = "chain"
    let rig = Rig()
    private let bobs: [PhysicsBody2D]

    init(kit: MeshKit, painter: LinkPainter) {
        var bobs: [PhysicsBody2D] = []
        let palette = [
            Color(r: 0.95, g: 0.42, b: 0.24),
            Color(r: 0.42, g: 0.72, b: 0.98),
            Color(r: 0.82, g: 0.86, b: 0.45),
        ]

        for (index, offsetX) in [Float(-330), 0, 330].enumerated() {
            let plane = Plane(name: "chain\(index)", cellSize: 60, at: SIMD3(offsetX, -330, 0))
            plane.world.setGravity(0, 1500)
            plane.damping = 0.02
            plane.iterations = 18

            var previous: PhysicsBody2D?
            let linkCount = 22
            for link in 0..<linkCount {
                let isBob = link == linkCount - 1
                let y = Float(link) * 32
                let body = plane.world.addCircle(
                    x: 0, y: y,
                    radius: isBob ? 15 : 7,
                    mass: isBob ? 5 : 1
                )
                body.friction = 0.1
                body.restitution = 0.2

                let shade = Float(link) / Float(linkCount - 1)
                let color = isBob
                    ? palette[index]
                    : Color(
                        r: 0.30 + palette[index].r * shade * 0.6,
                        g: 0.34 + palette[index].g * shade * 0.6,
                        b: 0.46 + palette[index].b * shade * 0.6
                    )
                plane.attach(body, mesh: kit.cell, color: color, scale: isBob ? 15 : 7)

                if let previous {
                    plane.link(previous, body, distance: 32, stiffness: 1)
                } else {
                    // 先頭は空間に固定する
                    plane.world.pin(body, x: 0, y: 0)
                }
                previous = body
                if isBob { bobs.append(body) }
            }

            plane.pivot.onDraw = { [weak plane, weak painter] in
                guard let plane, let painter else { return }
                painter.paintLinks(plane.links, color: Color(r: 0.45, g: 0.55, b: 0.72), weight: 2)
            }
            rig.add(plane)
        }
        self.bobs = bobs
    }

    func drive(time: Float, wind: Float) {
        for (index, plane) in rig.planes.enumerated() {
            let phase = Float(index) * 1.7
            // 鎖の固有角振動数は √(g/L) = √(1500/546) ≈ 1.66 rad/s。そこを叩くと
            // 共振して振り切れる（検査 P12 で確認済み）ので、風はそれより十分遅く保つ
            let gust = sin(time * 0.31 + phase) * 130 + sin(time * 0.17 + phase * 0.4) * 70
            for body in plane.world.bodies where !body.isStatic {
                body.applyForce(SIMD2(gust * wind * body.mass, 0))
            }
            // 平面そのものをゆっくり振る（親の回転で子の worldTransform が動く）
            plane.pivot.setRotation(y: sin(time * 0.24 + phase) * 0.7)
        }
    }

    func camera(time: Float, orbit: Float) -> (eye: SIMD3<Float>, center: SIMD3<Float>) {
        let angle = time * 0.09 * orbit
        return (
            eye: SIMD3(sin(angle) * 360, -120 - sin(time * 0.3) * 50, 880),
            center: SIMD3(0, 20, 0)
        )
    }

    /// 錘の高さ（作品としての見せ場が生きているかの目印）。
    var bobDepth: Float { bobs.map(\.position.y).max() ?? 0 }
}

// MARK: - cloth

/// 格子状に繋いだ布。拘束の数でブロードフェーズと拘束ソルバに負荷をかける。
@MainActor
final class ClothStage: Stage {
    let name = "cloth"
    let rig = Rig()
    private let plane: Plane
    private let columns = 22
    private let rows = 15

    init(kit: MeshKit, painter: LinkPainter) {
        let plane = Plane(name: "cloth", cellSize: 40, at: SIMD3(0, -210, 0))
        plane.world.setGravity(0, 820)
        plane.damping = 0.02
        plane.iterations = 12

        let spacing: Float = 27
        let originX = -Float(columns - 1) * spacing * 0.5
        var grid: [[PhysicsBody2D]] = []

        for row in 0..<rows {
            var line: [PhysicsBody2D] = []
            for column in 0..<columns {
                let body = plane.world.addCircle(
                    x: originX + Float(column) * spacing,
                    y: Float(row) * spacing,
                    radius: 4.5
                )
                body.friction = 0.4
                let shade = Float(row) / Float(rows - 1)
                plane.attach(
                    body,
                    mesh: kit.brick,
                    color: Color(r: 0.24 + shade * 0.55, g: 0.52 - shade * 0.18, b: 0.78 - shade * 0.32),
                    scale: 5
                )
                line.append(body)
            }
            grid.append(line)
        }

        // 上端を等間隔で吊る
        for column in stride(from: 0, to: columns, by: 3) {
            let body = grid[0][column]
            plane.world.pin(body, x: body.position.x, y: body.position.y)
        }

        // 構造拘束（右隣・下隣）
        for row in 0..<rows {
            for column in 0..<columns {
                if column + 1 < columns { plane.link(grid[row][column], grid[row][column + 1], distance: spacing) }
                if row + 1 < rows { plane.link(grid[row][column], grid[row + 1][column], distance: spacing) }
            }
        }

        plane.pivot.onDraw = { [weak plane, weak painter] in
            guard let plane, let painter else { return }
            painter.paintLinks(plane.links, color: Color(r: 0.30, g: 0.45, b: 0.70), weight: 1)
        }

        self.plane = plane
        rig.add(plane)
    }

    func drive(time: Float, wind: Float) {
        for body in plane.world.bodies where !body.isStatic {
            // 位置で位相をずらした風。布の面に波が走る
            // 布の固有角振動数は √(820/378) ≈ 1.47 rad/s。ここも避けて遅く揺らす
            let phase = body.position.y * 0.012
            let gust = sin(time * 0.48 + phase) * 170 + sin(time * 0.23) * 110
            body.applyForce(SIMD2(gust * wind * body.mass, 0))
        }
        plane.pivot.setRotation(y: sin(time * 0.19) * 0.85)
    }

    func camera(time: Float, orbit: Float) -> (eye: SIMD3<Float>, center: SIMD3<Float>) {
        let angle = time * 0.13 * orbit
        return (
            eye: SIMD3(sin(angle) * 300, -130, 760 + cos(angle) * 120),
            center: SIMD3(0, 30, 0)
        )
    }
}

// MARK: - pit

/// 落ちて溜まる坑。円と矩形が混ざり、列ごとに反発と摩擦が違う。
@MainActor
final class PitStage: Stage {
    let name = "pit"
    let rig = Rig()
    private let plane: Plane
    private let kit: MeshKit
    private var seed = Seeded(seed: 20260816)
    private var spawned = 0
    private var lastRecycle: Float = 0

    /// 実行中に入れ替えたボディの総数（ソークでの増減とリークの目印）。
    private(set) var recycleCount = 0

    init(kit: MeshKit) {
        self.kit = kit
        let plane = Plane(name: "pit", cellSize: 46, at: SIMD3(0, 60, 0))
        plane.world.setGravity(0, 1500)
        plane.world.bounds = (min: SIMD2(-430, -900), max: SIMD2(430, 250))
        plane.damping = 0.008
        plane.iterations = 8

        // 静止した床と壁（矩形の静的ボディ）
        let floor = plane.world.addRect(x: 0, y: 220, width: 820, height: 60)
        floor.isStatic = true
        floor.friction = 0.6
        floor.restitution = 0.2
        plane.attach(floor, mesh: kit.brick, color: Color(r: 0.16, g: 0.19, b: 0.26), scale: 1)
        plane.strands[0].node.scale = SIMD3(820, 60, 220)

        for side in [Float(-1), 1] {
            let wall = plane.world.addRect(x: side * 400, y: -40, width: 60, height: 460)
            wall.isStatic = true
            wall.friction = 0.5
            plane.attach(wall, mesh: kit.brick, color: Color(r: 0.13, g: 0.16, b: 0.23), scale: 1)
            plane.strands[plane.strands.count - 1].node.scale = SIMD3(60, 460, 200)
        }

        self.plane = plane
        rig.add(plane)

        for _ in 0..<96 { spawnOne() }
    }

    private func spawnOne() {
        let column = spawned % 6
        // 列ごとに反発と摩擦を変える
        let restitution = 0.05 + Float(column) * 0.16
        let friction = 0.7 - Float(column) * 0.11
        let x = -350 + Float(column) * 140 + seed.range(-26, 26)
        let y = seed.range(-860, -420)

        let body: PhysicsBody2D
        let mesh: Mesh?
        let scale: SIMD3<Float>
        if spawned % 2 == 0 {
            let radius = seed.range(13, 22)
            body = plane.world.addCircle(x: x, y: y, radius: radius, mass: radius / 16)
            mesh = kit.cell
            scale = SIMD3(repeating: radius)
        } else {
            let w = seed.range(24, 40)
            let h = seed.range(24, 40)
            body = plane.world.addRect(x: x, y: y, width: w, height: h, mass: (w + h) / 60)
            mesh = kit.brick
            scale = SIMD3(w, h, (w + h) * 0.5)
        }
        body.restitution = restitution
        body.friction = friction

        let heat = Float(column) / 5
        let strand = plane.attach(
            body,
            mesh: mesh,
            color: Color(r: 0.30 + heat * 0.66, g: 0.46 - heat * 0.16, b: 0.72 - heat * 0.46),
            z: seed.range(-70, 70),
            scale: 1
        )
        strand.node.scale = scale
        spawned += 1
    }

    func drive(time: Float, wind: Float) {
        // 一定間隔で底に溜まったものを取り除き、上から入れ直す
        if time - lastRecycle > 5 {
            lastRecycle = time
            let settled = plane.strands
                .filter { !$0.body.isStatic && $0.body.position.y > 140 }
                .sorted { $0.body.position.y > $1.body.position.y }
                .prefix(8)
            for strand in settled {
                plane.remove(strand)
                recycleCount += 1
            }
            for _ in 0..<settled.count { spawnOne() }
        }

        // 時折下から突き上げる
        let kick = sin(time * 0.8)
        if kick > 0.985 {
            for body in plane.world.bodies where !body.isStatic {
                body.applyForce(SIMD2(0, -90_000 * wind * body.mass))
            }
        }
    }

    func camera(time: Float, orbit: Float) -> (eye: SIMD3<Float>, center: SIMD3<Float>) {
        let angle = time * 0.11 * orbit
        return (
            eye: SIMD3(sin(angle) * 260, -90 - sin(time * 0.4) * 40, 820),
            center: SIMD3(0, 60, 0)
        )
    }
}

// MARK: - swarm

/// 散らばった細胞群。奥行きに広く撒いて、フラスタムカリングを働かせる。
@MainActor
final class SwarmStage: Stage {
    let name = "swarm"
    let rig = Rig()
    let usesCulling = true
    private let plane: Plane

    init(kit: MeshKit) {
        var seed = Seeded(seed: 816)
        let plane = Plane(name: "swarm", cellSize: 70, at: .zero)
        plane.world.setGravity(0, 0)
        plane.world.bounds = (min: SIMD2(-980, -520), max: SIMD2(980, 520))
        plane.damping = 0.001
        plane.iterations = 4

        for index in 0..<240 {
            let radius = seed.range(9, 17)
            let body = plane.world.addCircle(
                x: seed.range(-940, 940),
                y: seed.range(-480, 480),
                radius: radius,
                mass: radius / 12
            )
            body.restitution = 0.92
            body.friction = 0.02
            // 初速は前フレーム位置で与える（速度は px/ステップ）
            body.previousPosition = body.position - SIMD2(seed.range(-1.6, 1.6), seed.range(-1.6, 1.6))

            let depth = Float(index % 15)
            let heat = depth / 14
            let strand = plane.attach(
                body,
                mesh: kit.cell,
                color: Color(r: 0.34 + heat * 0.55, g: 0.62 - heat * 0.22, b: 0.92 - heat * 0.5),
                z: -700 + depth * 100,
                scale: radius
            )
            // カリング用のローカル AABB（スケールは worldBounds 側で効く）
            strand.node.bounds = AABB(min: SIMD3(repeating: -1.4), max: SIMD3(repeating: 1.4))
        }

        self.plane = plane
        rig.add(plane)
    }

    func drive(time: Float, wind: Float) {
        // ゆるい渦。中心へ寄せながら回す
        for body in plane.world.bodies where !body.isStatic {
            let p = body.position
            let swirl = SIMD2(-p.y, p.x) * 0.28
            let pull = -p * 0.16
            body.applyForce((swirl + pull) * wind * body.mass)
        }
        plane.pivot.setRotation(y: sin(time * 0.07) * 0.35)
    }

    func camera(time: Float, orbit: Float) -> (eye: SIMD3<Float>, center: SIMD3<Float>) {
        let angle = time * 0.16 * orbit
        // 半径を大きく振って、視錐台に入る数を意図的に変える
        let radius = 620 + sin(time * 0.23) * 420
        return (
            eye: SIMD3(sin(angle) * radius, -sin(time * 0.18) * 220, cos(angle) * radius),
            center: SIMD3(0, 0, -300)
        )
    }
}
