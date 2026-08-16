import Foundation
import simd
import metaphor

// 講評。画面に出る文字と朱はここが受け持つ。
//
// **判定より後にしか描かない。** 読み戻しの前に文字や罫を置くと、
// シルエットの外接矩形にそれが混ざる（0816-galley で同じ順番の縛りを置いている）。
//
// 折り返しのある `text(_:_:_:_:_:)`（箱版）は使わない。
// 複数行が折り返されず上下反転もする既知の穴があるため（metaphor#744 / #504）。

extension Sketch0816Atelier {

    private var panelWidth: Float { 470 }

    // MARK: 採寸台の見出し

    func drawSpecimenCaption(_ stage: Stage, _ index: Int, _ s: Specimen, local: Int) {
        let total = specimenList(stage).count
        textFont("Helvetica")

        // 上の帯: 場面と進み具合。
        fillRGB(Palette.ink)
        textAlign(.left, .top)
        textSize(15)
        text("採寸  \(stage.letter)  \(stage.title) — \(stage.subtitle)", 36, 30)

        textSize(13)
        fillRGB(Palette.blue)
        text("標本 \(index + 1) / \(total)  —  \(s.name)", 36, 54)

        // 下の帯: 標本名と、何を測っているのか。
        fillRGB(Palette.ink)
        textAlign(.left, .baseline)
        textSize(20)
        text(s.title, 36, height - 66)
        textSize(13)
        fillRGB(Palette.blue)
        text(s.note, 36, height - 40)

        // 進行のバー。ホールドの残りが見えると、止まっているのか進んでいるのかが分かる。
        let held = Float(local % Timing.holdFrames) / Float(Timing.holdFrames)
        noStroke()
        fill(Palette.blue.x, Palette.blue.y, Palette.blue.z, 90)
        rect(0, height - 4, width * (Float(index) + held) / Float(total), 4)
    }

    // MARK: 素描の見出し

    func drawStudyCaption(_ stage: Stage, progress: Float) {
        textFont("Helvetica")
        fillRGB(Palette.ink)
        textAlign(.left, .top)
        textSize(15)
        text("素描  \(stage.letter)  \(stage.title)", 36, 30)
        textSize(13)
        fillRGB(Palette.blue)
        text("石膏デッサン — ランプが回り、カメラが台を回り込む", 36, 54)

        noStroke()
        fill(Palette.blue.x, Palette.blue.y, Palette.blue.z, 60)
        rect(0, height - 4, width * progress, 4)
    }

    // MARK: 講評欄

    /// その場面の判定を右上に積む。直し（FAIL）は朱で、要確認は青で。
    func drawCritique(_ stage: Stage) {
        let mine = findings.filter { $0.id.hasPrefix(stage.letter) }
        guard !mine.isEmpty else { return }

        let rows = min(mine.count, 16)
        let lineH: Float = 17
        let panelH = Float(rows) * lineH + 46
        let x = width - panelWidth - 24
        let y: Float = 24

        noStroke()
        fill(10, 12, 16, 190)
        rect(x, y, panelWidth, panelH, 6)

        let fails = mine.filter { $0.verdict.isFail }.count
        let looks = mine.filter { if case .look = $0.verdict { return true }; return false }.count

        textFont("Helvetica")
        textAlign(.left, .top)
        textSize(13)
        fillRGB(Palette.ink)
        text("講評  \(stage.title)  \(mine.count) 項  直し \(fails)  要確認 \(looks)", x + 14, y + 12)

        textSize(11)
        for (k, f) in mine.prefix(rows).enumerated() {
            let ly = y + 34 + Float(k) * lineH
            switch f.verdict {
            case .pass: fillRGB(Palette.green)
            case .fail: fillRGB(Palette.red)
            case .look: fillRGB(Palette.blue)
            }
            text(f.verdict.mark, x + 14, ly)
            fillRGB(Palette.ink)
            text(f.id, x + 56, ly)
            fill(Palette.ink.x, Palette.ink.y, Palette.ink.z, 170)
            text(clip(f.title, 26), x + 220, ly)
        }

        if mine.count > rows {
            fill(Palette.ink.x, Palette.ink.y, Palette.ink.z, 140)
            text("ほか \(mine.count - rows) 項（全文は標準出力と frame.json へ）",
                 x + 14, y + 34 + Float(rows) * lineH)
        }
    }

