import Foundation
import metaphor
import simd

// 検証器。
//
// 作品の見た目とは独立に、MetaphorAudio / MetaphorNoise の振る舞いを**決定論的に**測る。
// 描画も時計も使わないので、実行するたびに同じ数値が出る。結果は frame.json の `custom` に
// `check.<ID>` として載り、AI はスクリーンショットではなくこの数値を一次証拠にできる
// （0816-marionette / 0816-adversary と同じ方針）。
//
// 音の側は `AudioAnalyzer.injectSamples(_:)` に**自分で合成した波**を流す。
// 何 Hz に何が乗っているかを自分で決めているので、期待値を数式で書き下せる。

/// 検査で使う FFT のサイズ。既定引数から参照するので、アクター隔離の外に置く。
private let fftSize = 1_024
/// 検査で使うサンプリング周波数。合成波と揃える。
private let rate = Score.sampleRate

/// 検査 1 件の結果。
struct Verdict {
    let id: String
    let passed: Bool
    /// 実測値。FAIL のとき何がどう違ったのかを人が読める形で残す。
    let detail: String

    var line: String { "\(passed ? "PASS" : "FAIL") \(detail)" }
}

/// 決定論的な検査の一式。`setup()` で 1 回だけ走らせる。
@MainActor
enum Instrument {

    /// ノイズ生成をスケッチ側から借りる（`createNoise` は Sketch の拡張なので直接は呼べない）。
    typealias NoiseFactory = (NoiseType, NoiseConfig) -> GKNoiseWrapper
    /// 同じく `loadSound`。
    typealias SoundLoader = (String) throws -> SoundFile

    static func runAll(
        makeNoise: NoiseFactory,
        loadSound: SoundLoader,
        scorePath: String
    ) -> [Verdict] {
        [
            // MetaphorAudio
            spectrumPeakBin(),
            bandEnergySelectivity(),
            bandEnergyWithoutSampleRate(),
            bandBoundaries(),
            volumeScale(),
            smoothingClamp(),
            spectrumNormalization(),
            waveformLength(),
            beatDeterminism(),
            silenceSafety(),
            // MetaphorAudio: SoundFile
            soundFileRanges(loadSound: loadSound, path: scorePath),
            soundFileAnalysisToggle(loadSound: loadSound, path: scorePath),
            soundFileMissingPath(loadSound: loadSound),
            // MetaphorNoise
            constantValue(makeNoise),
            normalizedRange(makeNoise),
            seedReproducibility(makeNoise),
            transformOps(makeNoise),
            compositionOps(makeNoise),
            frequencyPeriod(makeNoise),
            octaveDetail(makeNoise),
            originIgnoredBySample(makeNoise),
            gridMatchesSample(makeNoise),
            floatDoubleParity(makeNoise),
            standaloneNoiseParity(makeNoise),
            voronoiDistanceFlag(makeNoise),
            textureConsistency(makeNoise),
            turbulenceEffect(makeNoise),
            configResetsComposition(makeNoise),
            // 組み合わせ
            octaveDiscontinuity(makeNoise),
            bandToConfigSafety(),
        ]
    }

    // MARK: - 計測（判定ではない）

    /// X1: 毎フレーム `config` を書き換えると `sampleGrid` がいくら掛かるか。
    ///
    /// これは時計を使うので判定にはしない（実行ごとに数字が動く）。それでも
    /// **この作品の主題そのもの**なので、起動時に 1 度測って記録に残す。
    ///
    /// `GKNoiseWrapper` は `GKNoiseMap` をキャッシュしているが、`config` の setter は
    /// それを捨てる。音で毎フレーム設定を書き換える使い方は、毎フレーム
    /// マップを作り直すことになる。
    static func measureGridCost(_ makeNoise: NoiseFactory) -> String {
        let cols = 160
        let rows = 90
        var config = NoiseConfig(octaves: 5, frequency: 1.0, seed: 1)
        config.normalized = true
        config.sampleScale = SIMD2(0.02, 0.02)
        let noise = makeNoise(.perlin, config)

        func milliseconds(_ body: () -> Void) -> Double {
            let started = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }

        // 1 回目はマップ生成を含む。
        _ = noise.sampleGrid(width: cols, height: rows)

        let cached = milliseconds {
            for _ in 0..<20 { _ = noise.sampleGrid(width: cols, height: rows) }
        } / 20

        let rebuilt = milliseconds {
            for i in 0..<20 {
                // 実際の作品と同じ順序: config を書いてからサンプルする。
                config.frequency = 1.0 + Double(i) * 0.01
                noise.config = config
                _ = noise.sampleGrid(width: cols, height: rows)
            }
        } / 20

        let ratio = cached > 0 ? rebuilt / cached : .infinity
        // ビルド構成で桁が変わるので必ず添える（debug の数字を release の話として読むと誤る）。
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        return String(
            format: "X1 sampleGrid(%d×%d) [%@]: 設定を変えない %.3f ms / 毎回変える %.3f ms（%.0f 倍）",
            cols, rows, configuration as NSString, cached, rebuilt, ratio
        )
    }

    // MARK: - 共通ヘルパー

    /// FFT の 1 ビンが受け持つ周波数幅。期待ビンの計算に使う。
    private static var binWidth: Float { Float(rate) / Float(fftSize) }

    /// 検査用のアナライザ。`smoothing = 0` にして EMA を外し、1 回の注入で確定値を得る。
    private static func analyzer(
        fftSize: Int = fftSize,
        sampleRate: Double? = rate,
        smoothing: Float = 0
    ) -> AudioAnalyzer {
        let analyzer = AudioAnalyzer(fftSize: fftSize, sampleRate: sampleRate)
        analyzer.smoothing = smoothing
        return analyzer
    }

    /// サンプルを注入して 1 フレーム進める。
    private static func feed(_ analyzer: AudioAnalyzer, _ samples: [Float]) {
        analyzer.injectSamples(samples)
        analyzer.update()
    }

