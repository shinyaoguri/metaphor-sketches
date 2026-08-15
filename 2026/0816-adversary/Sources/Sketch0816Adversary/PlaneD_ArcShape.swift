import metaphor

// 面 D — arc とカスタムシェイプ
//
// Processing の arc() は角度をかなり細かく規定している:
//   stop <= start        … 何も描かない
//   stop - start > TWO_PI … 全円にクランプ
// ArcMode ごとの「fill の閉じ方」と「stroke の閉じ方」も metaphor 側の doc に明記がある
// (.default = fill は扇形 / stroke は弧のみ、.pie = stroke も中心へ閉じる、など)。
// カスタムシェイプ側は .points / .lines がどの色で描かれるか (fill か stroke か) を突く。

extension Sketch0816Adversary {

    func planeDArcShape() -> Plane {
        Plane(key: "D", title: "arc とカスタムシェイプ", checks: [
            d1ArcStopBeforeStart(),
            d2ArcBeyondTwoPi(),
            d3ArcPieStroke(),
            d4ArcChordStroke(),
            d5ShapePointsColor(),
            d6ShapeLinesColor(),
            d7EndShapeClose(),
            d8Contour(),
            d9DegenerateShapes(),
        ])
    }

    // MARK: D1

    private func d1ArcStopBeforeStart() -> Check {
        Check(
            id: "D1.arc-stop-before-start",
            title: "D1 arc(stop < start)",
            expect: "Processing は stop <= start のとき何も描かない",
            draw: { [self] r in
                let (s, ref) = split(r)
                noStroke()
                fill(Float(Ink.red.r), Float(Ink.red.g), Float(Ink.red.b))
                ellipseMode(.center)
                // 逆転した角度 (start > stop)
                arc(s.cx, s.cy, 90, 90, Float.pi, Float.pi * 0.25)
                noFill()
                stroke(60, 70, 84)
                strokeWeight(1)
                ellipse(ref.cx, ref.cy, 60, 60)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let n = px.inkCount(in: s)
                if n == 0 { return .pass("描かれた画素 0 (Processing 互換)") }
                return .fail("stop<start でも \(n)px 描かれた (Processing は描かない)")
            }
        )
    }

    // MARK: D2

    private func d2ArcBeyondTwoPi() -> Check {
        Check(
            id: "D2.arc-beyond-two-pi",
            title: "D2 arc(範囲 > 2π)",
            expect: "2π 超は全円にクランプされる。半透明なら濃さが一様のはず",
            draw: { [self] r in
                let (s, ref) = split(r)
                noStroke()
                // 半透明で描く。クランプせず巻き付けて描いていれば、周回数の多い角度だけ濃くなる。
                fill(Float(Ink.blue.r), Float(Ink.blue.g), Float(Ink.blue.b), 90)
                ellipseMode(.center)
                arc(s.cx, s.cy, 90, 90, 0, Float.pi * 5)
                noStroke()
                fill(60, 70, 84)
                circle(ref.cx, ref.cy, 60)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                guard let b = px.inkBounds(in: s) else { return .fail("何も描かれていない") }
                let sized = abs(b.w - 90) <= 4 && abs(b.h - 90) <= 4
                // 3 周ぶん重なる角度 (0.5rad) と 2 周ぶんの角度 (4.0rad) を比べる
                let p1 = (x: s.cx + 28 * cos(Float(0.5)), y: s.cy + 28 * sin(Float(0.5)))
                let p2 = (x: s.cx + 28 * cos(Float(4.0)), y: s.cy + 28 * sin(Float(4.0)))
                let c1 = px.rgb(p1.x, p1.y)
                let c2 = px.rgb(p2.x, p2.y)
                let diff = abs(c1.r - c2.r) + abs(c1.g - c2.g) + abs(c1.b - c2.b)
                if !sized { return .fail("外接=\(r0(b.w))×\(r0(b.h)) 期待 90×90") }
                if diff <= 12 { return .pass("全円・濃さ一様 (差\(diff))") }
                return .fail("角度で濃さが違う rgb(\(c1.r),\(c1.g),\(c1.b)) vs rgb(\(c2.r),\(c2.g),\(c2.b)) = 2π でクランプせず重ね描き")
            }
        )
    }

    // MARK: D3

