import metaphor

// 面 A — 状態スタック
//
// Processing の状態スタックは 3 系統ある:
//   push()/pop()             … 変換 + スタイル
//   pushMatrix()/popMatrix() … 変換のみ (スタイルには触れない)
//   pushStyle()/popStyle()   … スタイルのみ (変換には触れない)
// 「何が保存され、何が保存されないか」と「別系統どうしが干渉しないか」を敵対的に確かめる。

extension Sketch0816Adversary {

    func planeAState() -> Plane {
        Plane(key: "A", title: "状態スタック", checks: [
            a1FillRestored(),
            a2TranslateRestored(),
            a3PushStyleKeepsTransform(),
            a4PushMatrixKeepsStyle(),
            a5StrokeWeightRestored(),
            a6RectModeRestored(),
            a7ColorModeRestored(),
            a8StacksAreIndependent(),
            a9DeepNesting(),
        ])
    }

    // MARK: A1

    private func a1FillRestored() -> Check {
        Check(
            id: "A1.fill-restored",
            title: "A1 pop() が fill を戻す",
            expect: "push→fill 変更→pop の後は元の赤で描かれる",
            draw: { [self] r in
                let (s, ref) = split(r)
                fill(Float(Ink.red.r), Float(Ink.red.g), Float(Ink.red.b))
                push()
                fill(Float(Ink.blue.r), Float(Ink.blue.g), Float(Ink.blue.b))
                pop()
                noStroke()
                rectMode(.center)
                rect(s.cx, s.cy, 60, 60)
                swatch(ref, Ink.red)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectColor(px, at: s.cx, s.cy, Ink.red, what: "実測色")
            }
        )
    }

    // MARK: A2