    /// スペクトルの最大ビン。
    private static func peakBin(_ spectrum: [Float]) -> Int {
        var best = 0
        for i in 1..<spectrum.count where spectrum[i] > spectrum[best] { best = i }
        return best
    }

    private static func f(_ value: Float, _ digits: Int = 3) -> String {
        String(format: "%.\(digits)f", value)
    }

    private static func f(_ value: Double, _ digits: Int = 3) -> String {
        String(format: "%.\(digits)f", value)
    }

    // MARK: - MetaphorAudio: スペクトル

    /// A1: 単一正弦波のピークが理論ビンに立つか。
    ///
    /// ビン番号は `f · fftSize / sampleRate`。440Hz / 1024 / 44.1kHz なら 10.22 → ビン 10。
    static func spectrumPeakBin() -> Verdict {
        let tone: Float = 440
        let analyzer = analyzer()
        feed(analyzer, Score.sine(frequency: tone, count: fftSize, amplitude: 0.5))

        let measured = peakBin(analyzer.spectrum)
        let exact = tone / binWidth
        let expected = Int(exact.rounded())
        let ok = measured == expected
        return Verdict(
            id: "A1.spectrumPeakBin",
            passed: ok,
            detail: "A1 440Hz のピーク bin=\(measured) 期待=\(expected)"
                + "（厳密 \(f(exact, 2))、bin 幅 \(f(binWidth, 2))Hz）"
        )
    }

    /// A2: `bandEnergy` が指定帯域だけを拾うか。帯域内と帯域外の比で見る。
    static func bandEnergySelectivity() -> Verdict {
        let analyzer = analyzer()
        feed(analyzer, Score.sine(frequency: 440, count: fftSize, amplitude: 0.5))

        let inside = analyzer.bandEnergy(lowFreq: 350, highFreq: 550)
        let outside = analyzer.bandEnergy(lowFreq: 5_000, highFreq: 8_000)
        let ratio = outside > 0 ? inside / outside : .infinity
        let ok = inside > 0.2 && outside < 0.01
        return Verdict(
            id: "A2.bandEnergySelectivity",
            passed: ok,
            detail: "A2 440Hz: 帯域内(350-550)=\(f(inside)) 帯域外(5k-8k)=\(f(outside, 5))"
                + " 比=\(outside > 0 ? f(ratio, 1) : "∞")"
        )
    }

    /// A3: `sampleRate` を渡し忘れたまま `bandEnergy` を呼ぶと**黙って**失敗するか。
    ///
    /// 報告時（metaphor#783）は 0 が返るだけで、「そこにエネルギーが無い」と見分けが付かなかった。
    /// 上流は **戻り値 0 は据え置いたまま警告を出す**形で解決した（PR #790）。
    /// つまり直ったかどうかは戻り値ではなく **警告が出るか** で決まる。
    ///
    /// 警告は `debugWarning` から stdout へ出る（DEBUG ビルド限定・analyzer ごとに 1 回だけ）。
    /// 検査の中から拾うには呼び出しのあいだだけ stdout を横取りするしかないので、
    /// `capturingStandardOutput` で捕まえて文字列を突き合わせる。
    static func bandEnergyWithoutSampleRate() -> Verdict {
        let analyzer = analyzer(sampleRate: nil)
        feed(analyzer, Score.sine(frequency: 440, count: fftSize, amplitude: 0.5))

        var energy: Float = 0
        let logged = capturingStandardOutput {
            energy = analyzer.bandEnergy(lowFreq: 350, highFreq: 550)
        }
        let spectrumAlive = analyzer.spectrum.contains { $0 > 0.5 }
        // 「0 を返した」ことではなく「0 を返すと言った」ことを見る。
        let warned = logged.contains("sample rate is unknown")
        let silentFailure = spectrumAlive && energy == 0 && !warned
        return Verdict(
            id: "A3.bandEnergyWithoutSampleRate",
            passed: !silentFailure,
            detail: "A3 sampleRate 未設定: bandEnergy=\(f(energy, 5))"
                + " spectrum は生きている=\(spectrumAlive)"
                + " / 警告=\(warned ? "出た" : "出ない")"
                + "（#790 の解決は「0 のまま警告を出す」形。警告が出れば誤設定と無エネルギーを区別できる）"
        )
    }

