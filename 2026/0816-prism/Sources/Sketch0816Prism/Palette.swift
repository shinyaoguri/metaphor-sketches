import Foundation
import metaphor
import simd

// 層 A — `Color` 型そのものの決定論的な検査。
//
// 描画も実時計も使わないので、実行するたびに同じ数値が出る。オラクルは閉じた数式
// （教科書の HSV 変換・線形補間・16 進の桁分解）なので、ピクセルを読まずに判定できる。
//
// 描画パイプラインを通った後の色は `Spectrometer.swift`（層 B）が測る。
// この層が緑でないと層 B の FAIL を読み違えるので、**先にこちらを通す**。

/// `Color(hue:saturation:brightness:)` が受け取るスケール。
///
/// doc は範囲を書いていない。0…1 正規化かもしれないし Processing 風の 0…360 / 0…100
/// かもしれない。**決め打ちで検査すると、仮定が外れただけで全項目が FAIL する誤報になる**
/// ので、A0 で実測して確定させてから以降の検査に使う。
struct HSBScale {
    let maxH: Float
    let maxS: Float
    let maxV: Float
    let label: String

    static let unit = HSBScale(maxH: 1, maxS: 1, maxV: 1, label: "0…1 正規化")
    static let degrees = HSBScale(maxH: 360, maxS: 100, maxV: 100, label: "H 0…360 / S,V 0…100")

    /// 正規化した (h, s, v) を、確定したスケールに載せて `Color` を作る。
    func color(_ h: Float, _ s: Float, _ v: Float) -> Color {
        Color(hue: h * maxH, saturation: s * maxS, brightness: v * maxV)
    }
}

@MainActor
enum Palette {
    /// A0 で確定したスケール。以降の HSB 検査はこれを通して色を作る。
    private(set) static var scale: HSBScale = .unit

    static func runAll() -> [Verdict] {
        var out: [Verdict] = []
        out += hsb()
        out += interpolation()
        out += hexadecimal()
        out += components()
        return out
    }

    // MARK: - A0〜A4: HSB → RGB

