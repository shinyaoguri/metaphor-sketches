import Foundation
import metaphor

// 落ちうる呼び出しを、**頼んだときだけ**踏む口。
//
// 起動のたびに走る検査へ入れてしまうと、プロセスごと落ちて作品が起動しなくなる。
// 0816-marionette では v0.9.0 の `step(dt, iterations: -1)` をこれで踏んで起動不能にした。
// 同じ轍を踏まないよう、退化した引数はここへ隔離する。
//
//     PRISM_TRAP=radialSegmentsZero swift run
//
// ここに並ぶのは「落ちると分かっているもの」ではなく「**落ちるかどうかを確かめたいもの**」。
// 通ったなら通ったで、退化した引数を渡しても平気だという記録になる。

@MainActor
enum Trap {
    private static let names = [
        "colorModeZero",
        "colorModeNegative",
        "radialSegmentsZero",
        "radialSegmentsNegative",
        "gradientDegenerate",
        "graphicsZero",
    ]

    static func fire(_ name: String, _ s: Sketch0816Prism) {
        print("trap: \(name) を踏む")
        fflush(stdout)

        switch name {
        // カラーモードの最大値が 0。正規化のとき 0 除算になりうる。
        case "colorModeZero":
            s.colorMode(.rgb, 0)
            s.fill(1, 0, 0)
            print("trap: colorMode(.rgb, 0) → fill を通過した")

        // 最大値が負。スケールが反転する。
        case "colorModeNegative":
            s.colorMode(.rgb, -255)
            s.fill(255, 0, 0)
            print("trap: colorMode(.rgb, -255) → fill を通過した")

        // 円を 0 分割。頂点が作れない。
        case "radialSegmentsZero":
            s.radialGradient(s.width / 2, s.height / 2, 100, Color.white, Color.black, segments: 0)
            print("trap: radialGradient(segments: 0) を通過した")

        // 負の分割数。ループ回数が負になる。
        case "radialSegmentsNegative":
            s.radialGradient(s.width / 2, s.height / 2, 100, Color.white, Color.black, segments: -8)
            print("trap: radialGradient(segments: -8) を通過した")

        // 幅も高さも 0 のグラデーション矩形。軸に沿った補間の分母が 0 になる。
        case "gradientDegenerate":
            s.linearGradient(100, 100, 0, 0, Color.red, Color.blue, axis: .vertical)
            print("trap: linearGradient(w: 0, h: 0) を通過した")

        // 既出の穴（metaphor#798）。0816-escapement で報告済みで、こちらは参照用。
        // 層 B がオフスクリーンに全面的に依存しているので、同じ口を持たせておく。
        case "graphicsZero":
            let g = s.createGraphics(0, 0)
            print("trap: createGraphics(0, 0) → \(g == nil ? "nil" : "インスタンスが返った")")

        default:
            print("trap: 未知の名前 '\(name)'。使えるのは \(names.joined(separator: ", "))")
        }

        fflush(stdout)
    }
}
