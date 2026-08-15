import metaphor

// 面 E — 色とブレンド
//
// この面は「見た目が変わったか」ではなく **合成結果の数値** を突く。下地を描いてから
// ブレンドモードを変えて重ね、重なり部分の RGB が式どおりか照合する。
// 加算 / 乗算 / 差分 / アルファのどれも式が一意に決まるので、リニア空間と sRGB を
// 取り違えていればここでずれる。

extension Sketch0816Adversary {

    func planeEColorBlend() -> Plane {
        Plane(key: "E", title: "色とブレンド", checks: [
            e1HSBBasic(),
            e2RGBUnitMax(),
            e3LerpColor(),
            e4Additive(),
            e5Multiply(),
            e6Difference(),
            e7AlphaCompositing(),
            e8HSBAppliesToStroke(),
            e9PerChannelMax(),
        ])
    }

    /// 下地 → 重ねの 2 枚を置く定型。重なり部分の中心を返す。
    private func overlayRects(_ s: Rect) -> (base: Rect, over: Rect, probe: (x: Float, y: Float)) {
        let base = Rect(x: s.x + 20, y: s.y + 30, w: 110, h: 60)
        let over = Rect(x: s.x + 60, y: s.y + 30, w: 110, h: 60)
        return (base, over, (x: s.x + 95, y: s.y + 60))
    }

    // MARK: E1

    private func e1HSBBasic() -> Check {
        Check(
            id: "E1.hsb-basic",
            title: "E1 colorMode(HSB,360,100,100)",
            expect: "fill(0,100,100) は純赤 rgb(255,0,0)",
            draw: { [self] r in
                let (s, ref) = split(r)
                colorMode(.hsb, 360, 100, 100, 100)
                noStroke()
                fill(0, 100, 100)
                rectMode(.center)
                rect(s.cx, s.cy, 80, 60)
                colorMode(.rgb, 255)
                swatch(ref, (r: 255, g: 0, b: 0))
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectColor(px, at: s.cx, s.cy, (r: 255, g: 0, b: 0), what: "実測色")
            }
        )
    }

    // MARK: E2

