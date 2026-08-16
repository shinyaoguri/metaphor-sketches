import Foundation
import metaphor
import simd

/// 音で深さを測る。
///
/// 自分で合成した音（`Score`）を鳴らし、それを解析し返して、帯域エネルギーで
/// ノイズ場（`Field`）を彫る。見えているのは海図 — 深度で色分けした場の上に等深線 — で、
/// ビートごとにソナーの ping が広がる。
///
/// 起動時に `Instrument` の決定論的な自己検査が走り、判定は標準出力と
/// `frame.json` の `check.<ID>` に出る。
@main
final class Sketch0816Sounding: Sketch {

    // MARK: - 設定

    /// グリッドの解像度。等深線の細かさと 1 フレームの負荷を決める。
    private let cols = 160
    private let rows = 90

    /// 等深線を引く深度。海図の等深線と同じで、等間隔に並べる。
    private let contourLevels: [Float] = [0.26, 0.38, 0.50, 0.62, 0.74, 0.86]

    /// 海底を入れ替える間隔（秒）。
    private let surveyPeriod: Float = 24

    var config: SketchConfig {
        SketchConfig(width: 1280, height: 720, title: "0816-sounding")
    }

    // MARK: - 音

    private var score: SoundFile?
    private var microphone: AudioAnalyzer?
    private var scorePath = ""

    /// 絵を駆動する解析。合成した PCM を `injectSamples(_:)` へ直接流す。
    ///
    /// `SoundFile` の内蔵解析（`enableAnalysis`）ではなくこちらを使う理由は 2 つ。
    /// 1. `SoundFile` は `bandEnergy(lowFreq:highFreq:)` を公開しておらず、`band(0/1/2)` の
    ///    区切りは halfFFTSize の 1/8 と 1/2 なので、44.1kHz では低域が 2.7kHz まで伸びる
    ///    （`A4.bandBoundaries` の実測）。音楽的な帯域に切れない。
    /// 2. 鳴らさずに走らせたい（ソーク・GIF 撮り）ときに `gain = 0` では代用できない。
    ///    解析のタップはプレイヤーの下流にあるので、音を絞ると解析まで無音になって絵が止まる。
    ///    そのため `SOUNDING_MUTE=1` は `SoundFile` を作らず、この注入経路だけで回す。
    ///    鳴らす／鳴らさないで見た目が変わらないので、ソークが作品の負荷を測ったことになる。
    ///
    /// `SoundFile` 側の解析も有効にしたまま `isBeat` / `band(0)` を probe に出すので、
    /// あちらの経路も走っている。
    private var analysis: AudioAnalyzer?
    private var scorePCM: [Float] = []
    private var cursor = 0
    private var chunk = [Float](repeating: 0, count: 1_024)

    // MARK: - 地形

    private var field: Field?
    private var depthImage: MImage?
    private var segments: [SIMD4<Float>] = []

    // MARK: - 状態

    /// 帯域エネルギーの平滑値。生の値はフレームごとに跳ねるので、絵の側で均す。
    private var bass: Float = 0
    private var mids: Float = 0
    private var highs: Float = 0

    /// 帯域ごとの直近の最大。ゆっくり減衰する。
    private var peaks = SIMD3<Float>(0.02, 0.02, 0.02)

    /// 直前に ping を出した時刻。連打を避ける不応期に使う。
    private var lastPingAt: Float = -1

    /// 場の流れ。中域で積分する。
    private var drift = SIMD2<Float>(0, 0)

    /// ソナーの ping。ビートで生まれ、広がって消える。
    private struct Ping {
        var origin: SIMD2<Float>
        var age: Float
    }
    private var pings: [Ping] = []

    /// 測深点。ゆっくり移動して、そこから ping が出る。
    private var soundingPoint = SIMD2<Float>(0.5, 0.5)

    /// 何本目の測線か。海底が入れ替わるたびに増える。
    private var survey = 0
    private var lastSurveyAt: Float = 0
    /// 測線の掃き。海底の入れ替えを隠す 1.2 秒のワイプ。
    private var sweep: Float = 1.0

    // MARK: - 検査

