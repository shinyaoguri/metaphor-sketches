import Foundation
import metaphor

/// 三連祭壇画が映す、ただ 1 つの世界。
///
/// 3 枚のパネル（中央 = プライマリウィンドウ、左右の翼 = セカンダリウィンドウ）は、
/// この横長の世界を x 方向に切り分けて同時に描く。パネルが知っているのは自分の原点だけで、
/// 描く中身は全パネル共通のこの関数から出てくる。
///
/// **継ぎ目で絵が繋がるかどうかは「3 枚が同じ世界の同じ時刻を見ているか」に帰着する。**
/// metaphor のセカンダリウィンドウは 1 枚ごとに独立したレンダラー・レンダーループ・時計を
/// 持つので、ここは自明ではない。そこを絵と数値の両方で炙り出すのがこの作品の主題。
@MainActor
enum World {
    /// 左翼 800 + 中央 1280 + 右翼 800。
    static let width: Float = 2880
    static let height: Float = 720

    /// 地平線の y。全パネルで共通なので、ここがずれて見えたらパネルの高さが揃っていない。
    static let horizon: Float = 468

    /// 太陽が世界を 1 周する秒数。ゆっくり動くので「時計のずれ」ではなく「絵の連続性」を見る役。
    static let sunCycle: Float = 90

    /// 光の帯が世界を 1 周する秒数。世界幅 2880px を 6 秒 = 480px/s で走るため、
    /// 16.7ms（1 フレーム）の時計ずれが約 8px の跳びとして継ぎ目に出る。**時計の検流計**。
    static let bandCycle: Float = 6

    /// 行列の人数。
    static let marcherCount = 56

    // MARK: - 配色（0…1 正規化の Color で統一する。fill(0–255) と混ぜない）

    static let skyDawn = Color(r: 0.35, g: 0.22, b: 0.30)
    static let skyNoon = Color(r: 0.16, g: 0.24, b: 0.40)
    static let skyDusk = Color(r: 0.42, g: 0.24, b: 0.20)
    static let groundNear = Color(r: 0.07, g: 0.06, b: 0.09)
    static let groundFar = Color(r: 0.14, g: 0.13, b: 0.18)
    static let gold = Color(r: 0.85, g: 0.70, b: 0.36)

    // MARK: - 行列

    /// 世界を渡り続ける 1 人。
    struct Marcher {
        var start: Float   // 世界座標の初期 x
        var speed: Float   // px/s
        var scale: Float   // 背丈
        var phase: Float   // 歩調の位相
        var depth: Float   // 0 = 奥、1 = 手前
    }

    /// 決定論的に行列を組む（`randomSeed` を撒いてから呼ぶこと）。
    static func makeMarchers() -> [Marcher] {
        randomSeed(20_260_816)
        return (0..<marcherCount).map { _ in
            let depth = random(0, 1)
            return Marcher(
                start: random(0, width),
                // 奥ほど遅く小さい。手前ほど速い（視差）
                speed: 14 + depth * 26,
                scale: 0.45 + depth * 0.75,
                phase: random(0, .pi * 2),
                depth: depth
            )
        }
    }

    // MARK: - 描画

