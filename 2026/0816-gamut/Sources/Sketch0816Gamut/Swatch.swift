import Foundation
import metaphor

// 検査の土台。
//
// ブレンドは「下地に重ねた結果のピクセル」でしか確かめられないので、**必ず読み戻す**。
// ただし作品の絵を汚したくないので、合成はオフスクリーン（createGraphics）で行い、
// toImage().loadPixels() で CPU 側へ落として数える。
//
// 検査のたびに createGraphics すると重いので 1 枚を使い回す。

/// `MImage.pixels` のチャンネル並び。doc は「生の RGBA」と書いているが、Metal の
/// 既定フォーマットは bgra8Unorm なので **起動時に純色を置いて実測で決める**。
enum ChannelOrder: String {
    case rgba = "RGBA"
    case bgra = "BGRA"
}

/// オフスクリーン 1 枚に合成して読み戻す道具。
@MainActor
final class Swatch {
    let g: Graphics
    let w: Int
    let h: Int
    /// 実測で決めたチャンネル並び。`calibrate()` が設定する。
    private(set) var order: ChannelOrder = .bgra
    /// 校正の実測（issue に貼るため保持する）。
    private(set) var calibration = ""

    private var buffer: [UInt8] = []

    init(_ g: Graphics) {
        self.g = g
        self.w = Int(g.width)
        self.h = Int(g.height)
    }

    var cx: Int { w / 2 }
    var cy: Int { h / 2 }

    // MARK: - 描いて読む

    /// 1 枚に描いて、CPU 側へ読み戻す。以降 `read` が使える。
    ///
    /// `endDraw(wait: true)` で GPU の完了を待たないと、読み戻しが 1 フレーム前の
    /// 内容になりうる（毎回同じ数値が出ることが検査の前提なので必ず待つ）。
    func render(_ body: (Graphics) -> Void) {
        g.beginDraw()
        body(g)
        g.endDraw(wait: true)

        let img = g.toImage()
        img.loadPixels()
        buffer = img.pixels
    }

    /// 直近の `render` の結果から 1 画素読む。
    func read(_ x: Int, _ y: Int) -> RGBA8 {
        let i = (y * w + x) * 4
        guard i >= 0, i + 3 < buffer.count else { return RGBA8(-1, -1, -1, -1) }
        let c0 = Int(buffer[i]), c1 = Int(buffer[i + 1])
        let c2 = Int(buffer[i + 2]), c3 = Int(buffer[i + 3])
        switch order {
        case .rgba: return RGBA8(c0, c1, c2, c3)
        case .bgra: return RGBA8(c2, c1, c0, c3)
        }
    }

    /// 直近の `render` の結果の中心。
    func center() -> RGBA8 { read(cx, cy) }

    // MARK: - 定型

    /// 下地を全面に敷いてから、`mode` で `src` を全面に重ね、中心の色を返す。
    ///
    /// 下地は `background` ではなく `.opaque` の矩形で置く。`background` はクリア扱いで
    /// ブレンド状態を通らないので、「下地も同じ経路で描いた」状態を揃えるため。
    func over(base: Color, src: Color, mode: BlendMode) -> RGBA8 {
        render { g in
            g.noStroke()
            g.rectMode(.corner)
            g.blendMode(.opaque)
            g.fill(base)
            g.rect(0, 0, Float(w), Float(h))
            g.blendMode(mode)
            g.fill(src)
            g.rect(0, 0, Float(w), Float(h))
            g.blendMode(.alpha)
        }
        return center()
    }

    /// 下地だけを置いて読む。
    ///
    /// 期待値はこの**実測の dst** から計算する。下地は書き込まれた時点で 8bit に丸められるので、
    /// 指定した Float から計算すると量子化のぶんだけ期待値がずれ、許容差を緩めるはめになる。
    func baseOnly(_ base: Color) -> RGBA8 {
        render { g in
            g.noStroke()
            g.rectMode(.corner)
            g.blendMode(.opaque)
            g.fill(base)
            g.rect(0, 0, Float(w), Float(h))
        }
        return center()
    }

    /// 下地の上に `srcs` を順に重ねる（3 原色の混色に使う）。
    func stack(base: Color, srcs: [Color], mode: BlendMode) -> RGBA8 {
        render { g in
            g.noStroke()
            g.rectMode(.corner)
            g.blendMode(.opaque)
            g.fill(base)
            g.rect(0, 0, Float(w), Float(h))
            g.blendMode(mode)
            for c in srcs {
                g.fill(c)
                g.rect(0, 0, Float(w), Float(h))
            }
            g.blendMode(.alpha)
        }
        return center()
    }

    // MARK: - 自己校正

    /// `pixels` のチャンネル並びを実測で決める。
    ///
    /// 純赤を不透明で置き、どのオフセットに 255 が来るかで判別する。ここを取り違えると
    /// 以降の判定が全部ずれるので、**検査の一番最初に 1 回だけ**走らせる。
    func calibrate() -> Verdict {
        order = .rgba  // いったん素通しで読む
        let got = over(base: Color(r: 0, g: 0, b: 0), src: Color(r: 1, g: 0, b: 0), mode: .opaque)
        // 素通しで読んで r が立っていれば RGBA、b が立っていれば BGRA。
        let detected: ChannelOrder? =
            got.r > 200 && got.b < 60 ? .rgba : (got.b > 200 && got.r < 60 ? .bgra : nil)
        order = detected ?? .bgra
        calibration = "純赤を素通しで読むと \(got.text) → 並びは \(order.rawValue)"
        return Verdict(
            id: "B0.channelOrder", passed: detected != nil,
            detail: detected != nil
                ? "\(calibration)（この並びで以降を判定する）"
                : "並びを判定できなかった: \(calibration)。以降の判定は信用できない"
        )
    }
}