    private var verdicts: [Verdict] = []
    private var failedCount = 0
    /// 時計を使う計測（判定ではない）。
    private var gridCost = ""

    /// 1 フレームの地形更新にかかった時間（ミリ秒）。組み合わせの負荷を見るための実測。
    private var fieldMilliseconds: Double = 0
    /// そのうち等深線の抽出にかかった時間。
    private var contourMilliseconds: Double = 0

    // MARK: - 観測の口

    private let muted = ProcessInfo.processInfo.environment["SOUNDING_MUTE"] == "1"
    private let useMicrophone = ProcessInfo.processInfo.environment["SOUNDING_MIC"] == "1"
    private let shots = ProcessInfo.processInfo.environment["SOUNDING_SHOTS"] == "1"
    private let framesDirectory = ProcessInfo.processInfo.environment["SOUNDING_FRAMES"]
    private let trap = ProcessInfo.processInfo.environment["SOUNDING_TRAP"]
    private let trace = ProcessInfo.processInfo.environment["SOUNDING_TRACE"] == "1"
    private var shotsTaken = 0

    // MARK: - setup

    func setup() {
        frameRate(60)

        prepareAudio()
        prepareField()
        runSelfCheck()
        runTrapIfRequested()

        depthImage = createImage(cols, rows)
        if let directory = framesDirectory {
            beginFrameRecord(directory: directory)
            say("[frames] \(directory) へ連番を書き出す")
        }
    }

    /// 音源を用意する。既定は内蔵スコア、`SOUNDING_MIC=1` のときだけマイク。
    private func prepareAudio() {
        if useMicrophone {
            let analyzer = createAudioInput(fftSize: 1_024)
            do {
                try analyzer.start()
                microphone = analyzer
                say("[audio] マイク入力")
            } catch {
                // doc どおり AudioAnalyzerError しか飛んでこないはずなので、そのまま出す。
                say("[audio] マイクを開けなかった: \(error) — 内蔵スコアへ退避する")
            }
        }

        guard microphone == nil else { return }

        // 検査（A11–A13）は WAV を読み直すので、鳴らさないときも書き出しておく。
        do {
            scorePath = try Score.writeWAV()
        } catch {
            say("[audio] スコアを書き出せなかった: \(error)")
            return
        }

        // 絵を駆動する解析は、鳴らす／鳴らさないによらず注入経路で揃える。
        let analyzer = AudioAnalyzer(fftSize: 1_024, sampleRate: Score.sampleRate)
        analyzer.smoothing = 0.7
        analysis = analyzer
        scorePCM = Score.render()

        guard !muted else {
            say("[audio] 内蔵スコア（無音）\(scorePCM.count) サンプルを injectSamples で解析")
            return
        }

        do {
            let sound = try loadSound(scorePath)
            sound.enableAnalysis(fftSize: 1_024)
            sound.gain = 0.85
            sound.loop()
            score = sound
            say("[audio] 内蔵スコア \(String(format: "%.1f", sound.duration))s"
                + " gain=\(String(format: "%.2f", sound.gain)) を再生 + 解析")
        } catch {
            say("[audio] スコアを再生できなかった（解析だけ続ける）: \(error)")
        }
    }

    private func prepareField() {
        let noise = createNoise(.perlin, config: NoiseConfig(octaves: 5, frequency: 1.0, seed: 1))
        field = Field(noise: noise, cols: cols, rows: rows, seed: 1)
    }

    /// 決定論的な自己検査。起動のたびに同じ数値が出る。
    private func runSelfCheck() {
        verdicts = Instrument.runAll(
            makeNoise: { [self] type, config in createNoise(type, config: config) },
            loadSound: { [self] path in try loadSound(path) },
            scorePath: scorePath
        )
        failedCount = verdicts.filter { !$0.passed }.count

        say("--- self-check (metaphor 0.9.0) ---")
        for verdict in verdicts {
            say("\(verdict.passed ? "PASS" : "FAIL")\t\(verdict.id)\t\(verdict.detail)")
        }
        // 時計を使う計測は判定にしない（実行ごとに数字が動く）。記録には残す。
        gridCost = Instrument.measureGridCost { [self] type, config in
            createNoise(type, config: config)
        }
        say("MEASURE\t\(gridCost)")
        say("self-check 完了: \(verdicts.count - failedCount) / \(verdicts.count) PASS")
    }

