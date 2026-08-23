import Foundation
import simd

// らせん「m」の形そのもの。
//
// ここには metaphor の API を一切書かない。仕様の数式をそのまま持つ純粋な層にしておくと、
// Instrument.swift の検査が描画を起こさずに同じ関数を叩ける（実行のたびに同じ数値が出る）。

enum Insignia {

    // MARK: - 仕様のパラメータ

    static let tau: Float = 2 * .pi

    /// 巻き数（大きな山 + 山 + 尾のカール）。
    static let turns: Float = 2.35
    /// らせん初期半径。
    static let r0: Float = 1.0
    /// 全長にわたる半径の減衰率。
    static let k: Float = 0.58
    /// 軸方向の総移動距離。
    static let lx: Float = 3.05
    /// チューブ初期半径（太さ）。
    static let t0: Float = 0.36
    /// チューブのテーパー率。
    static let kt: Float = 0.70
    /// 細い側（終端）の丸め区間。
    static let cap: Float = 0.07
    /// 太い側（始端）の絞り区間。
    static let lead: Float = 0.065

    /// 軸方向の分割数。
    static let tubular = 560
    /// 円周方向の分割数。
    static let radial = 48

    /// y 軸の向き。
    ///
    /// 仕様は数学の流儀（+y が上）で書かれているが、metaphor の 3D は Processing 由来で
    /// **+y が画面下向き**（`Canvas3D.computeViewProjection` が投影に flipY を掛けている）。
    /// 仕様の式をそのまま使うと `m` が上下逆さまの `w` に見えるので、ここで 1 度だけ符号を反転し、
    /// 以降の全て（検査・カメラのプリセット・ライト）はこの反転済みの世界で考える。
    ///
    /// 反転しても向きの整合は崩れない。フレームは接線から作り直すので、
    /// 反転後の曲線に対して右手系の (T, N, B) が改めて組まれ、巻き順と法線の関係は保たれる
    /// （その事実は検査 G4 が毎回機械判定する）。
    static let yAxis: Float = -1

    // MARK: - 中心曲線

    /// 中心曲線。`t ∈ [0, 1]`。
    ///
    /// y に `R * (1 - cos θ)` を使うのが `m` の生命線。`1 - cos` は θ が 2π の倍数のたびに 0 になるので、
    /// **谷が必ず基線 y = 0 に接する**。`R * sin θ` にすると谷が基線から浮き、真横から見ても `m` にならない。
    static func curve(_ t: Float) -> SIMD3<Float> {
        let adv = (1 - pow(k, t)) / (1 - k)  // イージングされた軸方向進行
        let th = t * turns * tau
        let r = r0 * pow(k, t)

        let x = adv * lx - lx * 0.5
        let y = r * (1 - cos(th))
        let z = r * sin(th)
        return SIMD3(x, yAxis * y, z)
    }

    /// チューブ半径。両端が 0 に収束するので**フタ（キャップ）は要らない**。
    ///
    /// フタを付けると断面が「スパッと切れた」印象になる。半径 0 に落として閉じるほうが、
    /// 貝殻の巻き終わりのように収束して見える。
    static func tubeAt(_ t: Float) -> Float {
        // 両端はここで丸めずに 0 と言い切る。
        // 終端側の `sqrt(1 - u²)` は u が 1 に届く直前で 1e-8 台の残差を拾い、平方根がそれを
        // 1e-4 まで持ち上げてしまう（半径 0 のはずのリングが、直径 0.0003 の輪になる）。
        // 目には見えないが「閉じたソリッド」ではなくなるので、端点だけは式に頼らない。
        if t <= 0 || t >= 1 { return 0 }

        let base = t0 * pow(kt, t)

        // 太い側を短く急に絞って一点に収束させる
        let leadFactor: Float = t < lead ? pow(t / lead, 0.45) : 1

        // 細い側は円弧状に丸めて収束させる（針状に尖らせない）
        let tip: Float
        if t < 1 - cap {
            tip = 1
        } else {
            let u = (t - (1 - cap)) / cap
            tip = sqrt(max(0, 1 - u * u))
        }

        return base * leadFactor * tip
    }

    // MARK: - フレーム

    /// 中心曲線に沿った正規直交フレーム。
    struct Frames {
        var tangents: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var binormals: [SIMD3<Float>]
    }