    static func hsb() -> [Verdict] {
        var out: [Verdict] = []

        // A0: まずスケールを実測で確定する。緑 (0,1,0) になる方の解釈を採る。
        //     ここを決めずに先へ進むと、以降の FAIL が「変換の誤り」なのか
        //     「こちらの仮定違い」なのか区別できなくなる。
        do {
            let unit = rgb(Color(hue: 1.0 / 3.0, saturation: 1, brightness: 1))
            let degrees = rgb(Color(hue: 120, saturation: 100, brightness: 100))
            let green: (Float, Float, Float) = (0, 1, 0)
            let unitIsGreen = Hue.rgbEq(unit, green, 0.02)
            let degreesIsGreen = Hue.rgbEq(degrees, green, 0.02)

            // ちょうど片方だけが緑なら、その解釈で確定できる。
            let decided = unitIsGreen != degreesIsGreen
            if unitIsGreen { scale = .unit } else if degreesIsGreen { scale = .degrees }

            out.append(Verdict(id: "A0.hsbScale", passed: decided,
                detail: "hue=1/3,s=1,v=1 → \(Hue.s(unit)) / hue=120,s=100,v=100 → \(Hue.s(degrees))"
                    + " / 緑 (0,1,0) になるのは "
                    + (decided ? "\(scale.label) のみ → こちらで確定"
                               : "\(unitIsGreen ? "両方" : "どちらでもない") — 以降の HSB 判定は仮に \(scale.label) で読む")))
        }

        // A1: 三原色。色相環の 0 / 1/3 / 2/3 が赤・緑・青になるか。
        do {
            let r = rgb(scale.color(0, 1, 1))
            let g = rgb(scale.color(1.0 / 3.0, 1, 1))
            let b = rgb(scale.color(2.0 / 3.0, 1, 1))
            let ok = Hue.rgbEq(r, (1, 0, 0), Hue.exact)
                && Hue.rgbEq(g, (0, 1, 0), Hue.exact)
                && Hue.rgbEq(b, (0, 0, 1), Hue.exact)
            out.append(Verdict(id: "A1.hsbPrimaries", passed: ok,
                detail: "h=0 → \(Hue.s(r)) 期待=(1,0,0) / h=1/3 → \(Hue.s(g)) 期待=(0,1,0) / h=2/3 → \(Hue.s(b)) 期待=(0,0,1)"))
        }

        // A2: 色相環を 30° 刻みで一周し、教科書の HSV 変換と全点で突き合わせる。
        //     6 セクタの内側（f が 0 でない点）まで当てるので、セクタ分岐の取り違えを拾える。
        do {
            var worst: (h: Float, got: (Float, Float, Float), want: (Float, Float, Float), err: Float)?
            for step in 0..<12 {
                let h = Float(step) / 12
                let got = rgb(scale.color(h, 0.8, 0.9))
                let want = Hue.hsvToRGB(h, 0.8, 0.9)
                let err = max(abs(got.0 - want.0), abs(got.1 - want.1), abs(got.2 - want.2))
                if err > (worst?.err ?? -1) { worst = (h, got, want, err) }
            }
            let w = worst!
            let ok = w.err <= Hue.exact
            out.append(Verdict(id: "A2.hsbSectors", passed: ok,
                detail: "12 点中の最大ずれ h=\(Approx.f(w.h, 3)) → \(Hue.s(w.got)) 期待=\(Hue.s(w.want)) 誤差=\(Approx.f(w.err, 6))"))
        }

        // A3: 無彩色。s=0 なら色相によらずグレー、v=0 なら色相・彩度によらず黒。
        do {
            let a = rgb(scale.color(0, 0, 0.5))
            let b = rgb(scale.color(0.7, 0, 0.5))   // 色相を振っても同じであるべき
            let dark = rgb(scale.color(0.4, 1, 0))
            let ok = Hue.rgbEq(a, (0.5, 0.5, 0.5), Hue.exact)
                && Hue.rgbEq(b, (0.5, 0.5, 0.5), Hue.exact)
                && Hue.rgbEq(dark, (0, 0, 0), Hue.exact)
            out.append(Verdict(id: "A3.hsbAchromatic", passed: ok,
                detail: "s=0,v=0.5: h=0 → \(Hue.s(a)) / h=0.7 → \(Hue.s(b)) 期待=(0.5,0.5,0.5) / v=0 → \(Hue.s(dark)) 期待=(0,0,0)"))
        }

        // A4: 色相の巻き取り。h=1.0 は h=0.0 と同じ色に戻るか、範囲外がラップするか。
        //     doc は何も言っていないので、**NaN を返さないこと**を必須にし、
        //     ラップするかどうかは実測を書き出すだけにして誤報を避ける。
        do {
            let zero = rgb(scale.color(0, 1, 1))
            let one = rgb(scale.color(1, 1, 1))
            let over = rgb(scale.color(1.25, 1, 1))
            let quarter = rgb(scale.color(0.25, 1, 1))
            let finite = [zero, one, over, quarter].allSatisfy { $0.0.isFinite && $0.1.isFinite && $0.2.isFinite }
            let wrapsAtOne = Hue.rgbEq(zero, one, Hue.exact)
            let wrapsOver = Hue.rgbEq(over, quarter, Hue.exact)
            out.append(Verdict(id: "A4.hsbWrap", passed: finite,
                detail: "h=1.0 → \(Hue.s(one)) / h=0.0 → \(Hue.s(zero)) → \(wrapsAtOne ? "一致（巻き取る）" : "不一致")"
                    + " / h=1.25 → \(Hue.s(over)) / h=0.25 → \(Hue.s(quarter)) → \(wrapsOver ? "一致（ラップする）" : "不一致（クランプか外挿）")"
                    + " / 判定は有限値であることのみ"))
        }

        // A5: 範囲外の彩度・明度。doc の記載が無いので有限値であることだけを要求し、
        //     クランプするかどうかは実測として残す。
        do {
            let negS = rgb(Color(hue: 0, saturation: -1 * scale.maxS, brightness: scale.maxV))
            let overV = rgb(Color(hue: 0, saturation: scale.maxS, brightness: 2 * scale.maxV))
            let finite = [negS, overV].allSatisfy { $0.0.isFinite && $0.1.isFinite && $0.2.isFinite }
            let clampsV = overV.0 <= 1.0 + Hue.exact
            out.append(Verdict(id: "A5.hsbOutOfRange", passed: finite,
                detail: "s=-1 → \(Hue.s(negS)) / v=2倍 → \(Hue.s(overV)) → \(clampsV ? "1.0 にクランプ" : "1.0 を超える")"
                    + " / 判定は有限値であることのみ"))
        }

        return out
    }

