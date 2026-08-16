import Foundation
import metaphor

// blendMode と fill の α の噛み合わせだけを見る最小再現。
//
// 親作品 0816-gamut の検査（Instrument.swift）から作品の文脈を全部剥がし、
// 「不透明な下地に、完全に透明な色を 1 枚重ねる」だけにしたもの。
// 剥がしても同じ結果が出るなら、原因は作品側ではなくライブラリ側にある。
//
//   swift run
//
// 下地は rgb(102,77,51)。何も起きないのが期待。変わったモードが問題。
// 上流へ報告した metaphor#<N> の再現コードそのもの。

@main
final class Sketch0816ProbeBlendalpha: Sketch {
    var config: SketchConfig {
        SketchConfig(width: 320, height: 160, title: "0816-probe-blendalpha")
    }

    /// 下地と、重ねる色。どの 2 モードも違う結果になるように選んである。
    static let base = Color(r: 0.40, g: 0.30, b: 0.20)
    static let ink = Color(r: 0.25, g: 0.55, b: 0.15)

    static let modes: [(String, BlendMode)] = [
        ("alpha", .alpha), ("additive", .additive), ("multiply", .multiply),
        ("screen", .screen), ("subtract", .subtract), ("lightest", .lightest),
        ("darkest", .darkest), ("difference", .difference), ("exclusion", .exclusion),
    ]

    private var done = false

    func setup() {}

    func draw() {
        guard !done else { return }
        done = true

        // 下地だけを置いて、比較の基準を実測する。
        let dst = compose(nil, .opaque)
        print("下地            \(dst)")
        print("")
        print("--- α = 0（完全に透明。どのモードでも下地のままが期待）---")
        for (name, mode) in Self.modes {
            print(pad(name) + compose(Self.ink.withAlpha(0), mode))
        }
        print("")
        print("--- α = 0.5（効きが半分になるのが期待）---")
        for (name, mode) in Self.modes {
            print(pad(name) + compose(Self.ink.withAlpha(0.5), mode))
        }
        print("")
        print("--- α = 1（この列は全モード正しい）---")
        for (name, mode) in Self.modes {
            print(pad(name) + compose(Self.ink.withAlpha(1), mode))
        }
        fflush(stdout)
        noLoop()
    }

    /// 下地を敷いて `src` を 1 枚重ね、中心の画素を読む。
    private func compose(_ src: Color?, _ mode: BlendMode) -> String {
        noStroke()
        rectMode(.corner)

        blendMode(.opaque)
        fill(Self.base)
        rect(0, 0, width, height)

        if let src {
            blendMode(mode)
            fill(src)
            rect(0, 0, width, height)
        }
        blendMode(.alpha)

        loadPixels()
        // pixels は (A << 24) | (R << 16) | (G << 8) | B のパック済み UInt32。
        let p = pixels[Int(height / 2) * Int(width) + Int(width / 2)]
        return String(format: "rgba(%3d,%3d,%3d,%3d)",
                      (p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF, (p >> 24) & 0xFF)
    }

    private func pad(_ s: String) -> String {
        s.padding(toLength: 12, withPad: " ", startingAt: 0)
    }
}
