import Foundation
import metaphor

// 層 B — **描画パイプラインを通過した後の色**を測る。この作品の主題。
//
// 層 A（`Palette.swift`）が測るのは `Color` 型の中の数値で、画面には一度も出ていない。
// 「指定した色が実際にその色のピクセルになるか」は別の問いで、colorMode のスケール解釈・
// ブレンド・ティントはすべてこちら側にある。
//
// 測り方: `createGraphics` のオフスクリーンに描き、`endDraw(wait: true)` で GPU の完了を
// 待ってから `toImage()` → `loadPixels()` → `get(x, y)`。**本編の絵を汚さずに**読み戻せる。
//
// `Graphics` は Sketch API のサブセットで、`linearGradient` / `radialGradient` /
// `pushStyle` を持たない。それらは本編キャンバスに描いて `previousFrame()` で読む必要が
// あるのでフレームを跨ぐ。`Runtime.swift`（層 C）が担当する。

@MainActor
enum Spectrometer {
    /// 検査用オフスクリーンの一辺。読み取り点をアンチエイリアスから離せる程度に取る。
    private static let side = 64
    /// 描く矩形。四隅から離れた内側に置き、中心 (32, 32) を読む。
    private static let box: (x: Float, y: Float, w: Float, h: Float) = (16, 16, 32, 32)
    private static let probePoint = (x: 32, y: 32)

    static func runAll(_ s: Sketch0816Prism) -> [Verdict] {
        guard let g = s.createGraphics(side, side) else {
            return [Verdict(id: "B0.geometry", passed: false,
                detail: "createGraphics(\(side), \(side)) が nil を返した。層 B は全件測れない")]
        }
        var out: [Verdict] = []
        out += geometry(g)
        out += colorModes(g)
        out += blending(g)
        out += tinting(s, g)
        return out
    }

    // MARK: - B0: 読み戻しの座標系

    /// 何を測るにも、まず「読んだ座標が描いた座標と同じか」を確定させる。
    ///
    /// ここを仮定のまま進めると、上下が反転しているだけの結果を「色が違う」と誤読する。
    /// 左上だけを赤くした非対称な板を焼いて、どちらの隅に赤が出るかで向きを決める。
    static func geometry(_ g: Graphics) -> [Verdict] {
        let plate = expose(g) { c in
            c.background(Color.black)
            c.noStroke()
            c.fill(Color.red)
            c.rect(0, 0, Float(side) / 2, Float(side) / 2)   // 描画座標の左上 1/4
        }
        let topLeft = plate.at(8, 8)
        let bottomLeft = plate.at(8, side - 8)
        let isRed: (Color) -> Bool = { $0.r > 0.5 && $0.g < 0.2 && $0.b < 0.2 }
        let upright = isRed(topLeft) && !isRed(bottomLeft)
        let flipped = isRed(bottomLeft) && !isRed(topLeft)

        return [Verdict(id: "B0.geometry", passed: upright,
            detail: "左上 1/4 を赤く焼いた板: get(8,8)=\(Hue.s(rgb(topLeft))) / get(8,\(side - 8))=\(Hue.s(rgb(bottomLeft)))"
                + " → \(upright ? "描画座標と一致（上が上）" : flipped ? "上下反転している" : "どちらの隅にも赤が無い")")]
    }

    // MARK: - B1〜B6: カラーモード