    // MARK: - A6〜A8: 補間

    static func interpolation() -> [Verdict] {
        var out: [Verdict] = []
        let c1 = Color(r: 0.2, g: 0.4, b: 0.6, a: 0.8)
        let c2 = Color(r: 0.8, g: 0.2, b: 0.0, a: 0.4)

        // A6: 3 つの入口（グローバル関数・メソッド・型メソッド）が同じ答えを出すか。
        //     同じ計算に入口が 3 つあるので、どれか 1 つだけ古い実装ということがありうる。
        do {
            let viaFunc = lerpColor(c1, c2, 0.25)
            let viaMethod = c1.lerp(to: c2, t: 0.25)
            let viaStatic = Color.interpolate(from: c1, to: c2, t: 0.25)
            let ok = Hue.rgbEq(rgb(viaFunc), rgb(viaMethod), Hue.exact)
                && Hue.rgbEq(rgb(viaFunc), rgb(viaStatic), Hue.exact)
                && Approx.eq(viaFunc.a, viaMethod.a, Hue.exact)
                && Approx.eq(viaFunc.a, viaStatic.a, Hue.exact)
            out.append(Verdict(id: "A6.lerpAgreement", passed: ok,
                detail: "t=0.25 lerpColor=\(Hue.s(rgba(viaFunc))) / .lerp=\(Hue.s(rgba(viaMethod))) / .interpolate=\(Hue.s(rgba(viaStatic)))"))
        }

        // A7: 端点と中点。線形補間なので期待値は閉じた式で書ける。アルファも混ざるか。
        do {
            let at0 = lerpColor(c1, c2, 0)
            let at1 = lerpColor(c1, c2, 1)
            let mid = lerpColor(c1, c2, 0.5)
            let wantMid = ((c1.r + c2.r) / 2, (c1.g + c2.g) / 2, (c1.b + c2.b) / 2)
            let wantMidA = (c1.a + c2.a) / 2
            let ok = Hue.rgbEq(rgb(at0), rgb(c1), Hue.exact)
                && Hue.rgbEq(rgb(at1), rgb(c2), Hue.exact)
                && Hue.rgbEq(rgb(mid), wantMid, Hue.exact)
                && Approx.eq(mid.a, wantMidA, Hue.exact)
            out.append(Verdict(id: "A7.lerpEndpoints", passed: ok,
                detail: "t=0 → \(Hue.s(rgba(at0))) 期待=\(Hue.s(rgba(c1))) / t=1 → \(Hue.s(rgba(at1))) 期待=\(Hue.s(rgba(c2)))"
                    + " / t=0.5 → \(Hue.s(rgba(mid))) 期待=\(Hue.s((wantMid.0, wantMid.1, wantMid.2, wantMidA)))"))
        }

        // A8: 範囲外の t。Processing の `lerpColor` はクランプしない実装が多いが doc に
        //     記載が無いので、**有限値であること**だけを判定し、挙動は実測として残す。
        do {
            let under = lerpColor(c1, c2, -0.5)
            let over = lerpColor(c1, c2, 1.5)
            let finite = [under, over].allSatisfy { $0.r.isFinite && $0.g.isFinite && $0.b.isFinite && $0.a.isFinite }
            let clamped = Hue.rgbEq(rgb(under), rgb(c1), Hue.exact) && Hue.rgbEq(rgb(over), rgb(c2), Hue.exact)
            out.append(Verdict(id: "A8.lerpOutOfRange", passed: finite,
                detail: "t=-0.5 → \(Hue.s(rgba(under))) / t=1.5 → \(Hue.s(rgba(over))) → \(clamped ? "端点にクランプ" : "外挿する")"
                    + " / 判定は有限値であることのみ"))
        }

        return out
    }

    // MARK: - A9〜A12: 16 進

