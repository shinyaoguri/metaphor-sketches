import metaphor

// 面 B — 描画モード × 退化した引数
//
// Processing の rect()/ellipse() は、モード変換のあとに必ず座標を正規化する:
//   PGraphics.rect()    … a > c / b > d なら swap してから rectImpl
//   PGraphics.ellipse() … w < 0 なら x += w; w = -w (h も同様)
// つまり「負のサイズ」「corners で逆転した座標」でも**描かれる**のが Processing の仕様。
// metaphor が正規化を省いていれば、ここで消えるか裏返る。

extension Sketch0816Adversary {

    func planeBModes() -> Plane {
        Plane(key: "B", title: "描画モード × 退化した引数", checks: [
            b1CornersSwapped(),
            b2RectNegativeSize(),
            b3RectCenterNegative(),
            b4RectRadius(),
            b5EllipseCornersSwapped(),
            b6EllipseNegativeSize(),
            b7EllipseRadius(),
            b8ZeroSize(),
            b9CircleNegativeDiameter(),
        ])
    }

    /// 各検査で共通に使う「期待どおりならここに出るはず」の矩形。
    private func target(_ s: Rect) -> Rect {
        Rect(x: s.x + 24, y: s.y + 26, w: 80, h: 60)
    }

    private func drawReference(_ ref: Rect, ellipse isEllipse: Bool = false) {
        noStroke()
        fill(60, 70, 84)
        if isEllipse {
            ellipseMode(.corner)
            ellipse(ref.x + 6, ref.y + 26, 60, 45)
        } else {
            rectMode(.corner)
            rect(ref.x + 6, ref.y + 26, 60, 45)
        }
    }

    // MARK: B1

