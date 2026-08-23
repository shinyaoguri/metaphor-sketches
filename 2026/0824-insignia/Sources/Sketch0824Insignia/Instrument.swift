import Foundation
import simd

// 検証器。
//
// 作品の見た目とは独立に、「らせん m」が仕様どおりに組めているかを**決定論的に**測る。
// 描画も時計も使わないので、実行するたびに同じ数値が出る。結果は frame.json の `custom` に
// `check.<ID>` として載り、標準出力にも出る（スクリーンショットではなくこの数値が一次証拠）。
//
// なぜ機械判定が要るのか: metaphor の 3D 経路はバックフェースカリングをしないので、
// 面が内向きに組まれていても**面が消えず、目視では気付けない**（陰影だけが静かに壊れる）。
// 仕様 §7 の「よくある失敗」は、そのほとんどが絵を見ても判定できない類のもの。

/// 検査 1 件の結果。
struct Verdict {
    let id: String
    let passed: Bool
    /// 実測値。FAIL のとき何がどう違ったのかを人が読める形で残す。
    let detail: String

    var line: String { "\(passed ? "PASS" : "FAIL") \(detail)" }
}

/// 決定論的な検査の一式。`setup()` で 1 回だけ走らせる。
enum Instrument {

    /// 検査に使うメッシュは論理単位（`scale = 1`）で組む。
    /// 作品が描くメッシュはワールドスケールを掛けた別インスタンスだが、形は相似なので
    /// 巻き順・法線・多様体性の判定はこちらで足りる。
    static func runAll(worldScale: Float, shadowResolution: Int) -> [Verdict] {
        let mesh = Insignia.build()
        return [
            baselineContact(),
            tipConvergence(),
            meshCounts(mesh),
            outwardWinding(mesh),
            frameOrthonormality(),
            manifoldEdges(mesh),
            letterProfile(),
            shadowFootprint(mesh, worldScale: worldScale, resolution: shadowResolution),
        ]
    }

    // MARK: - G1: 谷が基線に接する

    /// `m` に見えるための必要条件。谷（θ = 2πm）で y がちょうど 0 になるか。
    ///
    /// ここが崩れると脚が地面から浮き、真横から見ても `m` に読めない（仕様 §7-3）。
    static func baselineContact() -> Verdict {
        var worst: Float = 0
        var worstT: Float = 0
        var count = 0

        var m = 0
        while Float(m) <= Insignia.turns {
            let t = Float(m) / Insignia.turns
            guard t <= 1 else { break }
            let y = abs(Insignia.curve(t).y)
            if y > worst {
                worst = y
                worstT = t
            }
            count += 1
            m += 1
        }

        let tolerance: Float = 1e-5
        return Verdict(
            id: "G1.baselineContact",
            passed: count >= 3 && worst < tolerance,
            detail:
                "谷 \(count) 個で |y| 最大 \(fmt(worst)) (t=\(fmt(worstT))) 期待<\(fmt(tolerance))"
        )
    }

    // MARK: - G2: 両端の収束

    /// 両端でチューブ半径が 0 に落ちるか。落ちていればフタは要らず、閉じたソリッドになる（仕様 §2.3）。
    static func tipConvergence() -> Verdict {
        let head = Insignia.tubeAt(0)
        let tail = Insignia.tubeAt(1)
        let mid = Insignia.tubeAt(0.5)
        return Verdict(
            id: "G2.tipConvergence",
            passed: head == 0 && tail == 0 && mid > 0,
            detail: "tubeAt(0)=\(fmt(head)) tubeAt(1)=\(fmt(tail)) tubeAt(0.5)=\(fmt(mid)) 期待=0/0/正"
        )
    }

    // MARK: - G3: 頂点数・インデックス数

    static func meshCounts(_ mesh: Insignia.MeshData) -> Verdict {
        let expectedVertices = (Insignia.tubular + 1) * (Insignia.radial + 1)
        let expectedIndices = Insignia.tubular * Insignia.radial * 6
        let ok = mesh.vertices.count == expectedVertices && mesh.indices.count == expectedIndices
        return Verdict(
            id: "G3.meshCounts",
            passed: ok,
            detail:
                "頂点 \(mesh.vertices.count)/期待 \(expectedVertices) インデックス \(mesh.indices.count)/期待 \(expectedIndices) 三角形 \(mesh.triangleCount)"
        )
    }

    // MARK: - G4: 巻き順が外向きか

