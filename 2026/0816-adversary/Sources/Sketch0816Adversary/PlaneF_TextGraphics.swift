import metaphor

// 面 F — テキスト計量とオフスクリーン
//
// textWidth() は「現在のフォント設定での文字列の幅」を返すと約束している。その値と、
// 実際に描いた文字の外接矩形が食い違えば、レイアウトを組む側は必ず破綻する。
// textAlign も「どの点を基準に置くか」の約束なので、返り値ではなく実位置で確かめる。
// createGraphics() は Processing では独立した状態を持つ (親の fill を継承しない)。

extension Sketch0816Adversary {

    func planeFTextGraphics() -> Plane {
        Plane(key: "F", title: "テキスト計量とオフスクリーン", checks: [
            f1TextWidthMatchesInk(),
            f2AlignCenter(),
            f3AlignRight(),
            f4AlignTop(),
            f5TextSizeScales(),
            f6TextBoxWrap(),
            f7GraphicsStyleIsolation(),
            f8GraphicsImagePlacement(),
            f9ImageModeCenter(),
            f10TextLeadingUnit(),
            f11TextBoxOrientation(),
        ])
    }

    /// F8/F9 が共有するオフスクリーンバッファ。
    private func buffer() -> Graphics? {
        if offscreen == nil { offscreen = createGraphics(100, 60) }
        return offscreen
    }

    /// F7 専用のバッファ (他の検査が描き換えないので、単独の挙動を見られる)。
    private func soloBuffer() -> Graphics? {
        if offscreenSolo == nil { offscreenSolo = createGraphics(100, 60) }
        return offscreenSolo
    }

    private static let sample = "HAMBURGE"

    // MARK: F1

    private func f1TextWidthMatchesInk() -> Check {
        Check(
            id: "F1.textwidth-matches-ink",
            title: "F1 textWidth() と実描画幅",
            expect: "返り値と実際に描かれた文字列の幅が一致する",
            draw: { [self] r in
                let (s, ref) = split(r)
                textSize(26)
                textAlign(.left, .baseline)
                scratch["F1.w"] = textWidth(Self.sample)
                noStroke()
                fill(Float(Ink.white.r), Float(Ink.white.g), Float(Ink.white.b))
                text(Self.sample, s.x + 10, s.cy + 8)
                // 見本: 返り値の幅ちょうどの帯
                fill(60, 70, 84)
                rectMode(.corner)
                rect(ref.x + 6, ref.cy - 4, min(scratch["F1.w"] ?? 0, ref.w - 12), 8)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                guard let b = px.inkBounds(in: s) else { return .fail("文字が描かれていない") }
                let w = scratch["F1.w"] ?? 0
                let d = abs(b.w - w)
                if d <= 6 { return .pass("textWidth=\(r1(w)) ink幅=\(r1(b.w))") }
                return .fail("textWidth=\(r1(w)) ink幅=\(r1(b.w)) 差\(r1(d))px")
            }
        )
    }

    // MARK: F2