    static func colorModes(_ g: Graphics) -> [Verdict] {
        var out: [Verdict] = []

        // B1: 既定のスケール。テンプレートが `fill(230, 64, 38)` と書く以上 0…255 のはずだが、
        //     ここを実測しておかないと以降の「スケールを変えたら」の比較対象が無い。
        do {
            let plate = expose(g) { c in
                c.background(Color.black)
                c.noStroke()
                c.fill(255, 0, 0)
                c.rect(box.x, box.y, box.w, box.h)
            }
            let got = plate.at(probePoint.x, probePoint.y)
            let ok = Hue.rgbEq(rgb(got), (1, 0, 0), Hue.quantized)
            out.append(Verdict(id: "B1.defaultScale", passed: ok,
                detail: "colorMode 未設定で fill(255,0,0) → \(Hue.s(rgb(got))) 期待=(1,0,0)（既定は Processing 風 0…255）"))
        }

        // B2: 正規化モード。`colorMode(.rgb, 1)` にすると 0…1 で書けるか。
        do {
            let plate = expose(g) { c in
                c.colorMode(.rgb, 1)
                c.background(Color.black)
                c.noStroke()
                c.fill(1, 0, 0)
                c.rect(box.x, box.y, box.w, box.h)
            }
            let got = plate.at(probePoint.x, probePoint.y)
            let ok = Hue.rgbEq(rgb(got), (1, 0, 0), Hue.quantized)
            out.append(Verdict(id: "B2.normalizedScale", passed: ok,
                detail: "colorMode(.rgb, 1) で fill(1,0,0) → \(Hue.s(rgb(got))) 期待=(1,0,0)"))
        }

        // B3: HSB モード。Processing 流の 360 / 100 / 100 で三原色が出るか。
        do {
            var samples: [(String, Color)] = []
            for (name, hue) in [("赤", Float(0)), ("緑", Float(120)), ("青", Float(240))] {
                let plate = expose(g) { c in
                    c.colorMode(.hsb, 360, 100, 100, 100)
                    c.background(Color.black)
                    c.noStroke()
                    c.fill(hue, 100, 100)
                    c.rect(box.x, box.y, box.w, box.h)
                }
                samples.append((name, plate.at(probePoint.x, probePoint.y)))
            }
            let wants: [(Float, Float, Float)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]
            let ok = zip(samples, wants).allSatisfy { Hue.rgbEq(rgb($0.0.1), $0.1, Hue.quantized) }
            let shown = zip(samples, wants).map { "\($0.0.0) → \(Hue.s(rgb($0.0.1)))期待\(Hue.s($0.1))" }.joined(separator: " / ")
            out.append(Verdict(id: "B3.hsbScale", passed: ok,
                detail: "colorMode(.hsb, 360,100,100) で h=0/120/240: \(shown)"))
        }

        // B4: **このリポジトリの CLAUDE.md が挙げている既知の地雷を正面から測る。**
        //     `fill(0–255)` と `Color`（0…1 正規化）が同一スケッチ内で混在する、という注意書きの
        //     裏側にある問い: colorMode を変えたとき `Color` 直渡しはどう扱われるのか。
        //     `Color` は型として 0…1 と決まっているので、colorMode に関係なくそのまま出るべき。
        //     HSB モードで再解釈されるなら、緑を渡したのに別の色が出る形で表に出る。
        do {
            let plate = expose(g) { c in
                c.colorMode(.hsb, 360, 100, 100, 100)   // 極端なスケールにしておく
                c.background(Color.black)
                c.noStroke()
                c.fill(Color.green)                     // 型で 0…1 と決まっている値
                c.rect(box.x, box.y, box.w, box.h)
            }
            let got = plate.at(probePoint.x, probePoint.y)
            let ok = Hue.rgbEq(rgb(got), (0, 1, 0), Hue.quantized)
            out.append(Verdict(id: "B4.colorLiteralUnaffected", passed: ok,
                detail: "colorMode(.hsb,360,100,100) のまま fill(Color.green) → \(Hue.s(rgb(got))) 期待=(0,1,0)"
                    + " / Color は型として 0…1 なので colorMode に影響されないはず"))
        }

        // B5: グレースケール指定が maxAll に追従するか。
        //     `fill(_ gray:)` は 1 引数なので、どのチャンネルの最大値を見るかが実装依存になりうる。
        do {
            let plate255 = expose(g) { c in
                c.colorMode(.rgb, 255)
                c.background(Color.black)
                c.noStroke()
                c.fill(128)
                c.rect(box.x, box.y, box.w, box.h)
            }
            let plate1 = expose(g) { c in
                c.colorMode(.rgb, 1)
                c.background(Color.black)
                c.noStroke()
                c.fill(0.5)
                c.rect(box.x, box.y, box.w, box.h)
            }
            let a = plate255.at(probePoint.x, probePoint.y)
            let b = plate1.at(probePoint.x, probePoint.y)
            let want: Float = 128.0 / 255.0
            let ok = Hue.rgbEq(rgb(a), (want, want, want), Hue.quantized)
                && Hue.rgbEq(rgb(b), (0.5, 0.5, 0.5), Hue.quantized)
            out.append(Verdict(id: "B5.grayScale", passed: ok,
                detail: "max=255 で fill(128) → \(Hue.s(rgb(a))) 期待=(0.502,0.502,0.502)"
                    + " / max=1 で fill(0.5) → \(Hue.s(rgb(b))) 期待=(0.5,0.5,0.5)"))
        }

        // B6: 状態スタック。`push()` / `pop()` は「変換とスタイル状態」を保存すると doc にあるが、
        //     colorMode がそのスタイルに含まれるかは書かれていない。**判定は復元されることを
        //     期待せず**、どちらの挙動かを実測として残す（含まれない設計も十分ありうる）。
        do {
            let plate = expose(g) { c in
                c.colorMode(.rgb, 255)
                c.background(Color.black)
                c.noStroke()
                c.push()
                c.colorMode(.rgb, 1)      // スタックの内側で切り替える
                c.pop()                   // ここで 255 に戻るか？
                c.fill(255, 0, 0)         // 戻っていれば純赤、戻っていなければ振り切れた赤
                c.rect(box.x, box.y, box.w, box.h)
            }
            let got = plate.at(probePoint.x, probePoint.y)
            let restored = Hue.rgbEq(rgb(got), (1, 0, 0), Hue.quantized)
            // どちらに転んでも「有限で読める色が出る」ことだけを必須にする。
            let finite = got.r.isFinite && got.g.isFinite && got.b.isFinite
            out.append(Verdict(id: "B6.stateStack", passed: finite,
                detail: "push → colorMode(.rgb,1) → pop の後に fill(255,0,0) → \(Hue.s(rgb(got)))"
                    + " → colorMode は \(restored ? "pop で復元される（スタイルに含まれる）" : "pop で復元されない（スタイル外）")"
                    + " / 判定は読めることのみ"))
        }

        return out
    }