    /// 1 枚のパネルを描く。
    ///
    /// - Parameters:
    ///   - ctx: そのパネルの描画コンテキスト（中央は `Sketch.context`、翼は `SketchWindow.context`）。
    ///   - panel: 世界のどこを切り出すか。
    ///   - clock: **描画に使う時刻**。3 枚に同じ値を渡すのが「揃った祭壇画」。
    ///   - stage: 灯など、パネルを跨いで共有する状態。
    static func render(into ctx: SketchContext, panel: Panel, clock: Float, stage: Stage) {
        let ox = panel.origin
        let pw = panel.width

        ctx.noStroke()

        // --- 空。世界全体に 1 枚の横グラデーションを敷き、パネルはその一部を見る ---
        ctx.background(Color(r: 0.05, g: 0.05, b: 0.07))
        ctx.linearGradient(-ox, 0, width * 0.5, horizon, skyDawn, skyNoon, axis: .horizontal)
        ctx.linearGradient(-ox + width * 0.5, 0, width * 0.5, horizon, skyNoon, skyDusk, axis: .horizontal)

        // --- 太陽。世界を 90 秒で 1 周する。継ぎ目を跨ぐ大きな円は絵で連続性が分かる ---
        let u = wrap01(clock / sunCycle)
        let sunX = u * width - ox
        let sunY = horizon - sin(Float.pi * u) * 330 - 24
        if sunX > -260 && sunX < pw + 260 {
            for ring in stride(from: 5, through: 1, by: -1) {
                let k = Float(ring)
                ctx.fill(Color(r: 1.0, g: 0.82, b: 0.52, alpha: 0.055 * (6 - k)))
                ctx.circle(sunX, sunY, 92 + k * 42)
            }
            ctx.fill(Color(r: 1.0, g: 0.93, b: 0.76))
            ctx.circle(sunX, sunY, 88)
        }

        // --- 遠景の稜線を 3 層。ノイズは世界座標で引くので継ぎ目で必ず繋がるはず ---
        let layers: [(freq: Float, amp: Float, base: Float, color: Color)] = [
            (0.0016, 96, horizon - 118, Color(r: 0.20, g: 0.20, b: 0.28)),
            (0.0029, 66, horizon - 62, Color(r: 0.13, g: 0.13, b: 0.19)),
            (0.0051, 38, horizon - 22, Color(r: 0.09, g: 0.09, b: 0.13)),
        ]
        let step: Float = 6
        for layer in layers {
            ctx.fill(layer.color)
            var i: Float = -step
            while i <= pw + step {
                let wx = ox + i
                let h = noise(wx * layer.freq) * layer.amp
                let top = layer.base - h
                ctx.rect(i, top, step + 1, horizon - top + 2)
                i += step
            }
        }

        // --- 地面 ---
        ctx.fill(groundFar)
        ctx.rect(0, horizon, pw, height - horizon)
        ctx.linearGradient(0, horizon, pw, height - horizon, groundFar, groundNear, axis: .vertical)

        // --- 灯（クリックで置かれる。世界座標で持つのでどのパネルからでも見える） ---
        for lantern in stage.lanterns {
            let lx = lantern.x - ox
            guard lx > -160 && lx < pw + 160 else { continue }
            for ring in stride(from: 4, through: 1, by: -1) {
                let k = Float(ring)
                ctx.fill(Color(r: 1.0, g: 0.78, b: 0.42, alpha: 0.05 * (5 - k)))
                ctx.circle(lx, lantern.y, 30 + k * 34)
            }
            ctx.fill(gold)
            ctx.circle(lx, lantern.y, 13)
        }

        // --- 行列。世界を左から右へ延々と渡る ---
        for m in stage.marchers {
            let wx = wrapPositive(m.start + m.speed * clock, width)
            // 継ぎ目を跨ぐ人を落とさないよう、世界の折り返しぶんも当たりを取る
            for candidate in [wx, wx - width, wx + width] {
                let x = candidate - ox
                guard x > -60 && x < pw + 60 else { continue }
                drawMarcher(ctx, x: x, m: m, clock: clock, worldX: candidate, stage: stage)
            }
        }

        // --- 光の帯。速いので、時計がずれていれば継ぎ目でここが跳ぶ ---
        let bandX = wrap01(clock / bandCycle) * width - ox
        for candidate in [bandX, bandX - width, bandX + width] {
            guard candidate > -90 && candidate < pw + 90 else { continue }
            for k in stride(from: 3, through: 1, by: -1) {
                let f = Float(k)
                ctx.fill(Color(r: 0.75, g: 0.88, b: 1.0, alpha: 0.05 * (4 - f)))
                ctx.rect(candidate - f * 22, 0, f * 44, height)
            }
            ctx.fill(Color(r: 0.92, g: 0.97, b: 1.0, alpha: 0.55))
            ctx.rect(candidate - 1.5, 0, 3, height)
        }

        drawRuler(ctx, panel: panel)
        drawFrame(ctx, panel: panel, clock: clock)
    }