    private func f2AlignCenter() -> Check {
        Check(
            id: "F2.align-center",
            title: "F2 textAlign(.center)",
            expect: "指定した x が文字列の中心になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                textSize(22)
                textAlign(.center, .baseline)
                noStroke()
                fill(Float(Ink.white.r), Float(Ink.white.g), Float(Ink.white.b))
                text(Self.sample, s.cx, s.cy + 8)
                // 基準線
                stroke(Float(Ink.violet.r), Float(Ink.violet.g), Float(Ink.violet.b), 120)
                strokeWeight(1)
                line(s.cx, s.y + 6, s.cx, s.bottom - 6)
                noStroke()
                fill(60, 70, 84)
                rectMode(.center)
                rect(ref.cx, ref.cy, 60, 8)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                // 基準線を除いた上半分だけを読む (線と文字が混ざらないよう文字帯だけ見る)
                let band = Rect(x: s.x, y: s.cy - 18, w: s.w, h: 26)
                guard let b = px.inkBounds(in: band) else { return .fail("文字が描かれていない") }
                return expectValue(b.cx, s.cx, tol: 5, what: "文字の中心x", unit: "px")
            }
        )
    }

    // MARK: F3

    private func f3AlignRight() -> Check {
        Check(
            id: "F3.align-right",
            title: "F3 textAlign(.right)",
            expect: "指定した x が文字列の右端になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                let anchor = s.right - 24
                textSize(22)
                textAlign(.right, .baseline)
                noStroke()
                fill(Float(Ink.white.r), Float(Ink.white.g), Float(Ink.white.b))
                text(Self.sample, anchor, s.cy + 8)
                noStroke()
                fill(60, 70, 84)
                rectMode(.corner)
                rect(ref.right - 6 - 60, ref.cy - 4, 60, 8)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let anchor = s.right - 24
                let band = Rect(x: s.x, y: s.cy - 18, w: s.w, h: 26)
                guard let b = px.inkBounds(in: band) else { return .fail("文字が描かれていない") }
                return expectValue(b.right, anchor, tol: 6, what: "文字の右端", unit: "px")
            }
        )
    }

    // MARK: F4

    private func f4AlignTop() -> Check {
        Check(
            id: "F4.align-top",
            title: "F4 textAlign(_, .top)",
            expect: "指定した y が文字の上端になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                let anchor = s.y + 30
                textSize(22)
                textAlign(.left, .top)
                noStroke()
                fill(Float(Ink.white.r), Float(Ink.white.g), Float(Ink.white.b))
                text(Self.sample, s.x + 20, anchor)
                noStroke()
                fill(60, 70, 84)
                rectMode(.corner)
                rect(ref.x + 6, ref.y + 30, 60, 8)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let anchor = s.y + 30
                guard let b = px.inkBounds(in: s) else { return .fail("文字が描かれていない") }
                // 大文字の上端とフォントの上端には差があるので緩めに見る
                return expectValue(b.y, anchor, tol: 10, what: "文字の上端", unit: "px")
            }
        )
    }

    // MARK: F5

    private func f5TextSizeScales() -> Check {
        Check(
            id: "F5.textsize-scales",
            title: "F5 textSize を 2 倍",
            expect: "textWidth も実描画幅もほぼ 2 倍になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                textAlign(.left, .baseline)
                textSize(14)
                scratch["F5.w1"] = textWidth(Self.sample)
                noStroke()
                fill(Float(Ink.white.r), Float(Ink.white.g), Float(Ink.white.b))
                text(Self.sample, s.x + 10, s.y + 34)
                textSize(28)
                scratch["F5.w2"] = textWidth(Self.sample)
                text(Self.sample, s.x + 10, s.y + 78)
                noStroke()
                fill(60, 70, 84)
                rectMode(.corner)
                rect(ref.x + 6, ref.y + 30, 30, 6)
                rect(ref.x + 6, ref.y + 60, 60, 6)
            },
            verify: { [self] _, _ in
                let w1 = scratch["F5.w1"] ?? 0
                let w2 = scratch["F5.w2"] ?? 0
                guard w1 > 0 else { return .fail("textWidth が 0") }
                let ratio = w2 / w1
                return expectValue(ratio, 2, tol: 0.1, what: "幅の比", unit: "倍")
            }
        )
    }

    // MARK: F6

    private func f6TextBoxWrap() -> Check {
        Check(
            id: "F6.textbox-wrap",
            title: "F6 text(str,x,y,w,h) の折り返し",
            expect: "箱の幅で折り返して複数行になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                textSize(14)
                textAlign(.left, .top)
                // textLeading は既定のまま (指定すると F10 の問題に巻き込まれる)
                noStroke()
                fill(Float(Ink.white.r), Float(Ink.white.g), Float(Ink.white.b))
                text("wrap this sentence into several lines", s.x + 10, s.y + 10, 120, 100)
                noFill()
                stroke(60, 70, 84)
                strokeWeight(1)
                rectMode(.corner)
                rect(ref.x + 6, ref.y + 10, 60, 60)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                guard let b = px.inkBounds(in: s) else { return .fail("文字が描かれていない") }
                // 折り返していれば箱の幅に収まり、高さは 1 行 (約 16px) より明確に大きい
                let wrapped = b.w <= 130 && b.h > 26
                if wrapped { return .pass("\(r0(b.w))×\(r0(b.h)) = 複数行") }
                return .fail("\(r0(b.w))×\(r0(b.h)) 折り返していない (幅 120 の箱を指定)")
            }
        )
    }

    // MARK: F7

    private func f7GraphicsStyleIsolation() -> Check {
        Check(
            id: "F7.graphics-style-isolation",
            title: "F7 createGraphics のスタイル独立",
            expect: "親の fill(赤) を継承せず、pg 既定の白で描かれる",
            draw: { [self] r in
                let (s, ref) = split(r)
                guard let pg = soloBuffer() else { return }
                // 親側で赤を設定してからオフスクリーンへ入る
                fill(Float(Ink.red.r), Float(Ink.red.g), Float(Ink.red.b))
                pg.beginDraw()
                pg.background(20, 24, 30)
                pg.noStroke()
                pg.rectMode(.corner)
                pg.rect(20, 10, 60, 40)
                pg.endDraw()
                imageMode(.corner)
                noTint()
                image(pg, s.x + 20, s.y + 20)
                noStroke()
                fill(Float(Ink.white.r), Float(Ink.white.g), Float(Ink.white.b))
                rectMode(.corner)
                rect(ref.x + 6, ref.y + 30, 40, 30)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                // pg 内の矩形は (20,10) から 60×40。貼り付け位置を足した中心を読む。
                let c = px.rgb(s.x + 20 + 50, s.y + 20 + 30)
                let isRed = abs(c.r - Ink.red.r) + abs(c.g - Ink.red.g) + abs(c.b - Ink.red.b) < 90
                let isWhite = c.r > 200 && c.g > 200 && c.b > 200
                if isWhite { return .pass("pg 既定の白 rgb(\(c.r),\(c.g),\(c.b))") }
                if isRed { return .fail("親の fill(赤) を継承した rgb(\(c.r),\(c.g),\(c.b))") }
                return .visual("pg 既定色 rgb(\(c.r),\(c.g),\(c.b))")
            }
        )
    }

    // MARK: F8

    private func f8GraphicsImagePlacement() -> Check {
        Check(
            id: "F8.graphics-placement",
            title: "F8 image(pg,x,y) の位置とサイズ",
            expect: "100×60 のバッファが指定位置に等倍で貼られる",
            draw: { [self] r in
                let (s, ref) = split(r)
                guard let pg = buffer() else { return }
                pg.beginDraw()
                pg.background(Float(Ink.blue.r), Float(Ink.blue.g), Float(Ink.blue.b))
                pg.endDraw()
                imageMode(.corner)
                noTint()
                image(pg, s.x + 20, s.y + 20)
                noStroke()
                fill(40, 60, 90)
                rectMode(.corner)
                rect(ref.x + 6, ref.y + 20, 50, 30)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let want = Rect(x: s.x + 20, y: s.y + 20, w: 100, h: 60)
                let placed = expectBounds(px.inkBounds(in: s), want, tol: 3, what: "貼付")
                if placed.isFail { return placed }
                // 位置だけでなく中身も見る。ここが緑 (= F9 が後から書いた色) なら、
                // 同一フレーム内で 1 枚の Graphics を描き換えて複数回貼ると
                // すべてが最後の内容になってしまう、ということ。
                let c = px.rgb(s.x + 70, s.y + 50)
                let isBlue = abs(c.r - Ink.blue.r) + abs(c.g - Ink.blue.g) + abs(c.b - Ink.blue.b) < 90
                if isBlue { return .pass("\(placed.detail) 色=青") }
                return .fail("貼付は正しいが色 rgb(\(c.r),\(c.g),\(c.b)) 期待 青 — 後続の描き換えが遡って効いている")
            }
        )
    }

    // MARK: F9

    private func f9ImageModeCenter() -> Check {
        Check(
            id: "F9.imagemode-center",
            title: "F9 imageMode(.center)",
            expect: "指定座標がバッファの中心になる",
            draw: { [self] r in
                let (s, ref) = split(r)
                guard let pg = buffer() else { return }
                pg.beginDraw()
                pg.background(Float(Ink.green.r), Float(Ink.green.g), Float(Ink.green.b))
                pg.endDraw()
                imageMode(.center)
                noTint()
                image(pg, s.cx, s.cy)
                imageMode(.corner)
                noStroke()
                fill(50, 80, 60)
                rectMode(.center)
                rect(ref.cx, ref.cy, 50, 30)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let want = Rect(x: s.cx - 50, y: s.cy - 30, w: 100, h: 60)
                return expectBounds(px.inkBounds(in: s), want, tol: 3, what: "貼付")
            }
        )
    }

    // MARK: F10

    private func f10TextLeadingUnit() -> Check {
        Check(
            id: "F10.textleading-unit",
            title: "F10 改行文字の扱い",
            expect: "Processing の text() は \\n で改行する (箱版が折り返さない今、唯一の複数行手段)",
            draw: { [self] r in
                let (s, ref) = split(r)
                textSize(14)
                textAlign(.left, .top)
                textLeading(30)
                noStroke()
                fill(Float(Ink.white.r), Float(Ink.white.g), Float(Ink.white.b))
                scratch["F10.wAA"] = textWidth("AA")
                scratch["F10.wAABB"] = textWidth("AABB")
                text("AA\nBB", s.x + 16, s.y + 10)
                textLeading(14)
                noStroke()
                fill(60, 70, 84)
                rectMode(.corner)
                rect(ref.x + 6, ref.y + 10, 24, 12)
                rect(ref.x + 6, ref.y + 40, 24, 12)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                guard let b = px.inkBounds(in: s) else { return .fail("文字が描かれていない") }
                let wAA = scratch["F10.wAA"] ?? 0
                let wAABB = scratch["F10.wAABB"] ?? 0
                if b.h > 20 {
                    return .pass("2 行 \(r0(b.w))×\(r0(b.h))px")
                }
                // 1 行で出た。幅が "AABB" 相当なら改行が捨てられて連結されたということ。
                if abs(b.w - wAABB) < abs(b.w - wAA) {
                    return .fail("1 行 \(r0(b.w))px ≈ textWidth(\"AABB\")=\(r1(wAABB)) — \\n が捨てられて連結された")
                }
                return .fail("1 行 \(r0(b.w))px ≈ textWidth(\"AA\")=\(r1(wAA)) — 2 行目が描かれない")
            }
        )
    }

    // MARK: F11

    private func f11TextBoxOrientation() -> Check {
        Check(
            id: "F11.textbox-orientation",
            title: "F11 箱版テキストの上下",
            expect: "text(x,y,w,h) は text(x,y) と同じ向きで描かれる",
            draw: { [self] r in
                let (s, ref) = split(r)
                textSize(24)
                textAlign(.left, .top)
                noStroke()
                fill(Float(Ink.white.r), Float(Ink.white.g), Float(Ink.white.b))
                // 上下非対称な字面 ("A" は上、"g" の下降部は下) を 2 つの API で描き比べる
                text("Ag", s.x + 16, s.y + 8)
                text("Ag", s.x + 16, s.y + 58, 60, 40)
                noStroke()
                fill(60, 70, 84)
                rectMode(.corner)
                rect(ref.x + 6, ref.y + 10, 30, 10)
                rect(ref.x + 6, ref.y + 60, 30, 10)
            },
            verify: { [self] r, px in
                let (s, _) = split(r)
                let plain = px.inkRowProfile(in: Rect(x: s.x, y: s.y + 4, w: 120, h: 46))
                let boxed = px.inkRowProfile(in: Rect(x: s.x, y: s.y + 54, w: 120, h: 46))
                guard plain.count >= 3 else { return .fail("3 引数版が描かれていない") }
                guard boxed.count >= 3 else { return .fail("5 引数版が描かれていない") }
                // 行ごとの ink 量の形を、そのままと上下反転で比べる
                let same = profileCorrelation(plain, boxed)
                let flipped = profileCorrelation(plain, boxed.reversed())
                if same >= flipped {
                    return .pass("同じ向き (相関 \(r1(same * 100))% > 反転 \(r1(flipped * 100))%)")
                }
                return .fail("反転の相関 \(r1(flipped * 100))% > 同じ向き \(r1(same * 100))% — 箱版が上下反転して描かれている")
            }
        )
    }
}