    private func d3ArcPieStroke() -> Check {
        Check(
            id: "D3.arc-pie-stroke",
            title: "D3 ArcMode .pie の stroke",
            expect: ".pie は端点から中心へ線を引いてパイ形に閉じる",
            draw: { [self] r in
                let (s, ref) = split(r)
                noFill()
                stroke(Float(Ink.violet.r), Float(Ink.violet.g), Float(Ink.violet.b))
                strokeWeight(2)
                ellipseMode(.center)
                // 0 → π/2 の 1/4 円。中心へ閉じるなら中心の右と下に半径線が出る
                arc(s.cx, s.cy, 100, 100, 0, Float.pi / 2, .pie)
                noFill()
                stroke(70, 50, 90)
                arc(ref.cx, ref.cy, 60, 60, 0, Float.pi / 2, .pie)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                // 中心から右へ 25px の位置 (半径線の上) に線があるか
                let onRadius = (0..<6).contains { dy in
                    px.isInk(Int(s.cx + 25), Int(s.cy) + dy - 3)
                }
                if onRadius { return .pass("中心へ閉じる半径線あり") }
                return .fail("中心へ閉じる半径線が無い")
            }
        )
    }

    // MARK: D4

    private func d4ArcChordStroke() -> Check {
        Check(
            id: "D4.arc-chord-stroke",
            title: "D4 ArcMode .chord の stroke",
            expect: ".chord は端点どうしを弦で結び、中心へは閉じない",
            draw: { [self] r in
                let (s, ref) = split(r)
                noFill()
                stroke(Float(Ink.green.r), Float(Ink.green.g), Float(Ink.green.b))
                strokeWeight(2)
                ellipseMode(.center)
                arc(s.cx, s.cy, 100, 100, 0, Float.pi / 2, .chord)
                noFill()
                stroke(50, 80, 60)
                arc(ref.cx, ref.cy, 60, 60, 0, Float.pi / 2, .chord)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                // 弦は (cx+50, cy) と (cx, cy+50) を結ぶ線。その中点付近 (cx+25, cy+25) に線がある。
                let onChord = (-3...3).contains { d in
                    px.isInk(Int(s.cx + 25) + d, Int(s.cy + 25))
                }
                // 中心へ閉じる線は無いはず (中心のすぐ右は空)
                let noRadius = !(-2...2).contains { d in
                    px.isInk(Int(s.cx + 12), Int(s.cy) + d)
                }
                if onChord && noRadius { return .pass("弦あり・半径線なし") }
                return .fail("弦=\(onChord) 半径線なし=\(noRadius)")
            }
        )
    }

    // MARK: D5

    private func d5ShapePointsColor() -> Check {
        Check(
            id: "D5.shape-points-color",
            title: "D5 beginShape(.points) の色",
            expect: "点は stroke 色で描かれる (fill 色ではない)",
            draw: { [self] r in
                let (s, ref) = split(r)
                fill(Float(Ink.red.r), Float(Ink.red.g), Float(Ink.red.b))
                stroke(Float(Ink.violet.r), Float(Ink.violet.g), Float(Ink.violet.b))
                strokeWeight(10)
                beginShape(.points)
                vertex(s.x + 40, s.cy)
                vertex(s.x + 80, s.cy)
                vertex(s.x + 120, s.cy)
                endShape()
                stroke(70, 50, 90)
                strokeWeight(10)
                point(ref.cx, ref.cy)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                guard px.inkCount(in: s) > 0 else { return .fail("点が描かれていない") }
                let c = px.rgb(s.x + 40, s.cy)
                let isStroke = abs(c.r - Ink.violet.r) + abs(c.g - Ink.violet.g) + abs(c.b - Ink.violet.b) < 90
                let isFill = abs(c.r - Ink.red.r) + abs(c.g - Ink.red.g) + abs(c.b - Ink.red.b) < 90
                if isStroke { return .pass("stroke 色 rgb(\(c.r),\(c.g),\(c.b))") }
                if isFill { return .fail("fill 色 rgb(\(c.r),\(c.g),\(c.b)) で描かれた 期待 stroke 色") }
                return .fail("想定外の色 rgb(\(c.r),\(c.g),\(c.b))")
            }
        )
    }

    // MARK: D6

    private func d6ShapeLinesColor() -> Check {
        Check(
            id: "D6.shape-lines-color",
            title: "D6 beginShape(.lines) の色",
            expect: "線分は stroke 色で描かれる (fill 色ではない)",
            draw: { [self] r in
                let (s, ref) = split(r)
                fill(Float(Ink.red.r), Float(Ink.red.g), Float(Ink.red.b))
                stroke(Float(Ink.blue.r), Float(Ink.blue.g), Float(Ink.blue.b))
                strokeWeight(6)
                beginShape(.lines)
                vertex(s.x + 30, s.y + 30)
                vertex(s.x + 130, s.y + 30)
                vertex(s.x + 30, s.y + 70)
                vertex(s.x + 130, s.y + 70)
                endShape()
                stroke(40, 60, 90)
                strokeWeight(6)
                line(ref.x + 6, ref.cy, ref.right - 6, ref.cy)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                guard px.inkCount(in: s) > 0 else { return .fail("線が描かれていない") }
                let c = px.rgb(s.x + 80, s.y + 30)
                let isStroke = abs(c.r - Ink.blue.r) + abs(c.g - Ink.blue.g) + abs(c.b - Ink.blue.b) < 90
                let isFill = abs(c.r - Ink.red.r) + abs(c.g - Ink.red.g) + abs(c.b - Ink.red.b) < 90
                if isStroke { return .pass("stroke 色 rgb(\(c.r),\(c.g),\(c.b))") }
                if isFill { return .fail("fill 色 rgb(\(c.r),\(c.g),\(c.b)) で描かれた 期待 stroke 色") }
                return .fail("想定外の色 rgb(\(c.r),\(c.g),\(c.b))")
            }
        )
    }

