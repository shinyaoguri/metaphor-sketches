import Foundation

/// 三次元セルオートマトンのルール。26 近傍（ムーア近傍）の「生きている」隣人の数で決める。
///
/// 二次元の B3/S23 をそのまま 3D へ持ち込むと、多くのルールは即座に絶滅するか空間を
/// 埋め尽くすかのどちらかになる。3D で長く動き続けるルールの多くは **多状態** で、
/// 死んだ細胞がいきなり消えるのではなく `states - 1` 段階かけて減衰し、その間は
/// 生き返れない（不応期を持つ）。この減衰段階が、群体に軌跡と厚みを与える。
///
/// 表記は 3D CA の慣習に合わせた `生存 / 誕生 / 状態数 / 近傍` で、判定は 27 bit の
/// マスクで行う（毎ステップ数十万回引くので、集合よりビット演算が速い）。
struct LifeRule {
    let name: String
    /// HUD 用の短い表記。
    let summary: String
    let surviveMask: UInt32
    let bornMask: UInt32
    /// 状態数。2 なら死んだ瞬間に消え、3 以上なら減衰段階を持つ。
    let states: Int
    /// このルールが育ちやすい初期密度。
    let seedDensity: Float
    /// 初期化する領域が格子全体に占める割合（1 で空間全体に蒔く）。
    let seedSpan: Float

    init(name: String, survive: [ClosedRange<Int>], born: [ClosedRange<Int>], states: Int,
         seedDensity: Float, seedSpan: Float) {
        self.name = name
        self.summary = "\(LifeRule.label(survive)) / \(LifeRule.label(born)) / \(states)"
        self.surviveMask = LifeRule.mask(survive)
        self.bornMask = LifeRule.mask(born)
        self.states = max(2, states)
        self.seedDensity = seedDensity
        self.seedSpan = seedSpan
    }

    private static func mask(_ ranges: [ClosedRange<Int>]) -> UInt32 {
        var m: UInt32 = 0
        for range in ranges {
            for v in range where v >= 0 && v <= 26 { m |= (1 << UInt32(v)) }
        }
        return m
    }

    private static func label(_ ranges: [ClosedRange<Int>]) -> String {
        ranges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
            .joined(separator: ",")
    }

    @inline(__always) func survives(_ n: Int) -> Bool { surviveMask & (1 << UInt32(n)) != 0 }
    @inline(__always) func isBorn(_ n: Int) -> Bool { bornMask & (1 << UInt32(n)) != 0 }

    /// 選択できるルール名（`@Param(choices:)` に渡す順序）。
    static let names = ["pyroclastic", "amoeba", "445", "coral", "architecture", "crystal"]

    static let presets: [LifeRule] = [
        // 噴煙のような塊が湧き上がり、崩れながら広がる
        LifeRule(name: "pyroclastic", survive: [4...7], born: [6...8], states: 10,
                 seedDensity: 0.30, seedSpan: 0.35),
        // 生存に 9 以上の隣人が要るので、濃い塊だけが生き残って這うように広がる
        LifeRule(name: "amoeba", survive: [9...26], born: [5...7], states: 5,
                 seedDensity: 0.52, seedSpan: 0.5),
        // 3D CA の定番。ひと塊の種（2×2×2）が振動しながら結晶状に展開する。
        // ちょうど 4 個の隣人という厳しい条件なので、ランダムなスープからは育たない
        LifeRule(name: "445", survive: [4...4], born: [4...4], states: 5,
                 seedDensity: 1.0, seedSpan: 0.1),
        // 珊瑚状の面が空間を折りたたむように広がる。密度が上下しても同じ濃さへ戻る
        LifeRule(name: "coral", survive: [5...8], born: [6...7, 9...9, 12...12], states: 4,
                 seedDensity: 0.30, seedSpan: 0.6),
        // 細い骨組みが空間へ伸び、建造物のような構造を組み上げる
        LifeRule(name: "architecture", survive: [4...6], born: [3...3], states: 2,
                 seedDensity: 0.13, seedSpan: 0.35),
        // ひと粒の種から結晶が成長し、格子を侵食していく
        LifeRule(name: "crystal", survive: [0...6], born: [1...1, 3...3], states: 2,
                 seedDensity: 1.0, seedSpan: 0.06),
    ]

