import Darwin
import metaphor

/// メモリストレステスト。
///
/// 負荷の種類をフェーズで切り替えながら自プロセスの phys_footprint を
/// 毎フレーム記録し、フェーズ別のメモリ挙動を stdout と Probe に報告する。
///
/// 読み方:
/// - フェーズ内で前半平均 → 後半平均が増え続ける = そのフェーズ固有の蓄積疑い
/// - cooldown が warmup 水準に戻らない = 解放されない蓄積（リーク疑い）
///   ※ キャッシュ（グリフ等）による定常増加は設計次第で正常。増加が
///     「有界か無限か」をフェーズ内の傾きで見る。
@main
final class Sketch0718MemoryStress: Sketch {
    var config: SketchConfig {
        SketchConfig(width: 1280, height: 720, title: "0718-memory-stress")
    }

    struct Phase {
        let name: String
        let frames: Int
    }

    /// 既定のフェーズ列。`METAPHOR_STRESS_PHASES`（カンマ区切り、同名複数可）で
    /// 上書きできる — 劣化の犯人フェーズを二分探索するための構成替え用。
    let phases: [Phase] = {
        let defaultFrames: [String: Int] = [
            "warmup": 240, "shapes2d": 480, "shapes3d": 480, "bigGeometry": 480,
            "text": 480, "pixels": 480, "postfx": 480, "cooldown": 480,
        ]
        let defaultOrder = [
            "warmup", "shapes2d", "shapes3d", "bigGeometry",
            "text", "pixels", "postfx", "cooldown",
        ]
        let names: [String]
        if let spec = ProcessInfo.processInfo.environment["METAPHOR_STRESS_PHASES"] {
            names = spec.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        } else {
            names = defaultOrder
        }
        return names.compactMap { name in
            defaultFrames[name].map { Phase(name: name, frames: $0) }
        }
    }()

    /// 2 周回す: 2 周目が 1 周目と同水準なら「経路初回確保の常駐プール（有界）」、
    /// 周回ごとに増えるなら「解放されない蓄積（リーク疑い）」と切り分けられる。
    /// `METAPHOR_STRESS_CYCLES` で上書き可。
    let cycles = ProcessInfo.processInfo.environment["METAPHOR_STRESS_CYCLES"]
        .flatMap(Int.init) ?? 2
    /// 最終周の cooldown は外部の `leaks` 検査が完走できるよう長く取る。
    let finalCooldownFrames = 1500

    var cycle = 0
    var phaseIndex = 0
    var frameInPhase = 0
    var totalFrames = 0
    var samples: [Double] = []
    var summary: [String] = []
    var phaseStartedAt: Float = 0

    /// App Nap / バックグラウンド QoS 降格を防ぐ activity assertion。
    /// これが無いと、ウィンドウのフォーカス状態次第でタイマー間引きが起き、
    /// fps 計測が実行ごとに大きくブレる（thermal=nominal のまま全体が減速する）。
    var activityToken: NSObjectProtocol?