    /// 頼まれたときだけ走らせる診断。
    ///
    /// 重い調査や、プロセスごと落ちうる操作をここに寄せる。常時実行すると
    /// 作品が起動しなくなる（0816-marionette で実際にそうなった）。
    /// この作品で見つかった穴はどれも落ちないので、いまは重い調査だけが入っている。
    private func runTrapIfRequested() {
        guard let trap else { return }
        switch trap {
        case "grid":
            // `sampleGrid` と `sample` が同じ場を指していないことの最小再現（N9 / N8）。
            // 上流へ貼る表をそのまま出す。
            let origin = SIMD2(0.35, -0.75)

            say("[trap] --- sampleScale を振る（perlin 64×64、行 0 の全点で比較）---")
            for scale in [4.0, 1.0, 0.5, 0.25, 0.1, 0.05, 0.02] {
                var config = NoiseConfig(octaves: 1, frequency: 1.0, seed: 21)
                config.normalized = false
                config.sampleScale = SIMD2(scale, scale)
                config.origin = origin
                let noise = createNoise(.perlin, config: config)
                let width = 64
                let grid = noise.sampleGrid(width: width, height: 64)
                var worst: Float = 0
                for i in 0..<width {
                    let expected = noise.sample(x: origin.x + Double(i) * scale, y: origin.y)
                    worst = max(worst, abs(grid[i] - expected))
                }
                say(String(
                    format: "[trap] sampleScale=%.2f (size=%.1f)  最大差 %.6f",
                    scale, scale * Double(width), worst
                ))
            }

            say("[trap] --- ノイズ種別を振る（sampleScale=0.02、16 点）---")
            for (type, name) in [
                (NoiseType.perlin, "perlin"), (.billow, "billow"), (.ridged, "ridged"),
                (.voronoi, "voronoi"), (.cylinders, "cylinders"), (.checkerboard, "checkerboard"),
            ] {
                var config = NoiseConfig(octaves: 1, frequency: 1.0, seed: 21)
                config.normalized = false
                config.sampleScale = SIMD2(0.02, 0.02)
                config.origin = origin
                let noise = createNoise(type, config: config)
                let grid = noise.sampleGrid(width: 16, height: 1)
                var worst: Float = 0
                for i in 0..<16 {
                    let expected = noise.sample(x: origin.x + Double(i) * 0.02, y: origin.y)
                    worst = max(worst, abs(grid[i] - expected))
                }
                // checkerboard だけ 0 になるが、それは 1 単位ごとの区分定数なので
                // マス内の位置ずれが値に出ないだけ。一致の証拠にはならない。
                say(String(
                    format: "[trap] %-12s  最大差 %.6f", (name as NSString).utf8String!, worst
                ))
            }

            say("[trap] --- origin / sampleScale は sample() に効かない（N8）---")
            var plainConfig = NoiseConfig(octaves: 4, frequency: 1.4, seed: 21)
            plainConfig.normalized = true
            var shiftedConfig = plainConfig
            shiftedConfig.origin = SIMD2(5.37, 5.61)
            shiftedConfig.sampleScale = SIMD2(3.0, 3.0)
            let plain = createNoise(.perlin, config: plainConfig)
            let shifted = createNoise(.perlin, config: shiftedConfig)
            say(String(
                format: "[trap] sample(0.37, 0.61): origin なし %.5f / origin (5.37, 5.61) %.5f",
                plain.sample(x: Float(0.37), y: Float(0.61)),
                shifted.sample(x: Float(0.37), y: Float(0.61))
            ))
            say(String(
                format: "[trap] grid[0] = %.5f / sample(5.37, 5.61) = %.5f（こちらは一致する）",
                shifted.sampleGrid(width: 4, height: 4)[0],
                plain.sample(x: Float(5.37), y: Float(5.61))
            ))
        default:
            say("[trap] 未知の名前: \(trap)")
        }
    }

    // MARK: - draw

