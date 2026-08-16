import Foundation
import simd
import metaphor

// 場面 4「影」— 影は幾何が言う場所へ落ちるか。
//
// 日時計と同じ理屈で、平行光の向きと柱の高さが決まれば**影の先端は式で出る**:
//
//   先端 = 頂点 + 進行方向 × (床の y − 頂点の y) / 進行方向.y
//
// 焼き上がった画面から暗部の先端を拾い、この点の投影と突き合わせる。
// 「影がそれっぽく出ている」ではなく「何ピクセルずれている」で言えるようにするため。
//
// 実装を読んで分かっている前提が三つある。判定の設計はここに乗っている:
//
//   - シャドウ深度パスは**メインパスの後**に走る（`Canvas3D.performShadowPass`）。
//     つまりあるフレームが読むシャドウマップは 1 フレーム前の描画で作られたもの
//   - ライト空間は**最初のディレクショナルライト**から作られ、範囲は
//     `sceneCenter = cameraCenter` を中心とした半径 500 の直方体で固定
//   - 影は**直接光にだけ**掛かる。環境光と自己発光は遮蔽物の裏にも残る（metaphor#364）

extension Sketch0816Atelier {

    enum ShadowSetup {
        /// 床の高さ（ワールド y。+Y が下向きなので中心より大きい）。
        static let floorDrop: Float = 210
        static let floorW: Float = 760
        static let floorH: Float = 520
        static let floorZ: Float = -60
        /// 柱（グノモン）。
        static let poleX: Float = -70
        static let poleZ: Float = -20
        static let poleThickness: Float = 28
        static let poleHeight: Float = 250
        /// 光の**進む**向き。床へ向かうので y は正（+Y が下向き）。
        /// z を正にして影を手前へ倒し、柱そのものと画面上で重ならないようにしてある。
        static let travel = SIMD3<Float>(0.55, 1.0, 0.30)
        /// 床と柱の色。
        static var floorBase: SIMD3<Float> { SIMD3(198, 192, 182) / 255 }
        static var poleBase: SIMD3<Float> { SIMD3(226, 220, 208) / 255 }
        static let bias: Float = 0.004
    }

    func shadowSpecimens() -> [Specimen] {
        [
            Specimen(name: "cast", title: "影の先端 enableShadows(1024)",
                     note: "頂点 + 進行方向×(床−頂点)/進行方向.y の投影と合うか"),
            Specimen(name: "ambient", title: "影の中の環境光",
                     note: "影は直接光にだけ掛かるはず（真っ黒なら metaphor#364 の再発）"),
            Specimen(name: "off", title: "disableShadows()",
                     note: "影が消えて、明暗が影無しの状態へ戻るか"),
            Specimen(name: "bias", title: "shadowBias(0)",
                     note: "バイアス無しでシャドウアクネが出るか"),
            Specimen(name: "resLow", title: "解像度 256",
                     note: "輪郭の中間調がどれだけ広がるか"),
            Specimen(name: "resHigh", title: "解像度 2048",
                     note: "解像度を上げて輪郭が締まるか"),
            Specimen(name: "custom", title: "自前シェイプは影を落とすか",
                     note: "beginShape3D の形は深度パスに記録されるか"),
        ]
    }

    // MARK: 幾何

    var shadowFloorY: Float { axis.y + ShadowSetup.floorDrop }
    var shadowPoleApex: SIMD3<Float> {
        SIMD3(axis.x + ShadowSetup.poleX,
              shadowFloorY - ShadowSetup.poleHeight,
              ShadowSetup.poleZ)
    }
    var shadowPoleFoot: SIMD3<Float> {
        SIMD3(axis.x + ShadowSetup.poleX, shadowFloorY, ShadowSetup.poleZ)
    }
    /// 解析で出した影の先端（ワールド）。柱の**天面の中心**が落ちる点。
    var shadowTipWorld: SIMD3<Float>? {
        shadowPoint(of: shadowPoleApex, travel: normalize(ShadowSetup.travel), planeY: shadowFloorY)
    }

    /// 天面の 4 隅が落ちる点。
    ///
    /// 柱は太さ 28 の角柱なので、**画面で見える影の先端は天面の中心ではなく、
    /// 光の向きにいちばん遠い隅**が作る。中心で測ると柱の半分ぶん（16px ほど）短く出る。
    var shadowTipCorners: [SIMD3<Float>] {
        let h = ShadowSetup.poleThickness / 2
        let t = normalize(ShadowSetup.travel)
        let apex = shadowPoleApex
        return [SIMD2<Float>(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)].compactMap {
            shadowPoint(of: SIMD3(apex.x + $0.x, apex.y, apex.z + $0.y),
                        travel: t, planeY: shadowFloorY)
        }
    }

