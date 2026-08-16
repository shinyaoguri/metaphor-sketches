import Foundation
import simd
import metaphor

// 場面 1「形」— プリミティブの寸法は指定どおりか。
//
// デッサンで最初に直されるのは形。ここでは組み込みプリミティブを 1 体ずつ画面中央に置き、
// **シルエットの外接矩形をピクセルで測って**、既定カメラの規約から出した理想値と突き合わせる。
//
// この場面だけ `noLights()` で描く。陰影が乗ると背景との境が滲んで、
// 測っているのが「形」なのか「明るさ」なのか分からなくなるため。

extension Sketch0816Atelier {

    // MARK: 標本

    func formSpecimens() -> [Specimen] {
        [
            Specimen(name: "sphere", title: "球 sphere(140)",
                     note: "透視では球のシルエットは接線円錐で決まる（単純な 2r ではない）"),
            Specimen(name: "box", title: "立方体 box(200)",
                     note: "8 隅の投影。分割に依らないので理想と実測が一致するはず"),
            Specimen(name: "cylinder", title: "円柱 cylinder(r:90 h:240)",
                     note: "軸は Y。上下の縁がどこまで張り出すか"),
            Specimen(name: "cone", title: "円錐 cone(r:100 h:240)",
                     note: "頂点は +Y。ワールドの Y は下向きなので既定では下を向く"),
            Specimen(name: "torus", title: "輪 torus(R:150 r:45)",
                     note: "リング面は XZ。既定カメラからは真横から見た形になる"),
            Specimen(name: "plane", title: "板 plane(300, 180)",
                     note: "z=0 の平面なので 1 単位 = 1 画素。もっとも素直な物差し"),
            Specimen(name: "detail", title: "分割 detail 3→48",
                     note: "分割を上げるほど内接多角形が外接円へ寄るか"),
            Specimen(name: "transform", title: "変換 translate・rotate・scale",
                     note: "合成順と push/pop の漏れ"),
        ]
    }

    // MARK: 採寸台の寸法

    /// 採寸に使う標本の寸法（描く側と測る側で同じ値を見るため 1 か所に置く）。
    enum FormSize {
        static let sphereRadius: Float = 140
        static let sphereDetail = 40
        static let boxSize: Float = 200
        static let cylinderRadius: Float = 90
        static let cylinderHeight: Float = 240
        static let cylinderDetail = 40
        static let coneRadius: Float = 100
        static let coneHeight: Float = 240
        static let coneDetail = 40
        static let torusRing: Float = 150
        static let torusTube: Float = 45
        static let torusDetail = 44
        static let planeW: Float = 300
        static let planeH: Float = 180
        /// 分割掃引。半径を小さめに取って 5 体を横に並べる。
        ///
        /// 下限の 3 を並びに入れないのは、3 分割の球が「内接多角形」と呼べる形ではなく
        /// （経度 3・緯度 4 の折り紙）、外接矩形が単調に増えるとは限らないため。
        /// 3 は落ちないことだけを別に見る（F7c と trap）。
        static let sweepDetails = [6, 10, 16, 24, 48]
        static let sweepLowest = 3
        static let sweepRadius: Float = 58
        static let sweepPitch: Float = 210
        /// 変換の検査に使う立方体と、漏れを見るための目印。
        static let xformBox: Float = 120
        static let xformRotate: Float = 0.6
        static let xformScale = SIMD3<Float>(1.5, 0.75, 1)
        static let markerBox: Float = 44
        static let markerOffsetY: Float = 250
    }

    // MARK: 描く