    private func e2RGBUnitMax() -> Check {
        Check(
            id: "E2.rgb-unit-max",
            title: "E2 colorMode(RGB, 1.0)",
            expect: "最大値 1 のとき fill(1,0,0) は純赤になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                colorMode(.rgb, 1)
                noStroke()
                fill(1, 0, 0)
                rectMode(.center)
                rect(s.cx, s.cy, 80, 60)
                colorMode(.rgb, 255)
                swatch(ref, (r: 255, g: 0, b: 0))
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectColor(px, at: s.cx, s.cy, (r: 255, g: 0, b: 0), what: "実測色")
            }
        )
    }

    // MARK: E3

    private func e3LerpColor() -> Check {
        Check(
            id: "E3.lerpcolor",
            title: "E3 lerpColor(赤, 青, 0.5)",
            expect: "RGB 線形補間なら rgb(128,0,128)",
            draw: { [self] r in
                let (s, ref) = split(r)
                let c = lerpColor(Color(r: 1, g: 0, b: 0), Color(r: 0, g: 0, b: 1), 0.5)
                noStroke()
                fill(c)
                rectMode(.center)
                rect(s.cx, s.cy, 80, 60)
                swatch(ref, (r: 128, g: 0, b: 128))
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectColor(px, at: s.cx, s.cy, (r: 128, g: 0, b: 128), tol: 12, what: "実測色")
            }
        )
    }

    // MARK: E4

    private func e4Additive() -> Check {
        Check(
            id: "E4.blend-additive",
            title: "E4 blendMode(.additive)",
            expect: "下地(60,30,20) + 重ね(80,40,20) = rgb(140,70,40)",
            draw: { [self] r in
                let (s, ref) = split(r)
                let o = overlayRects(s)
                noStroke()
                rectMode(.corner)
                blendMode(.alpha)
                fill(60, 30, 20)
                rect(o.base.x, o.base.y, o.base.w, o.base.h)
                blendMode(.additive)
                fill(80, 40, 20)
                rect(o.over.x, o.over.y, o.over.w, o.over.h)
                blendMode(.alpha)
                swatch(ref, (r: 140, g: 70, b: 40))
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let o = overlayRects(s)
                return expectColor(px, at: o.probe.x, o.probe.y, (r: 140, g: 70, b: 40), tol: 12, what: "重なり")
            }
        )
    }

    // MARK: E5

    private func e5Multiply() -> Check {
        Check(
            id: "E5.blend-multiply",
            title: "E5 blendMode(.multiply)",
            expect: "下地(200,180,160) × 重ね(128,255,64)/255 = rgb(100,180,40)",
            draw: { [self] r in
                let (s, ref) = split(r)
                let o = overlayRects(s)
                noStroke()
                rectMode(.corner)
                blendMode(.alpha)
                fill(200, 180, 160)
                rect(o.base.x, o.base.y, o.base.w, o.base.h)
                blendMode(.multiply)
                fill(128, 255, 64)
                rect(o.over.x, o.over.y, o.over.w, o.over.h)
                blendMode(.alpha)
                swatch(ref, (r: 100, g: 180, b: 40))
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let o = overlayRects(s)
                return expectColor(px, at: o.probe.x, o.probe.y, (r: 100, g: 180, b: 40), tol: 12, what: "重なり")
            }
        )
    }

    // MARK: E6

    private func e6Difference() -> Check {
        Check(
            id: "E6.blend-difference",
            title: "E6 blendMode(.difference)",
            expect: "|下地(200,180,160) − 重ね(128,255,64)| = rgb(72,75,96)",
            draw: { [self] r in
                let (s, ref) = split(r)
                let o = overlayRects(s)
                noStroke()
                rectMode(.corner)
                blendMode(.alpha)
                fill(200, 180, 160)
                rect(o.base.x, o.base.y, o.base.w, o.base.h)
                blendMode(.difference)
                fill(128, 255, 64)
                rect(o.over.x, o.over.y, o.over.w, o.over.h)
                blendMode(.alpha)
                swatch(ref, (r: 72, g: 75, b: 96))
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let o = overlayRects(s)
                return expectColor(px, at: o.probe.x, o.probe.y, (r: 72, g: 75, b: 96), tol: 12, what: "重なり")
            }
        )
    }

    // MARK: E7

    private func e7AlphaCompositing() -> Check {
        Check(
            id: "E7.alpha-compositing",
            title: "E7 アルファ合成の数値",
            expect: "下地(0,200,0) に赤 alpha=128 を重ねて rgb(128,99,0)",
            draw: { [self] r in
                let (s, ref) = split(r)
                let o = overlayRects(s)
                noStroke()
                rectMode(.corner)
                blendMode(.alpha)
                fill(0, 200, 0)
                rect(o.base.x, o.base.y, o.base.w, o.base.h)
                fill(255, 0, 0, 128)
                rect(o.over.x, o.over.y, o.over.w, o.over.h)
                swatch(ref, (r: 128, g: 99, b: 0))
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let o = overlayRects(s)
                return expectColor(px, at: o.probe.x, o.probe.y, (r: 128, g: 99, b: 0), tol: 12, what: "重なり")
            }
        )
    }

    // MARK: E8

    private func e8HSBAppliesToStroke() -> Check {
        Check(
            id: "E8.hsb-stroke",
            title: "E8 colorMode(HSB) が stroke にも効く",
            expect: "stroke(120,100,100) は純緑 rgb(0,255,0)",
            draw: { [self] r in
                let (s, ref) = split(r)
                colorMode(.hsb, 360, 100, 100, 100)
                stroke(120, 100, 100)
                strokeWeight(8)
                line(s.x + 20, s.cy, s.right - 20, s.cy)
                colorMode(.rgb, 255)
                stroke(0, 160, 0)
                strokeWeight(8)
                line(ref.x + 6, ref.cy, ref.right - 6, ref.cy)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectColor(px, at: s.cx, s.cy, (r: 0, g: 255, b: 0), what: "線の色")
            }
        )
    }

    // MARK: E9

    private func e9PerChannelMax() -> Check {
        Check(
            id: "E9.per-channel-max",
            title: "E9 チャンネル別の最大値",
            expect: "colorMode(RGB,100,10,1) で fill(50,5,0.5) は中間グレー",
            draw: { [self] r in
                let (s, ref) = split(r)
                colorMode(.rgb, 100, 10, 1, 1)
                noStroke()
                fill(50, 5, 0.5)
                rectMode(.center)
                rect(s.cx, s.cy, 80, 60)
                colorMode(.rgb, 255)
                swatch(ref, (r: 128, g: 128, b: 128))
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectColor(px, at: s.cx, s.cy, (r: 128, g: 128, b: 128), tol: 12, what: "実測色")
            }
        )
    }
}
