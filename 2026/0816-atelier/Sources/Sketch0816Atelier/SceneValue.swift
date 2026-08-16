import Foundation
import simd
import metaphor

// 場面 2「明暗」— 陰影は手計算と合うか。
//
// 明暗を測るには**法線が分かっている点**が要る。そこで標本には板（`plane`）を使う。
// `plane` は XY 平面・法線 +Z で生えるので、既定カメラの視軸に正対させれば
// N = (0,0,1)、V = (0,0,1) がその場で確定する。あとは Blinn-Phong を手で解くだけ。
//
//   出力 = ambient·base + emissive + Σ (base·N·L + spec·(N·H)^shininess)·lightColor·強度·減衰
//
// キャンバスは `bgra8Unorm`（sRGB 変換なし）なので、この値はそのまま 0…255 に載る。
// ガンマを噛ませずに突き合わせてよい。
//
// 押さえておく癖が三つ:
//   - ライトが 0 本ならシェーダーは即 `in.color` を返す（ambient も emissive も効かない）
//   - 平行光の引数は「光の**進む**向き」。シェーダー側で L = normalize(-direction)
//   - 最初のライトを足したとき ambient 0.3 が自動で入る

extension Sketch0816Atelier {

    enum ValueSetup {
        /// 標本の板。正対させるので投影は素直（z=0 → 1 単位 = 1 画素）。
        static let plateW: Float = 250
        static let plateH: Float = 250
        /// 3 枚並べるときの間隔。
        static let pitch: Float = 350
        /// 標本色。3 成分の値が違うので、チャンネルの取り違えに気付ける。
        static var base: SIMD3<Float> { Palette.specimen / 255 }
        /// 点光源・スポットを置く距離。
        static let lightZ: Float = 400
        /// スポットの半頂角。
        static let spotAngle: Float = Float.pi / 6
        /// 傾けた板の角度（真上向きにすると真横から見ることになり写らない）。
        static let tilt: Float = 1.22
        /// 鏡面の検査に使う球。
        static let specSphereR: Float = 120
        /// `specular(_ gray:)` / `emissive(_ gray:)` に渡す値。
        ///
        /// **0…1 で渡す。** この 2 つは `colorMode` を通らない（実装が値をそのまま
        /// マテリアルへ入れる）ので、`fill` と同じ 0–255 のつもりで渡すと桁が 255 倍ずれる。
        static let specularGray: Float = 0.6
        static let emissiveGray: Float = 0.4
        /// 上と同じ明るさを「0–255 の目盛りのつもり」で書いた値。
        static let emissiveGray255: Float = 0.4 * 255
    }

    func valueSpecimens() -> [Specimen] {
        [
            Specimen(name: "noLights", title: "ライト無し noLights()",
                     note: "ライトが 0 本ならシェーダーは fill 色をそのまま返す"),
            Specimen(name: "ambient", title: "環境光 ambientLight(76.5)",
                     note: "単独で効くのか、ライトと組んで初めて効くのか"),
            Specimen(name: "directional", title: "平行光 directionalLight",
                     note: "引数は光の進む向きか、光源のある向きか"),
            Specimen(name: "defaultLights", title: "既定 lights()",
                     note: "上を向いた面と下を向いた面、どちらが明るいか"),
            Specimen(name: "point", title: "点光源 pointLight（falloff 3 種）",
                     note: "減衰は 1/(1+f·d+0.1·f·d²)。既定 f=0.1 はピクセル空間で届くか"),
            Specimen(name: "spot", title: "スポット spotLight(angle: π/6)",
                     note: "照らされる円の半径は距離×tan(angle) になるか"),
            Specimen(name: "specular", title: "鏡面 specular・shininess",
                     note: "shininess を上げるとハイライトは締まるか"),
            Specimen(name: "emissive", title: "自己発光 emissive",
                     note: "ライト無しでも光るか。ライトと組んだときに加算されるか"),
            Specimen(name: "ao", title: "遮蔽 ambientOcclusion",
                     note: "Blinn-Phong 経路と PBR 経路のどちらで効くか"),
            Specimen(name: "grayScale", title: "gray 版の目盛り",
                     note: "fill・ambientLight は 0–255。emissive・specular も同じ目盛りか"),
        ]
    }

    // MARK: 板を置く