    func drawFormSpecimen(_ i: Int) {
        noLights()          // 形だけを見る。陰影は場面 2 の仕事
        noStroke()
        fillRGB(Palette.specimen)

        switch i {
        case 0:
            push(); translate(axis.x, axis.y, 0)
            sphere(FormSize.sphereRadius, detail: FormSize.sphereDetail)
            pop()

        case 1:
            push(); translate(axis.x, axis.y, 0)
            box(FormSize.boxSize)
            pop()

        case 2:
            push(); translate(axis.x, axis.y, 0)
            cylinder(radius: FormSize.cylinderRadius, height: FormSize.cylinderHeight,
                     detail: FormSize.cylinderDetail)
            pop()

        case 3:
            push(); translate(axis.x, axis.y, 0)
            cone(radius: FormSize.coneRadius, height: FormSize.coneHeight,
                 detail: FormSize.coneDetail)
            pop()

        case 4:
            push(); translate(axis.x, axis.y, 0)
            torus(ringRadius: FormSize.torusRing, tubeRadius: FormSize.torusTube,
                  detail: FormSize.torusDetail)
            pop()

        case 5:
            push(); translate(axis.x, axis.y, 0)
            plane(FormSize.planeW, FormSize.planeH)
            pop()

        case 6:
            for (k, d) in FormSize.sweepDetails.enumerated() {
                push()
                translate(sweepX(k), axis.y, 0)
                sphere(FormSize.sweepRadius, detail: d)
                pop()
            }

        default:
            push()
            translate(axis.x, axis.y, 0)
            rotateZ(FormSize.xformRotate)
            scale(FormSize.xformScale.x, FormSize.xformScale.y, FormSize.xformScale.z)
            box(FormSize.xformBox)
            pop()
            // pop() 後に置く目印。変換が漏れていればここがずれる。
            push()
            translate(axis.x, axis.y + FormSize.markerOffsetY, 0)
            box(FormSize.markerBox)
            pop()
        }
    }

    /// 分割掃引の k 番目の中心 x。
    func sweepX(_ k: Int) -> Float {
        let n = Float(FormSize.sweepDetails.count)
        return axis.x + (Float(k) - (n - 1) / 2) * FormSize.sweepPitch
    }

    // MARK: 測る

