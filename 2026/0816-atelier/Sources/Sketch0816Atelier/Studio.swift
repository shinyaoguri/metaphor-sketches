import Foundation
import simd
import metaphor

// アトリエそのもの。**作品側**の置き場で、検査はここを触らない。
//
// 石膏の静物（球・立方体・円柱・円錐・輪）が台の上に並び、ランプが弧を描いて回る。
// 見ていられる絵であることを優先している。理由は美観ではなく実利で、
// 見た目の異常に気付ける状態を保っていないと、検証としても弱くなる。
//
// **ワールドの +Y は画面の下向き**（`Optics` の注記を参照）。この舞台では
// 「上」がつねに -Y なので、床は大きい y、天井は小さい y にある。

// MARK: - 絵の具

enum Palette {
    /// 画室の空気。判定の「背景」でもあるので、石膏とは十分に離す。
    static let ground = SIMD3<Float>(16, 18, 24)
    /// 奥の壁。
    static let wall = SIMD3<Float>(52, 54, 63)
    /// 台の面。デッサン用紙の色に寄せた温かい灰。
    static let table = SIMD3<Float>(150, 142, 128)
    /// 石膏。
    static let plaster = SIMD3<Float>(226, 220, 208)
    /// ランプの灯。
    static let lamp = SIMD3<Float>(255, 236, 198)
    /// 講師の朱。
    static let red = SIMD3<Float>(216, 66, 48)
    /// 補助線の青。
    static let blue = SIMD3<Float>(92, 138, 184)
    /// 講評欄の文字。
    static let ink = SIMD3<Float>(234, 230, 222)
    /// 「良」の緑。
    static let green = SIMD3<Float>(120, 186, 128)

    /// 採寸台の標本色。背景とも台とも十分に離れていて、
    /// かつ 3 成分の値が違うので**チャンネルの取り違えに気付ける**。
    static let specimen = SIMD3<Float>(180, 120, 60)
}


// MARK: - 時間割

enum Timing {
    /// 1 場面のフレーム数（60fps で 15 秒）。採寸のぶんを含む。
    static let sceneFrames = 900
    /// 採寸 1 件をどれだけ見せるか（60fps で 0.6 秒）。
    static var holdFrames = 36
    /// 標本を差し替えた直後に撮る 1 回目（影が 1 フレーム遅れることの確認用）。
    static let earlyPass = 0
    /// 落ち着いてから撮る 2 回目。**本判定はこちら**。
    static let settledPass = 8
    /// 場面の数。
    static let stageCount = 5

    /// 判定だけを取りに行くモード（`ATELIER_FAST=1`）。
    ///
    /// 素描の時間を畳んで採寸だけを回す。**判定の中身は変えない**
    /// （ホールドを縮めるだけで、`settledPass` の位置は同じ）。
    static var fast = false

    /// 採寸を縮めるときのホールド。`settledPass` より十分に長く取る。
    static let fastHoldFrames = 14

    static func configureFast(_ on: Bool) {
        fast = on
        holdFrames = on ? fastHoldFrames : 36
    }
}

/// 場面。判定 ID の頭文字と対応する。
enum Stage: Int, CaseIterable {
    case form = 0      // F 形
    case value         // V 明暗
    case depth         // D 奥行き
    case shadow        // S 影
    case hand          // H 手

    var title: String {
        switch self {
        case .form: return "形"
        case .value: return "明暗"
        case .depth: return "奥行き"
        case .shadow: return "影"
        case .hand: return "手"
        }
    }

    var subtitle: String {
        switch self {
        case .form: return "プリミティブの寸法は指定どおりか"
        case .value: return "陰影は Blinn-Phong の手計算と合うか"
        case .depth: return "遠近と深度は投影の式どおりか"
        case .shadow: return "影は幾何が言う場所へ落ちるか"
        case .hand: return "自分で組んだ形は組み込みと並ぶか"
        }
    }

    var letter: String { ["F", "V", "D", "S", "H"][rawValue] }
}

// MARK: - 静物の配置

/// 台の上の石膏像 1 体。
struct Cast {
    enum Form {
        case sphere(radius: Float)
        case box(size: Float)
        case cylinder(radius: Float, height: Float)
        case cone(radius: Float, height: Float)
        case torus(ring: Float, tube: Float)
    }

    /// 台の面上での位置（x, z）。y は形から決まる（床に接地させる）。
    var x: Float
    var z: Float
    var form: Form
    /// 立ち姿の傾き（y 軸まわり）。
    var spin: Float

    /// 接地させたときの中心 y（床面 `floorY` から上へ = -Y へ持ち上げる）。
    func centerY(floorY: Float) -> Float {
        switch form {
        case .sphere(let r): return floorY - r
        case .box(let s): return floorY - s / 2
        case .cylinder(_, let h): return floorY - h / 2
        case .cone(_, let h): return floorY - h / 2
        case .torus(_, let tube): return floorY - tube
        }
    }
}

