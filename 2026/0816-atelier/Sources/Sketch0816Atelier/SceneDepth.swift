import Foundation
import simd
import metaphor

// 場面 3「奥行き」— 遠近と深度は投影の式どおりか。
//
// 既定カメラは毎フレーム `eye=(w/2, h/2, defaultZ)` へ戻る。この規約から、
// 深さ z に置いた**厚みのない板**の投影倍率は厳密に `defaultZ / (defaultZ - z)` になる。
// 板を使うのは、箱だと手前の面と奥の面で倍率が違ってシルエットの解釈が要るため。
//
// カメラの背後（`w ≦ 0`）は `screenPosition` が壊れる場所でもある。
// 0816-marionette ではここを踏んで**自分の検査バグ**を 8 件出したので、
// この作品では `Optics.project` が `w` も返すようにしてある。

extension Sketch0816Atelier {

    enum DepthSetup {
        /// 遠近の検査に使う板の一辺。
        static let tile: Float = 200
        /// 板を置く深さ。手前（+z）ほど大きく写る。
        static let depths: [Float] = [-600, -300, 0, 200]
        /// 上の深さに対応するワールド x のずらし量。
        /// 投影後の中心がだいたい 180 / 400 / 700 / 1080 px に来るよう逆算してある。
        static let offsets: [Float] = [-902.7, -355.5, 60, 298.9]
        /// `ortho()` の範囲を「ビュー空間の中心が画面の中心に来る」ように直したもの。
        ///
        /// near / far も明示する。既定の ±1000 だと、既定カメラのビュー空間では
        /// z が `-defaultZ` を中心に散るので奥の板がクリップされて消える
        /// （引数なしの `ortho()` が使いものにならない理由と同じ根）。
        static func fixedOrtho(width: Float, height: Float)
            -> (left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) {
            (left: -width / 2, right: width / 2, bottom: height / 2, top: -height / 2,
             near: -2200, far: 2200)
        }
        /// `screenX/Y` の照合に使う小板の位置。
        static let probePoint = SIMD3<Float>(-260, -140, 150)
        static let probeTile: Float = 90
        /// 深度テストの検査に使う 2 枚の板。
        static let nearZ: Float = 150
        static let farZ: Float = -250
        /// ビルボードの一辺。
        static let billboard: Float = 220
    }

    func depthSpecimens() -> [Specimen] {
        [
            Specimen(name: "foreshorten", title: "遠近 perspective",
                     note: "深さ z の板は defaultZ/(defaultZ−z) 倍で写るか"),
            Specimen(name: "orthoDefault", title: "正射影 ortho()（引数なし）",
                     note: "省略時の範囲は既定カメラと噛み合うか"),
            Specimen(name: "orthoFixed", title: "正射影 ortho(範囲を明示)",
                     note: "範囲を直せば奥行きで縮まなくなるか"),
            Specimen(name: "screenPos", title: "screenX / screenY",
                     note: "戻り値は焼き上がった位置と一致するか"),
            Specimen(name: "screenZ", title: "screenZ とカメラの背後",
                     note: "0…1 に収まるか。背後の点で何が返るか"),
            Specimen(name: "camera", title: "camera(eye:center:up:)",
                     note: "自前で組んだ view 行列と一致するか"),
            Specimen(name: "depthTest", title: "深度テスト",
                     note: "手前の板を先に描いても奥の板に上書きされないか"),
            Specimen(name: "billboard", title: "currentCameraRight / Up",
                     note: "カメラを傾けても正方形のまま写るか"),
        ]
    }

    /// 深さ z・ずらし量 X の板の、投影後の中心 x。
    private func tileCenterX(_ k: Int) -> Float {
        let s = standardOptics.foreshortening(atZ: DepthSetup.depths[k])
        return axis.x + DepthSetup.offsets[k] * s
    }

    // MARK: 描く