    /// 影を探す領域。**床の内側だけ**を見る。
    ///
    /// ここを雑に取ると三つのものを影と取り違える:
    ///
    /// - 画室の暗がり（床の外）。いちばん暗いので、放っておくと画面の隅が「先端」になる
    /// - 床の縁のアンチエイリアス。背景と床の中間色なので暗部の閾値に引っかかる
    /// - 柱そのもの。光が当たらない面は影と同じ明るさ（環境光だけ）になる
    ///
    /// なので床の四隅を投影して**内接する矩形**を取り、そこから 14px 内側へ寄せ、
    /// さらに足元より右（影が伸びる側）へ切る。画面下の見出しも外す。
    private func shadowSearchRegion() -> Rect {
        let o = standardOptics
        let hw = ShadowSetup.floorW / 2, hh = ShadowSetup.floorH / 2
        let corners = [
            SIMD3<Float>(axis.x - hw, shadowFloorY, ShadowSetup.floorZ - hh),
            SIMD3<Float>(axis.x + hw, shadowFloorY, ShadowSetup.floorZ - hh),
            SIMD3<Float>(axis.x - hw, shadowFloorY, ShadowSetup.floorZ + hh),
            SIMD3<Float>(axis.x + hw, shadowFloorY, ShadowSetup.floorZ + hh),
        ].map { o.project($0).screen }
        let inset: Float = 14
        let left = max(corners[0].x, corners[2].x) + inset
        let right = min(corners[1].x, corners[3].x) - inset
        let top = max(corners[0].y, corners[1].y) + inset
        let bottom = min(corners[2].y, corners[3].y) - inset

        let foot = o.project(shadowPoleFoot).screen
        let x = max(left, foot.x + 26)          // 柱そのものを外へ置く
        let y = top
        return Rect(x: x, y: y, w: max(right - x, 0),
                    h: max(min(bottom, height - 90) - y, 0))
    }

    /// 画室の暗がりの明るさ。これより暗い画素は「何も描かれていない」ので数に入れない。
    var groundLuma: Float { luma(Palette.ground / 255) }

    /// 床の明るいところ（影から離れた位置）。
    private var litProbe: SIMD3<Float> {
        SIMD3(axis.x - 260, shadowFloorY, ShadowSetup.floorZ - 120)
    }

    // MARK: 描く

    func drawShadowSpecimen(_ i: Int) {
        noStroke()
        noLights()
        ambientLight(76.5)
        let t = normalize(ShadowSetup.travel)
        directionalLight(t.x, t.y, t.z)

        switch i {
        case 2:
            disableShadows()
        case 3:
            enableShadows(resolution: 1024)
            shadowBias(0)
        case 4:
            enableShadows(resolution: 256)
            shadowBias(ShadowSetup.bias)
        case 5:
            enableShadows(resolution: 2048)
            shadowBias(ShadowSetup.bias)
        default:
            enableShadows(resolution: 1024)
            shadowBias(ShadowSetup.bias)
        }

        // 床。`plane` は XY 平面・法線 +Z なので、倒すと法線が -Y（画面の上向き）になる。
        push()
        translate(axis.x, shadowFloorY, ShadowSetup.floorZ)
        rotateX(Float.pi / 2)
        fillRGB(ShadowSetup.floorBase * 255)
        plane(ShadowSetup.floorW, ShadowSetup.floorH)
        pop()

        fillRGB(ShadowSetup.poleBase * 255)
        if i == 6 {
            // 柱を自前の三角形で組む（組み込みプリミティブと同じ寸法・同じ位置）。
            drawCustomPole()
        } else {
            push()
            translate(axis.x + ShadowSetup.poleX,
                      shadowFloorY - ShadowSetup.poleHeight / 2,
                      ShadowSetup.poleZ)
            box(ShadowSetup.poleThickness, ShadowSetup.poleHeight, ShadowSetup.poleThickness)
            pop()
        }
    }