    /// `body` の実行中に stdout へ出た文字列を捕まえる。
    ///
    /// `debugWarning` は `print` なので、警告が出たかどうかはライブラリの公開 API からは読めない。
    /// パイプへ差し替えて読み戻す（警告 1 行ぶんなのでパイプのバッファには収まる）。
    static func capturingStandardOutput(_ body: () -> Void) -> String {
        let pipe = Pipe()
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        body()

        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        try? pipe.fileHandleForWriting.close()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
        try? pipe.fileHandleForReading.close()
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    /// A4: `band(0/1/2)` が実際にどの周波数で切れるか。
    ///
    /// doc のコメントは「低音 0-250Hz / 中音 250-2kHz / 高音 2kHz+」。
    /// 実装は halfFFTSize を 1/8, 1/2 で割っているだけなので、サンプリング周波数に比例する。
    static func bandBoundaries() -> Verdict {
        var lowestOf = [Int: Float]()
        var highestOf = [Int: Float]()

        // 60Hz から 1/6 オクターブ刻みで 20kHz 手前まで掃く。
        var tone: Float = 60
        while tone < 20_000 {
            let analyzer = analyzer()
            feed(analyzer, Score.sine(frequency: tone, count: fftSize, amplitude: 0.5))
            let energies = (0..<3).map { analyzer.band($0) }
            var winner = 0
            for i in 1..<3 where energies[i] > energies[winner] { winner = i }
            if lowestOf[winner] == nil { lowestOf[winner] = tone }
            highestOf[winner] = tone
            tone *= powf(2, 1.0 / 6.0)
        }

        let described = (0..<3).map { index -> String in
            guard let low = lowestOf[index], let high = highestOf[index] else {
                return "band\(index)=なし"
            }
            return "band\(index)=\(Int(low))–\(Int(high))Hz"
        }.joined(separator: " ")

        // doc どおりなら band0 の上端は 250Hz 近辺のはず。
        let band0Top = highestOf[0] ?? 0
        let ok = band0Top < 400
        return Verdict(
            id: "A4.bandBoundaries",
            passed: ok,
            detail: "A4 実測の担当範囲: \(described)"
                + "（doc は 0–250 / 250–2k / 2k+。band0 の上端 \(Int(band0Top))Hz）"
        )
    }

    /// A5: `volume` が doc の言う「RMS」と一致するか。
    ///
    /// 振幅 A の正弦波の RMS は A/√2。実装は `min(rms * 4, 1)` なので、
    /// A ≳ 0.354 で飽和して振幅の差が見えなくなる。
    static func volumeScale() -> Verdict {
        let amplitude: Float = 0.2
        let analyzer = analyzer()
        let samples = Score.sine(frequency: 440, count: fftSize, amplitude: amplitude)
        feed(analyzer, samples)

        let rms = sqrtf(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let measured = analyzer.volume
        let ratio = rms > 0 ? measured / rms : 0
        // 飽和が始まる振幅（rms = 0.25 → A = 0.25·√2）。
        let saturation = 0.25 * sqrtf(2)
        let ok = abs(measured - rms) < 1e-3
        return Verdict(
            id: "A5.volumeScale",
            passed: ok,
            detail: "A5 A=\(f(amplitude, 2)) の正弦波: volume=\(f(measured, 4))"
                + " RMS=\(f(rms, 4)) 比=\(f(ratio, 3))"
                + "（A≧\(f(saturation, 3)) で 1.0 に飽和する）"
        )
    }

    /// A6: `smoothing` が doc どおり [0, 0.99] にクランプされるか。
    static func smoothingClamp() -> Verdict {
        let analyzer = analyzer()
        analyzer.smoothing = 1.5
        let high = analyzer.smoothing
        analyzer.smoothing = -0.5
        let low = analyzer.smoothing
        let ok = abs(high - 0.99) < 1e-6 && abs(low) < 1e-6
        return Verdict(
            id: "A6.smoothingClamp",
            passed: ok,
            detail: "A6 smoothing: 1.5→\(f(high)) 期待=0.990 / -0.5→\(f(low)) 期待=0.000"
        )
    }

    /// A7: `spectrum` が doc どおり 0.0–1.0 に収まるか（フルスケールを大きく超える入力で）。
    static func spectrumNormalization() -> Verdict {
        let analyzer = analyzer()
        feed(analyzer, Score.sine(frequency: 1_000, count: fftSize, amplitude: 8.0))

        let maximum = analyzer.spectrum.max() ?? 0
        let minimum = analyzer.spectrum.min() ?? 0
        let finite = analyzer.spectrum.allSatisfy { $0.isFinite }
        let ok = finite && minimum >= 0 && maximum <= 1.0001
        return Verdict(
            id: "A7.spectrumNormalization",
            passed: ok,
            detail: "A7 振幅 8.0 入力: spectrum min=\(f(minimum, 5)) max=\(f(maximum, 5))"
                + " すべて有限=\(finite)"
        )
    }

    /// A8: `waveform` の長さは `fftSize` か。短い入力はゼロ埋めされるか。
    static func waveformLength() -> Verdict {
        let size = 512
        let analyzer = analyzer(fftSize: size)
        feed(analyzer, Score.sine(frequency: 440, count: 300, amplitude: 0.5))

        let count = analyzer.waveform.count
        let tailIsZero = analyzer.waveform[300...].allSatisfy { $0 == 0 }
        let ok = count == size && tailIsZero
        return Verdict(
            id: "A8.waveformLength",
            passed: ok,
            detail: "A8 fftSize=\(size) に 300 サンプル注入: waveform.count=\(count)"
                + " 期待=\(size) 余りがゼロ埋め=\(tailIsZero)"
        )
    }

    /// A9: 同じ入力列を 2 回流したときに `isBeat` が同じフレームで立つか。
    static func beatDeterminism() -> Verdict {
        func beatFrames() -> [Int] {
            let analyzer = analyzer(smoothing: 0.8)
            let pcm = Score.render()
            var frames: [Int] = []
            let chunks = min(120, pcm.count / fftSize)
            for chunk in 0..<chunks {
                let start = chunk * fftSize
                feed(analyzer, Array(pcm[start..<(start + fftSize)]))
                if analyzer.isBeat { frames.append(chunk) }
            }
            // 注入せずに update() したときはフラグが降りるか（doc: update ごとにリセット）。
            analyzer.update()
            if analyzer.isBeat { frames.append(-1) }
            return frames
        }

        let first = beatFrames()
        let second = beatFrames()
        let ok = first == second && !first.contains(-1) && !first.isEmpty
        return Verdict(
            id: "A9.beatDeterminism",
            passed: ok,
            detail: "A9 スコア 120 フレーム: 1 回目 \(first.count) 拍 2 回目 \(second.count) 拍"
                + " 一致=\(first == second) 無注入で降りる=\(!first.contains(-1))"
                + " 先頭 \(first.prefix(6).map(String.init).joined(separator: ","))"
        )
    }

    /// A10: 無音を流したときに NaN / Inf が出ないか。
    static func silenceSafety() -> Verdict {
        let analyzer = analyzer()
        feed(analyzer, [Float](repeating: 0, count: fftSize))

        let values = [
            analyzer.volume,
            analyzer.band(0), analyzer.band(1), analyzer.band(2),
            analyzer.bandEnergy(lowFreq: 20, highFreq: 200),
        ]
        let finite = values.allSatisfy { $0.isFinite } && analyzer.spectrum.allSatisfy { $0.isFinite }
        let ok = finite && analyzer.volume == 0
        return Verdict(
            id: "A10.silenceSafety",
            passed: ok,
            detail: "A10 無音: volume=\(f(analyzer.volume, 5))"
                + " band=[\(values[1...3].map { f($0, 5) }.joined(separator: ", "))]"
                + " すべて有限=\(finite)"
        )
    }

    // MARK: - MetaphorAudio: SoundFile

    /// A11: 再生プロパティの範囲外値と `duration` の整合。
    ///
    /// 作品が鳴らしている本体には触らず、同じ WAV をもう 1 つ読んで（再生せずに）調べる。
    static func soundFileRanges(loadSound: SoundLoader, path: String) -> Verdict {
        guard let sound = try? loadSound(path) else {
            return Verdict(id: "A11.soundFileRanges", passed: false, detail: "A11 スコアを読めなかった")
        }

        sound.gain = 5.0
        let gainHigh = sound.gain
        sound.gain = -1.0
        let gainLow = sound.gain
        sound.rate = 99
        let rateHigh = sound.rate
        sound.rate = 0.01
        let rateLow = sound.rate
        sound.position = sound.duration * 10
        let positionHigh = sound.position
        sound.position = -5
        let positionLow = sound.position

        let expectedDuration = Score.duration
        let durationOK = abs(sound.duration - expectedDuration) < 0.01
        let ok = gainHigh == 1.0 && gainLow == 0.0
            && rateHigh == 4.0 && rateLow == 0.25
            && positionHigh <= sound.duration + 1e-6 && positionLow >= -1e-6
            && durationOK
        return Verdict(
            id: "A11.soundFileRanges",
            passed: ok,
            detail: "A11 gain 5→\(f(gainHigh)) -1→\(f(gainLow)) /"
                + " rate 99→\(f(rateHigh)) 0.01→\(f(rateLow)) /"
                + " position 10×→\(f(positionHigh)) -5→\(f(positionLow))"
                + "（doc どおり末尾以降のシークは stop 扱いで 0 に戻る）/"
                + " duration=\(f(sound.duration)) 期待=\(f(expectedDuration))"
        )
    }

    /// A12: `enableAnalysis` → `disableAnalysis` で doc どおり中立値へ戻るか。
    static func soundFileAnalysisToggle(loadSound: SoundLoader, path: String) -> Verdict {
        guard let sound = try? loadSound(path) else {
            return Verdict(id: "A12.analysisToggle", passed: false, detail: "A12 スコアを読めなかった")
        }

        let beforeSpectrum = sound.spectrum.count
        sound.enableAnalysis(fftSize: 1_024)
        let enabledSpectrum = sound.spectrum.count
        sound.disableAnalysis()
        sound.update()
        let afterSpectrum = sound.spectrum.count
        let afterVolume = sound.analysisVolume
        let afterBeat = sound.isBeat
        let afterBand = sound.band(0)

        let ok = beforeSpectrum == 0 && afterSpectrum == 0
            && afterVolume == 0 && !afterBeat && afterBand == 0
        return Verdict(
            id: "A12.analysisToggle",
            passed: ok,
            detail: "A12 spectrum.count: 有効化前=\(beforeSpectrum) 有効時=\(enabledSpectrum)"
                + " 無効化後=\(afterSpectrum) /"
                + " analysisVolume=\(f(afterVolume, 5)) isBeat=\(afterBeat) band(0)=\(f(afterBand, 5))"
        )
    }

    /// A13: 存在しないパスを渡したときに doc どおり `SoundFileError.fileNotFound` が出るか。
    static func soundFileMissingPath(loadSound: SoundLoader) -> Verdict {
        let path = "/nonexistent/metaphor-sounding-does-not-exist.wav"
        var description = "throw されなかった"
        var ok = false
        do {
            _ = try loadSound(path)
        } catch let error as SoundFileError {
            if case .fileNotFound = error { ok = true }
            description = "\(error)"
        } catch {
            description = "別の型: \(type(of: error))"
        }
        return Verdict(
            id: "A13.soundFileMissingPath",
            passed: ok,
            detail: "A13 存在しないパス: \(description) 期待=SoundFileError.fileNotFound"
        )
    }

    // MARK: - MetaphorNoise: 素の性質

    /// N1: `constant(value:)` がその値を厳密に返すか（最も素直なオラクル）。
    static func constantValue(_ makeNoise: NoiseFactory) -> Verdict {
        var raw = NoiseConfig()
        raw.normalized = false
        let constant = makeNoise(.constant(value: 0.25), raw)
        let plain = constant.sample(x: 3.7, y: -1.2)

        var normalized = NoiseConfig()
        normalized.normalized = true
        let mapped = makeNoise(.constant(value: 0.25), normalized).sample(x: 3.7, y: -1.2)

        // normalized は (v + 1) / 2。0.25 → 0.625。
        let ok = abs(plain - 0.25) < 1e-5 && abs(mapped - 0.625) < 1e-5
        return Verdict(
            id: "N1.constantValue",
            passed: ok,
            detail: "N1 constant(0.25): raw=\(f(plain, 5)) 期待=0.25000 /"
                + " normalized=\(f(mapped, 5)) 期待=0.62500"
        )
    }

    /// N2: `normalized: true` が doc どおり [0, 1] を守るか。
    static func normalizedRange(_ makeNoise: NoiseFactory) -> Verdict {
        var config = NoiseConfig(octaves: 6, frequency: 1.2, seed: 7)
        config.normalized = true
        let noise = makeNoise(.perlin, config)

        var minimum: Float = .greatestFiniteMagnitude
        var maximum: Float = -.greatestFiniteMagnitude
        for i in 0..<200 {
            for j in 0..<200 {
                let v = noise.sample(x: Float(i) * 0.03, y: Float(j) * 0.03)
                minimum = min(minimum, v)
                maximum = max(maximum, v)
            }
        }
        let ok = minimum >= -1e-5 && maximum <= 1 + 1e-5
        return Verdict(
            id: "N2.normalizedRange",
            passed: ok,
            detail: "N2 perlin 4 万点: min=\(f(minimum, 5)) max=\(f(maximum, 5)) 期待=[0, 1]"
        )
    }

    /// N3: 同じシードで再現し、違うシードで別物になるか。
    static func seedReproducibility(_ makeNoise: NoiseFactory) -> Verdict {
        func samples(seed: Int32) -> [Float] {
            let noise = makeNoise(.perlin, NoiseConfig(octaves: 4, frequency: 1.0, seed: seed))
            return (0..<64).map { noise.sample(x: Float($0) * 0.17, y: 0.31) }
        }

        let a = samples(seed: 42)
        let b = samples(seed: 42)
        let c = samples(seed: 43)
        let same = a == b
        let differs = zip(a, c).contains { abs($0 - $1) > 1e-4 }
        let ok = same && differs
        return Verdict(
            id: "N3.seedReproducibility",
            passed: ok,
            detail: "N3 seed=42 の 2 回が一致=\(same) / seed=43 と相違=\(differs)"
        )
    }

    /// N4: `invert` / `applyAbsoluteValue` / `clamp` / `raiseToPower` が定義どおりに効くか。
    static func transformOps(_ makeNoise: NoiseFactory) -> Verdict {
        var raw = NoiseConfig(octaves: 3, frequency: 1.0, seed: 5)
        raw.normalized = false
        let points: [(Float, Float)] = (0..<32).map { (Float($0) * 0.23, 0.7) }

        let base = makeNoise(.perlin, raw)
        let baseValues = points.map { base.sample(x: $0.0, y: $0.1) }

        let inverted = makeNoise(.perlin, raw)
        inverted.invert()
        let invertedValues = points.map { inverted.sample(x: $0.0, y: $0.1) }
        let invertOK = zip(baseValues, invertedValues).allSatisfy { abs($0 + $1) < 1e-5 }

        let absolute = makeNoise(.perlin, raw)
        absolute.applyAbsoluteValue()
        let absoluteValues = points.map { absolute.sample(x: $0.0, y: $0.1) }
        let absOK = zip(baseValues, absoluteValues).allSatisfy { abs(abs($0) - $1) < 1e-5 }

        let clamped = makeNoise(.perlin, raw)
        clamped.clamp(min: -0.1, max: 0.1)
        let clampedValues = points.map { clamped.sample(x: $0.0, y: $0.1) }
        let clampOK = clampedValues.allSatisfy { $0 >= -0.1 - 1e-5 && $0 <= 0.1 + 1e-5 }

        let powered = makeNoise(.perlin, raw)
        powered.raiseToPower(2)
        let poweredValues = points.map { powered.sample(x: $0.0, y: $0.1) }
        let poweredFinite = poweredValues.allSatisfy { $0.isFinite }

        let ok = invertOK && absOK && clampOK && poweredFinite
        return Verdict(
            id: "N4.transformOps",
            passed: ok,
            detail: "N4 invert=\(invertOK) abs=\(absOK) clamp=\(clampOK)"
                + " raiseToPower(2) が有限=\(poweredFinite)"
                + "（負値の底に非整数でない指数。clamp 後の範囲"
                + " [\(f(clampedValues.min() ?? 0, 4)), \(f(clampedValues.max() ?? 0, 4))]）"
        )
    }

    /// N5: `add` / `multiply` が可換か。合成後も値域が保たれるか。
    static func compositionOps(_ makeNoise: NoiseFactory) -> Verdict {
        var raw = NoiseConfig(octaves: 3, frequency: 1.0, seed: 11)
        raw.normalized = false
        let otherConfig = NoiseConfig(
            octaves: 3, frequency: 2.0, lacunarity: 2.0, seed: 29,
            persistence: 0.5, normalized: false
        )
        let points: [(Float, Float)] = (0..<32).map { (Float($0) * 0.19, -0.4) }

        func composed(_ reversed: Bool, multiply: Bool) -> [Float] {
            let a = makeNoise(.perlin, reversed ? otherConfig : raw)
            let b = makeNoise(.perlin, reversed ? raw : otherConfig)
            if multiply { a.multiply(b) } else { a.add(b) }
            return points.map { a.sample(x: $0.0, y: $0.1) }
        }

        let addForward = composed(false, multiply: false)
        let addReverse = composed(true, multiply: false)
        let mulForward = composed(false, multiply: true)
        let mulReverse = composed(true, multiply: true)

        let addCommutes = zip(addForward, addReverse).allSatisfy { abs($0 - $1) < 1e-5 }
        let mulCommutes = zip(mulForward, mulReverse).allSatisfy { abs($0 - $1) < 1e-5 }
        let addRange = (addForward.min() ?? 0, addForward.max() ?? 0)
        let ok = addCommutes && mulCommutes
        return Verdict(
            id: "N5.compositionOps",
            passed: ok,
            detail: "N5 add が可換=\(addCommutes) multiply が可換=\(mulCommutes)"
                + " / add の値域 [\(f(addRange.0, 4)), \(f(addRange.1, 4))]"
                + "（normalized:false の素の和なので ±1 を超えうる）"
        )
    }

    /// N6: `frequency` を倍にすると空間周期が半分になるか。符号の変わる回数で測る。
    static func frequencyPeriod(_ makeNoise: NoiseFactory) -> Verdict {
        // 短い区間・1 本の走査線だと交差が十数回しか出ず、比が数え落としで暴れる。
        // x∈[0,200] を 0.01 刻みで、4 本の走査線の合計で数える。
        func crossings(frequency: Double) -> Int {
            var config = NoiseConfig(octaves: 1, frequency: frequency, seed: 3)
            config.normalized = false
            let noise = makeNoise(.perlin, config)
            var count = 0
            for line in 0..<4 {
                let y = 0.37 + Float(line) * 11.13
                var previous = noise.sample(x: Float(0), y: y)
                for i in 1...20_000 {
                    let value = noise.sample(x: Float(i) * 0.01, y: y)
                    if (previous < 0) != (value < 0) { count += 1 }
                    previous = value
                }
            }
            return count
        }

        let counts = [0.5, 1.0, 2.0, 4.0].map { (frequency: $0, count: crossings(frequency: $0)) }
        // 隣り合う周波数はすべて 2 倍。交差数も 2 倍になるはず。
        let ratios = zip(counts.dropFirst(), counts).map { next, previous in
            previous.count > 0 ? Float(next.count) / Float(previous.count) : 0
        }
        let ok = ratios.allSatisfy { abs($0 - 2) < 0.2 }
        let described = counts.map { "f=\(f(Float($0.frequency), 1))→\($0.count)" }
            .joined(separator: " ")
        return Verdict(
            id: "N6.frequencyPeriod",
            passed: ok,
            detail: "N6 x∈[0,200]×4 本のゼロ交差: \(described)"
                + " / 倍化ごとの比=[\(ratios.map { f($0) }.joined(separator: ", "))] 期待≈2.000"
        )
    }

    /// N7: `octaves` を増やすと細かい成分が増えるか。隣接差分の分散で測る。
    static func octaveDetail(_ makeNoise: NoiseFactory) -> Verdict {
        func roughness(octaves: Int) -> Float {
            var config = NoiseConfig(octaves: octaves, frequency: 1.0, seed: 13)
            config.normalized = false
            let noise = makeNoise(.perlin, config)
            let values = (0..<2_000).map { noise.sample(x: Float($0) * 0.002, y: 0.25) }
            var sum: Float = 0
            for i in 1..<values.count {
                let d = values[i] - values[i - 1]
                sum += d * d
            }
            return sqrtf(sum / Float(values.count - 1))
        }

        let coarse = roughness(octaves: 1)
        let fine = roughness(octaves: 6)
        let ok = fine > coarse
        return Verdict(
            id: "N7.octaveDetail",
            passed: ok,
            detail: "N7 隣接差分の RMS: octaves=1 → \(f(coarse, 5)) octaves=6 → \(f(fine, 5))"
                + " 増加=\(ok)"
        )
    }

    /// N9: `sampleGrid` と `sample` の重なり方は docs どおりか。
    ///
    /// metaphor#785 は **docs で確定する**形で解決した（`GKNoiseGenerator` の
    /// "Two entry points, two coordinate spaces"）。`sample(x:y:)` は `origin` も
    /// `sampleScale` も適用せず、`sampleGrid` は両方を `GKNoiseMap` へ渡す。
    /// 重なるのは **index (0, 0) の 1 点だけ**で、`origin + index × sampleScale` を
    /// `sample()` に当ててもグリッドの i 番目は再現しない（実効ステップは `sampleScale`
    /// だけでなくグリッド寸法にも依る）。挙動は報告時から変わっていないので、
    /// 検査を「一致するはず」から「**docs が約束する形で食い違うはず**」へ向け直す。
    /// **この作品はグリッドを一次証拠に使うので、ここが崩れると全部崩れる。**
    static func gridMatchesSample(_ makeNoise: NoiseFactory) -> Verdict {
        let spacing = 0.02
        let origin = SIMD2(0.35, -0.75)
        var config = NoiseConfig(octaves: 4, frequency: 1.4, seed: 21)
        config.normalized = true
        config.sampleScale = SIMD2(spacing, spacing)
        config.origin = origin
        let noise = makeNoise(.perlin, config)

        let width = 64
        let height = 64
        let grid = noise.sampleGrid(width: width, height: height)

        // 約束その 1: 唯一の重なりである index (0, 0)。grid[0] は sample(origin) と一致する。
        let atOrigin = noise.sample(x: origin.x, y: origin.y)
        let originMatches = abs(grid[0] - atOrigin) < 1e-4

        // 約束その 2: そこから先は重ならない。`origin + col × sampleScale` を sample() に
        // 当てても grid[col] にはならない（別座標系なので当たる方が異常）。
        //
        // 行 0 の全点で比べる。「刻みを総当たりして一番合うものを探す」のは一度やって捨てた。
        // 点数を絞ると滑らかな関数には複数の刻みが同程度に当てはまり、正方格子なのに
        // x と y で別の答えが出る（= 見せかけの最小値）。行全体を使った残差の方が正直な数字になる。
        var worst: Float = 0
        var worstAt = 0
        for col in 1..<width {
            let expected = noise.sample(x: origin.x + Double(col) * spacing, y: origin.y)
            let delta = abs(grid[col] - expected)
            if delta > worst {
                worst = delta
                worstAt = col
            }
        }
        let diverges = worst > 1e-4

        let ok = originMatches && diverges
        return Verdict(
            id: "N9.gridMatchesSample",
            passed: ok,
            detail: "N9 grid(64×64) 行 0: grid[0]==sample(origin)=\(originMatches)"
                + "（\(f(grid[0], 5)) vs \(f(atOrigin, 5))）/"
                + " col≥1 を 1 マス=sampleScale(\(f(spacing, 3))) と読んだときの最大差=\(f(worst, 5))"
                + "（col=\(worstAt)）→ 別座標系として食い違う=\(diverges)"
                + " / docs が約束するのは (0,0) の一致だけ"
        )
    }

    /// N8: `origin` / `sampleScale` の効く範囲は docs どおりか。
    ///
    /// 実装上 `sample` は `gkNoise.value(atPosition:)` を直接呼ぶだけで、
    /// この 2 つはグリッド／テクスチャ経路にしか効かない。報告時（metaphor#785）は
    /// 「同じ座標を指す 2 つの入口が別の答えを返す」ことを問題として挙げたが、
    /// 上流は **その非対称を仕様として docs に明記する**形で解決した
    /// （`sample(x:y:)`: "neither origin nor sampleScale is applied"）。
    /// なので検査も「一致すべき」から「**宣言どおり非対称であるべき**」へ向け直す。
    /// 差の数値は変わらず detail に残すので、非対称の中身は今までどおり読める。
    static func originIgnoredBySample(_ makeNoise: NoiseFactory) -> Verdict {
        var base = NoiseConfig(octaves: 4, frequency: 1.4, seed: 21)
        base.normalized = true
        var shifted = base
        // 格子点を避けた原点にする（整数だと Perlin が 0 を返して差が消える）。
        shifted.origin = SIMD2(5.37, 5.61)
        shifted.sampleScale = SIMD2(3.0, 3.0)

        let plain = makeNoise(.perlin, base)
        let moved = makeNoise(.perlin, shifted)

        // 格子点ちょうど（整数座標）では Perlin が常に 0 を返すので、
        // どんな取り違えでも一致してしまう。必ず格子から外した点で測る。
        let probeX: Float = 0.37
        let probeY: Float = 0.61
        let atProbe = plain.sample(x: probeX, y: probeY)
        let movedAtProbe = moved.sample(x: probeX, y: probeY)
        let sampleIgnores = abs(atProbe - movedAtProbe) < 1e-6

        // グリッドの方は原点が (5.37, 5.61) へ移るはず。
        let movedGrid = moved.sampleGrid(width: 4, height: 4)[0]
        let atOriginOfGrid = plain.sample(x: Float(5.37), y: Float(5.61))
        let gridHonors = abs(movedGrid - atOriginOfGrid) < 1e-4

        // docs が宣言する非対称（sample は無視 / grid は反映）どおりなら PASS。
        // どちらかが崩れたら、それは docs と実装が食い違ったということ。
        let ok = sampleIgnores && gridHonors
        return Verdict(
            id: "N8.originScope",
            passed: ok,
            detail: "N8 origin/sampleScale: sample() が無視=\(sampleIgnores)"
                + "（(0.37, 0.61) で \(f(atProbe, 5)) vs \(f(movedAtProbe, 5))）"
                + " / sampleGrid が反映=\(gridHonors)"
                + "（grid[0]=\(f(movedGrid, 5)) sample(5.37, 5.61)=\(f(atOriginOfGrid, 5))）"
                + " / docs の宣言はこの非対称そのもの"
        )
    }

    /// N10: `sample` の Float 版と Double 版が一致するか。
    static func floatDoubleParity(_ makeNoise: NoiseFactory) -> Verdict {
        let noise = makeNoise(.billow, NoiseConfig(octaves: 3, frequency: 1.1, seed: 8))
        var worst: Float = 0
        for i in 0..<128 {
            let x = Double(i) * 0.037
            let y = -0.21
            let byDouble = noise.sample(x: x, y: y)
            let byFloat = noise.sample(x: Float(x), y: Float(y))
            worst = max(worst, abs(byDouble - byFloat))
        }
        let ok = worst < 1e-6
        return Verdict(
            id: "N10.floatDoubleParity",
            passed: ok,
            detail: "N10 Float 版と Double 版の最大差=\(f(worst, 7))"
        )
    }

    /// N11: スタンドアロンの `noise()` と `NoiseType.perlin` は別物か。
    ///
    /// 別実装なので値は違って当たり前。ここで確かめたいのは
    /// **スタンドアロン側がシードで再現するか**と、値域が doc どおり 0…1 か。
    static func standaloneNoiseParity(_ makeNoise: NoiseFactory) -> Verdict {
        noiseSeed(1_234)
        noiseDetail(octaves: 4, falloff: 0.5)
        let first = (0..<64).map { noise(Float($0) * 0.11, 0.5) }
        noiseSeed(1_234)
        noiseDetail(octaves: 4, falloff: 0.5)
        let second = (0..<64).map { noise(Float($0) * 0.11, 0.5) }

        let reproducible = first == second
        let inRange = first.allSatisfy { $0 >= 0 && $0 <= 1 }

        let gk = makeNoise(.perlin, NoiseConfig(octaves: 4, frequency: 1.0, seed: 1_234))
        let gkValues = (0..<64).map { gk.sample(x: Float($0) * 0.11, y: 0.5) }
        let identical = zip(first, gkValues).allSatisfy { abs($0 - $1) < 1e-4 }

        let ok = reproducible && inRange
        return Verdict(
            id: "N11.standaloneNoise",
            passed: ok,
            detail: "N11 noiseSeed で再現=\(reproducible) 値域 0…1=\(inRange)"
                + " / GKNoise .perlin と同値=\(identical)（別実装なので不一致が想定）"
        )
    }

    /// N12: `voronoiDistanceEnabled` の切り替えが実際に値を変えるか。
    static func voronoiDistanceFlag(_ makeNoise: NoiseFactory) -> Verdict {
        func samples(_ enabled: Bool) -> [Float] {
            var config = NoiseConfig(octaves: 1, frequency: 3.0, seed: 17)
            config.voronoiDistanceEnabled = enabled
            let noise = makeNoise(.voronoi, config)
            return (0..<64).map { noise.sample(x: Float($0) * 0.09, y: 0.6) }
        }

        let on = samples(true)
        let off = samples(false)
        let differs = zip(on, off).contains { abs($0 - $1) > 1e-4 }
        return Verdict(
            id: "N12.voronoiDistanceFlag",
            passed: differs,
            detail: "N12 voronoiDistanceEnabled で値が変わる=\(differs)"
                + "（on の先頭 \(f(on[0], 4)) / off の先頭 \(f(off[0], 4))）"
        )
    }

    /// N13: `texture` / `image` / `colorMappedTexture` が同じ場から一貫した結果を返すか。
    static func textureConsistency(_ makeNoise: NoiseFactory) -> Verdict {
        var config = NoiseConfig(octaves: 4, frequency: 1.3, seed: 33)
        config.normalized = true
        config.sampleScale = SIMD2(0.05, 0.05)
        let noise = makeNoise(.ridged, config)

        let width = 32
        let height = 24
        let grid = noise.sampleGrid(width: width, height: height)

        guard let image = noise.image(width: width, height: height) else {
            return Verdict(id: "N13.textureConsistency", passed: false, detail: "N13 image() が nil")
        }
        image.loadPixels()

        var worst = 0
        for index in stride(from: 0, to: width * height, by: 7) {
            let expected = Int(max(0, min(255, grid[index] * 255)))
            let actual = Int(image.pixels[index * 4])
            worst = max(worst, abs(actual - expected))
        }

        let tooFewStops = noise.colorMappedTexture(
            width: width, height: height,
            colorStops: [(0.0, SIMD4<UInt8>(0, 0, 0, 255))]
        )
        let enoughStops = noise.colorMappedTexture(
            width: width, height: height,
            colorStops: [(0.0, SIMD4<UInt8>(0, 0, 0, 255)), (1.0, SIMD4<UInt8>(255, 255, 255, 255))]
        )

        let ok = worst <= 1 && tooFewStops == nil && enoughStops != nil
        return Verdict(
            id: "N13.textureConsistency",
            passed: ok,
            detail: "N13 image の画素と sampleGrid の最大差=\(worst)/255"
                + " / colorMapped: stop 1 個→nil=\(tooFewStops == nil)"
                + " stop 2 個→生成=\(enoughStops != nil)"
        )
    }

    /// N14: `applyTurbulence` の power を上げると実際に場が乱れるか。
    static func turbulenceEffect(_ makeNoise: NoiseFactory) -> Verdict {
        var config = NoiseConfig(octaves: 3, frequency: 1.0, seed: 19)
        config.normalized = false
        let points: [(Float, Float)] = (0..<48).map { (Float($0) * 0.13, 0.15) }

        let plain = makeNoise(.perlin, config)
        let plainValues = points.map { plain.sample(x: $0.0, y: $0.1) }

        let turbulent = makeNoise(.perlin, config)
        turbulent.applyTurbulence(frequency: 2.4, power: 0.5, roughness: 3, seed: 19)
        let turbulentValues = points.map { turbulent.sample(x: $0.0, y: $0.1) }

        var drift: Float = 0
        for (a, b) in zip(plainValues, turbulentValues) { drift += abs(a - b) }
        drift /= Float(points.count)
        let finite = turbulentValues.allSatisfy { $0.isFinite }
        let ok = drift > 1e-3 && finite
        return Verdict(
            id: "N14.turbulenceEffect",
            passed: ok,
            detail: "N14 power=0.5 での平均変位=\(f(drift, 5)) すべて有限=\(finite)"
        )
    }

    /// N15: `config` を書き換えると合成（`add` / `applyTurbulence` 等）が消えるか。
    ///
    /// ライブラリのソースコメントには「config を変えるとソースが再構築され、合成は失われる」と
    /// 書いてあるが、生成される `llms.txt` 側にはその注記が落ちている。
    /// 毎フレーム config を書くこの作品では致命的な差なので、事実として測っておく。
    static func configResetsComposition(_ makeNoise: NoiseFactory) -> Verdict {
        var config = NoiseConfig(octaves: 3, frequency: 1.0, seed: 23)
        config.normalized = false
        let noise = makeNoise(.perlin, config)
        let before = noise.sample(x: 0.4, y: 0.9)

        noise.invert()
        let inverted = noise.sample(x: 0.4, y: 0.9)

        // 同じ値を書き戻すだけでも setter は走る。
        noise.config = config
        let afterRewrite = noise.sample(x: 0.4, y: 0.9)

        let invertApplied = abs(before + inverted) < 1e-5
        let compositionLost = abs(afterRewrite - before) < 1e-5
        return Verdict(
            id: "N15.configResetsComposition",
            passed: invertApplied,
            detail: "N15 invert 適用=\(invertApplied)（\(f(before, 5)) → \(f(inverted, 5))）"
                + " / 同値の config 書き戻しで invert が消える=\(compositionLost)"
                + "（→ \(f(afterRewrite, 5))）。llms.txt にこの注記が無い"
        )
    }

    // MARK: - 組み合わせ

    /// X2: 実行中に `octaves` を変えたとき、値がどれだけ飛ぶか。
    ///
    /// この作品は音でノイズの設定を動かすので、段の切り替えで画が飛ぶと実害になる。
    static func octaveDiscontinuity(_ makeNoise: NoiseFactory) -> Verdict {
        var config = NoiseConfig(octaves: 4, frequency: 1.2, seed: 31)
        config.normalized = true
        let noise = makeNoise(.perlin, config)
        let points: [(Float, Float)] = (0..<64).map { (Float($0) * 0.05, 0.5) }
        let before = points.map { noise.sample(x: $0.0, y: $0.1) }

        config.octaves = 5
        noise.config = config
        let after = points.map { noise.sample(x: $0.0, y: $0.1) }

        var maximum: Float = 0
        var mean: Float = 0
        for (a, b) in zip(before, after) {
            let d = abs(a - b)
            maximum = max(maximum, d)
            mean += d
        }
        mean /= Float(points.count)
        // 1 オクターブ増やしただけで場が別物になるなら、遷移は隠さないと見える。
        let ok = maximum < 0.25
        return Verdict(
            id: "X2.octaveDiscontinuity",
            passed: ok,
            detail: "X2 octaves 4→5: 最大変位=\(f(maximum, 4)) 平均=\(f(mean, 4)) 閾値=0.2500"
        )
    }

    /// X3: 音の側から来た異常値（NaN・∞・範囲外）を地形へ通さないか。
    static func bandToConfigSafety() -> Verdict {
        let inputs: [Float] = [.nan, .infinity, -.infinity, -5, 12, 0.5]
        let outputs = inputs.map { Field.sanitize($0) }
        let ok = outputs.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
            && outputs[0] == 0 && outputs[5] == 0.5
        return Verdict(
            id: "X3.bandToConfigSafety",
            passed: ok,
            detail: "X3 [NaN, +∞, -∞, -5, 12, 0.5] → [\(outputs.map { f($0, 2) }.joined(separator: ", "))]"
        )
    }
}