    // MARK: D7

    private func d7EndShapeClose() -> Check {
        Check(
            id: "D7.endshape-close",
            title: "D7 endShape(.close) が閉じる",
            expect: "最後の頂点と最初の頂点が線で結ばれる",
            draw: { [self] r in
                let (s, ref) = split(r)
                noFill()
                stroke(Float(Ink.amber.r), Float(Ink.amber.g), Float(Ink.amber.b))
                strokeWeight(3)
                // 逆 V 字。close すれば底辺 (最初と最後を結ぶ線) が現れる
                beginShape()
                vertex(s.x + 30, s.y + 90)
                vertex(s.x + 80, s.y + 20)
                vertex(s.x + 130, s.y + 90)
                endShape(.close)
                noFill()
                stroke(80, 60, 30)
                strokeWeight(3)
                triangle(ref.x + 8, ref.y + 80, ref.cx, ref.y + 25, ref.right - 8, ref.y + 80)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                // 底辺の中点 (s.x+80, s.y+90) に線があれば閉じている
                let closed = (-3...3).contains { d in
                    px.isInk(Int(s.x + 80), Int(s.y + 90) + d)
                }
                if closed { return .pass("底辺あり = 閉じている") }
                return .fail("最初と最後を結ぶ線が無い")
            }
        )
    }

    // MARK: D8

    private func d8Contour() -> Check {
        Check(
            id: "D8.contour-hole",
            title: "D8 beginContour() の穴",
            expect: "外周と逆向きに巻いた内周が穴になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                noStroke()
                fill(Float(Ink.green.r), Float(Ink.green.g), Float(Ink.green.b))
                beginShape()
                vertex(s.cx - 60, s.cy - 45)
                vertex(s.cx + 60, s.cy - 45)
                vertex(s.cx + 60, s.cy + 45)
                vertex(s.cx - 60, s.cy + 45)
                beginContour()
                // 外周と逆向き (反時計回り) に巻く
                vertex(s.cx - 25, s.cy - 20)
                vertex(s.cx - 25, s.cy + 20)
                vertex(s.cx + 25, s.cy + 20)
                vertex(s.cx + 25, s.cy - 20)
                endContour()
                endShape(.close)
                noStroke()
                fill(50, 80, 60)
                rectMode(.center)
                rect(ref.cx, ref.cy, 70, 50)
                fill(Float(Self.bg.r), Float(Self.bg.g), Float(Self.bg.b))
                rect(ref.cx, ref.cy, 30, 22)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let holeEmpty = !px.isInk(Int(s.cx), Int(s.cy))
                let ringFilled = px.isInk(Int(s.cx), Int(s.cy - 35))
                if holeEmpty && ringFilled { return .pass("穴あり・外周あり") }
                return .fail("中心が空=\(holeEmpty) 外周あり=\(ringFilled)")
            }
        )
    }

    // MARK: D9

    private func d9DegenerateShapes() -> Check {
        Check(
            id: "D9.degenerate-shapes",
            title: "D9 頂点 0/1/2 個のシェイプ",
            expect: "面を張れない頂点数でも落ちず、塗りは出ない",
            draw: { [self] r in
                let (s, ref) = split(r)
                noStroke()
                fill(Float(Ink.red.r), Float(Ink.red.g), Float(Ink.red.b))
                beginShape()
                endShape(.close)
                beginShape()
                vertex(s.x + 40, s.cy)
                endShape(.close)
                beginShape()
                vertex(s.x + 70, s.cy - 20)
                vertex(s.x + 120, s.cy + 20)
                endShape(.close)
                noFill()
                stroke(60, 70, 84)
                strokeWeight(1)
                rectMode(.corner)
                rect(ref.x + 6, ref.y + 30, 40, 40)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let n = px.inkCount(in: s)
                if n == 0 { return .pass("塗りは出ない (落ちない)") }
                return .visual("退化シェイプが \(n)px 描かれた")
            }
        )
    }
}
