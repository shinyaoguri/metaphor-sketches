import metaphor
import simd

// 仕掛け（Rig）。
//
// この作品の中身はぜんぶ「2D の物理ワールド」と「3D のシーングラフ」の対で出来ている。
// 物理は平面（XY）で解き、その平面ごとシーングラフのノードで 3D 空間に吊る。
// つまり `Node` の親が平面の姿勢を持ち、子が物理ボディに操られる。
//
// 座標の取り決め: **Y は下向き**。metaphor の 3D 投影は 2D キャンバスと同じく画面の
// 下方向が +Y で（`camera(up:)` に (0,1,0) を渡しても変わらない。`screenY` で実測: 
// world y=+250 → 画面 781 / y=-250 → 281）、`Physics2D` の doc 例も `setGravity(0, 980)`
// と Y 下向きで書かれている。両者が揃うので、この作品も一貫して Y 下向きで通す。
// `syncFromPhysics` は XY を素通しするだけなので、これで素直に噛み合う。

/// 物理ボディ 1 個と、それに操られるノード 1 個の対。
struct Strand {
    let body: PhysicsBody2D
    let node: Node
}

/// 1 枚の平面。固有の物理ワールドと、それを吊るすピボットノードを持つ。
@MainActor
final class Plane {
    /// 走査で実際に描かれたノードを数える箱。`attach` の時点で全ノードに仕込むので、
    /// 実行中に足したノード（pit の入れ替え）も取りこぼさない。
    weak var counter: DrawCounter?

    let world: Physics2D
    /// 平面そのものの姿勢。毎フレーム回して `worldTransform` の合成を働かせる。
    let pivot: Node
    private(set) var strands: [Strand] = []
    /// 拘束を線で描くための対（ローカル座標で描く）。
    private(set) var links: [(PhysicsBody2D, PhysicsBody2D)] = []

    /// 1 ステップあたりに速度から抜く割合。
    ///
    /// Verlet 積分には減衰が無く、`restitution` / `friction` も v0.9.0 では効かない
    /// （検査 P3b / P3c）ので、風で入れたエネルギーが抜ける先が無い。抜かないと
    /// 鎖が振り切れて構図が壊れるため、速度を毎ステップ少しだけ削る。
    var damping: Float = 0.02

    /// 1 ステップあたりの拘束・衝突の反復回数。
    ///
    /// 拘束ソルバは反復ごとに隣へ張力を伝えるので、長い鎖ほど反復が要る。
    /// 既定の 4 では 22 リンクの鎖に張力が届かず、伸びきって絡まる。
    var iterations: Int = 4

    init(name: String, cellSize: Float = 50, at position: SIMD3<Float> = .zero) {
        world = Physics2D(cellSize: cellSize)
        pivot = Node(name: name)
        pivot.position = position
    }

    /// `previousPosition` を現在位置へ寄せて速度を削る。
    func applyDamping() {
        guard damping > 0 else { return }
        for body in world.bodies where !body.isStatic {
            body.previousPosition += (body.position - body.previousPosition) * damping
        }
    }

    /// ボディを足し、それに対応するノードをピボットの子として吊る。
    @discardableResult
    func attach(_ body: PhysicsBody2D, mesh: Mesh?, color: Color, z: Float = 0, scale: Float = 1) -> Strand {
        let node = Node(name: "cell\(strands.count)")
        node.mesh = mesh
        node.fillColor = color
        node.position = SIMD3(body.position.x, body.position.y, z)
        node.scale = SIMD3(repeating: scale)
        pivot.addChild(node)
        let strand = Strand(body: body, node: node)
        strands.append(strand)
        return strand
    }

    /// ボディとノードを対で取り除く。`removeBody` は参照している拘束も畳む。
    func remove(_ strand: Strand) {
        world.removeBody(strand.body)
        pivot.removeChild(strand.node)
        strands.removeAll { $0.node === strand.node }
        links.removeAll { $0.0 === strand.body || $0.1 === strand.body }
    }