    func drawDepthSpecimen(_ i: Int) {
        noLights()
        noStroke()
        fillRGB(Palette.specimen)

        switch i {
        case 0:
            for (k, z) in DepthSetup.depths.enumerated() {
                push()
                translate(axis.x + DepthSetup.offsets[k], axis.y, z)
                plane(DepthSetup.tile, DepthSetup.tile)
                pop()
            }

        case 1:
            ortho()     // 引数なし = 既定の範囲
            push()
            translate(axis.x, axis.y, 0)
            plane(DepthSetup.tile, DepthSetup.tile)
            pop()

        case 2:
            let r = DepthSetup.fixedOrtho(width: width, height: height)
            ortho(left: r.left, right: r.right, bottom: r.bottom, top: r.top,
                  near: r.near, far: r.far)
            for (k, z) in DepthSetup.depths.enumerated() {
                push()
                // 正射影では倍率が 1 なので、ずらし量はそのまま画面のずれになる。
                translate(axis.x + Float(k - 2) * 300 + 150, axis.y, z)
                plane(DepthSetup.tile, DepthSetup.tile)
                pop()
            }

        case 3:
            push()
            translate(axis.x + DepthSetup.probePoint.x,
                      axis.y + DepthSetup.probePoint.y,
                      DepthSetup.probePoint.z)
            plane(DepthSetup.probeTile, DepthSetup.probeTile)
            pop()

        case 4:
            // 数値の検査だが、絵としては奥へ退いていく列にしておく。
            for k in 0..<6 {
                let z = Float(k) * -220 + 300
                push()
                translate(axis.x + Float(k - 3) * 150 + 75, axis.y, z)
                box(90)
                pop()
            }

        case 5:
            let cam = depthCameraOptics()
            camera(eye: cam.eye, center: cam.center, up: cam.up)
            push()
            translate(axis.x + 120, axis.y - 60, -80)
            plane(DepthSetup.tile, DepthSetup.tile)
            pop()

        case 6:
            // 手前の板を**先に**描き、奥の板をあとから重ねる。
            fill(96, 150, 210)
            push(); translate(axis.x, axis.y, DepthSetup.nearZ)
            plane(300, 300); pop()
            fill(214, 86, 66)
            push(); translate(axis.x, axis.y, DepthSetup.farZ)
            plane(520, 520); pop()

        default:
            let cam = depthCameraOptics()
            camera(eye: cam.eye, center: cam.center, up: cam.up)
            let right = context.canvas3D.currentCameraRight
            let up = context.canvas3D.currentCameraUp
            let c = cam.center
            let h = DepthSetup.billboard / 2
            beginShape3D(.triangles)
            normal(0, 0, 1)
            let p00 = c - right * h - up * h
            let p10 = c + right * h - up * h
            let p11 = c + right * h + up * h
            let p01 = c - right * h + up * h
            for p in [p00, p10, p11, p00, p11, p01] { vertex(p.x, p.y, p.z) }
            endShape3D(.close)
        }
    }

    /// 場面 3 で使う自前カメラ。斜め上から台を見下ろす向き。
    ///
    /// **ワールドの Y は下向き**なので、見下ろすには eye の y を小さく取る。
    func depthCameraOptics() -> (eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) {
        let z = Optics.standardZ(height: height)
        return (eye: SIMD3(width / 2 + 220, height / 2 - 180, z * 0.9),
                center: SIMD3(width / 2, height / 2, -60),
                up: SIMD3(0, 1, 0))
    }

    // MARK: 測る