    static func named(_ name: String) -> LifeRule {
        presets.first { $0.name == name } ?? presets[0]
    }
}

/// 立方格子上の三次元ライフゲーム（多状態セルオートマトン）。
///
/// セルの値は `0` = 死、`1` = 生、`2...states-1` = 減衰中。近傍数に数えるのは生のセルだけ。
/// 26 近傍を素直に数えると 1 セルあたり 27 回の参照になり、デバッグビルドでは 24³ でも
/// 100ms 近くかかる。ここでは 3×3×3 のブロック和が軸ごとに分離できることを使い、
/// X → Y → Z の 3 パス（1 セルあたり 6 回の加算）で求めている。
final class Life3D {
    /// 一辺のセル数。
    private(set) var size: Int
    /// セルの状態（0 = 死 / 1 = 生 / 2 以上 = 減衰中）。
    private(set) var cells: [UInt8]
    /// 連続して生存している世代数（255 で飽和）。色付けに使う。
    private(set) var age: [UInt8]
    /// 表示強度 0…1。状態ごとの目標値へ毎フレーム指数的に近づく。
    private(set) var intensity: [Float]

    private var scratch: [UInt8]
    private var alive: [UInt8]   // 生きているセルだけを 1 にしたマスク（ブロック和の入力）
    private var sumA: [UInt8]    // X 方向の 3 連和
    private var sumB: [UInt8]    // さらに Y 方向へ畳んだ和
    private var sumC: [UInt8]    // さらに Z 方向へ畳んだ和 = 3×3×3 ブロック和

    private(set) var generation = 0
    private(set) var population = 0
    private(set) var births = 0
    private(set) var deaths = 0
    /// 停滞・絶滅を検知して自動で蒔き直した回数。
    private(set) var reseedCount = 0

    var rule: LifeRule
    /// 境界を巻き込む（トーラス）か。有限境界だと群体が壁で削られて痩せていくルールが多い。
    var wrap: Bool = true

    /// 直近の「入れ替わり量（誕生＋死亡）」の履歴（停滞判定用）。
    /// 個体数で判定すると、形は変わり続けているのに数だけ一定な群体を誤って停滞と見なしてしまう。
    private var history: [Int] = []

    init(size: Int, rule: LifeRule) {
        self.size = size
        self.rule = rule
        let count = size * size * size
        cells = [UInt8](repeating: 0, count: count)
        scratch = cells
        age = cells
        alive = cells
        sumA = cells
        sumB = cells
        sumC = cells
        intensity = [Float](repeating: 0, count: count)
    }

    var cellCount: Int { size * size * size }

    @inline(__always)
    func index(_ x: Int, _ y: Int, _ z: Int) -> Int {
        (z * size + y) * size + x
    }

    /// 格子サイズを変える（内容は破棄して蒔き直す）。
    func resize(to newSize: Int, density: Float, span: Float) {
        guard newSize != size else { return }
        size = newSize
        let count = newSize * newSize * newSize
        cells = [UInt8](repeating: 0, count: count)
        scratch = cells
        age = cells
        alive = cells
        sumA = cells
        sumB = cells
        sumC = cells
        intensity = [Float](repeating: 0, count: count)
        generation = 0
        seed(density: density, span: span)
    }