    func draw() {
        let bands = readAudio()
        advanceComposition()
        updateField(bands)

        background(3, 6, 12)
        drawDepth()
        drawContours()
        drawPings()
        drawSweep()
        drawHUD()

        publishProbes()
        handleShots()
        handleTrace()
    }

    /// 画面を見なくても状態が分かるように、定期的に数値だけ出す。
    private func handleTrace() {
        guard trace, frameCount % 120 == 0 else { return }
        say(String(
            format: "[trace] f=%5d t=%6.1f fps=%4.1f low=%.3f mid=%.3f high=%.3f"
                + " freq=%.2f turb=%.2f seed=%d 等深線=%d ping=%d"
                + " field=%.2fms (config %.2f + grid %.2f + 等深線 %.2f)",
            frameCount, time, deltaTime > 0 ? 1 / deltaTime : 0, bass, mids, highs,
            field?.frequency ?? 0, field?.turbulence ?? 0, Int(field?.seed ?? 0),
            segments.count, pings.count, fieldMilliseconds,
            field?.configMilliseconds ?? 0, field?.sampleMilliseconds ?? 0, contourMilliseconds
        ))
    }

    // MARK: - 音を読む

    /// 低域・中域・高域を読み、絵が跳ねないように平滑して返す。
    ///
    /// `band(0/1/2)` ではなく `bandEnergy` を使う。前者の区切りは
    /// halfFFTSize の 1/8 と 1/2 なので、44.1kHz では低域が 2.7kHz まで伸びてしまい、
    /// 音楽的な帯域にならない（`A4.bandBoundaries` に実測がある）。
    private func readAudio() -> SIMD3<Float> {
        var raw = SIMD3<Float>(0, 0, 0)
        var beat = false

        // 再生している SoundFile 側の解析も回しておく（あちらの経路を走らせるため）。
        score?.update()

        if let microphone {
            microphone.update()
            raw = bands(of: microphone)
            beat = microphone.isBeat
        } else if let analysis, !scorePCM.isEmpty {
            // 経過時間ぶんだけスコアを進めて、その窓を解析へ流す。
            cursor = (cursor + Int(min(deltaTime, 0.1) * Float(Score.sampleRate))) % scorePCM.count
            for i in 0..<chunk.count {
                chunk[i] = scorePCM[(cursor + i) % scorePCM.count]
            }
            analysis.injectSamples(chunk)
            analysis.update()
            raw = bands(of: analysis)
            beat = analysis.isBeat
        }

        // 帯域ごとに自分の直近の最大で割る。
        //
        // `spectrum` は最大ビンが 1.0 になるよう正規化されている（`A7`）ので、
        // ドローンが立っているあいだ中域・高域は 0.02 前後にしかならない。
        // そのまま地形へ渡すと低域だけが効いた絵になるため、帯域ごとに追従する
        // ゲインを掛けて、それぞれの動きが見えるようにする。
        let levels = SIMD3(
            Field.sanitize(raw.x), Field.sanitize(raw.y), Field.sanitize(raw.z)
        )
        for axis in 0..<3 {
            peaks[axis] = max(levels[axis], peaks[axis] * 0.9995)
        }
        let scaled = SIMD3(
            min(levels.x / max(peaks.x, 0.02), 1),
            min(levels.y / max(peaks.y, 0.02), 1),
            min(levels.z / max(peaks.z, 0.02), 1)
        )

        let smoothing: Float = 0.82
        bass = bass * smoothing + scaled.x * (1 - smoothing)
        mids = mids * smoothing + scaled.y * (1 - smoothing)
        highs = highs * smoothing + scaled.z * (1 - smoothing)

        // ping は測深そのもの。拍ごとに 1 つで足りるので不応期を置く。
        if beat, sweep >= 1, time - lastPingAt > 0.28 {
            lastPingAt = time
            pings.append(Ping(origin: soundingPoint, age: 0))
            if pings.count > 12 { pings.removeFirst(pings.count - 12) }
        }
        return SIMD3(bass, mids, highs)
    }