    /// 全三角形で「面法線（頂点順から作る）」と「頂点法線（自前で与えたチューブ外向き）」が同じ側を向くか。
    ///
    /// 仕様 §7-1 の機械判定。metaphor はカリングしないので、逆に組んでも面は消えない。
    /// 両端は半径 0 に潰れていて面積が 0 なので、退化した三角形は判定から外して数だけ報告する。
    static func outwardWinding(_ mesh: Insignia.MeshData) -> Verdict {
        var inward = 0
        var degenerate = 0
        var worstDot: Float = 1

        var i = 0
        while i < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[i])]
            let b = mesh.vertices[Int(mesh.indices[i + 1])]
            let c = mesh.vertices[Int(mesh.indices[i + 2])]
            i += 3

            let faceNormal = cross(b.position - a.position, c.position - a.position)
            if length(faceNormal) < 1e-12 {
                degenerate += 1
                continue
            }
            let vertexNormal = normalize(a.normal + b.normal + c.normal)
            let d = dot(normalize(faceNormal), vertexNormal)
            worstDot = min(worstDot, d)
            if d <= 0 { inward += 1 }
        }

        return Verdict(
            id: "G4.outwardWinding",
            passed: inward == 0,
            detail:
                "内向き \(inward) 枚 / 判定対象 \(mesh.triangleCount - degenerate) 枚 (退化 \(degenerate) 枚は除外) 内積の最小 \(fmt(worstDot)) 期待>0"
        )
    }

    // MARK: - G5: フレームの正規直交性

    /// (T, N, B) が正規直交で、かつ右手系（T × N = B）のままか。
    /// ここが崩れるとチューブの断面が歪み、法線も嘘になる。
    static func frameOrthonormality() -> Verdict {
        let frames = Insignia.computeFrames()
        var worst: Float = 0
        var worstLabel = "-"

        func note(_ value: Float, _ label: String) {
            if value > worst {
                worst = value
                worstLabel = label
            }
        }

        for i in 0...Insignia.tubular {
            let t = frames.tangents[i]
            let n = frames.normals[i]
            let b = frames.binormals[i]
            note(abs(length(t) - 1), "|T|-1@\(i)")
            note(abs(length(n) - 1), "|N|-1@\(i)")
            note(abs(length(b) - 1), "|B|-1@\(i)")
            note(abs(dot(t, n)), "T·N@\(i)")
            note(abs(dot(n, b)), "N·B@\(i)")
            note(abs(dot(t, b)), "T·B@\(i)")
            note(length(cross(t, n) - b), "T×N-B@\(i)")
        }

        let tolerance: Float = 1e-4
        return Verdict(
            id: "G5.frameOrthonormality",
            passed: worst < tolerance,
            detail: "最大偏差 \(fmt(worst)) (\(worstLabel)) 期待<\(fmt(tolerance))"
        )
    }

    // MARK: - G6: 閉じたソリッドか

    /// 継ぎ目の重複頂点を同一視したうえで、
    ///
    /// 1. 内部エッジが**ちょうど 2 枚**の三角形に共有されているか（穴も裏返りも無い）
    /// 2. 境界エッジが両端リングのぶんだけ（= `radial * 2` 本）か
    /// 3. その両端リングが**幾何的に 1 点へ潰れている**か
    ///
    /// を見る。3 が成り立つときだけ「フタ無しで閉じたソリッド」と言える（仕様 §2.3）。
    static func manifoldEdges(_ mesh: Insignia.MeshData) -> Verdict {
        let stride = Insignia.radial + 1

        // 継ぎ目（j = radial）は j = 0 と同じ点。グリッド座標に戻して同一視する。
        func canonical(_ index: UInt32) -> Int {
            let i = Int(index) / stride
            let j = Int(index) % stride
            return i * Insignia.radial + (j % Insignia.radial)
        }

        var edgeCount: [Int64: Int] = [:]
        edgeCount.reserveCapacity(mesh.triangleCount * 3)

        func key(_ a: Int, _ b: Int) -> Int64 {
            let lo = Int64(min(a, b))
            let hi = Int64(max(a, b))
            return lo << 32 | hi
        }

        var i = 0
        while i < mesh.indices.count {
            let a = canonical(mesh.indices[i])
            let b = canonical(mesh.indices[i + 1])
            let c = canonical(mesh.indices[i + 2])
            i += 3
            for (u, v) in [(a, b), (b, c), (c, a)] where u != v {
                edgeCount[key(u, v), default: 0] += 1
            }
        }

        var boundary = 0
        var overShared = 0
        for (_, count) in edgeCount {
            if count == 1 {
                boundary += 1
            } else if count != 2 {
                overShared += 1
            }
        }

        // 両端リングが 1 点に潰れているか
        func ringSpread(_ ring: Int) -> Float {
            let base = ring * stride
            let origin = mesh.vertices[base].position
            var worst: Float = 0
            for j in 0...Insignia.radial {
                worst = max(worst, distance(mesh.vertices[base + j].position, origin))
            }
            return worst
        }
        let spread = max(ringSpread(0), ringSpread(Insignia.tubular))

        let expectedBoundary = Insignia.radial * 2
        let ok = overShared == 0 && boundary == expectedBoundary && spread < 1e-6
        return Verdict(
            id: "G6.closedSolid",
            passed: ok,
            detail:
                "3 枚以上に共有されたエッジ \(overShared) 本 境界エッジ \(boundary)/期待 \(expectedBoundary) 両端リングの広がり \(fmt(spread)) 期待<1e-06"
        )
    }

    // MARK: - G7: 真横から `m` に読めるか

    /// 真横（+Z 方向）への正射影で、中心曲線の輪郭が `m` の骨格になっているか。
    ///
    /// 期待するのは**谷 3・山 2**。小文字の `m` は 3 本の脚が基線に着き、その間に 2 つのアーチが立つ。
    /// 巻き数 2.35 のうち 2 巻きぶんがこの骨格を作り、余りの 0.35 が尾のカールになる。
    static func letterProfile() -> Verdict {
        let samples = Insignia.tubular * 4
        var ys: [Float] = []
        ys.reserveCapacity(samples + 1)
        for i in 0...samples {
            ys.append(Insignia.curve(Float(i) / Float(samples)).y)
        }

        // ワールドは +y が下向きなので、画面の「山」は y の極小、「谷」は y の極大。
        var peaks = 0
        var valleys = 0
        var worstValley: Float = 0
        for i in 1..<ys.count - 1 {
            let prev = ys[i - 1], cur = ys[i], next = ys[i + 1]
            if cur < prev && cur <= next { peaks += 1 }
            if cur > prev && cur >= next {
                valleys += 1
                worstValley = max(worstValley, abs(cur))
            }
        }
        // 始端 t=0 は谷（θ=0）だが極値判定の窓に入らないので足す
        valleys += 1

        let ok = peaks == 2 && valleys == 3 && worstValley < 1e-5
        return Verdict(
            id: "G7.letterProfile",
            passed: ok,
            detail:
                "山 \(peaks)/期待 2 谷 \(valleys)/期待 3 谷の |y| 最大 \(fmt(worstValley)) 期待<1e-05"
        )
    }

    // MARK: - S1: 影の実効解像度

    /// シャドウマップのうち、この作品が実際に占める面積。
    ///
    /// metaphor の `ShadowMap.updateLightSpaceMatrix` は正射影の範囲を `sceneRadius` から作るが、
    /// 呼び出し元（`Canvas3D+Frame.swift`）はこれを渡さないので**常に既定の 500 が使われる**。
    /// つまり影の焼き付け範囲は 1000 ワールド単位で固定で、作品側から狭める手段が無い。
    /// 仕様 §4 が要求する「正射影 ±2.4」は表現できないため、ワールドスケールで実質的に合わせにいく。
    ///
    /// 判定は「輪郭が読める程度に焼けているか」。マップ上で 512px を下回ったら FAIL にする。
    static func shadowFootprint(_ mesh: Insignia.MeshData, worldScale: Float, resolution: Int)
        -> Verdict
    {
        let fixedSceneRadius: Float = 500
        let worldRadius = Insignia.boundingRadius(mesh) * worldScale
        let pixels = Float(resolution) * worldRadius / fixedSceneRadius

        return Verdict(
            id: "S1.shadowFootprint",
            passed: pixels >= 512,
            detail:
                "外接球半径 \(fmt(worldRadius)) / 固定 sceneRadius \(fmt(fixedSceneRadius)) → \(Int(pixels))px "
                + "(マップ \(resolution)px、作品の外接球ぴったりに絞れれば \(resolution)px) 期待>=512px"
        )
    }

    // MARK: - 補助

    private static func fmt(_ value: Float) -> String {
        String(format: "%.6g", value)
    }
}