    /// 種を蒔く。`span` が 1 未満なら中央の立方領域だけに蒔く。
    func seed(density: Float, span: Float) {
        for i in cells.indices {
            cells[i] = 0
            age[i] = 0
        }
        let extent = max(2, Int((Float(size) * min(max(span, 0.02), 1)).rounded()))
        let lo = (size - extent) / 2
        let hi = min(size, lo + extent)
        var count = 0
        for z in lo..<hi {
            for y in lo..<hi {
                for x in lo..<hi where Float.random(in: 0..<1) < density {
                    let i = index(x, y, z)
                    cells[i] = 1
                    age[i] = 1
                    count += 1
                }
            }
        }
        population = count
        births = count
        deaths = 0
        generation = 0
        history.removeAll(keepingCapacity: true)
        refreshAliveMask()
        computeBlockSums()
    }

    /// 生きているセルだけのマスクを作り直す。
    private func refreshAliveMask() {
        cells.withUnsafeBufferPointer { src in
            alive.withUnsafeMutableBufferPointer { dst in
                for i in dst.indices { dst[i] = src[i] == 1 ? 1 : 0 }
            }
        }
    }

    /// 3×3×3 のブロック和を軸ごとの 3 パスで求める（入力は `alive`、結果は `sumC`）。
    /// `wrap` が真なら各軸の端を反対側へ繋ぐ。
    private func computeBlockSums() {
        let n = size
        let torus = wrap

        alive.withUnsafeBufferPointer { src in
            sumA.withUnsafeMutableBufferPointer { a in
                for row in stride(from: 0, to: n * n * n, by: n) {
                    for x in 0..<n {
                        var s = Int(src[row + x])
                        if x > 0 { s += Int(src[row + x - 1]) } else if torus { s += Int(src[row + n - 1]) }
                        if x < n - 1 { s += Int(src[row + x + 1]) } else if torus { s += Int(src[row]) }
                        a[row + x] = UInt8(s)
                    }
                }
            }
        }
        sumA.withUnsafeBufferPointer { a in
            sumB.withUnsafeMutableBufferPointer { b in
                for z in 0..<n {
                    let plane = z * n * n
                    for y in 0..<n {
                        let row = plane + y * n
                        let up = y > 0 ? row - n : plane + (n - 1) * n
                        let down = y < n - 1 ? row + n : plane
                        for x in 0..<n {
                            var s = Int(a[row + x])
                            if y > 0 || torus { s += Int(a[up + x]) }
                            if y < n - 1 || torus { s += Int(a[down + x]) }
                            b[row + x] = UInt8(s)
                        }
                    }
                }
            }
        }
        sumB.withUnsafeBufferPointer { b in
            sumC.withUnsafeMutableBufferPointer { c in
                let planeSize = n * n
                for z in 0..<n {
                    let plane = z * planeSize
                    let back = z > 0 ? plane - planeSize : (n - 1) * planeSize
                    let front = z < n - 1 ? plane + planeSize : 0
                    for i in 0..<planeSize {
                        var s = Int(b[plane + i])
                        if z > 0 || torus { s += Int(b[back + i]) }
                        if z < n - 1 || torus { s += Int(b[front + i]) }
                        c[plane + i] = UInt8(s)
                    }
                }
            }
        }
    }

    /// 1 世代進める。`sumC` は常に「現在の `cells` に対応するブロック和」に保たれる
    /// （seed / restore の直後と、各ステップの最後に計算し直す）。
    func step() {
        var born = 0
        var died = 0
        var living = 0
        let decayStart: UInt8 = 2
        let lastState = UInt8(rule.states - 1)
        let hasDecay = rule.states > 2

        cells.withUnsafeBufferPointer { src in
            alive.withUnsafeBufferPointer { live in
                sumC.withUnsafeBufferPointer { block in
                    scratch.withUnsafeMutableBufferPointer { dst in
                        age.withUnsafeMutableBufferPointer { ages in
                            for i in dst.indices {
                                let state = src[i]
                                // ブロック和には自分自身が含まれるので引く
                                let neighbors = Int(block[i]) - Int(live[i])

                                if state == 1 {
                                    if rule.survives(neighbors) {
                                        dst[i] = 1
                                        living += 1
                                        ages[i] = ages[i] < 255 ? ages[i] + 1 : 255
                                    } else {
                                        dst[i] = hasDecay ? decayStart : 0
                                        ages[i] = 0
                                        died += 1
                                    }
                                } else if state == 0 {
                                    if rule.isBorn(neighbors) {
                                        dst[i] = 1
                                        ages[i] = 1
                                        living += 1
                                        born += 1
                                    } else {
                                        dst[i] = 0
                                    }
                                } else {
                                    // 減衰中。最終段階を超えたら消える（この間は生き返らない）
                                    dst[i] = state >= lastState ? 0 : state + 1
                                }
                            }
                        }
                    }
                }
            }
        }

        swap(&cells, &scratch)
        refreshAliveMask()
        computeBlockSums()

        generation += 1
        population = living
        births = born
        deaths = died

        history.append(born + died)
        if history.count > 16 { history.removeFirst() }
    }