enum Studio {
    /// 台の面の高さ（ワールド y）。画面中心より下。
    static let floorY: Float = 590
    /// 台の奥行き方向の中心。
    static let floorZ: Float = -120
    /// 奥の壁の位置。
    static let wallZ: Float = -820

    /// 石膏像の並び。手前から奥へ散らして、重なりで前後関係が読めるようにしてある。
    static func casts() -> [Cast] {
        [
            Cast(x: -360, z: -40, form: .sphere(radius: 84), spin: 0),
            Cast(x: -150, z: 90, form: .box(size: 150), spin: 0.42),
            Cast(x: 40, z: -110, form: .cylinder(radius: 62, height: 232), spin: 0),
            Cast(x: 250, z: 40, form: .cone(radius: 76, height: 214), spin: 0),
            Cast(x: 452, z: -70, form: .torus(ring: 78, tube: 26), spin: 0.8),
        ]
    }

    /// ランプの位置。台の上を弧を描いて回る。
    ///
    /// `phase` は 0…1 の一巡。**時計ではなくフレーム番号から作る**ので、
    /// 何度走らせても同じ絵が出る（採寸の決定論と同じ理由）。
    static func lampPosition(phase: Float, width: Float) -> SIMD3<Float> {
        let a = phase * Float.pi * 2
        return SIMD3(
            width / 2 + cos(a) * 300,
            floorY - 470 - sin(a * 2) * 40,   // つねに台より上（-Y 側）
            floorZ + sin(a) * 200 + 180
        )
    }

    /// 静物を見るカメラ。台の中心をゆっくり回り込む。
    static func orbitEye(phase: Float, width: Float, height: Float) -> SIMD3<Float> {
        let a = phase * Float.pi * 2
        let r: Float = 760
        return SIMD3(
            width / 2 + sin(a) * r * 0.40,
            height / 2 - 10 - cos(a * 0.5) * 34,
            Optics.standardZ(height: height) + 90 + cos(a) * 80
        )
    }

    static func orbitCenter(width: Float, height: Float) -> SIMD3<Float> {
        SIMD3(width / 2, height / 2 + 130, floorZ)
    }
}

// MARK: - 舞台を描く

extension Sketch0816Atelier {

    /// `fill(_:_:_:)` へ 0–255 の三つ組をそのまま渡す。
    func fillRGB(_ c: SIMD3<Float>) { fill(c.x, c.y, c.z) }

    /// 奥の壁と台。`plane` は **XY 平面・法線 +Z** で生えるので、
    /// 台にするには x 軸まわりに 90° 倒す必要がある（倒すと法線が -Y = 画面の上向きになる）。
    func drawRoom() {
        noStroke()

        push()
        translate(width / 2, height / 2 - 40, Studio.wallZ)
        fillRGB(Palette.wall)
        plane(9000, 5200)
        pop()

        push()
        translate(width / 2, Studio.floorY, Studio.floorZ)
        rotateX(Float.pi / 2)
        fillRGB(Palette.table)
        plane(3400, 2600)
        pop()
    }

    /// 石膏の静物一式。
    func drawCasts(spin: Float) {
        noStroke()
        fillRGB(Palette.plaster)
        // **0…1 で渡す。** `specular(_ gray:)` は colorMode を通らないので、
        // fill と同じつもりで 120 を渡すと 120 倍の鏡面になって白く飛ぶ（場面 2 の V10 の実物）。
        specular(0.34)
        shininess(26)

        for c in Studio.casts() {
            push()
            translate(width / 2 + c.x, c.centerY(floorY: Studio.floorY), Studio.floorZ + c.z)
            rotateY(c.spin + spin)
            switch c.form {
            case .sphere(let r):
                sphere(r, detail: 40)
            case .box(let s):
                box(s)
            case .cylinder(let r, let h):
                cylinder(radius: r, height: h, detail: 40)
            case .cone(let r, let h):
                // 円錐は既定で頂点が +Y（= 画面の下）を向く。立てるには反転が要る。
                rotateZ(Float.pi)
                cone(radius: r, height: h, detail: 40)
            case .torus(let ring, let tube):
                torus(ringRadius: ring, tubeRadius: tube, detail: 44)
            }
            pop()
        }

        specular(0)
        shininess(32)
    }

    /// ランプ本体（自己発光する小さな球）。灯そのものは呼び出し側でライトとして足す。
    func drawLamp(at p: SIMD3<Float>) {
        push()
        translate(p.x, p.y, p.z)
        fillRGB(Palette.lamp)
        emissive(0.85)          // ここも 0…1。200 を渡すと灯ではなく白い穴になる

        sphere(18, detail: 20)
        emissive(0)
        pop()
    }
}
