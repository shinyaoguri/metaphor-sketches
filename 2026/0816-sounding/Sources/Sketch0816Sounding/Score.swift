import Foundation

// 内蔵スコア。
//
// この作品の音源は外部ファイルではなく、起動時にここで合成する。理由は 2 つ:
//
// 1. **周波数成分が既知**になる。何 Hz に何のエネルギーが乗っているかを自分で決めるので、
//    解析側（AudioAnalyzer）が返すスペクトルの期待値を数式で書き下せる。
//    スクリーンショットではなく数値を一次証拠にするための土台。
// 2. **リポジトリに音声ファイルを持ち込まずに済む**。実行のたびに同じ波形を合成するので、
//    決定論も保たれる（浮動小数の演算順序が同じなら同じ WAV になる）。
//
// 出力は 44.1kHz / 16bit / モノラルの WAV。`SoundFile` は AVAudioFile 経由で読むので
// 標準的な RIFF ヘッダで足りる。
enum Score {

    /// 合成のサンプリング周波数。`AudioAnalyzer.sampleRate` へ渡す値でもある。
    static let sampleRate: Double = 44_100

    /// 1 ループの長さ（秒）。BPM 120 の 16 拍ちょうど。
    static let duration: Double = 8.0

    /// 拍の長さ（秒）。ビート検出の期待間隔でもある。
    static let beat: Double = 0.5

    // MARK: - 周波数の設計（検査の期待値になる）

    /// ドローンの基音。低域バンドの主成分。
    static let droneFundamental: Float = 55.0

    /// キックの開始周波数（ここから 40Hz へ落ちる）。
    static let kickStartFrequency: Float = 90.0

    /// アルペジオの音列（A マイナーペンタトニック）。中域〜高域の主成分。
    static let arpeggio: [Float] = [440.0, 523.25, 587.33, 659.25, 880.0]

    /// シマーの中心周波数。高域バンドの主成分。
    static let shimmerCenter: Float = 4_200.0

    // MARK: - 合成

    /// 1 ループぶんのモノラル PCM を合成する。範囲は [-1, 1]。
    static func render() -> [Float] {
        let frameCount = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: frameCount)
        // 決定論のため、乱数は固定シードの線形合同法だけを使う（Foundation の乱数は使わない）。
        var rng = LCG(seed: 0x5EED_0816)

        for i in 0..<frameCount {
            let t = Float(Double(i) / sampleRate)
            var value: Float = 0

            value += drone(t)
            value += kick(t)
            value += arp(t)
            value += shimmer(t, rng: &rng)

            samples[i] = value
        }

        // クリップを避けつつ、解析に十分な振幅を確保する（ピークを 0.9 に揃える）。
        let peak = samples.reduce(0) { max($0, abs($1)) }
        if peak > 0 {
            let gain = 0.9 / peak
            for i in 0..<frameCount { samples[i] *= gain }
        }
        return samples
    }

    /// 低域: 基音とその 5 度・オクターブ。ゆっくり息をする。
    private static func drone(_ t: Float) -> Float {
        let breath = 0.75 + 0.25 * sin(t * Float.pi * 2 / 8.0)
        let f = droneFundamental
        return breath * (0.28 * sinf(t * f * 2 * .pi)
            + 0.10 * sinf(t * f * 1.5 * 2 * .pi)
            + 0.13 * sinf(t * f * 2.0 * 2 * .pi))
    }

    /// 低域のインパルス。ビート検出の対象で、作品では ping の引き金になる。
    private static func kick(_ t: Float) -> Float {
        let phase = Float(fmod(Double(t), beat))
        guard phase < 0.25 else { return 0 }
        // 90Hz から 40Hz へ落ちる。位相は積分した瞬時周波数で作る（不連続を避ける）。
        let decay = expf(-phase / 0.055)
        let f = 40 + (kickStartFrequency - 40) * expf(-phase / 0.03)
        return 0.55 * decay * sinf(phase * f * 2 * .pi)
    }

    /// 中域: 8 分音符のアルペジオ。音列は 8 秒で一巡しない長さにして、ループの継ぎ目を目立たせない。
    private static func arp(_ t: Float) -> Float {
        let step = Int(t / 0.25)
        // 5 音を 3 つ飛ばしで拾うと 5 と 3 が互いに素なので 15 ステップ周期になる。
        let note = arpeggio[(step * 3) % arpeggio.count]
        let octave: Float = (step % 7 == 3) ? 2.0 : 1.0
        let phase = t - Float(step) * 0.25
        let env = expf(-phase / 0.09) * (1 - expf(-phase / 0.004))
        let f = note * octave
        return 0.20 * env * (sinf(phase * f * 2 * .pi) + 0.25 * sinf(phase * f * 3 * 2 * .pi))
    }

    /// 高域: 2 秒ごとの短いノイズバースト。高域バンドを動かすためだけに居る。
    private static func shimmer(_ t: Float, rng: inout LCG) -> Float {
        let n = rng.nextSymmetric()
        let phase = Float(fmod(Double(t), 2.0))
        guard phase < 0.6 else { return 0 }
        let env = expf(-phase / 0.18) * (1 - expf(-phase / 0.01))
        // 白色ノイズを高域の搬送波で変調して、おおよそ shimmerCenter 付近へ寄せる。
        return 0.10 * env * n * sinf(t * shimmerCenter * 2 * .pi)
    }

    // MARK: - WAV 書き出し

    /// 合成した PCM を WAV として書き出し、そのパスを返す。
    ///
    /// 置き場はシステムの一時ディレクトリ。リポジトリには音声を持ち込まない。
    static func writeWAV(to path: String? = nil) throws -> String {
        let destination = path ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("metaphor-sounding-score.wav").path
        let samples = render()
        try wavData(from: samples).write(to: URL(fileURLWithPath: destination), options: .atomic)
        return destination
    }

    /// モノラル 16bit PCM の RIFF/WAVE を組み立てる。
    static func wavData(from samples: [Float]) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let rate = UInt32(sampleRate)
        let byteRate = rate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataBytes = UInt32(samples.count * Int(bitsPerSample / 8))

        var data = Data(capacity: 44 + Int(dataBytes))
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLE(UInt32(16))          // PCM 用 fmt チャンクの長さ
        data.appendLE(UInt16(1))           // フォーマット = リニア PCM
        data.appendLE(channels)
        data.appendLE(rate)
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.appendLE(dataBytes)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            data.appendLE(Int16(clamped * 32_767))
        }
        return data
    }

    // MARK: - 検査用の素の波形

    /// 単一正弦波。解析側の期待値を数式で書けるので、検査の基準信号に使う。
    ///
    /// - Parameters:
    ///   - frequency: 周波数（Hz）
    ///   - count: サンプル数
    ///   - amplitude: 振幅（RMS は `amplitude / √2` になる）
    ///   - rate: サンプリング周波数
    static func sine(
        frequency: Float,
        count: Int,
        amplitude: Float = 1.0,
        rate: Double = sampleRate
    ) -> [Float] {
        (0..<count).map { i in
            amplitude * sinf(Float(Double(i) / rate) * frequency * 2 * .pi)
        }
    }
}

/// 線形合同法。決定論を保つためだけの最小実装（品質は問わない）。
struct LCG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    /// [-1, 1] の値を返す。
    mutating func nextSymmetric() -> Float {
        Float(next() >> 40) / Float(1 << 23) * 2 - 1
    }
}

private extension Data {
    /// 整数をリトルエンディアンで追記する（WAV ヘッダはすべてリトルエンディアン）。
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        // Data 自身の withUnsafeBytes と名前が衝突するので、グローバル版を明示する。
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