    /// `beginShape3D` で組んだ角柱。組み込みの `box` と同じ寸法・同じ場所に立てる。
    private func drawCustomPole() {
        let h = ShadowSetup.poleThickness / 2
        let top = shadowFloorY - ShadowSetup.poleHeight
        let bottom = shadowFloorY
        let cx = axis.x + ShadowSetup.poleX
        let cz = ShadowSetup.poleZ
        let faces: [(n: SIMD3<Float>, a: SIMD2<Float>, b: SIMD2<Float>)] = [
            (SIMD3(0, 0, 1), SIMD2(-h, h), SIMD2(h, h)),
            (SIMD3(0, 0, -1), SIMD2(h, -h), SIMD2(-h, -h)),
            (SIMD3(1, 0, 0), SIMD2(h, h), SIMD2(h, -h)),
            (SIMD3(-1, 0, 0), SIMD2(-h, -h), SIMD2(-h, h)),
        ]
        beginShape3D(.triangles)
        for f in faces {
            normal(f.n.x, f.n.y, f.n.z)
            let p0 = SIMD3(cx + f.a.x, bottom, cz + f.a.y)
            let p1 = SIMD3(cx + f.b.x, bottom, cz + f.b.y)
            let p2 = SIMD3(cx + f.b.x, top, cz + f.b.y)
            let p3 = SIMD3(cx + f.a.x, top, cz + f.a.y)
            for p in [p0, p1, p2, p0, p2, p3] { vertex(p.x, p.y, p.z) }
        }
        endShape3D(.close)
    }

    // MARK: 測る

    func judgeShadowSpecimen(_ i: Int, _ c: Canvas, _ pass: Int) -> [Finding] {
        let o = standardOptics
        let region = shadowSearchRegion()
        let litLevel = luma(clampUnit(ShadowSetup.floorBase * (0.3 + shadowNdotL())))
        let shadowLevel = luma(ShadowSetup.floorBase * 0.3)
        let cut = (litLevel + shadowLevel) / 2

        // pass 0 は「標本を差し替えた直後」。影が 1 フレーム遅れることの確認だけに使う。
        if pass == 0 {
            guard i == 0 else { return [] }
            let n = darkCount(c, in: region, below: cut)
            scratch["shadow.early"] = Float(n)
            return []
        }

        switch i {
        case 0:
            guard let centerTip = shadowTipWorld else {
                return [Finding("S1.castTip", "影の先端", .fail("光が床へ向かっていない（進行方向の y が 0 以下）"))]
            }
            let foot = o.project(shadowPoleFoot).screen
            let dir = normalize(o.project(centerTip).screen - foot)
            // 見える先端は天面のいちばん遠い隅が作る。
            let corners = shadowTipCorners.map { o.project($0).screen }
            let tip = corners.max(by: { dot($0, dir) < dot($1, dir) }) ?? o.project(centerTip).screen
            guard let measured = c.darkestExtreme(in: region, darkerThan: cut,
                                                  brighterThan: groundLuma + 0.03, along: dir) else {
                return [Finding("S1.castTip", "影の先端",
                                .fail("暗部が 1 画素も無い（影が落ちていない）"
                                      + " / 解析上の先端=(\(f1(tip.x)), \(f1(tip.y)))"))]
            }
            let late = Float(darkCount(c, in: region, below: cut))
            var out = [
                Finding("S1.castTip", "影の先端の位置",
                        expect(length(measured - tip), 0, tol: 8,
                               what: "実測=(\(f1(measured.x)), \(f1(measured.y))) 解析=(\(f1(tip.x)), \(f1(tip.y))) の距離"
                                     + "（天面の隅が作る先端。中心が落ちる点は"
                                     + "(\(f1(o.project(centerTip).screen.x)), \(f1(o.project(centerTip).screen.y)))）")),
                Finding("S1b.castLength", "影の長さ",
                        expect(length(measured - foot), length(tip - foot), tol: 8,
                               what: "足元から先端まで")),
            ]
            if let early = scratch["shadow.early"] {
                out.append(Finding("S1c.shadowLag", "標本を差し替えた直後の影",
                                   .look("差し替え直後の暗部=\(f0(early))px / \(Timing.settledPass) フレーム後=\(f0(late))px"
                                         + " → シャドウ深度パスはメインパスの後に走るので、"
                                         + "形を変えた最初のフレームは 1 つ前の形の影を映す")))
            }
            return out

        case 1:
            guard let tipWorld = shadowTipWorld else { return [] }
            // 影の内側（足元と先端の中間）と、影から離れた明るいところを比べる。
            let mid = (shadowPoleFoot + tipWorld) / 2
            let midScreen = o.project(mid).screen
            let inShadow = c.average(around: midScreen.x, midScreen.y, radius: 4)
            let litScreen = o.project(litProbe).screen
            let inLight = c.average(around: litScreen.x, litScreen.y, radius: 4)
            let wantShadow = ShadowSetup.floorBase * 0.3
            let wantLit = clampUnit(ShadowSetup.floorBase * (0.3 + shadowNdotL()))
            return [
                Finding("S2.ambientInShadow", "影の中に環境光が残るか",
                        expectColor(inShadow, wantShadow, tol: 0.05,
                                    what: "影の内側（環境光 0.3 × 床の色。真っ黒なら metaphor#364 の再発）")),
                Finding("S2b.litFloor", "影の外の床",
                        expectColor(inLight, wantLit, tol: 0.05,
                                    what: "環境光 0.3 + N·L=\(f3(shadowNdotL()))")),
            ]

        case 2:
            let n = darkCount(c, in: region, below: cut)
            return [Finding("S3.disable", "disableShadows() で影が消えるか",
                            n < 200
                                ? .pass("暗部=\(n)px（影は消えている）")
                                : .fail("暗部=\(n)px 残っている"))]

        case 3:
            // 影から離れた明るい床に、まだらな暗点（アクネ）が出ていないか。
            let litScreen = o.project(litProbe).screen
            let patch = Rect.around(litScreen.x, litScreen.y, 90, 40)
            let acne = darkCount(c, in: patch, below: cut)
            let total = Int(patch.w * patch.h)
            return [Finding("S4.shadowAcne", "shadowBias(0) でアクネが出るか",
                            .look("影から離れた床 \(total)px 中 暗点=\(acne)px"
                                  + "（\(f2(Float(acne) / Float(total) * 100))%）"
                                  + " / バイアス \(f3(ShadowSetup.bias)) のときは S5 系の面で 0 に近いはず"))]

        case 4:
            let n = edgeCount(c, in: region, low: shadowLevel, high: litLevel)
            scratch["shadow.edge256"] = Float(n)
            return [Finding("S5.edge256", "解像度 256 の輪郭",
                            .look("中間調の画素=\(n)px（3x3 PCF なので解像度が低いほど広がる）"))]

        case 5:
            let n = Float(edgeCount(c, in: region, low: shadowLevel, high: litLevel))
            guard let low = scratch["shadow.edge256"] else {
                return [Finding("S5b.edgeSharpens", "解像度を上げると輪郭は締まるか",
                                .look("解像度 2048 の中間調=\(f0(n))px（256 の測定が無いので比較できず）"))]
            }
            return [Finding("S5b.edgeSharpens", "解像度を上げると輪郭は締まるか",
                            n < low
                                ? .pass("中間調 256→\(f0(low))px / 2048→\(f0(n))px で締まった")
                                : .fail("中間調 256→\(f0(low))px / 2048→\(f0(n))px で締まらなかった"))]

        default:
            let n = darkCount(c, in: region, below: cut)
            return [Finding("S6.customCasts", "beginShape3D の形は影を落とすか",
                            n > 400
                                ? .pass("暗部=\(n)px（自前の形も深度パスに載っている）")
                                : .fail("暗部=\(n)px（組み込みプリミティブと同じ寸法・同じ位置に立てても影が出ない。"
                                        + "イミディエイトのカスタムシェイプは影の深度パスに記録されていない疑い）"))]
        }
    }