    private func b1CornersSwapped() -> Check {
        Check(
            id: "B1.rect-corners-swapped",
            title: "B1 rectMode(.corners) の逆転座標",
            expect: "右下→左上の順で渡しても正規化されて同じ矩形になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                let t = target(s)
                noStroke()
                fill(Float(Ink.blue.r), Float(Ink.blue.g), Float(Ink.blue.b))
                rectMode(.corners)
                // わざと右下 → 左上 の順で渡す
                rect(t.right, t.bottom, t.x, t.y)
                drawReference(ref)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectBounds(px.inkBounds(in: s), target(s), what: "矩形")
            }
        )
    }

    // MARK: B2

    private func b2RectNegativeSize() -> Check {
        Check(
            id: "B2.rect-negative-size",
            title: "B2 rect() の負の w/h",
            expect: "負のサイズは左上方向へ描かれる (Processing は swap する)",
            draw: { [self] r in
                let (s, ref) = split(r)
                let t = target(s)
                noStroke()
                fill(Float(Ink.green.r), Float(Ink.green.g), Float(Ink.green.b))
                rectMode(.corner)
                rect(t.right, t.bottom, -t.w, -t.h)
                drawReference(ref)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectBounds(px.inkBounds(in: s), target(s), what: "矩形")
            }
        )
    }

    // MARK: B3

    private func b3RectCenterNegative() -> Check {
        Check(
            id: "B3.rect-center-negative",
            title: "B3 rectMode(.center) × 負の w/h",
            expect: "中心基準なので符号によらず同じ矩形になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                let t = target(s)
                noStroke()
                fill(Float(Ink.amber.r), Float(Ink.amber.g), Float(Ink.amber.b))
                rectMode(.center)
                rect(t.cx, t.cy, -t.w, -t.h)
                drawReference(ref)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectBounds(px.inkBounds(in: s), target(s), what: "矩形")
            }
        )
    }

    // MARK: B4

    private func b4RectRadius() -> Check {
        Check(
            id: "B4.rect-radius",
            title: "B4 rectMode(.radius)",
            expect: "w/h を半幅・半高として中心から広げる",
            draw: { [self] r in
                let (s, ref) = split(r)
                let t = target(s)
                noStroke()
                fill(Float(Ink.violet.r), Float(Ink.violet.g), Float(Ink.violet.b))
                rectMode(.radius)
                rect(t.cx, t.cy, t.w / 2, t.h / 2)
                drawReference(ref)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectBounds(px.inkBounds(in: s), target(s), what: "矩形")
            }
        )
    }

    // MARK: B5

    private func b5EllipseCornersSwapped() -> Check {
        Check(
            id: "B5.ellipse-corners-swapped",
            title: "B5 ellipseMode(.corners) の逆転座標",
            expect: "右下→左上の順でも同じ外接矩形の楕円になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                let t = target(s)
                noStroke()
                fill(Float(Ink.blue.r), Float(Ink.blue.g), Float(Ink.blue.b))
                ellipseMode(.corners)
                ellipse(t.right, t.bottom, t.x, t.y)
                drawReference(ref, ellipse: true)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                // 楕円はアンチエイリアスで外接矩形が 1px 内側に出ることがあるので緩めに見る
                return expectBounds(px.inkBounds(in: s), target(s), tol: 4, what: "外接")
            }
        )
    }

    // MARK: B6

    private func b6EllipseNegativeSize() -> Check {
        Check(
            id: "B6.ellipse-negative-size",
            title: "B6 ellipse() の負の w/h",
            expect: "負のサイズでも絶対値の楕円が描かれる",
            draw: { [self] r in
                let (s, ref) = split(r)
                let t = target(s)
                noStroke()
                fill(Float(Ink.green.r), Float(Ink.green.g), Float(Ink.green.b))
                ellipseMode(.center)
                ellipse(t.cx, t.cy, -t.w, -t.h)
                drawReference(ref, ellipse: true)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectBounds(px.inkBounds(in: s), target(s), tol: 4, what: "外接")
            }
        )
    }

    // MARK: B7

    private func b7EllipseRadius() -> Check {
        Check(
            id: "B7.ellipse-radius",
            title: "B7 ellipseMode(.radius)",
            expect: "w/h を半径として中心から広げる",
            draw: { [self] r in
                let (s, ref) = split(r)
                let t = target(s)
                noStroke()
                fill(Float(Ink.amber.r), Float(Ink.amber.g), Float(Ink.amber.b))
                ellipseMode(.radius)
                ellipse(t.cx, t.cy, t.w / 2, t.h / 2)
                drawReference(ref, ellipse: true)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectBounds(px.inkBounds(in: s), target(s), tol: 4, what: "外接")
            }
        )
    }

    // MARK: B8

    private func b8ZeroSize() -> Check {
        Check(
            id: "B8.zero-size",
            title: "B8 サイズ 0 の退化図形",
            expect: "面積 0 の塗りは何も描かず、落ちない",
            draw: { [self] r in
                let (s, ref) = split(r)
                let t = target(s)
                noStroke()
                fill(Float(Ink.red.r), Float(Ink.red.g), Float(Ink.red.b))
                rectMode(.corner)
                rect(t.x, t.y, 0, t.h)
                rect(t.x + 20, t.y, t.w, 0)
                ellipseMode(.center)
                ellipse(t.cx, t.cy, 0, 0)
                // 見本側は「何も描かれない」ことの対照として枠だけ
                noFill()
                stroke(60, 70, 84)
                strokeWeight(1)
                rect(ref.x + 6, ref.y + 26, 60, 45)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let n = px.inkCount(in: s)
                if n == 0 { return .pass("描かれた画素 0") }
                return .fail("面積 0 の図形が \(n)px 描かれた")
            }
        )
    }

    // MARK: B9

    private func b9CircleNegativeDiameter() -> Check {
        Check(
            id: "B9.circle-negative-diameter",
            title: "B9 circle() の負の直径",
            expect: "負の直径でも絶対値の円になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                let t = target(s)
                noStroke()
                fill(Float(Ink.violet.r), Float(Ink.violet.g), Float(Ink.violet.b))
                circle(t.cx, t.cy, -60)
                noStroke()
                fill(60, 70, 84)
                circle(ref.cx, ref.cy, 45)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let t = target(s)
                let want = Rect(x: t.cx - 30, y: t.cy - 30, w: 60, h: 60)
                return expectBounds(px.inkBounds(in: s), want, tol: 4, what: "外接")
            }
        )
    }
}