    func judgeFormSpecimen(_ i: Int, _ c: Canvas) -> [Finding] {
        let o = standardOptics
        let all = Rect(x: 0, y: 0, w: width, h: height)

        switch i {
        case 0:
            guard let s = c.silhouette(in: all) else { return [miss("F1.sphere", "球")] }
            // 軸上の球なので閉じた式が使える（接線円錐）。ここは両方出して突き合わせておく。
            let closedForm = o.apparentSphereRadius(center: axis, radius: FormSize.sphereRadius) * 2
            let sampled = o.bounds(of: Sample.spherePoints(center: axis, radius: FormSize.sphereRadius))
            let ideal = sampled?.w ?? closedForm
            var out = [Finding("F1.sphere", "球のシルエット径",
                               expectInscribed(s.w, ideal: ideal, detail: FormSize.sphereDetail,
                                               what: "横径（半径 \(f0(FormSize.sphereRadius)) の球。"
                                                     + "刻んだ標本点=\(f2(ideal))px / 接線円錐の閉じた式=\(f2(closedForm))px）"))]
            // 素朴に 2r（=280px）と思っていると 7px ずれる。そこも数値で残す。
            out.append(Finding("F1b.sphereNaive", "球径と 2r のずれ",
                               .look("実測=\(f2(s.w))px / 接線円錐から出した理想=\(f2(ideal))px"
                                     + " / 素朴な 2r=\(f0(FormSize.sphereRadius * 2))px"
                                     + " → 透視のぶん \(f2(ideal - FormSize.sphereRadius * 2))px 大きい")))
            out.append(aspect("F1c.sphereRound", "球の縦横比", s))
            return out

        case 1:
            guard let s = c.silhouette(in: all) else { return [miss("F2.box", "立方体")] }
            let pts = Sample.boxCorners(center: axis, size: SIMD3(repeating: FormSize.boxSize))
            guard let b = o.bounds(of: pts) else { return [miss("F2.box", "立方体（解析）")] }
            return [
                Finding("F2.box", "立方体の投影幅",
                        expect(s.w, b.w, tol: 2.5, what: "横幅（8 隅の投影から）")),
                Finding("F2b.boxHeight", "立方体の投影高",
                        expect(s.h, b.h, tol: 2.5, what: "縦幅")),
                Finding("F2c.boxNear", "手前の面が指定寸法より大きく写るか",
                        .look("実測=\(f2(s.w))px / 指定=\(f0(FormSize.boxSize))px"
                              + " / 手前の面（z=+\(f0(FormSize.boxSize / 2))）の倍率="
                              + f3(o.foreshortening(atZ: FormSize.boxSize / 2)))),
            ]

        case 2:
            guard let s = c.silhouette(in: all) else { return [miss("F3.cylinder", "円柱")] }
            let pts = Sample.cylinderRims(center: axis, radius: FormSize.cylinderRadius,
                                          height: FormSize.cylinderHeight)
            guard let b = o.bounds(of: pts) else { return [miss("F3.cylinder", "円柱（解析）")] }
            return [
                Finding("F3.cylinder", "円柱の径",
                        expectInscribed(s.w, ideal: b.w, detail: FormSize.cylinderDetail,
                                        what: "横径（上下の縁の投影から）")),
                Finding("F3b.cylinderHeight", "円柱の高さ",
                        expectInscribed(s.h, ideal: b.h, detail: FormSize.cylinderDetail,
                                        what: "縦幅（縁のいちばん手前が決める）")),
            ]

        case 3:
            guard let s = c.silhouette(in: all) else { return [miss("F4.cone", "円錐")] }
            let pts = Sample.conePoints(center: axis, radius: FormSize.coneRadius,
                                        height: FormSize.coneHeight)
            guard let b = o.bounds(of: pts) else { return [miss("F4.cone", "円錐（解析）")] }
            // 頂点はどちらを向くか。上 1/4 と下 1/4 で描かれた画素数を比べる。
            let q = s.h / 4
            let top = c.drawnCount(in: Rect(x: s.x, y: s.y, w: s.w, h: q))
            let bottom = c.drawnCount(in: Rect(x: s.x, y: s.bottom - q, w: s.w, h: q))
            let tipDown = bottom < top
            return [
                Finding("F4.cone", "円錐の底面径",
                        expectInscribed(s.w, ideal: b.w, detail: FormSize.coneDetail,
                                        what: "横径")),
                Finding("F4b.coneHeight", "円錐の高さ",
                        expectInscribed(s.h, ideal: b.h, detail: FormSize.coneDetail,
                                        what: "縦幅")),
                Finding("F4c.coneTip", "円錐の頂点が向く先",
                        .look("上 1/4 の画素=\(top) / 下 1/4 の画素=\(bottom)"
                              + " → 頂点は画面の\(tipDown ? "下" : "上")向き"
                              + "（メッシュは頂点が +Y。ワールドの Y は下向きなので下が期待）")),
            ]

        case 4:
            guard let s = c.silhouette(in: all) else { return [miss("F5.torus", "輪")] }
            let pts = Sample.torusPoints(center: axis, ring: FormSize.torusRing, tube: FormSize.torusTube)
            guard let b = o.bounds(of: pts) else { return [miss("F5.torus", "輪（解析）")] }
            return [
                Finding("F5.torus", "輪の外径",
                        expectInscribed(s.w, ideal: b.w, detail: FormSize.torusDetail,
                                        what: "横径（外径 2(R+r)=\(f0((FormSize.torusRing + FormSize.torusTube) * 2)) 相当）")),
                Finding("F5b.torusThickness", "輪の厚み",
                        expectInscribed(s.h, ideal: b.h, detail: FormSize.torusDetail,
                                        what: "縦幅（リング面が XZ なので管の太さぶん）")),
            ]

        case 5:
            guard let s = c.silhouette(in: all) else { return [miss("F6.plane", "板")] }
            return [
                Finding("F6.plane", "板の幅",
                        expect(s.w, FormSize.planeW, tol: 2.5,
                               what: "横幅（z=0 なので 1 単位 = 1 画素）")),
                Finding("F6b.planeHeight", "板の高さ",
                        expect(s.h, FormSize.planeH, tol: 2.5, what: "縦幅")),
                Finding("F6c.planeCenter", "板の中心",
                        expect(s.cx, axis.x, tol: 2.0, what: "中心 x")),
            ]

        case 6:
            // 掃引の球は画面の軸から外れているので、閉じた式は使えない。
            // 標本点を刻んで、その球の位置なりの理想を出す。
            var ratios: [(label: String, value: Float)] = []
            var widths: [String] = []
            var missing: [String] = []
            var lastPair: (measured: Float, ideal: Float)? = nil
            for (k, d) in FormSize.sweepDetails.enumerated() {
                let center = SIMD3(sweepX(k), axis.y, Float(0))
                let cell = Rect.around(sweepX(k), axis.y, FormSize.sweepPitch / 2 - 12, 140)
                guard let s = c.silhouette(in: cell),
                      let idealRect = o.bounds(of: Sample.spherePoints(center: center,
                                                                      radius: FormSize.sweepRadius))
                else {
                    missing.append("d\(d)")
                    continue
                }
                ratios.append((label: "d\(d)", value: s.w / idealRect.w))
                widths.append("d\(d)=\(f1(s.w))/\(f1(idealRect.w))px")
                lastPair = (s.w, idealRect.w)
            }
            var out: [Finding] = []
            if missing.isEmpty {
                out.append(Finding("F7.detailMonotonic", "分割を上げると外接円へ寄るか",
                                   expectMonotonic(ratios, increasing: true, slack: 0.004,
                                                   what: "実測/理想の比（\(widths.joined(separator: " "))）")))
                if let last = lastPair {
                    out.append(Finding("F7b.detailConverges", "分割 48 で理想へ届くか",
                                       expectInscribed(last.measured, ideal: last.ideal, detail: 48,
                                                       what: "もっとも細かい球の横径")))
                }
            } else {
                out.append(Finding("F7.detailMonotonic", "分割を上げると外接円へ寄るか",
                                   .fail("測れなかった分割がある: \(missing.joined(separator: ", "))")))
            }
            return out

        default:
            // 変換の合成: world = T * Rz * S * p
            let t = float4x4(translation: SIMD3(axis.x, axis.y, 0))
            let r = float4x4(rotationZ: FormSize.xformRotate)
            let sMat = float4x4(scale: FormSize.xformScale)
            let rs = r * sMat
            let model = t * rs
            let local = Sample.boxCorners(center: .zero, size: SIMD3(repeating: FormSize.xformBox))
            let world = local.map { p -> SIMD3<Float> in
                let v = model * SIMD4<Float>(p.x, p.y, p.z, 1)
                return SIMD3(v.x, v.y, v.z)
            }
            guard let b = o.bounds(of: world) else { return [miss("F8.transform", "変換（解析）")] }

            // 目印だけを含む帯（変換した箱と重ならない位置）で測る。
            let markerBand = Rect(x: 0, y: axis.y + FormSize.markerOffsetY - 70, w: width, h: 140)
            let bodyBand = Rect(x: 0, y: 0, w: width, h: axis.y + FormSize.markerOffsetY - 80)
            guard let bodyS = c.silhouette(in: bodyBand) else { return [miss("F8.transform", "変換した箱")] }
            guard let markS = c.silhouette(in: markerBand) else { return [miss("F8b.pushPop", "目印")] }

            let markerPts = Sample.boxCorners(
                center: SIMD3(axis.x, axis.y + FormSize.markerOffsetY, 0),
                size: SIMD3(repeating: FormSize.markerBox))
            guard let markB = o.bounds(of: markerPts) else { return [miss("F8b.pushPop", "目印（解析）")] }

            return [
                Finding("F8.transform", "translate・rotate・scale の合成",
                        expect(bodyS.w, b.w, tol: 3.0,
                               what: "回転 \(f2(FormSize.xformRotate))rad・非一様スケール後の横幅")),
                Finding("F8b.transformHeight", "合成後の高さ",
                        expect(bodyS.h, b.h, tol: 3.0, what: "縦幅")),
                Finding("F8c.pushPop", "push/pop で変換が戻るか",
                        expect(markS.cx, markB.cx, tol: 2.0,
                               what: "pop 後に置いた目印の中心 x（漏れていればずれる）")),
            ]
        }
    }

    // MARK: 小道具

    func miss(_ id: String, _ what: String) -> Finding {
        Finding(id, "\(what)が写らなかった", .fail("シルエットが 1 画素も取れなかった（描画そのものが出ていない疑い）"))
    }

    /// 縦横比が 1 かどうか（球が楕円に潰れていないか）。
    private func aspect(_ id: String, _ title: String, _ s: Rect) -> Finding {
        let ratio = s.w / max(s.h, 0.001)
        return Finding(id, title, expect(ratio, 1.0, tol: 0.02, what: "横/縦", unit: ""))
    }
}