    /// 低域・中域・高域を音楽的な区切りで取り出す。
    private func bands(of analyzer: AudioAnalyzer) -> SIMD3<Float> {
        SIMD3(
            analyzer.bandEnergy(lowFreq: 30, highFreq: 160),
            analyzer.bandEnergy(lowFreq: 300, highFreq: 1_600),
            analyzer.bandEnergy(lowFreq: 2_500, highFreq: 8_000)
        )
    }

    // MARK: - 時間的な構成

    private func advanceComposition() {
        let dt = min(deltaTime, 0.1)

        // 測深点はゆっくりしたリサージュを描く。
        soundingPoint = SIMD2(
            0.5 + 0.28 * sinf(time * 0.13),
            0.5 + 0.22 * sinf(time * 0.081 + 1.1)
        )

        for index in pings.indices { pings[index].age += dt }
        pings.removeAll { $0.age > 3.4 }

        // 中域で場が流れる。常にわずかに進むので、無音でも死んで見えない。
        drift += SIMD2(0.00018 + mids * 0.0016, sinf(time * 0.047) * 0.00055) * (dt * 60)

        if time - lastSurveyAt > surveyPeriod {
            lastSurveyAt = time
            survey += 1
            sweep = 0
            field?.reseed(Int32(1 + survey * 7))
        }
        if sweep < 1 { sweep = min(1, sweep + dt / 1.2) }
    }

    private func updateField(_ bands: SIMD3<Float>) {
        guard let field else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        field.update(bass: bands.x, mids: bands.y, highs: bands.z, drift: drift)
        let sampled = DispatchTime.now().uptimeNanoseconds
        segments.removeAll(keepingCapacity: true)
        for level in contourLevels {
            field.contour(at: level, into: &segments)
        }
        let finished = DispatchTime.now().uptimeNanoseconds
        fieldMilliseconds = Double(finished - started) / 1_000_000
        contourMilliseconds = Double(finished - sampled) / 1_000_000
    }

    // MARK: - 描画

    /// 深度帯。グリッドと同じ解像度の画像を作り、画面いっぱいへ引き伸ばす。
    ///
    /// 等深線と同じ `values` から作るので、線と色が食い違うことがない。
    private func drawDepth() {
        guard let field, let depthImage else { return }

        let count = cols * rows
        if depthImage.pixels.count != count * 4 {
            depthImage.pixels = [UInt8](repeating: 255, count: count * 4)
        }
        depthImage.pixels.withUnsafeMutableBufferPointer { buffer in
            for index in 0..<count {
                let color = Field.depthColor(field.values[index])
                let offset = index * 4
                buffer[offset] = UInt8(max(0, min(255, color.x)))
                buffer[offset + 1] = UInt8(max(0, min(255, color.y)))
                buffer[offset + 2] = UInt8(max(0, min(255, color.z)))
                buffer[offset + 3] = 255
            }
        }
        depthImage.updatePixels()
        image(depthImage, 0, 0, width, height)
    }

    /// 等深線。数千本になるので `beginShape(.lines)` 1 本にまとめる。
    private func drawContours() {
        guard !segments.isEmpty else { return }
        let sx = width / Float(cols - 1)
        let sy = height / Float(rows - 1)

        noFill()
        stroke(226, 232, 214, 150 + highs * 105)
        strokeWeight(1.0)
        beginShape(.lines)
        for segment in segments {
            vertex(segment.x * sx, segment.y * sy)
            vertex(segment.z * sx, segment.w * sy)
        }
        endShape()
    }

    /// ソナーの ping。キックのたびに測深点から広がる。
    private func drawPings() {
        guard !pings.isEmpty else { return }
        noFill()
        for ping in pings {
            let t = ping.age / 3.4
            let radius = 40 + t * 900
            let alpha = (1 - t) * (1 - t) * 210
            stroke(120, 226, 236, alpha)
            strokeWeight(1 + (1 - t) * 1.6)
            circle(ping.origin.x * width, ping.origin.y * height, radius * 2)
        }

        // 測深点そのもの。
        noStroke()
        fill(150, 240, 250, 200)
        circle(soundingPoint.x * width, soundingPoint.y * height, 7)
    }