    /// 標本の板。`tilt` は x 軸まわりの傾き（法線が (0, -sin, cos) になる）。
    private func plate(_ x: Float, tilt: Float = 0,
                       w: Float = ValueSetup.plateW, h: Float = ValueSetup.plateH) {
        push()
        translate(x, axis.y, 0)
        if tilt != 0 { rotateX(tilt) }
        plane(w, h)
        pop()
    }

    /// 板の並びの k 番目（n 枚）の中心 x。
    private func slotX(_ k: Int, of n: Int) -> Float {
        axis.x + (Float(k) - Float(n - 1) / 2) * ValueSetup.pitch
    }

    // MARK: 描く

    func drawValueSpecimen(_ i: Int) {
        noStroke()
        fillRGB(Palette.specimen)

        switch i {
        case 0:
            noLights()
            plate(axis.x)

        case 1:
            // 左: 環境光だけ。右: 環境光 + 平行光。
            noLights()
            ambientLight(76.5)
            plate(slotX(0, of: 2))
            directionalLight(0, 0, -1)      // カメラ側から板へ進む光 → L = (0,0,1)
            plate(slotX(1, of: 2))

        case 2:
            // 正面・斜め・裏から。1 枚ずつライトを組み直す。
            let angles: [Float] = [0, Float.pi / 3, Float.pi * 0.75]
            for (k, a) in angles.enumerated() {
                noLights()
                // L = (sin a, 0, cos a) にしたいので、進む向きはその逆。
                directionalLight(-sin(a), 0, -cos(a))
                plate(slotX(k, of: angles.count))
            }

        case 3:
            noLights()
            lights()
            plate(slotX(0, of: 3), tilt: ValueSetup.tilt)     // 法線が上向き（-Y 寄り）
            plate(slotX(1, of: 3))                            // 正対
            plate(slotX(2, of: 3), tilt: -ValueSetup.tilt)    // 法線が下向き（+Y 寄り）

        case 4:
            let falloffs: [Float] = [0.1, 0.01, 0.001]
            for (k, f) in falloffs.enumerated() {
                let x = slotX(k, of: falloffs.count)
                noLights()
                ambientLight(76.5)
                pointLight(x, axis.y, ValueSetup.lightZ, falloff: f)
                plate(x)
            }

        case 5:
            noLights()
            ambientLight(76.5)
            // falloff は 0 にしておく。距離減衰が乗ったままだと、明るさが閾値を割る位置が
            // 角度の切れ目より内側に来てしまい、**測っているのが角度なのか減衰なのか**が
            // 分からなくなる（最初にそれで 31px ずれた）。
            spotLight(axis.x, axis.y, ValueSetup.lightZ, 0, 0, -1,
                      angle: ValueSetup.spotAngle, falloff: 0)
            plate(axis.x, w: 700, h: 560)

        case 6:
            let shininesses: [Float] = [8, 64]
            for (k, sh) in shininesses.enumerated() {
                noLights()
                ambientLight(30)
                // 視線とほぼ同じ向きから当てて、ハイライトを球の正面に置く。
                directionalLight(-0.25, -0.25, -1)
                // **0…1 で渡す。** `specular(_ gray:)` は colorMode を通らないので、
                // fill と同じつもりで 255 を渡すと 255 倍の鏡面になって画面が飛ぶ
                // （その食い違い自体は V10 で測る）。
                specular(ValueSetup.specularGray)
                shininess(sh)
                push()
                translate(slotX(k, of: shininesses.count), axis.y, 0)
                sphere(ValueSetup.specSphereR, detail: 48)
                pop()
            }
            specular(0)
            shininess(32)

        case 7:
            // 左: ライト無し + emissive。右: 平行光 + emissive。
            noLights()
            emissive(ValueSetup.emissiveGray)
            plate(slotX(0, of: 2))
            directionalLight(0, 0, -1)
            plate(slotX(1, of: 2))
            emissive(0)

        case 8:
            // 左: 既定（Blinn-Phong）で ao=0。右: roughness() で PBR に入れて ao=0。
            noLights()
            ambientLight(76.5)
            directionalLight(0, 0, -1)
            ambientOcclusion(0)
            plate(slotX(0, of: 2))
            roughness(0.6)          // これで PBR 経路へ切り替わる
            metallic(0)
            plate(slotX(1, of: 2))
            ambientOcclusion(1)
            roughness(0.5)

        default:
            // 同じ明るさのつもりで 0…1 と 0–255 の両方を渡し、絵で食い違いを見せる。
            noLights()
            ambientLight(76.5)
            directionalLight(0, 0, -1)
            emissive(ValueSetup.emissiveGray)
            plate(slotX(0, of: 2))
            emissive(ValueSetup.emissiveGray255)
            plate(slotX(1, of: 2))
            emissive(0)
        }
    }

