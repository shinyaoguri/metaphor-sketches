import Foundation
import metaphor

// MARK: - 小道具

enum Log {
    /// パイプへ流したときにブロックバッファされて「動いていない」と誤診しないよう、
    /// 1 行ごとに必ず流し切る。
    static func line(_ s: String) {
        print(s)
        fflush(stdout)
    }
}

func fmt(_ v: Float, _ digits: Int = 3) -> String {
    String(format: "%.\(digits)f", v)
}

func sci(_ v: Float) -> String {
    String(format: "%.2e", v)
}

enum Env {
    static func flag(_ name: String) -> Bool {
        guard let s = ProcessInfo.processInfo.environment[name] else { return false }
        return s == "1" || s.lowercased() == "true"
    }

    static func string(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }

    static func int(_ name: String, default def: Int, min lo: Int, max hi: Int) -> Int {
        guard let s = ProcessInfo.processInfo.environment[name], let v = Int(s) else { return def }
        return Swift.max(lo, Swift.min(hi, v))
    }
}

// MARK: - 譜面

/// 1 粒 = 1 声部。**この並びは MSL 側の `Voice` と 1 バイトも違ってはいけない**
/// （`Kernels.swift` の `structDecl` と対で保つ。ずれを検査するのが `G10`）。
///
/// `SIMD2<Float>` は 8 バイト境界なので、`seed`（4B）の後ろに 4B の詰め物が要る。
/// 詰め物を書かないと Swift 側 24B / MSL 側 20B でずれる。
struct Voice: Equatable {
    var pos: SIMD2<Float>
    var vel: SIMD2<Float>
    var seed: UInt32
    var pad: UInt32 = 0
}

/// 二人の奏者が同じものを弾いていると言えるように、**譜面はここ 1 箇所にしか無い**。
/// GPU 側は `Kernels.swift` が同じ式を MSL で書き写したもので、
/// 食い違いを測るのが作品の主題（`G1` / `G2`）。
enum Score {
    /// ステージ座標。原点が舞台の中心で、半径 1.0 が見える範囲。
    static let bound: Float = 1.55
    /// 固定タイムステップ。実フレーム時間を使うと CPU / GPU の差に
    /// 「刻みの差」が混ざって、何を測ったのか分からなくなる。
    static let dt: Float = 1.0 / 60.0
    static let damping: Float = 0.995

    /// 整数ハッシュ。**浮動小数と違い両者で完全一致するはず**なので、
    /// 湧き直しの位置がずれたらそれは実装の食い違い（丸めのせいにできない）。
    static func hash(_ v: UInt32) -> UInt32 {
        var h = v &* 747_796_405 &+ 2_891_336_453
        h = ((h >> ((h >> 28) &+ 4)) ^ h) &* 277_803_737
        return (h >> 22) ^ h
    }

    static func unit(_ h: UInt32) -> Float {
        Float(h & 0x00FF_FFFF) / Float(0x0100_0000)
    }

    /// 渦・呼吸・引き戻しの 3 項。時刻に依るので、同じ `t` を両者へ渡す。
    static func field(_ p: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
        let r2 = p.x * p.x + p.y * p.y
        let swirl = SIMD2<Float>(-p.y, p.x) * (1.2 / (0.35 + r2))
        let breath = SIMD2<Float>(sin(p.y * 3.1 + t * 0.7), cos(p.x * 3.1 - t * 0.9)) * 0.55
        let pull = p * (-0.45 * r2)
        return swirl + breath + pull
    }

    /// 半陰的オイラー。MSL 側と**演算の順番まで**揃える（順番を変えると丸めが変わる）。
    static func advance(_ v: Voice, _ t: Float, _ dt: Float) -> Voice {
        var out = v
        let a = field(v.pos, t)
        out.vel = (v.vel + a * dt) * damping
        out.pos = v.pos + out.vel * dt
        if out.pos.x * out.pos.x + out.pos.y * out.pos.y > bound * bound {
            out = respawn(seed: v.seed)
        }
        return out
    }

    /// 舞台の外へ出た声部を、種から決まる位置へ入れ直す。
    static func respawn(seed: UInt32) -> Voice {
        let h1 = hash(seed)
        let h2 = hash(h1)
        let angle = unit(h1) * 6.283_185_3
        let radius = 0.12 + unit(h2) * 0.18
        return Voice(
            pos: SIMD2(cos(angle) * radius, sin(angle) * radius),
            vel: SIMD2(0, 0),
            seed: h2)
    }

    /// 開幕の配置。両者はこの同じ配列から始める。
    static func opening(count: Int) -> [Voice] {
        (0..<count).map { i in
            let s = hash(UInt32(i) &+ 0x9E37_79B9)
            var v = respawn(seed: s)
            // 初速を与えて渦に乗せる（無いと中心で固まって絵にならない）。
            let h = hash(s)
            v.vel = SIMD2(-v.pos.y, v.pos.x) * (0.8 + unit(h) * 0.6)
            return v
        }
    }
}

// MARK: - 楽章

enum Movement: Int, CaseIterable {
    /// 調弦。検査盤を出し、二重奏の前提が成り立っているかを見せる。
    case tuning
    /// 斉唱。同じ式・同じ刻み。ズレは float の精度ぶんだけのはず。
    case unison
    /// 端数。声部数を境界値へ動かし続ける。末尾が落ちれば絵の縁が欠ける。
    case oddBars
    /// 輪唱。2 パス連鎖のバリアを入切する。
    case canon
    /// 写譜。右手の描画経路を GPU バッファ直描き / CPU 配列経由で入れ替える。
    case copy

    var title: String {
        switch self {
        case .tuning: return "調弦  tuning"
        case .unison: return "第 I 楽章  斉唱  unison"
        case .oddBars: return "第 II 楽章  端数  odd bars"
        case .canon: return "第 III 楽章  輪唱  canon"
        case .copy: return "第 IV 楽章  写譜  copy"
        }
    }

    var seconds: Float {
        self == .tuning ? 8 : 12
    }

    /// 第 II 楽章で巡る声部数。`threadExecutionWidth`（多くは 32）の
    /// 倍数ちょうど・±1・素数を混ぜてある。
    static let bars: [Int] = [63, 64, 65, 255, 1023, 1025, 4096]
}