    // MARK: - B7〜B10: ブレンド

    /// ブレンドの検査に使う既知の 2 色。
    ///
    /// 加算が 1.0 で飽和しないよう、成分ごとの和がすべて 1 未満になる組を選ぶ。
    /// 飽和すると「加算が効いていない」と「飽和した」の区別が付かなくなる。
    private static let dst = Color(r: 0.2, g: 0.4, b: 0.6)
    private static let src = Color(r: 0.5, g: 0.25, b: 0.1)

    static func blending(_ g: Graphics) -> [Verdict] {
        var out: [Verdict] = []

        // 期待値は成分ごとの定義式で書き下す（格納値どうしの演算と仮定）。
        let d = (dst.r, dst.g, dst.b)
        let s = (src.r, src.g, src.b)
        let expected: [(BlendMode, String, (Float, Float, Float))] = [
            (.additive, "additive", (d.0 + s.0, d.1 + s.1, d.2 + s.2)),
            (.multiply, "multiply", (d.0 * s.0, d.1 * s.1, d.2 * s.2)),
            (.screen, "screen", (1 - (1 - d.0) * (1 - s.0), 1 - (1 - d.1) * (1 - s.1), 1 - (1 - d.2) * (1 - s.2))),
            (.difference, "difference", (abs(s.0 - d.0), abs(s.1 - d.1), abs(s.2 - d.2))),
            (.exclusion, "exclusion", (s.0 + d.0 - 2 * s.0 * d.0, s.1 + d.1 - 2 * s.1 * d.1, s.2 + d.2 - 2 * s.2 * d.2)),
            (.darkest, "darkest", (min(d.0, s.0), min(d.1, s.1), min(d.2, s.2))),
            (.lightest, "lightest", (max(d.0, s.0), max(d.1, s.1), max(d.2, s.2))),
            (.opaque, "opaque", s),
        ]

        // B7: 定義式が書けるモードをまとめて当てる。
        do {
            var mismatched: [String] = []
            var matched = 0
            for (mode, name, want) in expected {
                let got = rgb(paint(g, mode))
                if Hue.rgbEq(got, want, Hue.quantized) {
                    matched += 1
                } else {
                    mismatched.append("\(name)→\(Hue.s(got))期待\(Hue.s(want))")
                }
            }
            let ok = mismatched.isEmpty
            out.append(Verdict(id: "B7.blendModes", passed: ok,
                detail: "dst=\(Hue.s(d)) src=\(Hue.s(s)) / \(matched)/\(expected.count) 件一致"
                    + (mismatched.isEmpty ? "" : " / 不一致: " + mismatched.joined(separator: " "))))
        }

        // B8: `subtract` は引く向きが doc に書かれていない（src-dst か dst-src か）。
        //     期待値を決め打ちできないので、**どちらの向きなのかを実測として残す**。
        do {
            let got = rgb(paint(g, .subtract))
            let srcMinusDst = (max(0, s.0 - d.0), max(0, s.1 - d.1), max(0, s.2 - d.2))
            let dstMinusSrc = (max(0, d.0 - s.0), max(0, d.1 - s.1), max(0, d.2 - s.2))
            let isSrcMinusDst = Hue.rgbEq(got, srcMinusDst, Hue.quantized)
            let isDstMinusSrc = Hue.rgbEq(got, dstMinusSrc, Hue.quantized)
            let finite = got.0.isFinite && got.1.isFinite && got.2.isFinite
            out.append(Verdict(id: "B8.subtractDirection", passed: finite,
                detail: "subtract → \(Hue.s(got)) / src-dst=\(Hue.s(srcMinusDst)) dst-src=\(Hue.s(dstMinusSrc))"
                    + " → \(isSrcMinusDst ? "src-dst" : isDstMinusSrc ? "dst-src" : "どちらとも一致しない")"
                    + " / 判定は読めることのみ（doc に向きの記載が無い）"))
        }

        // B9: **ブレンド後のアルファ**。不透明な src を不透明な dst に重ねたら、
        //     出てくる色も不透明であるべき。ここが抜けると RGB は正しいのに、
        //     ウィンドウ合成や Syphon 送出の段で下地が透ける — 画面だけ見て
        //     「白く抜けた」と気付く類の壊れ方をする。
        //
        //     B7 で RGB だけを見ていたときは 8/8 一致で通っていた。混色の見本を絵にして
        //     初めて 1 枚だけ白いことに気付いたので、**アルファも数値で押さえる**。
        do {
            let modes: [(BlendMode, String)] = [
                (.alpha, "alpha"), (.additive, "additive"), (.multiply, "multiply"),
                (.screen, "screen"), (.difference, "difference"), (.exclusion, "exclusion"),
                (.darkest, "darkest"), (.lightest, "lightest"), (.subtract, "subtract"),
                (.opaque, "opaque"),
            ]
            var lost: [String] = []
            for (mode, name) in modes {
                let got = paint(g, mode)
                if got.a < 0.99 { lost.append("\(name)→a=\(Approx.f(got.a, 3))") }
            }
            out.append(Verdict(id: "B9.blendAlpha", passed: lost.isEmpty,
                detail: "不透明な src(a=1) を不透明な dst(a=1) に重ねた \(modes.count) モード / "
                    + (lost.isEmpty ? "すべて a=1.000 を保った"
                                    : "アルファが落ちた: " + lost.joined(separator: " "))
                    + " 期待=すべて a=1.000"))
        }

        // B10: アルファ合成。白の上に 50% の黒を重ねたら中間になるか。
        //     **厳密な 0.5 を要求しない。** 合成がリニア空間で行われるか sRGB のガンマ空間で
        //     行われるかで答えが変わり、doc はどちらとも書いていない。中間にあることを
        //     必須にし、実測値を残して後から色空間を判断できるようにする。
        do {
            let plate = expose(g) { c in
                c.blendMode(.opaque)
                c.background(Color.white)
                c.blendMode(.alpha)
                c.noStroke()
                c.fill(Color(r: 0, g: 0, b: 0, alpha: 0.5))
                c.rect(box.x, box.y, box.w, box.h)
            }
            let got = plate.at(probePoint.x, probePoint.y)
            let mid = (got.r + got.g + got.b) / 3
            let between = mid > 0.25 && mid < 0.75
            let linear = Approx.eq(mid, 0.5, 0.02)
            out.append(Verdict(id: "B10.alphaComposite", passed: between,
                detail: "白の上に a=0.5 の黒 → \(Hue.s(rgb(got))) 平均=\(Approx.f(mid, 3))"
                    + " / リニア合成なら 0.500 → \(linear ? "一致" : "不一致（ガンマ空間での合成か、アルファの扱いが別）")"
                    + " / 判定は白黒の中間にあることのみ"))
        }

        return out
    }