    func judgeDepthSpecimen(_ i: Int, _ c: Canvas) -> [Finding] {
        let o = standardOptics

        switch i {
        case 0:
            var out: [Finding] = []
            for (k, z) in DepthSetup.depths.enumerated() {
                let s = o.foreshortening(atZ: z)
                let cx = tileCenterX(k)
                let cell = Rect.around(cx, axis.y, DepthSetup.tile * s / 2 + 40, DepthSetup.tile * s / 2 + 40)
                guard let sil = c.silhouette(in: cell) else {
                    out.append(Finding("D1\(k).foreshorten", "深さ \(f0(z)) の板", .fail("写らなかった")))
                    continue
                }
                out.append(Finding("D1\(k).foreshorten\(f0(z))", "深さ \(f0(z)) の板の幅",
                                   expect(sil.w, DepthSetup.tile * s, tol: 2.5,
                                          what: "倍率 \(f3(s)) = defaultZ/(defaultZ−z)")))
            }
            // 手前と奥の比。倍率の式そのものを 1 行で見せる。
            let sNear = o.foreshortening(atZ: DepthSetup.depths.last!)
            let sFar = o.foreshortening(atZ: DepthSetup.depths.first!)
            out.append(Finding("D1e.foreshortenRatio", "手前と奥の比",
                               .look("手前(z=\(f0(DepthSetup.depths.last!)))=\(f3(sNear)) 倍 / "
                                     + "奥(z=\(f0(DepthSetup.depths.first!)))=\(f3(sFar)) 倍 / "
                                     + "比=\(f3(sNear / sFar))")))
            return out

        case 1:
            let want = o.withDefaultOrtho()
            let pts = Sample.planeCorners(center: axis, width: DepthSetup.tile, height: DepthSetup.tile)
            guard let b = want.bounds(of: pts) else {
                return [Finding("D2.orthoDefault", "既定 ortho の位置", .fail("解析側で投影できない"))]
            }
            let sil = c.silhouette(in: Rect(x: 0, y: 0, w: width, h: height))
            let measured = sil.map { "実測中心=(\(f1($0.cx)), \(f1($0.cy))) 幅=\(f1($0.w))px" }
                ?? "画面内に写らなかった"
            return [
                Finding("D2.orthoDefault", "ortho() 省略時に被写体が来る位置",
                        .look("画面中央（\(f0(axis.x)), \(f0(axis.y))）に置いた板 / "
                              + "解析上の中心=(\(f1(b.cx)), \(f1(b.cy))) / \(measured) / "
                              + "省略時の範囲は原点を挟む対称範囲 "
                              + "[-\(f0(width / 2)), \(f0(width / 2))]×[-\(f0(height / 2)), \(f0(height / 2))]。"
                              + "**ワールドではなくビュー空間**に当たるが、既定カメラのビュー空間は"
                              + "原点が画面中心なので噛み合う（metaphor#777 は旧既定 "
                              + "[0, \(f0(width))]×[\(f0(height)), 0] が噛み合わず隅へ寄っていたもので、"
                              + "v0.10.0 で解決）")),
                // 測る先は **レンダリングの実測** であって、解析モデル `withDefaultOrtho()` ではない。
                // 報告時（metaphor#777）はその解析モデルが旧既定の複製として正しかったが、
                // いまは実測が画面中央に来る。解析モデルと比べ続けると
                // 「ライブラリではなくこちらの複製」を測ることになるので、予測は参考値として残し、
                // 合否は実測の中心が画面中央から離れていないかで決める。
                Finding("D2b.orthoDefaultOffCenter", "被写体が画面中心から離れる量", {
                    guard let s = sil else { return Verdict.fail("画面内に写らなかった（実測できない）") }
                    let dx = s.cx - axis.x
                    let dy = s.cy - axis.y
                    let analytic = "解析モデルの予測=(\(f1(b.cx - axis.x)), \(f1(b.cy - axis.y))) px"
                    return abs(dx) > 100 || abs(dy) > 100
                        ? .fail("実測中心が画面中央から (\(f1(dx)), \(f1(dy))) px ずれる / \(analytic)")
                        : .pass("実測中心のずれ=(\(f1(dx)), \(f1(dy))) px / \(analytic)")
                }()),
            ]

        case 2:
            let r = DepthSetup.fixedOrtho(width: width, height: height)
            let want = o.withOrtho(left: r.left, right: r.right, bottom: r.bottom, top: r.top,
                                   near: r.near, far: r.far)
            var widths: [(label: String, value: Float)] = []
            var out: [Finding] = []
            for (k, z) in DepthSetup.depths.enumerated() {
                let centerWorld = SIMD3(axis.x + Float(k - 2) * 300 + 150, axis.y, z)
                let pts = Sample.planeCorners(center: centerWorld,
                                              width: DepthSetup.tile, height: DepthSetup.tile)
                guard let b = want.bounds(of: pts) else { continue }
                let cell = Rect.around(b.cx, b.cy, b.w / 2 + 40, b.h / 2 + 40)
                guard let sil = c.silhouette(in: cell) else {
                    out.append(Finding("D3\(k).orthoFixed", "正射影・深さ \(f0(z))", .fail("写らなかった")))
                    continue
                }
                widths.append((label: "z\(f0(z))", value: sil.w))
                out.append(Finding("D3\(k).orthoFixed\(f0(z))", "正射影・深さ \(f0(z)) の板の幅",
                                   expect(sil.w, DepthSetup.tile, tol: 2.5,
                                          what: "正射影なので深さに依らず指定寸法のはず")))
            }
            if widths.count >= 2 {
                let spread = (widths.map { $0.value }.max() ?? 0) - (widths.map { $0.value }.min() ?? 0)
                out.append(Finding("D3e.orthoNoForeshorten", "正射影で奥行きが効かないか",
                                   expect(spread, 0, tol: 2.5, what: "深さを変えたときの幅の振れ幅")))
            }
            return out

        case 3:
            let world = SIMD3(axis.x + DepthSetup.probePoint.x,
                              axis.y + DepthSetup.probePoint.y,
                              DepthSetup.probePoint.z)
            let api = SIMD2(screenX(world.x, world.y, world.z), screenY(world.x, world.y, world.z))
            let mine = o.project(world).screen
            let cell = Rect.around(mine.x, mine.y, 140, 140)
            var out: [Finding] = [
                Finding("D4.screenXY", "screenX/Y と自前の投影",
                        expect(length(api - mine), 0, tol: 0.6,
                               what: "API=(\(f2(api.x)), \(f2(api.y))) 自前=(\(f2(mine.x)), \(f2(mine.y))) の距離")),
            ]
            if let sil = c.silhouette(in: cell) {
                out.append(Finding("D4b.screenXYPixels", "screenX/Y と焼き上がりの中心",
                                   expect(length(SIMD2(sil.cx, sil.cy) - api), 0, tol: 2.5,
                                          what: "実測中心=(\(f1(sil.cx)), \(f1(sil.cy))) と API の距離")))
            } else {
                out.append(Finding("D4b.screenXYPixels", "screenX/Y と焼き上がりの中心",
                                   .fail("小板が写らなかった（解析位置=(\(f1(mine.x)), \(f1(mine.y)))）")))
            }
            return out

        case 4:
            let zs: [Float] = [-400, -200, 0, 200, 400]
            var samples: [(label: String, value: Float)] = []
            for z in zs {
                samples.append((label: "z\(f0(z))", value: screenZ(axis.x, axis.y, z)))
            }
            let inRange = samples.allSatisfy { $0.value >= 0 && $0.value <= 1 }
            // カメラの背後。既定カメラの eye は z = defaultZ にある。
            let behindZ = o.defaultZ + 120
            let behind = o.project(SIMD3(axis.x + 100, axis.y, behindZ))
            let apiBehindZ = screenZ(axis.x + 100, axis.y, behindZ)
            let apiBehindX = screenX(axis.x + 100, axis.y, behindZ)
            return [
                Finding("D5.screenZMonotonic", "screenZ は手前ほど小さいか",
                        expectMonotonic(samples, increasing: false, slack: 0, what: "screenZ")),
                Finding("D5b.screenZRange", "screenZ は 0…1 か",
                        inRange ? .pass("全点が 0…1 | " + samples.map { "\($0.label)=\(f3($0.value))" }.joined(separator: " "))
                                : .fail("範囲外あり | " + samples.map { "\($0.label)=\(f3($0.value))" }.joined(separator: " "))),
                // 上流は `screenPosition` の値を変えるのではなく **`isInFront(_:_:_:)` を足す**
                // 形で解決した（metaphor#824 / PR #873）。背後の点で screenX/Y/Z が反転した値を
                // 返すこと自体は変わらないので、「背後だから無効」は述語で判別する。
                // 実測値は detail に残して、何が返ってくるかは今までどおり読めるようにする。
                Finding("D5c.screenZBehindCamera", "カメラ背後の点を判別できるか", {
                    let behindIsBehind = !isInFront(axis.x + 100, axis.y, behindZ)
                    let frontIsFront = isInFront(axis.x, axis.y, 0)
                    let measured = "背後の実測: w=\(f2(behind.w)) screenZ=\(f3(apiBehindZ)) "
                        + "screenX=\(f1(apiBehindX))（画面中心の左へ回る値のまま）"
                    return behindIsBehind && frontIsFront
                        ? .pass("isInFront: 背後=false / 手前=true → \(measured)")
                        : .fail("isInFront が判別しない（背後=\(!behindIsBehind) 手前=\(frontIsFront)）"
                                + " → \(measured)")
                }()),
            ]

        case 5:
            let cam = depthCameraOptics()
            let want = o.withCamera(eye: cam.eye, center: cam.center, up: cam.up)
            let world = SIMD3(axis.x + 120, axis.y - 60, -80)
            let pts = Sample.planeCorners(center: world, width: DepthSetup.tile, height: DepthSetup.tile)
            guard let b = want.bounds(of: pts) else {
                return [Finding("D6.camera", "自前カメラ", .fail("解析側で投影できない"))]
            }
            guard let sil = c.silhouette(in: Rect.around(b.cx, b.cy, b.w / 2 + 60, b.h / 2 + 60)) else {
                return [Finding("D6.camera", "自前カメラ",
                                .fail("板が写らなかった（解析上の中心=(\(f1(b.cx)), \(f1(b.cy)))）"))]
            }
            return [
                Finding("D6.camera", "camera() の view 行列",
                        expect(length(SIMD2(sil.cx, sil.cy) - SIMD2(b.cx, b.cy)), 0, tol: 3.0,
                               what: "実測中心=(\(f1(sil.cx)), \(f1(sil.cy))) 解析=(\(f1(b.cx)), \(f1(b.cy))) の距離")),
                Finding("D6b.cameraSize", "自前カメラでの寸法",
                        expect(sil.w, b.w, tol: 3.0, what: "横幅")),
            ]

        case 6:
            let got = c.average(around: axis.x, axis.y)
            let near = SIMD3<Float>(96, 150, 210) / 255
            let far = SIMD3<Float>(214, 86, 66) / 255
            let dNear = length(got - near), dFar = length(got - far)
            return [
                Finding("D7.depthTest", "手前を先に描いても奥に上書きされないか",
                        dNear < dFar
                            ? .pass("中心は手前の色 実測=(\(f3(got.x)), \(f3(got.y)), \(f3(got.z))) "
                                    + "手前との距離=\(f3(dNear)) 奥との距離=\(f3(dFar))")
                            : .fail("中心が奥の色になった 実測=(\(f3(got.x)), \(f3(got.y)), \(f3(got.z))) "
                                    + "手前との距離=\(f3(dNear)) 奥との距離=\(f3(dFar))")),
            ]

        default:
            let cam = depthCameraOptics()
            let want = o.withCamera(eye: cam.eye, center: cam.center, up: cam.up)
            // 自前でもカメラの右・上を組んで、API と突き合わせる。
            let zAxis = normalize(cam.eye - cam.center)
            let xAxis = normalize(cross(cam.up, zAxis))
            let yAxis = cross(zAxis, xAxis)
            let apiRight = context.canvas3D.currentCameraRight
            let apiUp = context.canvas3D.currentCameraUp
            let h = DepthSetup.billboard / 2
            let corners = [
                cam.center - xAxis * h - yAxis * h, cam.center + xAxis * h - yAxis * h,
                cam.center + xAxis * h + yAxis * h, cam.center - xAxis * h + yAxis * h,
            ]
            guard let b = want.bounds(of: corners) else {
                return [Finding("D8.billboard", "ビルボード", .fail("解析側で投影できない"))]
            }
            guard let sil = c.silhouette(in: Rect.around(b.cx, b.cy, b.w / 2 + 60, b.h / 2 + 60)) else {
                return [Finding("D8.billboard", "ビルボード", .fail("板が写らなかった"))]
            }
            return [
                Finding("D8.cameraBasis", "currentCameraRight / Up と自前の基底",
                        expect(length(apiRight - xAxis) + length(apiUp - yAxis), 0, tol: 0.002,
                               what: "right の差=\(f3(length(apiRight - xAxis))) up の差=\(f3(length(apiUp - yAxis)))",
                               unit: "")),
                Finding("D8b.billboardSquare", "ビルボードは正方形のまま写るか",
                        expect(sil.w / max(sil.h, 0.001), 1.0, tol: 0.03,
                               what: "横/縦（実測 \(f1(sil.w))×\(f1(sil.h))px）", unit: "")),
                Finding("D8c.billboardSize", "ビルボードの寸法",
                        expect(sil.w, b.w, tol: 3.0, what: "横幅")),
            ]
        }
    }
}