    // MARK: 測る

    /// 標本の板の中心（ワールド）。
    private func plateCenter(_ x: Float) -> SIMD3<Float> { SIMD3(x, axis.y, 0) }

    /// 既定カメラの目。陰影の解析に要る（V ベクトル）。
    private var eyePoint: SIMD3<Float> { standardOptics.eye }

    /// 板 1 枚ぶんの期待色を、解析側の Blinn-Phong で出す。
    ///
    /// **判定はすべてこの 1 か所を通す。** 場面ごとに式を書き下すと、
    /// 検査側の写し間違いが「ライブラリの穴」に見えてしまう。
    private func expectedPlate(_ x: Float, normal n: SIMD3<Float> = SIMD3(0, 0, 1),
                               ambient: Float = Shading.defaultAmbient,
                               emissive: Float = 0,
                               lights: [Shading.Light]) -> SIMD3<Float> {
        let model = Shading(base: ValueSetup.base, ambient: ambient,
                            emissive: SIMD3(repeating: emissive))
        return model.color(at: plateCenter(x), normal: n, eye: eyePoint, lights: lights)
    }

    func judgeValueSpecimen(_ i: Int, _ c: Canvas) -> [Finding] {
        let base = ValueSetup.base
        let amb = Shading.defaultAmbient

        switch i {
        case 0:
            let got = c.average(around: axis.x, axis.y)
            return [Finding("V1.noLights", "ライト無しは fill 色そのまま",
                            expectColor(got, base, tol: 0.012, what: "板の中心"))]

        case 1:
            let left = c.average(around: slotX(0, of: 2), axis.y)
            let right = c.average(around: slotX(1, of: 2), axis.y)
            return [
                Finding("V2.ambientAlone", "環境光だけを置いたとき",
                        expectColor(left, base, tol: 0.012,
                                    what: "ambientLight(76.5) のみ（ライト 0 本なので fill 色のままが期待）")),
                Finding("V2b.ambientWithLight", "環境光 + 平行光",
                        expectColor(right,
                                    expectedPlate(slotX(1, of: 2),
                                                  lights: [Shading.Light(travel: SIMD3(0, 0, -1))]),
                                    tol: 0.02, what: "ambient 0.3 + N·L=1")),
            ]

        case 2:
            let angles: [Float] = [0, Float.pi / 3, Float.pi * 0.75]
            var out: [Finding] = []
            for (k, a) in angles.enumerated() {
                let got = c.average(around: slotX(k, of: angles.count), axis.y)
                let ndotl = max(cos(a), 0)      // N=(0,0,1), L=(sin a, 0, cos a)
                let want = expectedPlate(slotX(k, of: angles.count),
                                         lights: [Shading.Light(travel: SIMD3(-sin(a), 0, -cos(a)))])
                out.append(Finding("V3\(["a", "b", "c"][k]).directional\(f0(a * 180 / .pi))",
                                   "平行光 \(f0(a * 180 / .pi))°",
                                   expectColor(got, want, tol: 0.02,
                                               what: "N·L=\(f3(ndotl)) のとき ambient+N·L=\(f3(amb + ndotl))")))
            }
            return out

        case 3:
            let L = normalize(-Shading.defaultLightDirection)
            let up = SIMD3<Float>(0, -sin(ValueSetup.tilt), cos(ValueSetup.tilt))
            let front = SIMD3<Float>(0, 0, 1)
            let down = SIMD3<Float>(0, sin(ValueSetup.tilt), cos(ValueSetup.tilt))
            let gotUp = c.average(around: slotX(0, of: 3), axis.y)
            let gotFront = c.average(around: slotX(1, of: 3), axis.y)
            let gotDown = c.average(around: slotX(2, of: 3), axis.y)
            let defaultLight = Shading.Light(travel: Shading.defaultLightDirection,
                                             intensity: Shading.defaultLightIntensity)
            func want(_ n: SIMD3<Float>, _ k: Int) -> SIMD3<Float> {
                expectedPlate(slotX(k, of: 3), normal: n, lights: [defaultLight])
            }
            return [
                Finding("V4a.lightsUp", "lights() と上向きの面",
                        expectColor(gotUp, want(up, 0), tol: 0.025,
                                    what: "N·L=\(f3(dot(up, L)))（負なら環境光だけ）")),
                Finding("V4b.lightsFront", "lights() と正対面",
                        expectColor(gotFront, want(front, 1), tol: 0.025,
                                    what: "N·L=\(f3(dot(front, L)))")),
                Finding("V4c.lightsDown", "lights() と下向きの面",
                        expectColor(gotDown, want(down, 2), tol: 0.025,
                                    what: "N·L=\(f3(dot(down, L)))")),
                Finding("V4d.lightsFromBelow", "既定の光はどちらから差すか",
                        .look("上向きの面=\(f3(luma(gotUp))) / 正対=\(f3(luma(gotFront)))"
                              + " / 下向きの面=\(f3(luma(gotDown)))"
                              + " → 下向きの面のほうが明るければ光は下から差している"
                              + "（metaphor#774。既定の進行方向は (-0.5, -1.0, -0.8) で、"
                              + "ワールドの Y は下向きなので光は上へ向かって進む）")),
            ]

        case 4:
            let falloffs: [Float] = [0.1, 0.01, 0.001]
            var out: [Finding] = []
            for (k, f) in falloffs.enumerated() {
                let got = c.average(around: slotX(k, of: falloffs.count), axis.y)
                let atten = Shading.attenuation(distance: ValueSetup.lightZ, falloff: f)
                let x = slotX(k, of: falloffs.count)
                let want = expectedPlate(x, lights: [Shading.Light(
                    travel: SIMD3(0, 0, -1),
                    position: SIMD3(x, axis.y, ValueSetup.lightZ), falloff: f)])
                out.append(Finding("V5\(["a", "b", "c"][k]).pointFalloff\(f3(f))",
                                   "点光源 falloff=\(f3(f))",
                                   expectColor(got, want, tol: 0.02,
                                               what: "距離 \(f0(ValueSetup.lightZ)) で減衰=\(f3(atten))")))
            }
            let attenDefault = Shading.attenuation(distance: ValueSetup.lightZ, falloff: 0.1)
            out.append(Finding("V5d.pointDefaultUnusable", "既定 falloff はピクセル空間で届くか",
                               .look("falloff=0.1・距離 \(f0(ValueSetup.lightZ)) の減衰=\(f3(attenDefault))"
                                     + "（= 実質ゼロ。既定カメラがピクセル空間なので、"
                                     + "既定値のままでは点光源が見えない）")))
            return out

        case 5:
            // 照らされた円の半径。環境光ぶんより明るい画素の横方向の広がりを測る。
            let ambLevel = luma(base * 0.3)
            let band = Rect(x: axis.x - 360, y: axis.y - 6, w: 720, h: 12)
            var left = Float.greatestFiniteMagnitude, right = -Float.greatestFiniteMagnitude
            for x in Int(band.x)..<Int(band.right) {
                let v = luma(c.average(around: Float(x), axis.y, radius: 1))
                if v > ambLevel + 0.05 {
                    left = min(left, Float(x)); right = max(right, Float(x))
                }
            }
            guard right > left else {
                return [Finding("V6.spotRadius", "スポットの照射半径",
                                .fail("環境光より明るい画素が無い（スポットが届いていない）"))]
            }
            let measured = (right - left) / 2
            let ideal = ValueSetup.lightZ * tan(ValueSetup.spotAngle)
            return [
                Finding("V6.spotRadius", "スポットの照射半径",
                        expect(measured, ideal, tol: 12,
                               what: "距離 \(f0(ValueSetup.lightZ)) × tan(\(f2(ValueSetup.spotAngle)))")),
                Finding("V6b.spotCenter", "スポットの中心",
                        expect((left + right) / 2, axis.x, tol: 4, what: "照射円の中心 x")),
            ]

        case 6:
            var areas: [(label: String, value: Float)] = []
            var peaks: [String] = []
            for (k, sh) in [Float(8), Float(64)].enumerated() {
                let cell = Rect.around(slotX(k, of: 2), axis.y,
                                       ValueSetup.specSphereR + 12, ValueSetup.specSphereR + 12)
                let n = c.brighterCount(in: cell, than: 0.72)
                areas.append((label: "sh\(f0(sh))", value: Float(n)))
                peaks.append("sh\(f0(sh)) の明部=\(n)px")
            }
            return [
                Finding("V7.shininessTightens", "shininess を上げるとハイライトは締まるか",
                        expectMonotonic(areas, increasing: false, slack: 0,
                                        what: "明るさ 0.72 超の画素数")),
                Finding("V7b.specularAppears", "specular で明部が出るか",
                        areas.allSatisfy { $0.value > 0 }
                            ? .pass("いずれもハイライトあり | \(peaks.joined(separator: " / "))")
                            : .fail("ハイライトが出ない | \(peaks.joined(separator: " / ")))")),
            ]

        case 7:
            let left = c.average(around: slotX(0, of: 2), axis.y)
            let right = c.average(around: slotX(1, of: 2), axis.y)
            let e = SIMD3<Float>(repeating: ValueSetup.emissiveGray)
            let wantEmissive = expectedPlate(slotX(1, of: 2), emissive: ValueSetup.emissiveGray,
                                             lights: [Shading.Light(travel: SIMD3(0, 0, -1))])
            return [
                Finding("V8.emissiveAlone", "ライト無しの emissive",
                        expectColor(left, base, tol: 0.012,
                                    what: "ライト 0 本（emissive も乗らないのが実装どおり）")),
                Finding("V8b.emissiveWithLight", "平行光と組んだ emissive",
                        expectColor(right, wantEmissive, tol: 0.025,
                                    what: "ambient+N·L に emissive \(f3(e.x)) を加算")),
            ]

        case 8:
            let left = c.average(around: slotX(0, of: 2), axis.y)
            let right = c.average(around: slotX(1, of: 2), axis.y)
            let blinn = base * (0.3 + 1.0)
            return [
                Finding("V9.aoBlinnPhong", "既定経路で ambientOcclusion(0)",
                        expectColor(left, blinn, tol: 0.02,
                                    what: "Blinn-Phong は ao を読まないので変化しないのが実装どおり")),
                Finding("V9b.aoPBR", "PBR 経路で ambientOcclusion(0)",
                        luma(right) < luma(left) - 0.02
                            ? .pass("PBR 側で暗くなった 実測=\(f3(luma(right))) < 既定側=\(f3(luma(left)))")
                            : .look("PBR 側で暗くならなかった 実測=\(f3(luma(right))) 既定側=\(f3(luma(left)))"
                                    + "（roughness() で PBR に入っているかを目視で確かめる）")),
            ]

        default:
            let asUnit = c.average(around: slotX(0, of: 2), axis.y)
            let as255 = c.average(around: slotX(1, of: 2), axis.y)
            let want = expectedPlate(slotX(0, of: 2), emissive: ValueSetup.emissiveGray,
                                     lights: [Shading.Light(travel: SIMD3(0, 0, -1))])
            return [
                Finding("V10.emissiveUnitScale", "emissive を 0…1 で渡したとき",
                        expectColor(asUnit, want, tol: 0.025,
                                    what: "emissive(\(f2(ValueSetup.emissiveGray))) は素直に足される")),
                Finding("V10b.emissiveColorModeScale", "emissive を 0–255 のつもりで渡したとき",
                        luma(as255) > 0.99
                            ? .fail("emissive(\(f0(ValueSetup.emissiveGray255))) で真っ白（実測=\(f3(luma(as255))))。"
                                    + "`emissive(_ gray:)` と `specular(_ gray:)` は colorMode を通らず、"
                                    + "値をそのままマテリアルへ入れる。`fill(_ gray:)` と "
                                    + "`ambientLight(_ strength:)` は 0–255 なので、"
                                    + "**同じ「gray」でも目盛りが違う**")
                            : .pass("0–255 の目盛りとして扱われた 実測=\(f3(luma(as255)))")),
            ]
        }
    }
}
