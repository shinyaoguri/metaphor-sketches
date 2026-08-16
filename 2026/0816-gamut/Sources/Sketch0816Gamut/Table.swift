import Foundation
import metaphor

// 作品の絵。
//
// 同じ 3 原色が、光として重なれば白へ、絵の具として重なれば黒へ向かう。
// 両方の卓に**同じ「薄め」つまみ（α）**が効く — はずだが、合成の仕方によっては効かない。
// **その非対称が絵に出ることが、この作品の主題であり、そのまま検証にもなっている。**
//
// 光は縁へ向かって消えるので `radialGradient` の外縁を α=0 にして描く。
// α が合成に入らないモード（screen / lightest）では、その「消える」が起きず
// 縁の立ったベタの円になる。バグが絵に直接現れる。

/// 卓 1 つぶんの設定。
struct Table {
    let name: String
    let note: String
    /// 下地（暗闇 / 白紙）。
    let backdrop: Color
    /// 3 原色。色相環から作る。
    let inks: [(name: String, color: Color)]
    /// 選べる合成。← → で送る。
    let modes: [BlendMode]
    /// 光は減衰する（放射グラデーション）、絵の具は均一に乗る（ベタ）。
    let isLight: Bool
}

extension Table {
    /// 光の卓。暗闇に 3 原色の光を重ねると白へ向かう。
    static let light = Table(
        name: "光 / LIGHT",
        note: "暗闇に重ねるほど明るい（加法混色）",
        backdrop: Color(gray: 0.04),
        inks: [
            ("R", Color(hue: 0, saturation: 1, brightness: 1)),
            ("G", Color(hue: 1.0 / 3.0, saturation: 1, brightness: 1)),
            ("B", Color(hue: 2.0 / 3.0, saturation: 1, brightness: 1)),
        ],
        modes: [.additive, .screen, .lightest],
        isLight: true
    )

    /// 絵の具の卓。白紙に 3 原色を重ねると黒へ向かう。
    static let pigment = Table(
        name: "絵の具 / PIGMENT",
        note: "白紙に重ねるほど暗い（減法混色）",
        backdrop: Color(gray: 0.96),
        inks: [
            ("C", Color(hue: 0.5, saturation: 1, brightness: 1)),
            ("M", Color(hue: 5.0 / 6.0, saturation: 1, brightness: 1)),
            ("Y", Color(hue: 1.0 / 6.0, saturation: 1, brightness: 1)),
        ],
        modes: [.multiply, .darkest, .subtract],
        isLight: false
    )

    /// 現在のモード名（HUD 用）。
    func modeName(_ i: Int) -> String { Instrument.label(modes[i % modes.count]).name }
    func mode(_ i: Int) -> BlendMode { modes[i % modes.count] }
}

extension Sketch0816Gamut {

    /// 3 つの円の中心（卓の描画と、実測を読む位置で同じ配置を使う）。
    ///
    /// 配置半径は円の半径に対して十分小さく取る。光は縁へ向かって減衰するので、
    /// 開きすぎると**卓の中心でどの光も減衰しきって白に届かない**（0.17 では
    /// 3 色の重なりが rgb(110,110,110) の灰色にしかならなかった）。
    func inkCenters(in area: Patch, spread: Float, spin: Float) -> [(x: Float, y: Float)] {
        let base = min(area.w, area.h)
        let place = base * placeRatio * spread
        return (0..<3).map { i in
            let a = spin + Float(i) * (2 * Float.pi / 3) - Float.pi / 2
            return (x: area.cx + cos(a) * place, y: area.cy + sin(a) * place)
        }
    }

    /// 配置半径の係数（卓の短辺に対する比）。
    var placeRatio: Float { 0.125 }

    func inkDiameter(in area: Patch) -> Float { min(area.w, area.h) * 0.62 }

    /// 卓を 1 枚描く。
    func drawTable(_ t: Table, in area: Patch, mode: BlendMode, alpha: Float,
                   spread: Float, spin: Float) {
        noStroke()
        rectMode(.corner)

        // 下地。ブレンド無効で置いて、以降の重なりの基準を確定させる。
        blendMode(.opaque)
        fill(t.backdrop)
        rect(area.x, area.y, area.w, area.h)

        let centers = inkCenters(in: area, spread: spread, spin: spin)
        let d = inkDiameter(in: area)

        blendMode(mode)
        for (i, ink) in t.inks.enumerated() {
            let c = centers[i]
            if t.isLight {
                // 光は縁へ向かって消える。その「消える」を α で表しているので、
                // α が合成に入らないモード（screen / lightest）では減衰が起きず、
                // 縁の立ったベタの円になる — **穴がそのまま絵に出る**。
                radialGradient(c.x, c.y, d / 2,
                               ink.color.withAlpha(alpha), ink.color.withAlpha(0),
                               segments: 64)
                // 芯。放射グラデーションは**中心でしか満強度にならない**ので、
                // これが無いと 3 つの光が重なる卓の中心が白に届かない（灰色で止まる）。
                // 芯の半径は配置半径より大きく取る（卓の中心が芯の内側に入るように）。
                fill(ink.color.withAlpha(alpha))
                circle(c.x, c.y, d * 0.5)
            } else {
                fill(ink.color.withAlpha(alpha))
                circle(c.x, c.y, d)
            }
        }
        blendMode(.alpha)
    }

    /// 卓から読む点（3 色の重なり = 中心、2 色の重なり = 円の中間方向）。
    func samplePoints(in area: Patch, spread: Float, spin: Float) -> [(label: String, x: Float, y: Float)] {
        let base = min(area.w, area.h)
        let place = base * placeRatio * spread
        var pts: [(String, Float, Float)] = [("3 色", area.cx, area.cy)]
        for i in 0..<3 {
            let a = spin + (Float(i) + 0.5) * (2 * Float.pi / 3) - Float.pi / 2
            // 2 色だけが重なる帯は、3 色領域の**外側**にある。中心から place の
            // 1.8 倍あたりで、3 つ目の円からは外れつつ 2 つの円の内側に入る
            // （place と同じ距離だと 3 色領域に入ってしまい、黒しか読めなかった）。
            let t = place * 1.8
            pts.append(("2 色", area.cx + cos(a) * t, area.cy + sin(a) * t))
        }
        return pts.map { (label: $0.0, x: $0.1, y: $0.2) }
    }
}