    private func a2TranslateRestored() -> Check {
        Check(
            id: "A2.translate-restored",
            title: "A2 pop() が translate を戻す",
            expect: "push→translate(60,40)→pop の後の矩形は元の原点基準",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(s.x + 20, s.y + 20)
                push()
                translate(60, 40)
                pop()
                noStroke()
                fill(Float(Ink.green.r), Float(Ink.green.g), Float(Ink.green.b))
                rectMode(.corner)
                rect(0, 0, 40, 40)
                pop()
                // 見本: 同じ位置を変換なしで
                noStroke()
                fill(60, 90, 70)
                rect(ref.x + 10, ref.y + 20, 40, 40)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let want = Rect(x: s.x + 20, y: s.y + 20, w: 40, h: 40)
                return expectBounds(px.inkBounds(in: s), want, what: "矩形")
            }
        )
    }

    // MARK: A3

    private func a3PushStyleKeepsTransform() -> Check {
        Check(
            id: "A3.pushstyle-keeps-transform",
            title: "A3 popStyle() は変換を戻さない",
            expect: "pushStyle→translate(50,0)→popStyle の後も 50px ずれたまま",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(s.x, s.y + 20)
                pushStyle()
                translate(50, 0)
                popStyle()
                noStroke()
                fill(Float(Ink.amber.r), Float(Ink.amber.g), Float(Ink.amber.b))
                rectMode(.corner)
                rect(0, 0, 40, 40)
                pop()
                noStroke()
                fill(90, 70, 40)
                rect(ref.x + 10, ref.y + 20, 40, 40)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let want = Rect(x: s.x + 50, y: s.y + 20, w: 40, h: 40)
                return expectBounds(px.inkBounds(in: s), want, what: "矩形")
            }
        )
    }

    // MARK: A4

    private func a4PushMatrixKeepsStyle() -> Check {
        Check(
            id: "A4.pushmatrix-keeps-style",
            title: "A4 popMatrix() はスタイルを戻さない",
            expect: "pushMatrix→fill(青)→popMatrix の後も青のまま",
            draw: { [self] r in
                let (s, ref) = split(r)
                fill(Float(Ink.red.r), Float(Ink.red.g), Float(Ink.red.b))
                pushMatrix()
                fill(Float(Ink.blue.r), Float(Ink.blue.g), Float(Ink.blue.b))
                popMatrix()
                noStroke()
                rectMode(.center)
                rect(s.cx, s.cy, 60, 60)
                swatch(ref, Ink.blue)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectColor(px, at: s.cx, s.cy, Ink.blue, what: "実測色")
            }
        )
    }

    // MARK: A5

    private func a5StrokeWeightRestored() -> Check {
        Check(
            id: "A5.strokeweight-restored",
            title: "A5 pop() が strokeWeight を戻す",
            expect: "push→strokeWeight(18)→pop の後の線は太さ 3",
            draw: { [self] r in
                let (s, ref) = split(r)
                strokeWeight(3)
                push()
                strokeWeight(18)
                pop()
                stroke(Float(Ink.violet.r), Float(Ink.violet.g), Float(Ink.violet.b))
                line(s.x + 20, s.cy, s.right - 20, s.cy)
                strokeWeight(3)
                stroke(80, 50, 100)
                line(ref.x + 10, ref.cy, ref.right - 10, ref.cy)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                guard let b = px.inkBounds(in: s) else {
                    return .fail("線が描かれていない")
                }
                return expectValue(b.h, 3, tol: 2, what: "線の太さ", unit: "px")
            }
        )
    }

    // MARK: A6

    private func a6RectModeRestored() -> Check {
        Check(
            id: "A6.rectmode-restored",
            title: "A6 pop() が rectMode を戻す",
            expect: "push→rectMode(.center)→pop の後は corner 解釈",
            draw: { [self] r in
                let (s, ref) = split(r)
                rectMode(.corner)
                push()
                rectMode(.center)
                pop()
                noStroke()
                fill(Float(Ink.green.r), Float(Ink.green.g), Float(Ink.green.b))
                rect(s.x + 30, s.y + 30, 50, 50)
                fill(50, 90, 60)
                rect(ref.x + 10, ref.y + 30, 50, 50)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let want = Rect(x: s.x + 30, y: s.y + 30, w: 50, h: 50)
                return expectBounds(px.inkBounds(in: s), want, what: "矩形")
            }
        )
    }

    // MARK: A7

    private func a7ColorModeRestored() -> Check {
        Check(
            id: "A7.colormode-restored",
            title: "A7 pop() が colorMode を戻す",
            expect: "push→colorMode(HSB)→pop の後は RGB 解釈 (200,100,50)",
            draw: { [self] r in
                let (s, ref) = split(r)
                colorMode(.rgb, 255)
                push()
                colorMode(.hsb, 360, 100, 100, 100)
                pop()
                noStroke()
                fill(200, 100, 50)
                rectMode(.center)
                rect(s.cx, s.cy, 60, 60)
                swatch(ref, (r: 200, g: 100, b: 50))
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                return expectColor(px, at: s.cx, s.cy, (r: 200, g: 100, b: 50), what: "実測色")
            }
        )
    }

    // MARK: A8

    private func a8StacksAreIndependent() -> Check {
        Check(
            id: "A8.stacks-independent",
            title: "A8 スタイル/変換スタックの交差",
            expect: "pushStyle→push→pop→popStyle で赤・原点に戻る",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(s.x + 20, s.y + 20)
                fill(Float(Ink.red.r), Float(Ink.red.g), Float(Ink.red.b))
                pushStyle()
                fill(Float(Ink.blue.r), Float(Ink.blue.g), Float(Ink.blue.b))
                push()
                fill(Float(Ink.green.r), Float(Ink.green.g), Float(Ink.green.b))
                translate(70, 50)
                pop()
                popStyle()
                noStroke()
                rectMode(.corner)
                rect(0, 0, 40, 40)
                pop()
                noStroke()
                fill(90, 40, 40)
                rect(ref.x + 10, ref.y + 20, 40, 40)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let want = Rect(x: s.x + 20, y: s.y + 20, w: 40, h: 40)
                let bounds = expectBounds(px.inkBounds(in: s), want, what: "矩形")
                if bounds.isFail { return bounds }
                return expectColor(px, at: s.x + 40, s.y + 40, Ink.red, what: "色")
            }
        )
    }

    // MARK: A9

    private func a9DeepNesting() -> Check {
        Check(
            id: "A9.deep-nesting",
            title: "A9 8 段の入れ子から戻す",
            expect: "8 回 push して変換/色を変え、8 回 pop すれば元通り",
            draw: { [self] r in
                let (s, ref) = split(r)
                push()
                translate(s.x + 20, s.y + 20)
                fill(Float(Ink.amber.r), Float(Ink.amber.g), Float(Ink.amber.b))
                strokeWeight(2)
                for i in 0..<8 {
                    push()
                    translate(Float(i) * 7, Float(i) * 3)
                    rotate(Float(i) * 0.1)
                    scale(1.0 + Float(i) * 0.1)
                    fill(Float(20 * i), 255 - Float(20 * i), 128)
                    strokeWeight(Float(i) + 1)
                }
                for _ in 0..<8 { pop() }
                noStroke()
                rectMode(.corner)
                rect(0, 0, 40, 40)
                pop()
                noStroke()
                fill(90, 60, 20)
                rect(ref.x + 10, ref.y + 20, 40, 40)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let want = Rect(x: s.x + 20, y: s.y + 20, w: 40, h: 40)
                let bounds = expectBounds(px.inkBounds(in: s), want, what: "矩形")
                if bounds.isFail { return bounds }
                return expectColor(px, at: s.x + 40, s.y + 40, Ink.amber, what: "色")
            }
        )
    }
}
