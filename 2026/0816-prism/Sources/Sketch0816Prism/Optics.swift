import Foundation
import metaphor

// プリズムの光学モデル。
//
// 作品の絵を出すための計算だが、**同時に自分の検証コードの土台**でもある。
// ここが間違っていると「metaphor の色がおかしい」と誤報しかねないので、
// 閉じた式で書けるところは `Instrument` 側から当て直せるようにしてある
// （最小偏角・分散の順序・屈折率の実測値）。
//
// 単位: 波長は nm、角度はラジアン。

enum Optics {
    /// 可視域の端。ここより外は目に見えないので描かない。
    static let minWavelength: Float = 380
    static let maxWavelength: Float = 700

    /// プリズムの頂角。正三角形なので 60°。
    static let apex: Float = .pi / 3

    // MARK: - 分散

    /// Cauchy の分散式による屈折率。ガラスは BK7（ホウケイ酸クラウン）を採る。
    ///
    ///     n(λ) = B + C / λ²      （λ は µm）
    ///
    /// B = 1.5046, C = 0.00420 µm² は BK7 の実測に合う係数で、
    /// n(486nm)=1.522 / n(589nm)=1.517 / n(656nm)=1.514 を再現する。
    /// **短い波長ほど屈折率が高い**ので、紫が最も大きく曲がる。虹の並びはこれで決まる。
    static func refractiveIndex(_ wavelengthNM: Float) -> Float {
        let micron = wavelengthNM / 1000
        return 1.5046 + 0.00420 / (micron * micron)
    }

    /// 三角プリズムを通った光の偏角 δ。
    ///
    ///     θ2 = asin(sin θ1 / n)      入射面の屈折
    ///     θ3 = A - θ2                プリズム内部の幾何
    ///     θ4 = asin(n sin θ3)        出射面の屈折
    ///     δ  = θ1 + θ4 - A           入射方向からの振れ
    ///
    /// 出射面で全反射する（`n sin θ3` が 1 を超える）と光は出てこない。その場合は `nil`。
    static func deviation(incidence theta1: Float, index n: Float, apex a: Float = apex) -> Float? {
        let sinTheta2 = sin(theta1) / n
        guard abs(sinTheta2) <= 1 else { return nil }
        let theta2 = asin(sinTheta2)
        let theta3 = a - theta2
        let sinTheta4 = n * sin(theta3)
        guard abs(sinTheta4) <= 1 else { return nil }   // 全反射
        return theta1 + asin(sinTheta4) - a
    }

    /// 最小偏角。入射角と出射角が等しくなる対称の通り方をしたときの偏角。
    ///
    ///     δmin = 2 asin(n sin(A/2)) - A
    ///
    /// `deviation` を入射角について掃引した最小値と一致するはずで、
    /// **独立に書ける第 2 の式**なので自己検査のオラクルに使える。
    static func minimumDeviation(index n: Float, apex a: Float = apex) -> Float? {
        let s = n * sin(a / 2)
        guard abs(s) <= 1 else { return nil }
        return 2 * asin(s) - a
    }

    // MARK: - 波長から色へ

    /// 波長を色相へ写す区分線形テーブル。
    ///
    /// 波長と色相は線形の関係ではない（緑の帯が広く、青紫の帯が狭い）ので、
    /// 目に見える並びに合う代表点を置いて間を補間する。
    private static let hueTable: [(nm: Float, hue: Float)] = [
        (700, 0.00),   // 赤
        (620, 0.02),
        (590, 0.10),   // 橙
        (570, 0.15),   // 黄
        (540, 0.28),
        (510, 0.36),   // 緑
        (490, 0.48),   // 青緑
        (470, 0.58),
        (450, 0.66),   // 青
        (420, 0.74),
        (380, 0.80),   // 菫
    ]

    /// 可視域の端での明るさの落ち込み。虹の両端が自然に暗くなる。
    private static func luminance(_ nm: Float) -> Float {
        if nm < 420 { return lerp(0.25, 1.0, (nm - 380) / 40) }
        if nm > 645 { return lerp(1.0, 0.25, (nm - 645) / 55) }
        return 1
    }

    private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * min(max(t, 0), 1)
    }

    /// 単色光の色。
    ///
    /// **`Color(hue:saturation:brightness:)` を作品の主要経路に置いている。**
    /// 層 A で式の正しさを測っている API が、そのまま絵を作る側でも使われる。
    /// 検査だけで通した API は「通した」以上のことを言えないので、本編でも通す。
    static func color(forWavelength nm: Float) -> Color {
        let clamped = min(max(nm, minWavelength), maxWavelength)
        var hue: Float = 0
        for i in 0..<(hueTable.count - 1) {
            let hi = hueTable[i], lo = hueTable[i + 1]
            if clamped <= hi.nm && clamped >= lo.nm {
                let t = (hi.nm - clamped) / (hi.nm - lo.nm)
                hue = lerp(hi.hue, lo.hue, t)
                break
            }
        }
        return Color(hue: hue, saturation: 1, brightness: luminance(clamped))
    }

    /// 可視域を等間隔に刻んだ単色光の並び。分光の描画と再合成の両方で使う。
    static func spectrum(count: Int) -> [(nm: Float, color: Color)] {
        (0..<count).map { i in
            let t = Float(i) / Float(max(count - 1, 1))
            let nm = maxWavelength - (maxWavelength - minWavelength) * t   // 赤 → 菫
            return (nm, color(forWavelength: nm))
        }
    }
}