    static func hexadecimal() -> [Verdict] {
        var out: [Verdict] = []

        // A9: 6 桁は RRGGBB。不透明で返るか。
        do {
            let c = Color(hex: 0xFF8033)
            let want: (Float, Float, Float) = (1.0, 128.0 / 255.0, 51.0 / 255.0)
            let ok = Hue.rgbEq(rgb(c), want, Hue.quantized) && Approx.eq(c.a, 1, Hue.quantized)
            out.append(Verdict(id: "A9.hexRGB", passed: ok,
                detail: "0xFF8033 → \(Hue.s(rgba(c))) 期待=\(Hue.s((want.0, want.1, want.2, 1)))"))
        }

        // A10: 8 桁は AARRGGBB。**6 桁との判別は値の大きさでしかできない**ので、
        //      0xFFFFFF（= 0x00FFFFFF）が「透明な白」ではなく「不透明な白」になるかを見る。
        //      ここを取り違えると、白を指定したのに何も出ないという形で表に出る。
        do {
            let argb = Color(hex: 0x80FF8033)
            let opaqueWhite = Color(hex: 0xFFFFFF)
            let wantA: Float = 128.0 / 255.0
            let okARGB = Approx.eq(argb.a, wantA, Hue.quantized)
                && Hue.rgbEq(rgb(argb), (1.0, 128.0 / 255.0, 51.0 / 255.0), Hue.quantized)
            let okWhite = Hue.rgbEq(rgb(opaqueWhite), (1, 1, 1), Hue.quantized)
                && Approx.eq(opaqueWhite.a, 1, Hue.quantized)
            out.append(Verdict(id: "A10.hexARGB", passed: okARGB && okWhite,
                detail: "0x80FF8033 → \(Hue.s(rgba(argb))) 期待 a=\(Approx.f(wantA, 3))"
                    + " / 0xFFFFFF → \(Hue.s(rgba(opaqueWhite))) 期待=(1,1,1,a=1.000)（6 桁は不透明）"))
        }

        // A11: 文字列版。"#RRGGBB" と "#AARRGGBB"。
        do {
            let short = Color(hex: "#FF8033")
            let long = Color(hex: "#80FF8033")
            let okShort = short.map { Hue.rgbEq(rgb($0), (1.0, 128.0 / 255.0, 51.0 / 255.0), Hue.quantized) && Approx.eq($0.a, 1, Hue.quantized) } ?? false
            let okLong = long.map { Approx.eq($0.a, 128.0 / 255.0, Hue.quantized) } ?? false
            out.append(Verdict(id: "A11.hexString", passed: okShort && okLong,
                detail: "\"#FF8033\" → \(short.map { Hue.s(rgba($0)) } ?? "nil") 期待=(1,0.502,0.200,a=1)"
                    + " / \"#80FF8033\" → \(long.map { Hue.s(rgba($0)) } ?? "nil") 期待 a=0.502"))
        }

        // A12: 形式外の文字列で nil を返すか（失敗系）。
        //
        //     doc は受け付ける形を "#RRGGBB" と "#AARRGGBB" に限っている。それ以外の桁数は
        //     形式外なので nil が期待。**16 進として読めてしまう桁数**（1〜5, 7 桁）を重点的に
        //     並べる。ここが素通りすると、打ち間違いが nil ではなく「別の色」として静かに通る。
        do {
            let cases = [
                "#GGGGGG",      // 16 進でない
                "",             // 空
                "not a color",  // 語
                "#",            // 記号だけ
                "#F",           // 1 桁
                "#FFF",         // 3 桁（CSS の短縮形。CSS なら白）
                "#12345",       // 5 桁
                "#1234567",     // 7 桁
            ]
            let results = cases.map { (input: $0, color: Color(hex: $0)) }
            let accepted = results.filter { $0.color != nil }
            let ok = accepted.isEmpty
            let shown = accepted.isEmpty
                ? "すべて nil"
                : accepted.map { "\"\($0.input)\"→\(Hue.s(rgba($0.color!)))" }.joined(separator: " ")
            out.append(Verdict(id: "A12.hexStringInvalid", passed: ok,
                detail: "形式外 \(cases.count) 件中 \(accepted.count) 件が色として通った: \(shown)"
                    + " / 期待=すべて nil（doc の形式は \"#RRGGBB\" と \"#AARRGGBB\" のみ）"))
        }

        return out
    }

    // MARK: - A13〜A16: 成分と定数