    /// `dst` を敷いた上に `src` の矩形を指定モードで重ね、中心の色を読む。
    private static func paint(_ g: Graphics, _ mode: BlendMode) -> Color {
        let plate = expose(g) { c in
            // 下地を敷く間はブレンドを無効にしておく。ここが前回のモードのままだと
            // 「敷いたはずの dst」が別物になり、以降の期待値がすべてずれる。
            c.blendMode(.opaque)
            c.background(dst)
            c.blendMode(mode)
            c.noStroke()
            c.fill(src)
            c.rect(box.x, box.y, box.w, box.h)
        }
        return plate.at(probePoint.x, probePoint.y)
    }

    // MARK: - B11: ティント

    static func tinting(_ s: Sketch0816Prism, _ g: Graphics) -> [Verdict] {
        // 白い板を 1 枚焼いておき、それを別のオフスクリーンへ色付きで貼る。
        guard let source = s.createGraphics(side, side) else {
            return [Verdict(id: "B11.tint", passed: false, detail: "検査用の 2 枚目の createGraphics が nil")]
        }
        source.beginDraw()
        source.background(Color.white)
        source.endDraw(wait: true)
        let white = source.toImage()

        let tinted = expose(g) { c in
            c.blendMode(.opaque)
            c.background(Color.black)
            c.tint(Color.red)
            c.image(white, 0, 0, Float(side), Float(side))
        }
        let cleared = expose(g) { c in
            c.blendMode(.opaque)
            c.background(Color.black)
            c.noTint()
            c.image(white, 0, 0, Float(side), Float(side))
        }
        let a = tinted.at(probePoint.x, probePoint.y)
        let b = cleared.at(probePoint.x, probePoint.y)
        let ok = Hue.rgbEq(rgb(a), (1, 0, 0), Hue.quantized)
            && Hue.rgbEq(rgb(b), (1, 1, 1), Hue.quantized)

        return [Verdict(id: "B11.tint", passed: ok,
            detail: "白い板に tint(Color.red) → \(Hue.s(rgb(a))) 期待=(1,0,0)"
                + " / noTint() → \(Hue.s(rgb(b))) 期待=(1,1,1)")]
    }

    // MARK: - 焼いて読む

    /// 描いた結果を読み取れる状態にした 1 枚。写真乾板のつもり。
    @MainActor
    private struct Plate {
        let image: MImage
        func at(_ x: Int, _ y: Int) -> Color { image.get(x, y) }
    }

    /// オフスクリーンに 1 枚焼いて、CPU 側で読める状態にして返す。
    ///
    /// `endDraw(wait: true)` で GPU の完了を待つ。ここを待たないと、読み戻した色が
    /// 前フレームの残りだったり途中結果だったりして、**実行のたびに違う数字が出る**。
    private static func expose(_ g: Graphics, _ body: (Graphics) -> Void) -> Plate {
        g.beginDraw()
        body(g)
        g.endDraw(wait: true)
        let image = g.toImage()
        image.loadPixels()
        return Plate(image: image)
    }

    private static func rgb(_ c: Color) -> (Float, Float, Float) { (c.r, c.g, c.b) }
}