    func setup() {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "memory stress measurement"
        )
        frameRate(60)
        randomSeed(42)
        print("[stress] start footprint=\(fmt(footprintMB()))MB")
    }

    func draw() {
        let phase = phases[phaseIndex]
        if frameInPhase == 0 {
            enterPhase(phase.name)
        }

        background(12, 12, 16)
        drawPhase(phase.name)

        let footprint = footprintMB()
        samples.append(footprint)
        probe("stress.phaseIndex", phaseIndex)
        probe("stress.phase", phase.name)
        probe("stress.frameInPhase", frameInPhase)
        probe("stress.footprintMB", footprint)

        frameInPhase += 1
        totalFrames += 1
        if frameInPhase >= frames(for: phase) {
            exitPhase(phase.name)
            frameInPhase = 0
            phaseIndex += 1
            if phaseIndex == phases.count {
                phaseIndex = 0
                cycle += 1
                if cycle >= cycles {
                    printFinalReport()
                    exit(0)
                }
            }
        }
    }

    private func frames(for phase: Phase) -> Int {
        if phase.name == "cooldown", cycle == cycles - 1 {
            return finalCooldownFrames
        }
        return phase.frames
    }

    // MARK: - フェーズ描画

    private func drawPhase(_ name: String) {
        switch name {
        case "warmup", "cooldown":
            // ほぼ空: ベースラインの water mark を取る
            noStroke()
            fill(200, 200, 220)
            circle(width / 2, height / 2, 40)

        case "shapes2d":
            // 2D 図形を毎フレーム 5,000 個（決定論的配置）
            noStroke()
            for i in 0..<5000 {
                let fi = Float(i)
                let x = (sin(time * 0.7 + fi * 0.618) * 0.5 + 0.5) * width
                let y = (cos(time * 0.9 + fi * 0.377) * 0.5 + 0.5) * height
                fill(80 + fi.truncatingRemainder(dividingBy: 160), 120, 220, 160)
                circle(x, y, 6)
            }

        case "shapes3d":
            // 3D プリミティブ 1,200 個（インスタンシング経路 + ライティング）
            lights()
            noStroke()
            for i in 0..<1200 {
                let fi = Float(i)
                push()
                translate(
                    (sin(fi * 0.618 + time * 0.3) * 0.45 + 0.5) * width,
                    (cos(fi * 0.377 + time * 0.4) * 0.45 + 0.5) * height,
                    -150 - fi.truncatingRemainder(dividingBy: 400)
                )
                rotateX(time + fi)
                rotateY(time * 0.7 + fi)
                fill(90 + fi.truncatingRemainder(dividingBy: 150), 140, 230)
                if i % 4 == 0 {
                    sphere(9, detail: 16)
                } else {
                    box(14)
                }
                pop()
            }

        case "bigGeometry":
            // 毎フレーム形が変わる大型カスタムシェイプ（約 9 万頂点/フレーム）
            noStroke()
            fill(70, 190, 190, 200)
            for band in 0..<3 {
                let fb = Float(band)
                beginShape(.triangleStrip)
                let n = 15000
                for i in 0..<n {
                    let t = Float(i) / Float(n - 1)
                    let x = t * width
                    let mid = height * (0.25 + 0.25 * fb)
                    let wobble = sin(t * 40 + time * 2 + fb * 2.1) * 60
                    vertex(x, mid + wobble - 14)
                    vertex(x, mid + wobble + 14)
                }
                endShape()
            }

        case "text":
            // 毎フレーム新しい文字種（CJK を巡回）でグリフキャッシュを膨張させる
            fill(235)
            textSize(15)
            for row in 0..<20 {
                var line = ""
                for col in 0..<16 {
                    let code = 0x4E00 + (totalFrames * 20 + row * 16 + col) % 6000
                    line.append(Character(UnicodeScalar(code)!))
                }
                text(line, 24, 30 + Float(row) * 32)
            }

        case "pixels":
            // 全ピクセル読み戻し → 書き換え → 再アップロード（CPU⇄GPU 転送）
            noStroke()
            fill(230, 120, 60)
            circle(width / 2 + sin(time * 3) * 300, height / 2, 120)
            loadPixels()
            let buffer = pixels
            for i in 0..<buffer.count {
                buffer[i] = buffer[i] &+ 0x00010101
            }
            updatePixels()

        case "postfx":
            // ポストプロセスチェーン（bloom + blur）を通す。描画自体は軽め
            noStroke()
            for i in 0..<500 {
                let fi = Float(i)
                let x = (sin(time * 0.8 + fi * 0.618) * 0.5 + 0.5) * width
                let y = (cos(time * 1.1 + fi * 0.377) * 0.5 + 0.5) * height
                fill(200 + fi.truncatingRemainder(dividingBy: 55), 180, 120)
                circle(x, y, 10)
            }

        default:
            break
        }
    }

    private func enterPhase(_ name: String) {
        samples.removeAll(keepingCapacity: true)
        phaseStartedAt = time
        if name == "postfx" {
            addPostEffect(BloomEffect(intensity: 1.2, threshold: 0.5))
            addPostEffect(BlurEffect(radius: 6))
        }
        print("[stress] cycle=\(cycle + 1)/\(cycles) phase=\(name) begin footprint=\(fmt(footprintMB()))MB")
    }

    private func exitPhase(_ name: String) {
        if name == "postfx" {
            clearPostEffects()
        }
        let elapsed = time - phaseStartedAt
        let fps = elapsed > 0 ? Double(samples.count) / Double(elapsed) : 0
        let half = samples.count / 2
        let firstHalf = average(Array(samples.prefix(half)))
        let secondHalf = average(Array(samples.suffix(samples.count - half)))
        let line = "[stress] cycle=\(cycle + 1)/\(cycles) phase=\(name) frames=\(samples.count)"
            + " fps=\(fmt(fps))"
            + " firstHalf=\(fmt(firstHalf))MB secondHalf=\(fmt(secondHalf))MB"
            + " slope=\(fmt(secondHalf - firstHalf))MB"
            + " max=\(fmt(samples.max() ?? 0))MB"
            + " thermal=\(thermalLabel)"
        summary.append(line)
        print(line)
    }

    /// 熱スロットリング判定用。fps 劣化が thermal=serious 以降と同期していれば
    /// ライブラリではなく SoC の熱が原因。
    private var thermalLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func printFinalReport() {
        print("[stress] ===== final report =====")
        for line in summary {
            print(line)
        }
        print("[stress] end footprint=\(fmt(footprintMB()))MB totalFrames=\(totalFrames)")
    }

    // MARK: - 計測

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    private func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