    /// 欄に収まらない題を落とす。`textWidth` を使わないのは、この作品の判定と
    /// 無関係な計量の穴（metaphor#802）を持ち込まないため。
    private func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    // MARK: - 落ちうる口

    /// **頼んだときだけ**再現する。
    ///
    /// 落ちうる呼び出しを常時の検査に混ぜると、直っていない環境では
    /// **作品そのものが起動しなくなる**（0816-marionette で実際にそうなった）。
    /// なので環境変数の裏に置き、`tools/probe.sh trap <名前>` からだけ叩く。
    func runTrap(_ name: String) {
        emit("trap: \(name)")
        switch name {
        case "detailNegative":
            emit("sphere(100, detail: -8) / torus(detail: -3) — 分割は下限 3 へ丸められる仕様")
            noLights(); fill(200, 140, 80)
            push(); translate(axis.x - 200, axis.y, 0); sphere(100, detail: -8); pop()
            push(); translate(axis.x + 200, axis.y, 0)
            torus(ringRadius: 100, tubeRadius: 30, detail: -3); pop()

        case "detailZero":
            emit("cylinder(detail: 0) / cone(detail: 0)")
            noLights(); fill(200, 140, 80)
            push(); translate(axis.x - 200, axis.y, 0)
            cylinder(radius: 80, height: 160, detail: 0); pop()
            push(); translate(axis.x + 200, axis.y, 0)
            cone(radius: 80, height: 160, detail: 0); pop()

        case "zeroSize":
            emit("plane(0, 0) / box(0) / sphere(0) / torus(0, 0)")
            noLights(); fill(200, 140, 80)
            push(); translate(axis.x, axis.y, 0)
            plane(0, 0); box(0); sphere(0); torus(ringRadius: 0, tubeRadius: 0)
            pop()

        case "negativeSize":
            emit("box(-120) / sphere(-80) / cylinder(radius: -50, height: -50)")
            noLights(); fill(200, 140, 80)
            push(); translate(axis.x, axis.y, 0)
            box(-120); sphere(-80); cylinder(radius: -50, height: -50)
            pop()

        case "meshZero":
            emit("createBoxMesh(0) / createSphereMesh(0, detail: 0) / createTorusMesh(0, 0)")
            let a = createBoxMesh(0)
            let b = createSphereMesh(0, detail: 0)
            let c = createTorusMesh(ringRadius: 0, tubeRadius: 0, detail: 0)
            emit("box=\(a == nil ? "nil" : "生成") sphere=\(b == nil ? "nil" : "生成") torus=\(c == nil ? "nil" : "生成")")

        case "shadowZero":
            emit("enableShadows(resolution: 0)")
            enableShadows(resolution: 0)

        case "shadowNegative":
            emit("enableShadows(resolution: -1)")
            enableShadows(resolution: -1)

        case "orthoDegenerate":
            emit("ortho(left: 100, right: 100, bottom: 100, top: 100) — 幅ゼロの視体積")
            ortho(left: 100, right: 100, bottom: 100, top: 100)
            noLights(); fill(200, 140, 80)
            push(); translate(axis.x, axis.y, 0); box(120); pop()
            emit("screenX=\(screenX(axis.x, axis.y, 0)) screenZ=\(screenZ(axis.x, axis.y, 0))")

        case "cameraDegenerate":
            emit("camera(eye: p, center: p) — 視線方向が定義できない")
            let p = SIMD3<Float>(axis.x, axis.y, 200)
            camera(eye: p, center: p)
            noLights(); fill(200, 140, 80)
            push(); translate(axis.x, axis.y, 0); box(120); pop()
            emit("screenX=\(screenX(axis.x, axis.y, 0)) screenY=\(screenY(axis.x, axis.y, 0))")

        case "materialBadSource":
            emit("createMaterial に通らない MSL を渡す")
            do {
                _ = try createMaterial(source: "not metal at all", fragmentFunction: "nope")
                emit("例外が飛ばなかった")
            } catch {
                emit("例外: \(error)")
            }

        default:
            emit("使い方: ATELIER_TRAP=<detailNegative|detailZero|zeroSize|negativeSize|meshZero"
                 + "|shadowZero|shadowNegative|orthoDegenerate|cameraDegenerate|materialBadSource>")
        }
        emit("trap: \(name) は落ちずに戻った")
    }
}
