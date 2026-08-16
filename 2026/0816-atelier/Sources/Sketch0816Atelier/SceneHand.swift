import Foundation
import simd
import metaphor

// 場面 5「手」— 自分で組んだ形は組み込みと並ぶか。
//
// デッサンでいえば、目で見て手で引いた線が石膏像と合っているかを確かめる段。
// ここでは `beginShape3D` / `vertex` / `normal` で組んだ形と `mesh()` 経由の形を、
// 同じ寸法・同じ位置の組み込みプリミティブと並べて突き合わせる。
//
// イミディエイトのカスタムシェイプは**非インスタンス経路**を通る。
// v0.9.0 のこの経路のフラグメントシェーダーはシャドウを読まない（場面 4 の S6 が測る）。
// つまり「同じに見える形」でも通る道が違うので、並べる価値がある。

extension Sketch0816Atelier {

    enum HandSetup {
        static let quad: Float = 240
        static let pitch: Float = 400
        static let meshPlaneW: Float = 300
        static let meshPlaneH: Float = 180
        static let coneRadius: Float = 90
        static let coneHeight: Float = 200
        static let cylinderRadius: Float = 80
        static let cylinderHeight: Float = 200
        static let torusRing: Float = 80
        static let torusTube: Float = 24
        static let detail = 36
        /// カスタムマテリアルが塗る色（シェーダーに直書きしてある値と同じ）。
        static let flatColor = SIMD3<Float>(0.16, 0.72, 0.86)
        /// 市松テクスチャの一辺（画素）と market の目数。
        static let checkerSize = 64
        static let checkerCells = 8
        /// 頂点カラーの板の隅（左上・右上・右下・左下）と、そこへ置く色。
        static var quadCorners: [SIMD2<Float>] {
            let h = quad / 2
            return [SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)]
        }
        static let cornerColors: [SIMD3<Float>] = [
            SIMD3(0.90, 0.25, 0.20), SIMD3(0.25, 0.80, 0.35),
            SIMD3(0.20, 0.45, 0.95), SIMD3(0.95, 0.85, 0.25),
        ]