    /// 測線の掃き。海底の入れ替えをこの 1.2 秒で隠す。
    private func drawSweep() {
        guard sweep < 1 else { return }
        let x = sweep * width
        noFill()
        stroke(180, 245, 255, 220)
        strokeWeight(2)
        line(x, 0, x, height)
        noStroke()
        fill(6, 20, 32, 150 * (1 - sweep))
        rect(0, 0, x, height)
    }

    private func drawHUD() {
        noStroke()
        fill(4, 10, 18, 170)
        rect(16, 16, 268, 106)

        fill(196, 226, 232, 235)
        textSize(13)
        text("SOUNDING — survey \(survey + 1)", 28, 38)
        textSize(11)
        fill(150, 186, 198, 220)
        text(String(format: "low %.2f  mid %.2f  high %.2f", bass, mids, highs), 28, 58)
        text(
            String(
                format: "freq %.2f  persist %.2f  turb %.2f",
                field?.frequency ?? 0, field?.persistence ?? 0, field?.turbulence ?? 0
            ),
            28, 76
        )
        text(
            String(format: "contours %d  field %.2f ms", segments.count, fieldMilliseconds),
            28, 94
        )

        // 自己検査の要約。FAIL があるなら赤で残す（0816-adversary と同じ扱い）。
        if failedCount > 0 {
            fill(236, 96, 96, 235)
            text("self-check \(failedCount) FAIL", 28, 112)
        } else {
            fill(120, 200, 150, 220)
            text("self-check all PASS", 28, 112)
        }

        // 深度の凡例。海図らしさはここが担う。
        let legendX = width - 172
        fill(4, 10, 18, 170)
        rect(legendX - 12, 16, 160, 40)
        for i in 0..<24 {
            let t = Float(i) / 23
            let color = Field.depthColor(t)
            fill(color.x, color.y, color.z, 255)
            rect(legendX + Float(i) * 5.6, 26, 5.6, 12)
        }
        fill(150, 186, 198, 220)
        textSize(10)
        text("deep", legendX, 50)
        text("shoal", legendX + 106, 50)
    }

    // MARK: - 観測

    private func publishProbes() {
        probe("audio.bass", bass)
        probe("audio.mids", mids)
        probe("audio.highs", highs)
        probe("field.frequency", field?.frequency ?? 0)
        probe("field.persistence", field?.persistence ?? 0)
        probe("field.turbulence", field?.turbulence ?? 0)
        // 伸長前の値幅。小さいほど「ノイズが平ら」= 伸長に頼っている状態。
        probe("field.contrast", field?.contrast ?? 0)
        probe("field.seed", Int(field?.seed ?? 0))
        probe("field.ms", fieldMilliseconds)
        probe("contours.segments", segments.count)
        probe("pings.count", pings.count)
        // SoundFile 内蔵の解析。こちらの区切りは band(0/1/2) 固定で、注入経路の値とは別物。
        if let score {
            probe("soundfile.band0", score.band(0))
            probe("soundfile.beat", score.isBeat)
            probe("soundfile.position", score.position)
        }
        probe("survey.index", survey)
        probe("summary.passed", verdicts.count - failedCount)
        probe("summary.failed", failedCount)
        probe("measure.gridCost", gridCost)
        for verdict in verdicts {
            probe("check.\(verdict.id)", verdict.line)
        }
    }

    /// 場面ごとに 1 枚ずつ書き出して、巡回を待たずに絵を見られるようにする。
    ///
    /// `saveFrame(_:)` は渡した名前に無条件で `~/Desktop/` を前置するので、
    /// 絶対パスを渡してはいけない（metaphor#757）。連番が要るときは
    /// `beginFrameRecord(directory:)` を使う（こちらは絶対パスを尊重する）。
    private func handleShots() {
        guard shots, shotsTaken < 4 else { return }
        let dueAt = Float(shotsTaken) * 6 + 3
        guard time >= dueAt else { return }
        shotsTaken += 1
        saveFrame("sounding-\(shotsTaken).png")
        say("[shot] sounding-\(shotsTaken).png")
    }

    /// 標準出力へ出す。パイプへ流すとブロックバッファされるので必ず流し切る。
    private func say(_ message: String) {
        print(message)
        fflush(stdout)
    }
}