    static func components() -> [Verdict] {
        var out: [Verdict] = []

        // A13: グレースケール初期化。0 が黒・1 が白で、アルファは独立か。
        do {
            let black = Color(gray: 0)
            let mid = Color(gray: 0.5, alpha: 0.25)
            let white = Color(gray: 1)
            let ok = Hue.rgbEq(rgb(black), (0, 0, 0), Hue.exact)
                && Hue.rgbEq(rgb(mid), (0.5, 0.5, 0.5), Hue.exact)
                && Approx.eq(mid.a, 0.25, Hue.exact)
                && Hue.rgbEq(rgb(white), (1, 1, 1), Hue.exact)
            out.append(Verdict(id: "A13.grayInit", passed: ok,
                detail: "gray=0 → \(Hue.s(rgb(black))) / gray=0.5,a=0.25 → \(Hue.s(rgba(mid))) / gray=1 → \(Hue.s(rgb(white)))"))
        }

        // A14: `withAlpha` は RGB を触らずアルファだけ差し替えるか。
        do {
            let base = Color(r: 0.2, g: 0.4, b: 0.6, a: 1.0)
            let faded = base.withAlpha(0.3)
            let ok = Hue.rgbEq(rgb(faded), rgb(base), Hue.exact) && Approx.eq(faded.a, 0.3, Hue.exact)
            out.append(Verdict(id: "A14.withAlpha", passed: ok,
                detail: "\(Hue.s(rgba(base))).withAlpha(0.3) → \(Hue.s(rgba(faded))) 期待=RGB 不変・a=0.300"))
        }

        // A15: `simd` の成分順が (r, g, b, a) か。ここが入れ替わっていると
        //      シェーダへ渡した色だけが化けるという分かりにくい壊れ方をする。
        do {
            let c = Color(r: 0.1, g: 0.2, b: 0.3, a: 0.4)
            let v = c.simd
            let ok = Approx.eq(v.x, 0.1, Hue.exact) && Approx.eq(v.y, 0.2, Hue.exact)
                && Approx.eq(v.z, 0.3, Hue.exact) && Approx.eq(v.w, 0.4, Hue.exact)
            // 往復（SIMD4 から作り直す）でも保たれるか。
            let back = Color(v)
            let roundTrip = Hue.rgbEq(rgb(back), rgb(c), Hue.exact) && Approx.eq(back.a, c.a, Hue.exact)
            out.append(Verdict(id: "A15.simdOrder", passed: ok && roundTrip,
                detail: "(0.1,0.2,0.3,0.4).simd = (\(Approx.f(v.x, 3)), \(Approx.f(v.y, 3)), \(Approx.f(v.z, 3)), \(Approx.f(v.w, 3)))"
                    + " 期待=(r,g,b,a) 順 / SIMD4 からの往復=\(roundTrip ? "一致" : "不一致")"))
        }

        // A16: 名前付き定数が名前どおりの色か。
        //      orange だけは実装が選んだ中間色なので厳密値を要求せず、
        //      「赤 > 緑 > 青 の順で暖色側にある」ことだけを見る。
        do {
            let exact: [(String, Color, (Float, Float, Float))] = [
                ("red", .red, (1, 0, 0)), ("green", .green, (0, 1, 0)), ("blue", .blue, (0, 0, 1)),
                ("cyan", .cyan, (0, 1, 1)), ("magenta", .magenta, (1, 0, 1)), ("yellow", .yellow, (1, 1, 0)),
                ("white", .white, (1, 1, 1)), ("black", .black, (0, 0, 0)),
            ]
            let mismatched = exact.filter { !Hue.rgbEq(rgb($0.1), $0.2, Hue.exact) }
            let clear = Color.clear
            let clearOK = Approx.eq(clear.a, 0, Hue.exact)
            let orange = Color.orange
            let orangeOK = orange.r > orange.g && orange.g > orange.b && orange.r > 0.8
            let ok = mismatched.isEmpty && clearOK && orangeOK
            let detail = mismatched.isEmpty
                ? "8 定数すべて一致"
                : mismatched.map { "\($0.0)=\(Hue.s(rgb($0.1))) 期待=\(Hue.s($0.2))" }.joined(separator: " / ")
            out.append(Verdict(id: "A16.constants", passed: ok,
                detail: "\(detail) / clear a=\(Approx.f(clear.a, 3)) 期待=0.000 / orange=\(Hue.s(rgb(orange))) 期待=r>g>b"))
        }

        return out
    }

    // MARK: - 取り出しの小道具

    private static func rgb(_ c: Color) -> (Float, Float, Float) { (c.r, c.g, c.b) }
    private static func rgba(_ c: Color) -> (Float, Float, Float, Float) { (c.r, c.g, c.b, c.a) }
}