    /// 曲線に沿ったフレームを求める（閉曲線ではないので始端と終端は繋げない）。
    ///
    /// 素朴な Frenet フレーム（主法線 = 曲率ベクトル）は変曲点で向きが飛ぶので使わない。
    /// 初期法線だけを接線の最小成分から選び、以降は**接線の回転に合わせて前のフレームを回す**
    /// （回転最小化フレーム）。こうするとチューブが途中で捻れず、継ぎ目の UV も素直に繋がる。
    static func computeFrames(segments: Int = tubular) -> Frames {
        var tangents = [SIMD3<Float>](repeating: .zero, count: segments + 1)
        var normals = tangents
        var binormals = tangents

        for i in 0...segments {
            let t = Float(i) / Float(segments)
            tangents[i] = normalize(tangentAt(t, segments: segments))
        }

        // 初期法線: 接線の絶対値が最小の軸を選ぶ（接線と平行になりにくい軸）
        var minAxis = SIMD3<Float>(1, 0, 0)
        let first = tangents[0]
        let ax = abs(first.x), ay = abs(first.y), az = abs(first.z)
        if ay <= ax && ay <= az {
            minAxis = SIMD3(0, 1, 0)
        } else if az <= ax && az <= ay {
            minAxis = SIMD3(0, 0, 1)
        }
        normals[0] = normalize(cross(tangents[0], minAxis))
        binormals[0] = cross(tangents[0], normals[0])

        for i in 1...segments {
            var normal = normals[i - 1]
            let axis = cross(tangents[i - 1], tangents[i])
            if length(axis) > 1e-6 {
                let unit = normalize(axis)
                let theta = acos(max(-1, min(1, dot(tangents[i - 1], tangents[i]))))
                normal = rotate(normal, around: unit, by: theta)
            }
            normals[i] = normalize(normal - tangents[i] * dot(tangents[i], normal))
            binormals[i] = cross(tangents[i], normals[i])
        }

        return Frames(tangents: tangents, normals: normals, binormals: binormals)
    }

    /// 中心差分による接線（端は片側差分に落とす）。
    static func tangentAt(_ t: Float, segments: Int = tubular) -> SIMD3<Float> {
        let h = 1 / Float(segments)
        let a = max(0, t - h)
        let b = min(1, t + h)
        return curve(b) - curve(a)
    }

    /// ロドリゲスの回転公式。
    static func rotate(_ v: SIMD3<Float>, around axis: SIMD3<Float>, by angle: Float) -> SIMD3<Float>
    {
        let c = cos(angle)
        let s = sin(angle)
        return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1 - c)
    }

    // MARK: - メッシュ

    /// 1 頂点ぶんの生データ。DynamicMesh へ流し込む前に、検査から同じ配列を読めるようにしておく。
    struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    /// 組み上がったメッシュ（インデックスは三角形ごとに 3 つずつ並ぶ）。
    struct MeshData {
        var vertices: [Vertex]
        var indices: [UInt32]

        var triangleCount: Int { indices.count / 3 }
    }

    /// チューブを組む。
    ///
    /// 継ぎ目（v = 0 と v = 2π）の頂点は**重複させる**（j を radial + 1 個作る）。
    /// UV を継ぎ目で 0 と 1 に分けるためで、位置としては同じ点が 2 つ在る。
    /// 検査 G6 の多様体判定はこの重複を同一視してから数える。
    static func build(scale: Float = 1) -> MeshData {
        let frames = computeFrames()
        var vertices: [Vertex] = []
        vertices.reserveCapacity((tubular + 1) * (radial + 1))

        for i in 0...tubular {
            let t = Float(i) / Float(tubular)
            let p = curve(t)
            let r = tubeAt(t)
            let n = frames.normals[i]
            let b = frames.binormals[i]

            for j in 0...radial {
                let v = Float(j) / Float(radial) * tau
                let dir = normalize(-sin(v) * n + cos(v) * b)
                vertices.append(
                    Vertex(
                        position: (p + r * dir) * scale,
                        normal: dir,
                        uv: SIMD2(t, Float(j) / Float(radial))
                    ))
            }
        }

        // 外向き CCW。ここを逆に組むと面が内向きになり、陰影が裏返る。
        // metaphor はバックフェースカリングをしない（3D 経路は全て cullMode(.none)）ので、
        // 裏返っても面が消えず**目視では気付きにくい**。だから検査 G4 で機械判定する。
        var indices: [UInt32] = []
        indices.reserveCapacity(tubular * radial * 6)
        let stride = radial + 1
        for i in 1...tubular {
            for j in 1...radial {
                let a = UInt32(stride * (i - 1) + (j - 1))
                let b = UInt32(stride * i + (j - 1))
                let c = UInt32(stride * i + j)
                let d = UInt32(stride * (i - 1) + j)
                indices.append(contentsOf: [a, d, b])
                indices.append(contentsOf: [b, d, c])
            }
        }

        return MeshData(vertices: vertices, indices: indices)
    }

    /// 軸平行バウンディングボックス。
    static func bounds(_ mesh: MeshData) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices {
            lo = simd_min(lo, v.position)
            hi = simd_max(hi, v.position)
        }
        return (lo, hi)
    }

    /// バウンディングボックスの中心を原点とした外接球半径。
    /// カメラの自動フレーミングと、影の実効解像度の見積もりに使う。
    static func boundingRadius(_ mesh: MeshData) -> Float {
        let (lo, hi) = bounds(mesh)
        let center = (lo + hi) * 0.5
        var maxSq: Float = 0
        for v in mesh.vertices {
            maxSq = max(maxSq, length_squared(v.position - center))
        }
        return sqrt(maxSq)
    }
}