    /// 行列の 1 人。灯に近づくと暖色に灯る。
    private static func drawMarcher(
        _ ctx: SketchContext, x: Float, m: Marcher, clock: Float, worldX: Float, stage: Stage
    ) {
        let s = m.scale
        let y = horizon + 6 + m.depth * 34
        let bob = sin(clock * 5.4 + m.phase) * 2.6 * s
        let bodyH = 54 * s
        let top = y - bodyH + bob

        // もっとも近い灯からの距離で灯り具合を決める
        var glow: Float = 0
        for lantern in stage.lanterns {
            let d = abs(lantern.x - worldX)
            glow = max(glow, max(0, 1 - d / 210))
        }

        let base = Color(r: 0.03, g: 0.03, b: 0.05)
        let lit = Color(r: 0.96, g: 0.72, b: 0.40)
        let body = base.lerp(to: lit, t: glow * 0.85)

        ctx.noStroke()
        ctx.fill(body)
        // 衣（裾が広がる三角）
        ctx.triangle(x, top, x - 11 * s, y + bob, x + 11 * s, y + bob)
        // 頭巾
        ctx.circle(x, top + 2 * s, 15 * s)
        // 杖
        ctx.stroke(body)
        ctx.strokeWeight(max(1, 2 * s))
        let swing = sin(clock * 5.4 + m.phase) * 5 * s
        ctx.line(x + 12 * s, top + 8 * s, x + 12 * s + swing, y + bob + 4)
        ctx.noStroke()

        // 灯に照らされた足元の影
        if glow > 0.02 {
            ctx.fill(Color(r: 1.0, g: 0.78, b: 0.45, alpha: glow * 0.22))
            ctx.circle(x, y + bob + 3, 46 * s)
        }
    }

    /// 世界座標の物差し。**3 枚を並べたとき、この目盛りが連続していれば継ぎ目は合っている。**
    /// 作品自身が自分を測る定規を持つ（このリポジトリの流儀）。
    private static func drawRuler(_ ctx: SketchContext, panel: Panel) {
        let ox = panel.origin
        let y = height - 26
        ctx.noStroke()
        ctx.fill(Color(r: 0, g: 0, b: 0, alpha: 0.45))
        ctx.rect(0, y - 12, panel.width, 38)

        ctx.textSize(10)
        var wx = (ox / 100).rounded(.down) * 100
        while wx <= ox + panel.width {
            let x = wx - ox
            if x >= 0 && x <= panel.width {
                let major = wx.truncatingRemainder(dividingBy: 400) == 0
                ctx.fill(gold.withAlpha(major ? 0.95 : 0.4))
                ctx.rect(x, y, 1, major ? 12 : 6)
                if major {
                    ctx.text("\(Int(wx))", x + 4, y + 12)
                }
            }
            wx += 100
        }
    }

    /// パネルの額縁と銘。ウィンドウの位置を指定する API が無いので、**人が並べるための手掛かり**を
    /// 絵の中に書いておく（この不便さ自体が検証結果のひとつ）。
    private static func drawFrame(_ ctx: SketchContext, panel: Panel, clock: Float) {
        ctx.noFill()
        ctx.stroke(gold.withAlpha(0.55))
        ctx.strokeWeight(3)
        ctx.rect(1.5, 1.5, panel.width - 3, height - 3)
        ctx.noStroke()

        ctx.fill(Color(r: 0, g: 0, b: 0, alpha: 0.5))
        ctx.rect(14, 14, 236, 46)
        ctx.fill(gold)
        ctx.textSize(15)
        ctx.text(panel.name, 24, 34)
        ctx.textSize(11)
        ctx.fill(Color(r: 0.8, g: 0.8, b: 0.86))
        ctx.text("世界 x \(Int(panel.origin))–\(Int(panel.origin + panel.width))   t=\(String(format: "%.2f", clock))s", 24, 50)
    }

    // MARK: - 小道具

    static func wrap01(_ v: Float) -> Float {
        let f = v - v.rounded(.down)
        return f < 0 ? f + 1 : f
    }

    static func wrapPositive(_ v: Float, _ m: Float) -> Float {
        let r = v.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }
}