    /// セルの状態に対する表示強度の目標値。減衰中は段階的に暗くなる。
    @inline(__always)
    func targetIntensity(_ state: UInt8) -> Float {
        if state == 1 { return 1 }
        if state == 0 { return 0 }
        guard rule.states > 2 else { return 0 }
        // 減衰し始めで 0.45、最終段階で 0 に近づく（生きた細胞より小さく・暗く見せる）
        let progress = Float(Int(state) - 1) / Float(rule.states - 2)
        return 0.45 * (1 - progress)
    }

    /// 表示強度を実時間で補間する（生死の切り替わりを滑らかに見せる）。
    func updateIntensity(deltaTime: Float, rise: Float = 16, fall: Float = 7) {
        let up = 1 - exp(-deltaTime * rise)
        let down = 1 - exp(-deltaTime * fall)
        cells.withUnsafeBufferPointer { src in
            intensity.withUnsafeMutableBufferPointer { buf in
                for i in buf.indices {
                    let target = targetIntensity(src[i])
                    let current = buf[i]
                    buf[i] = current + (target - current) * (target > current ? up : down)
                }
            }
        }
    }

    /// 絶滅、または細胞の入れ替わりが止まった（静止画・短周期の振動になった）か。
    var isStagnant: Bool {
        if population == 0 { return true }
        guard history.count >= 12 else { return false }
        let churn = history.suffix(12).reduce(0, +)
        // 12 世代かけても個体数の 2% ぶんしか入れ替わらなければ、実質止まっているとみなす
        return churn <= max(4, population / 50)
    }

    /// 周囲 26 近傍がすべて生きているセル（＝群体の内側で外から見えない）。
    /// 自分自身の状態は問わないので、減衰中の細胞も内側なら省ける。
    @inline(__always)
    func isInterior(_ i: Int) -> Bool {
        Int(sumC[i]) - Int(alive[i]) == 26
    }

    // MARK: - リロードを跨いだ保存

    struct Saved: Codable {
        var size: Int
        var cells: [UInt8]
        var age: [UInt8]
        var generation: Int
        var reseedCount: Int
    }

    func snapshotState() -> Saved {
        Saved(size: size, cells: cells, age: age, generation: generation, reseedCount: reseedCount)
    }

    func restore(_ saved: Saved) {
        let count = saved.size * saved.size * saved.size
        guard saved.cells.count == count, saved.age.count == count else { return }
        size = saved.size
        cells = saved.cells
        scratch = saved.cells
        age = saved.age
        alive = [UInt8](repeating: 0, count: count)
        sumA = alive
        sumB = alive
        sumC = alive
        intensity = cells.map { targetIntensity($0) }
        generation = saved.generation
        reseedCount = saved.reseedCount
        population = cells.reduce(0) { $0 + ($1 == 1 ? 1 : 0) }
        history.removeAll(keepingCapacity: true)
        refreshAliveMask()
        computeBlockSums()
    }

    func markReseeded() {
        reseedCount += 1
    }
}
