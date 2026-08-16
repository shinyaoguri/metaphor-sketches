import Foundation
import metaphor

// 2 枚の感光層。この作品はここで焼いた 2 枚を、以降ずっと使い回す。
//
// **版 (plate) は 2D、被写体 (subject) は 3D。** 別々のオフスクリーンに焼いてから
// 重ねる、というのがこの作品の立ち位置で、同じフレームに混ぜるのは場面 4 だけ。
//
// 動きはすべて `frameCount` から導く。壁時計を使うと `shots` / `frames` の出力が
// 実行のたびに変わり、GIF と静止画が同じものを指さなくなる。

@MainActor
final class Layers {
    /// 2D の版。等高線と網点の銅版画。
    let plate: Graphics
    /// 3D の被写体。回る構成体。
    let subject: Graphics3D
    /// 講評欄（HUD）。**グラフを立てるとメインキャンバスの描画は画面に出ない**ので、
    /// 文字も層として焼いてグラフに載せるしかない。
    /// 公式サンプルが挙げる第一の用途（UI を別レイヤーに分ける）がそのまま要る。
    let hud: Graphics

    let w: Int
    let h: Int

    init?(sketch: Sketch0816Emulsion, width: Int, height: Int) {
        guard let plate = sketch.createGraphics(width, height),
              let subject = sketch.createGraphics3D(width, height),
              let hud = sketch.createGraphics(width, height) else { return nil }
        self.plate = plate
        self.subject = subject
        self.hud = hud
        self.w = width
        self.h = height
    }

    // MARK: - 2D の版

    /// 等高線の版を焼く。
    ///
    /// 暗室の印画紙に合わせて単色（青緑）に寄せ、**半透明の帯を必ず含める**。
    /// α が 1 の絵しか焼かないと `.alpha` 合成の検証が空振りする。
    func exposePlate(frame: Int) {
        let fw = Float(w), fh = Float(h)
        let t = Float(frame) * 0.004

        plate.beginDraw()
        // 版の下地。**完全な透明**にしておく。ここを不透明にすると、
        // `.alpha` で重ねたとき下の層が最初から見えなくなる。
        plate.background(0, 0, 0, 0)
        plate.noFill()

        // 等高線 — 中心をずらした同心の輪を、ハッシュで歪ませる
        //
        // **α は 0–255。** `fill` / `stroke` の第 4 引数は既定の colorMode に従うので
        // 0…1 で渡すと実質ゼロになり、何も見えなくなる（実際に一度そうして、
        // 版が真っ白ならぬ真っ黒のまま出た）。0…1 なのは `Color` の方。
        plate.strokeWeight(1.4)
        let rings = 26
        for i in 0..<rings {
            let k = Float(i) / Float(rings)
            let radius = 60 + k * fh * 0.62
            let alpha = (0.22 + 0.5 * (1 - k)) * 255
            plate.stroke(120 + 60 * k, 210 - 40 * k, 235, alpha)
            plate.beginShape(.polygon)
            let steps = 96
            for s in 0...steps {
                let a = Float(s) / Float(steps) * .pi * 2
                // 決定論的な歪み。時刻ではなく frame から作る
                let wob = 1 + 0.10 * sin(a * 3 + t * 6 + Float(i) * 0.7)
                          + 0.05 * sin(a * 7 - t * 4 + Float(i) * 0.3)
                plate.vertex(fw * 0.5 + cos(a) * radius * wob,
                             fh * 0.5 + sin(a) * radius * wob * 0.82)
            }
            plate.endShape(.close)
        }

        // 網点 — 版らしさを出す。**ここは半透明**で焼く（α の検証に効く帯）
        plate.noStroke()
        let dots = 420
        for i in 0..<dots {
            let x = Emulsion.hash(i, 0) * fw
            let y = Emulsion.hash(i, 1) * fh
            let r = 1.2 + Emulsion.hash(i, 2) * 3.4
            plate.fill(200, 240, 255, (0.10 + Emulsion.hash(i, 3) * 0.35) * 255)
            plate.circle(x, y, r)
        }

        // 版木の縁。四隅を締めて「紙」に見せる
        plate.noFill()
        plate.strokeWeight(2)
        plate.stroke(150, 220, 240, (0.55) * 255)
        plate.beginShape(.polygon)
        plate.vertex(28, 28); plate.vertex(fw - 28, 28)
        plate.vertex(fw - 28, fh - 28); plate.vertex(28, fh - 28)
        plate.endShape(.close)

        plate.endDraw()
    }

    // MARK: - 3D の被写体