    func link(_ a: PhysicsBody2D, _ b: PhysicsBody2D, distance: Float? = nil, stiffness: Float = 1) {
        let constraint = world.addConstraint(a, b, distance: distance)
        constraint.stiffness = stiffness
        links.append((a, b))
    }

    /// 物理の位置をノードへ写す。Z はノード側の値が保たれる。
    func sync() {
        for strand in strands {
            strand.node.syncFromPhysics(strand.body)
        }
    }
}

/// シーン 1 つ分の仕掛け一式。
@MainActor
final class Rig {
    let root = Node(name: "rig")
    private(set) var planes: [Plane] = []

    /// 走査中に `onDraw` から数える。カリングされたノードでは呼ばれない。
    let counter = DrawCounter()

    var bodyCount: Int { planes.reduce(0) { $0 + $1.world.bodies.count } }
    var constraintCount: Int { planes.reduce(0) { $0 + $1.world.constraints.count } }
    var nodeCount: Int { planes.reduce(0) { $0 + $1.strands.count } }

    func add(_ plane: Plane) {
        plane.counter = counter
        planes.append(plane)
        root.addChild(plane.pivot)
        reindex()
    }

    /// 全ノードに通し番号を振り直し、その番号で印を付ける `onDraw` を仕込む。
    /// pit のように実行中にノードが増減する場面では、数が変わるたびに呼ぶ。
    func reindex() {
        counter.resize(nodeCount)
        var index = 0
        for plane in planes {
            for strand in plane.strands {
                let slot = index
                strand.node.onDraw = { [weak counter] in counter?.mark(slot) }
                index += 1
            }
        }
        indexedCount = nodeCount
    }

    /// 直近に `reindex()` した時点のノード数。
    private(set) var indexedCount = 0

    /// 全ノードを通し番号つきで順に返す（照合用）。
    func indexedStrands() -> [(index: Int, strand: Strand)] {
        var result: [(Int, Strand)] = []
        var index = 0
        for plane in planes {
            for strand in plane.strands {
                result.append((index, strand))
                index += 1
            }
        }
        return result
    }

    /// 固定刻みで物理を進める。フレーム時間をそのまま渡すと結果が揺れるため
    /// （検査 P1）、実時間を 1/120 秒の固定刻みへ分割して食わせる。
    func step(elapsed: Float, maxSubSteps: Int = 8) -> Int {
        let fixed: Float = 1.0 / 120.0
        let count = min(maxSubSteps, max(1, Int((elapsed / fixed).rounded())))
        for _ in 0..<count {
            for plane in planes {
                plane.world.step(fixed, iterations: plane.iterations)
                plane.applyDamping()
            }
        }
        return count
    }

    func sync() {
        for plane in planes { plane.sync() }
    }

    /// 運動エネルギーの総和（速度は px/ステップなので相対値として使う）。
    var kineticEnergy: Float {
        var total: Float = 0
        for plane in planes {
            for body in plane.world.bodies where !body.isStatic {
                let v = body.velocity
                total += 0.5 * body.mass * simd_dot(v, v)
            }
        }
        return total
    }
}

/// 走査中に実際に描かれたノードを、**1 個ずつ**記録する箱。
///
/// 数だけだと「画面に映っているのにカリングされた」を検出できない。ノードごとに
/// 印を付けておけば、画面内に投影されるノードが確かに描かれたかを 1 個単位で照合できる。
@MainActor
final class DrawCounter {
    private(set) var marks: [Bool] = []

    var drawn: Int { marks.lazy.filter { $0 }.count }

    func resize(_ count: Int) {
        if marks.count != count { marks = Array(repeating: false, count: count) }
    }

    func reset() {
        for i in marks.indices { marks[i] = false }
    }

    func mark(_ index: Int) {
        guard marks.indices.contains(index) else { return }
        marks[index] = true
    }

    func wasDrawn(_ index: Int) -> Bool { marks.indices.contains(index) ? marks[index] : false }
}