    /// 床の法線 (0, -1, 0) と光の向きの内積。
    private func shadowNdotL() -> Float {
        let L = normalize(-ShadowSetup.travel)
        return max(dot(SIMD3<Float>(0, -1, 0), L), 0)
    }

    private func darkCount(_ c: Canvas, in rect: Rect, below level: Float) -> Int {
        var n = 0
        var y = Int(max(rect.y, 0))
        let yEnd = Int(min(rect.bottom, height))
        let xStart = Int(max(rect.x, 0))
        let xEnd = Int(min(rect.right, width))
        while y < yEnd {
            var x = xStart
            while x < xEnd {
                let v = luma(c.rgb(x, y) / 255)
                // 背景（画室の暗がり）は数えない。床の上だけを見る。
                if v < level && v > groundLuma + 0.03 { n += 1 }
                x += 1
            }
            y += 1
        }
        return n
    }

    private func edgeCount(_ c: Canvas, in rect: Rect, low: Float, high: Float) -> Int {
        let lo = low + (high - low) * 0.25
        let hi = low + (high - low) * 0.75
        var n = 0
        var y = Int(max(rect.y, 0))
        let yEnd = Int(min(rect.bottom, height))
        let xStart = Int(max(rect.x, 0))
        let xEnd = Int(min(rect.right, width))
        while y < yEnd {
            var x = xStart
            while x < xEnd {
                let v = luma(c.rgb(x, y) / 255)
                if v > lo && v < hi { n += 1 }
                x += 1
            }
            y += 1
        }
        return n
    }
}