    /// 被写体を焼く。
    ///
    /// `Graphics3D` には `background()` が無い（`Graphics` にはある）。
    /// つまり**下地の色を選べない**。ここが `.alpha` 合成の成否を握るので、
    /// 何色でクリアされているのかは `Darkroom` の `L3` で実測する。
    func exposeSubject(frame: Int) {
        let fw = Float(w), fh = Float(h)
        let spin = Float(frame) * 0.011

        subject.beginDraw(time: Float(frame) / 60)

        // 既定カメラに頼らず自分で置く。z = 0 平面で 1 ワールド単位 = 1px になる距離。
        let fov: Float = .pi / 3
        let z = (fh / 2) / tan(fov / 2)
        subject.perspective(fov: fov, near: 0.1, far: 10000)
        subject.camera(eye: SIMD3(fw / 2, fh / 2, z),
                       center: SIMD3(fw / 2, fh / 2, 0),
                       up: SIMD3(0, 1, 0))

        subject.ambientLight(0.18)
        subject.directionalLight(-0.4, -0.7, -0.6, color: Color(SIMD4(1.0, 0.92, 0.80, 1)))
        subject.directionalLight(0.6, 0.3, 0.4, color: Color(SIMD4(0.35, 0.45, 0.70, 1)))
        subject.specular(0.6)
        subject.shininess(28)

        subject.noStroke()
        subject.pushMatrix()
        subject.translate(fw / 2, fh / 2, 0)
        subject.rotateY(spin)
        subject.rotateX(0.42 + 0.18 * sin(spin * 0.6))

        // 芯の球
        subject.fill(Color(SIMD4(0.94, 0.72, 0.38, 1)))
        subject.sphere(74, detail: 40)

        // 環 — 3 枚を直交させて構成体にする
        let ringColors: [SIMD4<Float>] = [
            SIMD4(0.86, 0.55, 0.30, 1),
            SIMD4(0.72, 0.44, 0.52, 1),
            SIMD4(0.55, 0.62, 0.72, 1),
        ]
        for (i, c) in ringColors.enumerated() {
            subject.pushMatrix()
            subject.rotateX(Float(i) * .pi / 3)
            subject.rotateZ(Float(i) * .pi / 4 + spin * 0.5)
            subject.fill(Color(c))
            subject.torus(ringRadius: 132 + Float(i) * 26, tubeRadius: 7, detail: 44)
            subject.popMatrix()
        }

        // 衛星 — 決定論的な位置に小さな箱を撒く
        for i in 0..<9 {
            let a = Float(i) / 9 * .pi * 2 + spin * 0.8
            let r: Float = 200 + Emulsion.hash(i, 5) * 60
            subject.pushMatrix()
            subject.translate(cos(a) * r, sin(a) * r * 0.7, sin(a * 1.7) * 90)
            subject.rotateY(a * 2)
            subject.rotateX(a)
            subject.fill(Color(SIMD4(0.90, 0.86, 0.78, 1)))
            subject.box(14 + Emulsion.hash(i, 6) * 12)
            subject.popMatrix()
        }

        subject.popMatrix()
        // CPU 側でテクスチャを読む場面があるので、完了を待ってから返す。
        // `wait: false` のままだと古い内容を読み得る（`L4` で実測する）。
        subject.endDraw(wait: true)
    }

    // MARK: - 講評欄

    /// 下端の講評欄を焼く。判定の要約と、いま何を見ているかを出す。
    func exposeHUD(title: String, caption: String, tally: String, allPassed: Bool, lines: [String]) {
        let fw = Float(w), fh = Float(h)
        let barH: Float = 118

        hud.beginDraw()
        hud.background(0, 0, 0, 0)

        // 欄の下地。半透明の黒で、絵を透かしたまま文字を読ませる
        hud.noStroke()
        hud.fill(6, 9, 14, (0.72) * 255)
        hud.rect(0, fh - barH, fw, barH)
        hud.fill(150, 220, 240, (0.5) * 255)
        hud.rect(0, fh - barH, fw, 1)

        hud.fill(235, 244, 250, (0.95) * 255)
        hud.textSize(19)
        hud.text(title, 26, fh - barH + 30)

        hud.fill(168, 196, 214, (0.9) * 255)
        hud.textSize(13)
        hud.text(caption, 26, fh - barH + 54)

        // 判定の要約。FAIL があれば朱を入れる
        hud.textSize(13)
        hud.fill(allPassed ? Color(SIMD4(0.62, 0.85, 0.66, 0.95))
                           : Color(SIMD4(0.94, 0.42, 0.36, 0.98)))
        hud.text(tally, 26, fh - barH + 78)

        hud.textSize(12)
        hud.fill(196, 210, 222, (0.85) * 255)
        var y = fh - barH + 78
        for line in lines.prefix(3) {
            hud.text(line, 300, y)
            y += 16
        }

        // 右肩の作品名
        hud.textAlign(.right)
        hud.fill(120, 150, 170, (0.8) * 255)
        hud.textSize(12)
        hud.text("0816-emulsion", fw - 26, fh - barH + 30)
        hud.textAlign(.left)

        hud.endDraw()
    }
}

// MARK: - 共有の小道具

enum Emulsion {
    /// 決定論的なハッシュ。同じ (i, k) には常に同じ値を返す。
    /// 乱数源を持ち込むと `shots` と `frames` が別物になる。
    static func hash(_ i: Int, _ k: Int) -> Float {
        let v = sin(Float(i) * 12.9898 + Float(k) * 78.233) * 43758.5453
        return v - floor(v)
    }

    /// 標準出力へ 1 行。**`fflush` とセットにする。**
    /// パイプへ流すとブロックバッファされ、「動いていない」と誤診する
    /// （#10 で実際に一度誤診した）。
    static func say(_ s: String) {
        print(s)
        fflush(stdout)
    }
}