        /// applyMatrix に渡す変換。
        static let xformRotate: Float = -0.5
        static let xformScale = SIMD3<Float>(0.8, 1.6, 1)
        static let xformBox: Float = 130
    }

    /// フラグメントだけのカスタムマテリアル。
    ///
    /// **`[[stage_in]]` 以外の引数を宣言していない。** インスタンス経路と非インスタンス経路で
    /// buffer(1) の中身が違う（`InstancedSceneUniforms` と `Canvas3DUniforms`）ので、
    /// 受け取らないでおけばどちらの道でも同じシェーダーが使える。
    static let flatMaterialSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct AtelierVertexOut {
        float4 position [[position]];
        float3 worldPosition;
        float3 normal;
        float4 color;
    };

    fragment float4 atelierFlatFragment(AtelierVertexOut in [[stage_in]]) {
        return float4(0.16, 0.72, 0.86, 1.0);
    }
    """

    func handSpecimens() -> [Specimen] {
        [
            Specimen(name: "normal", title: "normal() の有無",
                     note: "法線を省くと面はどうなるか（自動計算はあるか）"),
            Specimen(name: "vertexColor", title: "頂点カラー vertex(…color:)",
                     note: "頂点ごとの色は補間されるか"),
            Specimen(name: "meshPlane", title: "createPlaneMesh + mesh()",
                     note: "値としてのメッシュと即時の plane() は同じ寸法か"),
            Specimen(name: "meshPrimitives", title: "cone / cylinder / torus のメッシュ",
                     note: "生成側と描画側で寸法の解釈がそろっているか"),
            Specimen(name: "meshCache", title: "clearMeshCache()",
                     note: "捨てたあとも描けるか。件数を読む口はあるか"),
            Specimen(name: "material", title: "createMaterial / noMaterial",
                     note: "カスタムマテリアルが当たり、解除で既定へ戻るか"),
            Specimen(name: "texture", title: "texture() を 3D シェイプへ",
                     note: "UV が生えているプリミティブに市松が貼れるか"),
            Specimen(name: "applyMatrix", title: "applyMatrix(float4x4)",
                     note: "自前の 4x4 が現在の変換に乗るか"),
        ]
    }

    private func handSlotX(_ k: Int, of n: Int) -> Float {
        axis.x + (Float(k) - Float(n - 1) / 2) * HandSetup.pitch
    }

    // MARK: 支度

    /// `setup()` から 1 回だけ呼ぶ。メッシュ・マテリアル・テクスチャはここで作る
    /// （`draw()` で毎フレーム作るとキャッシュが入れ替わり続ける）。
    func prepareHand() {
        if let m = createPlaneMesh(HandSetup.meshPlaneW, HandSetup.meshPlaneH) { handMeshes["plane"] = m }
        if let m = createConeMesh(radius: HandSetup.coneRadius, height: HandSetup.coneHeight,
                                  detail: HandSetup.detail) { handMeshes["cone"] = m }
        if let m = createCylinderMesh(radius: HandSetup.cylinderRadius, height: HandSetup.cylinderHeight,
                                      detail: HandSetup.detail) { handMeshes["cylinder"] = m }
        if let m = createTorusMesh(ringRadius: HandSetup.torusRing, tubeRadius: HandSetup.torusTube,
                                   detail: HandSetup.detail) { handMeshes["torus"] = m }
        emit("メッシュを \(handMeshes.count) 個生成（plane / cone / cylinder / torus）")

        do {
            flatMaterial = try createMaterial(source: Self.flatMaterialSource,
                                              fragmentFunction: "atelierFlatFragment")
        } catch {
            emit("[!] createMaterial が失敗: \(error)")
        }

        checkerImage = makeChecker()
    }

    /// 手続きで作る市松。アセットを持ち込まずにテクスチャ経路を通すため。
    private func makeChecker() -> MImage? {
        let n = HandSetup.checkerSize
        guard let img = MImage.createImage(n, n, device: context.renderer.device) else { return nil }
        let cell = n / HandSetup.checkerCells
        img.loadPixels()
        for y in 0..<n {
            for x in 0..<n {
                let on = ((x / cell) + (y / cell)) % 2 == 0
                img.set(x, y, on ? Color(r: 0.95, g: 0.93, b: 0.88) : Color(r: 0.12, g: 0.16, b: 0.24))
            }
        }
        img.updatePixels()
        return img
    }

    // MARK: 描く

    func drawHandSpecimen(_ i: Int) {
        noStroke()
        fillRGB(Palette.specimen)

        switch i {
        case 0:
            noLights()
            ambientLight(76.5)
            directionalLight(0, 0, -1)          // L = (0,0,1)。正対する面なら N·L = 1
            // 法線を**まだ一度も指定していない状態**で先に描く（順番が効く検査なので）。
            customQuad(at: handSlotX(0, of: 3), withNormal: false)
            customQuad(at: handSlotX(1, of: 3), withNormal: true)
            // 直前に normal() を呼んだあとで、また省いて描く（持ち越しが無いかを見る）。
            customQuad(at: handSlotX(2, of: 3), withNormal: false)

        case 1:
            noLights()                          // ライト 0 本 = 頂点カラーがそのまま出る
            // 左は fill を白にしてから、右は fill を標本色にしてから、同じ頂点カラーで組む。
            // 頂点カラーが fill と掛け合わされるなら、右だけが濁る。
            fill(255)
            vertexColorQuad(at: handSlotX(0, of: 2))
            fillRGB(Palette.specimen)
            vertexColorQuad(at: handSlotX(1, of: 2))

        case 2:
            noLights()
            if let m = handMeshes["plane"] {
                push(); translate(handSlotX(0, of: 2), axis.y, 0); mesh(m); pop()
            }
            push(); translate(handSlotX(1, of: 2), axis.y, 0)
            plane(HandSetup.meshPlaneW, HandSetup.meshPlaneH); pop()

        case 3:
            noLights()
            let pairs: [(String, () -> Void)] = [
                ("cone", { self.cone(radius: HandSetup.coneRadius, height: HandSetup.coneHeight,
                                     detail: HandSetup.detail) }),
                ("cylinder", { self.cylinder(radius: HandSetup.cylinderRadius,
                                             height: HandSetup.cylinderHeight,
                                             detail: HandSetup.detail) }),
                ("torus", { self.torus(ringRadius: HandSetup.torusRing, tubeRadius: HandSetup.torusTube,
                                       detail: HandSetup.detail) }),
            ]
            for (k, pair) in pairs.enumerated() {
                let x = handSlotX(k, of: 3)
                if let m = handMeshes[pair.0] {
                    push(); translate(x, axis.y - 130, 0); mesh(m); pop()
                }
                push(); translate(x, axis.y + 130, 0); pair.1(); pop()
            }

        case 4:
            noLights()
            // 捨てた直後に描けるかを見る。`clearMeshCache()` は Canvas3D 側にしか無い
            // （Sketch から生えていないので context 越しに呼ぶ）。
            context.canvas3D.clearMeshCache()
            push(); translate(handSlotX(0, of: 2), axis.y, 0)
            sphere(110, detail: 32); pop()
            if let m = handMeshes["plane"] {
                push(); translate(handSlotX(1, of: 2), axis.y, 0); mesh(m); pop()
            }

        case 5:
            noLights()
            ambientLight(76.5)
            directionalLight(0, 0, -1)
            if let mat = flatMaterial {
                // 左: 組み込みプリミティブ（**インスタンス経路**）へ当てる
                material(mat)
                push(); translate(handSlotX(0, of: 3), axis.y, 0)
                plane(HandSetup.quad, HandSetup.quad); pop()
                // 中: 自前のシェイプ（**非インスタンス経路**）へ当てる
                customQuad(at: handSlotX(1, of: 3), withNormal: true)
                noMaterial()
            }
            // 右: 解除後。既定シェーディングへ戻っているか
            push(); translate(handSlotX(2, of: 3), axis.y, 0)
            plane(HandSetup.quad, HandSetup.quad); pop()

        case 6:
            noLights()
            if let img = checkerImage {
                texture(img)
                push(); translate(axis.x, axis.y, 0)
                plane(HandSetup.quad * 1.4, HandSetup.quad * 1.4); pop()
                noTexture()
            }

        default:
            noLights()
            push()
            let t = float4x4(translation: SIMD3(axis.x, axis.y, 0))
            let r = float4x4(rotationZ: HandSetup.xformRotate)
            let s = float4x4(scale: HandSetup.xformScale)
            let rs = r * s
            let m = t * rs
            applyMatrix(m)
            box(HandSetup.xformBox)
            pop()
        }
    }

    /// 4 隅に別々の色を置いた板。
    private func vertexColorQuad(at x: Float) {
        let h = HandSetup.quad / 2
        beginShape3D(.triangles)
        for k in [0, 1, 2, 0, 2, 3] {
            let p = HandSetup.quadCorners[k]
            let col = HandSetup.cornerColors[k]
            vertex(x + p.x, axis.y + p.y, 0, Color(r: col.x, g: col.y, b: col.z))
        }
        endShape3D(.close)
    }

    /// 三角形 2 枚の板。`withNormal` が false のときは `normal()` を呼ばない。
    private func customQuad(at x: Float, withNormal: Bool) {
        let h = HandSetup.quad / 2
        beginShape3D(.triangles)
        if withNormal { normal(0, 0, 1) }
        let pts: [SIMD2<Float>] = [SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)]
        for k in [0, 1, 2, 0, 2, 3] {
            vertex(x + pts[k].x, axis.y + pts[k].y, 0)
        }
        endShape3D(.close)
    }

    // MARK: 測る

    func judgeHandSpecimen(_ i: Int, _ c: Canvas) -> [Finding] {
        let o = standardOptics
        let base = Palette.specimen / 255

        switch i {
        case 0:
            let without = c.average(around: handSlotX(0, of: 3), axis.y)
            let withN = c.average(around: handSlotX(1, of: 3), axis.y)
            let afterN = c.average(around: handSlotX(2, of: 3), axis.y)
            let want = base * (0.3 + 1.0)               // fill が 1 回だけ乗るとき
            let squared = base * base * (0.3 + 1.0)     // fill が 2 回乗るとき
            return [
                Finding("H1.normalGiven", "normal() を与えた面",
                        expectColor(withN, want, tol: 0.025,
                                    what: "N=(0,0,1), L=(0,0,1) なので ambient+N·L=1.3 × fill")),
                Finding("H1b.fillSquared", "イミディエイトの 3D で fill が何回乗るか",
                        length(withN - clampUnit(squared)) < length(withN - clampUnit(want))
                            ? .fail("実測=(\(f3(withN.x)), \(f3(withN.y)), \(f3(withN.z))) は"
                                    + " fill を 2 回掛けた値 (\(f3(squared.x)), \(f3(squared.y)), \(f3(squared.z)))"
                                    + " のほうに近い（1 回なら (\(f3(want.x)), \(f3(want.y)), \(f3(want.z))）。"
                                    + "`beginShape3D` は記録時に頂点カラーへ fill を焼き込み、"
                                    + "シェーダーでもう一度 `uniforms.color` を掛けている")
                            : .pass("fill は 1 回だけ乗っている 実測=(\(f3(withN.x)), \(f3(withN.y)), \(f3(withN.z)))")),
                Finding("H1c.normalOmitted", "normal() を省いた面",
                        length(without - withN) < 0.02
                            ? .pass("省いた側=(\(f3(without.x)), \(f3(without.y)), \(f3(without.z)))"
                                    + " は与えた側と一致。`endShape3D` が三角形ごとに面法線を"
                                    + "自動計算している（リテインドの `MShape` にはこれが無く、"
                                    + "面が真っ黒になる = metaphor#738）")
                            : .fail("省いた側=(\(f3(without.x)), \(f3(without.y)), \(f3(without.z)))"
                                    + " / 与えた側=(\(f3(withN.x)), \(f3(withN.y)), \(f3(withN.z)))"
                                    + " → 自動計算が効いていない")),
                Finding("H1d.normalNotSticky", "normal() が次のシェイプへ持ち越されないか",
                        length(afterN - without) < 0.02
                            ? .pass("normal() のあとで省いて描いても自動計算のまま"
                                    + "（実測=(\(f3(afterN.x)), \(f3(afterN.y)), \(f3(afterN.z)))）")
                            : .fail("直前の normal() が残っている 実測=(\(f3(afterN.x)), \(f3(afterN.y)), \(f3(afterN.z)))"
                                    + " / 省いた側=(\(f3(without.x)), \(f3(without.y)), \(f3(without.z)))")),
            ]

        case 1:
            let inset = HandSetup.quad / 2 - 16
            let whiteX = handSlotX(0, of: 2)
            let tintedX = handSlotX(1, of: 2)
            let colors = HandSetup.cornerColors
            let tl = c.average(around: whiteX - inset, axis.y - inset, radius: 2)
            let br = c.average(around: whiteX + inset, axis.y + inset, radius: 2)
            let mid = c.average(around: whiteX, axis.y, radius: 2)
            // 三角形は [0,1,2] と [0,2,3] に割れるので、板の中心はちょうど
            // 対角（隅 0 と隅 2）の上に乗る。**4 隅の平均ではない。**
            let avg = (colors[0] + colors[2]) / 2
            let tintedTL = c.average(around: tintedX - inset, axis.y - inset, radius: 2)
            return [
                Finding("H2.vertexColorCorners", "頂点カラーが隅に出るか（fill = 白）",
                        (length(tl - colors[0]) < 0.10 && length(br - colors[2]) < 0.10)
                            ? .pass("左上=(\(f3(tl.x)), \(f3(tl.y)), \(f3(tl.z))) 右下=(\(f3(br.x)), \(f3(br.y)), \(f3(br.z)))")
                            : .fail("左上=(\(f3(tl.x)), \(f3(tl.y)), \(f3(tl.z))) 期待≈(\(f3(colors[0].x)), \(f3(colors[0].y)), \(f3(colors[0].z)))"
                                    + " / 右下=(\(f3(br.x)), \(f3(br.y)), \(f3(br.z))) 期待≈(\(f3(colors[2].x)), \(f3(colors[2].y)), \(f3(colors[2].z)))")),
                Finding("H2b.vertexColorBlend", "中心は 4 隅の混色か",
                        expectColor(mid, avg, tol: 0.10, what: "中心（fill = 白。対角 0–2 の中点）")),
                Finding("H2c.vertexColorTimesFill", "頂点カラーに fill が掛かるか",
                        length(tintedTL - colors[0] * base) < length(tintedTL - colors[0])
                            ? .fail("fill を標本色にすると左上=(\(f3(tintedTL.x)), \(f3(tintedTL.y)), \(f3(tintedTL.z))) となり、"
                                    + "頂点カラー×fill=(\(f3(colors[0].x * base.x)), \(f3(colors[0].y * base.y)), \(f3(colors[0].z * base.z)))"
                                    + " に近い。**頂点カラーだけを塗る手立てが無い**"
                                    + "（fill を白にしておかないと濁る）")
                            : .pass("fill を変えても頂点カラーはそのまま 実測=(\(f3(tintedTL.x)), \(f3(tintedTL.y)), \(f3(tintedTL.z)))")),
            ]

        case 2:
            let cellL = Rect.around(handSlotX(0, of: 2), axis.y, 175, 130)
            let cellR = Rect.around(handSlotX(1, of: 2), axis.y, 175, 130)
            guard let l = c.silhouette(in: cellL) else {
                return [Finding("H3.meshPlane", "createPlaneMesh + mesh()", .fail("メッシュが写らなかった"))]
            }
            guard let r = c.silhouette(in: cellR) else {
                return [Finding("H3.meshPlane", "即時の plane()", .fail("板が写らなかった"))]
            }
            return [
                Finding("H3.meshPlane", "createPlaneMesh の寸法",
                        expect(l.w, HandSetup.meshPlaneW, tol: 2.5, what: "横幅")),
                Finding("H3b.meshMatchesImmediate", "メッシュと即時描画の一致",
                        expect(l.w - r.w, 0, tol: 1.5, what: "横幅の差（mesh() − plane()）")),
                Finding("H3c.meshPlaneHeight", "createPlaneMesh の高さ",
                        expect(l.h, HandSetup.meshPlaneH, tol: 2.5, what: "縦幅")),
            ]

        case 3:
            var out: [Finding] = []
            let names = ["cone", "cylinder", "torus"]
            for (k, name) in names.enumerated() {
                let x = handSlotX(k, of: 3)
                let top = Rect.around(x, axis.y - 130, 190, 125)
                let bottom = Rect.around(x, axis.y + 130, 190, 125)
                guard let a = c.silhouette(in: top), let b = c.silhouette(in: bottom) else {
                    out.append(Finding("H4\(k).\(name)Mesh", "\(name) のメッシュと即時描画",
                                       .fail("どちらかが写らなかった")))
                    continue
                }
                out.append(Finding("H4\(k).\(name)Mesh", "\(name) のメッシュと即時描画の寸法差",
                                   expect(a.w - b.w, 0, tol: 3.0,
                                          what: "横幅の差（mesh=\(f1(a.w)) 即時=\(f1(b.w))）")))
            }
            return out

        case 4:
            let cellL = Rect.around(handSlotX(0, of: 2), axis.y, 175, 160)
            let cellR = Rect.around(handSlotX(1, of: 2), axis.y, 175, 130)
            let drewSphere = c.silhouette(in: cellL) != nil
            let drewMesh = c.silhouette(in: cellR) != nil
            return [
                Finding("H5.clearMeshCache", "clearMeshCache() の直後に描けるか",
                        (drewSphere && drewMesh)
                            ? .pass("捨てた直後の球もメッシュも描けた（単位メッシュは作り直される）")
                            : .fail("球=\(drewSphere ? "出た" : "出ない") / メッシュ=\(drewMesh ? "出た" : "出ない")")),
                Finding("H5b.meshCountAccessor", "キャッシュの件数を読む口",
                        .look("`meshCount` は `AssetCache`（loadImage / loadModel 用）のもので、"
                              + "`Canvas3D` のメッシュキャッシュは件数を読む公開の口が無い。"
                              + "実測=assetCache.meshCount=\(context.assetCache.meshCount)"
                              + "（プリミティブを何個キャッシュしていても動かない）")),
            ]

        case 5:
            let onPrimitive = c.average(around: handSlotX(0, of: 3), axis.y)
            let onCustomShape = c.average(around: handSlotX(1, of: 3), axis.y)
            let plain = c.average(around: handSlotX(2, of: 3), axis.y)
            let want = base * (0.3 + 1.0)
            let ground = Palette.ground / 255
            guard flatMaterial != nil else {
                return [Finding("H6.customMaterialInstanced", "カスタムマテリアル",
                                .fail("createMaterial が失敗していて当てられない"))]
            }
            return [
                Finding("H6.customMaterialInstanced", "組み込みプリミティブへ当てたとき",
                        length(onPrimitive - ground) < 0.02
                            ? .fail("何も描かれない（実測は背景色 "
                                    + "(\(f3(onPrimitive.x)), \(f3(onPrimitive.y)), \(f3(onPrimitive.z)))）。"
                                    + "フラグメントだけのカスタムマテリアルはインスタンス経路に残るが、"
                                    + "そのパイプラインは**非インスタンスの頂点シェーダー**で組まれる。"
                                    + "buffer(1) が InstancedSceneUniforms と Canvas3DUniforms で別物なので"
                                    + "頂点が画面外へ飛ぶ = metaphor#717。**main では修正済み・v0.9.0 には未リリース**")
                            : expectColor(onPrimitive, HandSetup.flatColor, tol: 0.02,
                                          what: "シェーダーに直書きした色")),
                Finding("H6b.customMaterialImmediate", "自前シェイプへ当てたとき",
                        length(onCustomShape - HandSetup.flatColor) < 0.05
                            ? .pass("当たった 実測=(\(f3(onCustomShape.x)), \(f3(onCustomShape.y)), \(f3(onCustomShape.z)))")
                            : .fail("当たらない 実測=(\(f3(onCustomShape.x)), \(f3(onCustomShape.y)), \(f3(onCustomShape.z)))"
                                    + " 期待=(\(f3(HandSetup.flatColor.x)), \(f3(HandSetup.flatColor.y)), \(f3(HandSetup.flatColor.z)))。"
                                    + "`beginShape3D` の描画（`drawShape3DVertices`）は組み込みの"
                                    + "パイプラインを直に張っていて `currentCustomMaterial` を見ない。"
                                    + "doc は「以降の 3D 描画に適用します」と書いているが、"
                                    + "**効くのはメッシュ／プリミティブの経路だけ**（main でも同じ）")),
                Finding("H6c.noMaterial", "noMaterial() で既定へ戻るか",
                        expectColor(plain, want, tol: 0.03, what: "解除後の板（ambient+N·L）")),
            ]

        case 6:
            guard checkerImage != nil else {
                return [Finding("H7.texture", "3D シェイプへのテクスチャ", .fail("市松を作れなかった"))]
            }
            let cell = Rect.around(axis.x, axis.y, HandSetup.quad * 0.6, HandSetup.quad * 0.6)
            let bright = c.brighterCount(in: cell, than: 0.6)
            let total = Int(cell.w * cell.h)
            let ratio = Float(bright) / Float(max(total, 1))
            return [
                Finding("H7.texture", "3D シェイプへのテクスチャ",
                        expect(ratio, 0.5, tol: 0.12,
                               what: "市松の明部の割合（\(bright)/\(total)）", unit: "")),
            ]

        default:
            let t = float4x4(translation: SIMD3(axis.x, axis.y, 0))
            let r = float4x4(rotationZ: HandSetup.xformRotate)
            let s = float4x4(scale: HandSetup.xformScale)
            let rs = r * s
            let m = t * rs
            let local = Sample.boxCorners(center: .zero, size: SIMD3(repeating: HandSetup.xformBox))
            let world = local.map { p -> SIMD3<Float> in
                let v = m * SIMD4<Float>(p.x, p.y, p.z, 1)
                return SIMD3(v.x, v.y, v.z)
            }
            guard let b = o.bounds(of: world) else {
                return [Finding("H8.applyMatrix", "applyMatrix", .fail("解析側で投影できない"))]
            }
            guard let sil = c.silhouette(in: Rect(x: 0, y: 0, w: width, h: height)) else {
                return [Finding("H8.applyMatrix", "applyMatrix", .fail("箱が写らなかった"))]
            }
            return [
                Finding("H8.applyMatrix", "applyMatrix(float4x4) の横幅",
                        expect(sil.w, b.w, tol: 3.0, what: "自前の 4x4 を乗せた箱")),
                Finding("H8b.applyMatrixHeight", "applyMatrix の縦幅",
                        expect(sil.h, b.h, tol: 3.0, what: "縦幅")),
                Finding("H8c.applyMatrixCenter", "applyMatrix の中心",
                        expect(sil.cx, b.cx, tol: 2.5, what: "中心 x")),
            ]
        }
    }
}
