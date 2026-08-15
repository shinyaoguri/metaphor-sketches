import metaphor

// 面 C — 変換の数値的正しさ
//
// ここは「見た目が破綻していないか」ではなく「ライブラリが自分で返した数と、実際に描いた
// ピクセルが一致するか」を突く。screenX()/screenY() は変換後の描画位置を返すと約束して
// いるので、その値と ink の位置がずれていたら内部矛盾になる。

extension Sketch0816Adversary {

    func planeCTransform() -> Plane {
        Plane(key: "C", title: "変換の数値的正しさ", checks: [
            c1ScreenXYMatchesInk(),
            c2ShearX(),
            c3ApplyMatrix6(),
            c4ScaleAffectsStrokeWeight(),
            c5RotateDirection(),
            c6ResetMatrix(),
            c7ScaleZero(),
            c8ScreenXY2DVs3D(),
            c9NonUniformScaleOnCircle(),
        ])
    }

    // MARK: C1

    private func c1ScreenXYMatchesInk() -> Check {
        Check(
            id: "C1.screenxy-matches-ink",
            title: "C1 screenX/Y が実描画と一致",
            expect: "translate→rotate→scale 後の screenX/Y が ink の中心と一致する",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(s.x + 70, s.y + 70)
                rotate(0.45)
                scale(1.3)
                // (24, -12) をモデル座標として、そこに小さな正方形を置く
                scratch["C1.sx"] = screenX(24, -12)
                scratch["C1.sy"] = screenY(24, -12)
                noStroke()
                fill(Float(Ink.blue.r), Float(Ink.blue.g), Float(Ink.blue.b))
                rectMode(.center)
                rect(24, -12, 10, 10)
                pop()
                noStroke()
                fill(60, 70, 84)
                rectMode(.center)
                rect(ref.cx, ref.cy, 14, 14)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                guard let b = px.inkBounds(in: s) else { return .fail("何も描かれていない") }
                let sx = scratch["C1.sx"] ?? 0
                let sy = scratch["C1.sy"] ?? 0
                let d = abs(b.cx - sx) + abs(b.cy - sy)
                if d <= 4 {
                    return .pass("screen(\(r1(sx)),\(r1(sy))) ≈ ink(\(r1(b.cx)),\(r1(b.cy)))")
                }
                return .fail("screen(\(r1(sx)),\(r1(sy))) ink(\(r1(b.cx)),\(r1(b.cy))) 差\(r1(d))px")
            }
        )
    }

    // MARK: C2

    private func c2ShearX() -> Check {
        Check(
            id: "C2.shearx",
            title: "C2 shearX() のせん断量",
            expect: "x' = x + tan(a)·y。高さ 50・a=0.5 なら幅は 40+tan(0.5)·50",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(s.x + 24, s.y + 30)
                shearX(0.5)
                noStroke()
                fill(Float(Ink.green.r), Float(Ink.green.g), Float(Ink.green.b))
                rectMode(.corner)
                rect(0, 0, 40, 50)
                pop()
                noStroke()
                fill(60, 70, 84)
                rect(ref.x + 6, ref.y + 30, 40, 50)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                guard let b = px.inkBounds(in: s) else { return .fail("何も描かれていない") }
                let want = 40 + tan(Float(0.5)) * 50
                return expectValue(b.w, want, tol: 4, what: "せん断後の幅", unit: "px")
            }
        )
    }

    // MARK: C3

    private func c3ApplyMatrix6() -> Check {
        Check(
            id: "C3.applymatrix-6",
            title: "C3 applyMatrix(6 成分) の並び",
            expect: "Processing 形式 (n00,n01,n02,n10,n11,n12) で n02/n12 が平行移動",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(s.x, s.y)
                // 単位行列 + 平行移動 (50, 30)。Processing の並びなら右へ 50・下へ 30。
                applyMatrix(1, 0, 50, 0, 1, 30)
                noStroke()
                fill(Float(Ink.amber.r), Float(Ink.amber.g), Float(Ink.amber.b))
                rectMode(.corner)
                rect(0, 0, 40, 40)
                pop()
                noStroke()
                fill(60, 70, 84)
                rect(ref.x + 6, ref.y + 30, 40, 40)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let want = Rect(x: s.x + 50, y: s.y + 30, w: 40, h: 40)
                return expectBounds(px.inkBounds(in: s), want, what: "矩形")
            }
        )
    }

    // MARK: C4

    private func c4ScaleAffectsStrokeWeight() -> Check {
        Check(
            id: "C4.scale-strokeweight",
            title: "C4 scale() が線幅に効くか",
            expect: "Processing は変換で線幅もスケールする (scale(3)×weight 2 → 6px)",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(s.x + 20, s.y + 40)
                scale(3)
                stroke(Float(Ink.violet.r), Float(Ink.violet.g), Float(Ink.violet.b))
                strokeWeight(2)
                line(0, 0, 50, 0)
                pop()
                stroke(70, 50, 90)
                strokeWeight(6)
                line(ref.x + 6, ref.cy, ref.right - 6, ref.cy)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                guard let b = px.inkBounds(in: s) else { return .fail("線が描かれていない") }
                if abs(b.h - 6) <= 2 {
                    return .pass("線幅=\(r1(b.h))px (スケール済み)")
                }
                if abs(b.h - 2) <= 2 {
                    return .fail("線幅=\(r1(b.h))px 期待 6px (scale が線幅に効いていない)")
                }
                return .fail("線幅=\(r1(b.h))px 期待 6px")
            }
        )
    }

    // MARK: C5

    private func c5RotateDirection() -> Check {
        Check(
            id: "C5.rotate-direction",
            title: "C5 rotate(+π/2) の回り方",
            expect: "y 下向き座標系なので正の角度は画面上で時計回り",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(s.x + 60, s.y + 40)
                rotate(Float.pi / 2)
                noStroke()
                fill(Float(Ink.red.r), Float(Ink.red.g), Float(Ink.red.b))
                // 右向きの横長を描く。時計回りに 90° 回れば「下向きの縦長」になる。
                rectMode(.corner)
                rect(0, 0, 60, 12)
                pop()
                noStroke()
                fill(80, 40, 40)
                rect(ref.cx - 6, ref.y + 20, 12, 60)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let want = Rect(x: s.x + 60 - 12, y: s.y + 40, w: 12, h: 60)
                return expectBounds(px.inkBounds(in: s), want, what: "回転後")
            }
        )
    }

    // MARK: C6

    private func c6ResetMatrix() -> Check {
        Check(
            id: "C6.resetmatrix",
            title: "C6 resetMatrix() が単位行列に戻す",
            expect: "積んだ translate を捨てて、以後は画面座標そのままになる",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(300, 200)
                rotate(0.7)
                scale(2)
                resetMatrix()
                noStroke()
                fill(Float(Ink.blue.r), Float(Ink.blue.g), Float(Ink.blue.b))
                rectMode(.corner)
                rect(s.x + 20, s.y + 30, 40, 40)
                pop()
                noStroke()
                fill(60, 70, 84)
                rect(ref.x + 6, ref.y + 30, 40, 40)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let want = Rect(x: s.x + 20, y: s.y + 30, w: 40, h: 40)
                return expectBounds(px.inkBounds(in: s), want, what: "矩形")
            }
        )
    }

    // MARK: C7

    private func c7ScaleZero() -> Check {
        Check(
            id: "C7.scale-zero",
            title: "C7 scale(0) の退化",
            expect: "特異行列でも落ちず、面積 0 なので何も残らない",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(s.cx, s.cy)
                scale(0)
                noStroke()
                fill(Float(Ink.red.r), Float(Ink.red.g), Float(Ink.red.b))
                rectMode(.center)
                rect(0, 0, 80, 60)
                circle(0, 0, 40)
                pop()
                noFill()
                stroke(60, 70, 84)
                strokeWeight(1)
                rectMode(.corner)
                rect(ref.x + 6, ref.y + 30, 40, 40)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let n = px.inkCount(in: s)
                if n <= 4 { return .pass("残った画素 \(n)") }
                return .fail("scale(0) なのに \(n)px 描かれた")
            }
        )
    }

    // MARK: C8

    private func c8ScreenXY2DVs3D() -> Check {
        Check(
            id: "C8.screenxy-2d-vs-3d",
            title: "C8 screenX(x,y) と screenX(x,y,0)",
            expect: "同じ 2D 変換下で 2 引数版と 3 引数版が一致するか (仕様未定義の疑い)",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(s.x + 60, s.y + 60)
                rotate(0.3)
                scratch["C8.x2"] = screenX(30, 20)
                scratch["C8.y2"] = screenY(30, 20)
                scratch["C8.x3"] = screenX(30, 20, 0)
                scratch["C8.y3"] = screenY(30, 20, 0)
                noStroke()
                fill(Float(Ink.green.r), Float(Ink.green.g), Float(Ink.green.b))
                rectMode(.center)
                rect(30, 20, 10, 10)
                pop()
                noStroke()
                fill(60, 70, 84)
                rectMode(.center)
                rect(ref.cx, ref.cy, 14, 14)
            },
            verify: { [self] _, _ in
                let x2 = scratch["C8.x2"] ?? 0, y2 = scratch["C8.y2"] ?? 0
                let x3 = scratch["C8.x3"] ?? 0, y3 = scratch["C8.y3"] ?? 0
                let d = abs(x2 - x3) + abs(y2 - y3)
                if d <= 1 {
                    return .pass("2D(\(r1(x2)),\(r1(y2))) = 3D(\(r1(x3)),\(r1(y3)))")
                }
                return .visual("2D(\(r1(x2)),\(r1(y2))) ≠ 3D(\(r1(x3)),\(r1(y3))) 差\(r1(d))px")
            }
        )
    }

    // MARK: C9

    private func c9NonUniformScaleOnCircle() -> Check {
        Check(
            id: "C9.nonuniform-scale-circle",
            title: "C9 非一様 scale 下の circle()",
            expect: "scale(2,1) 下の直径 40 の円は 80×40 の楕円になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(s.x + 20, s.cy)
                scale(2, 1)
                noStroke()
                fill(Float(Ink.amber.r), Float(Ink.amber.g), Float(Ink.amber.b))
                circle(20, 0, 40)
                pop()
                noStroke()
                fill(70, 60, 40)
                ellipseMode(.center)
                ellipse(ref.cx, ref.cy, 60, 30)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                guard let b = px.inkBounds(in: s) else { return .fail("円が描かれていない") }
                let okW = abs(b.w - 80) <= 4
                let okH = abs(b.h - 40) <= 4
                if okW && okH { return .pass("外接=\(r0(b.w))×\(r0(b.h))") }
                return .fail("外接=\(r0(b.w))×\(r0(b.h)) 期待 80×40")
            }
        )
    }
}
