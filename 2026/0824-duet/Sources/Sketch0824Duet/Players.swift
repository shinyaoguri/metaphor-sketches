import Foundation
import metaphor

/// 二人の奏者。**同じ譜面（`Score`）を、片方は Swift で、片方は MSL で弾く。**
///
/// GPU の結果は「いま投げたフレーム」では読めない（コマンドバッファが完了していない）。
/// そこでカーネル自身に**弾いた小節番号**を `statusBuffer` へ書かせ、
/// 読めた番号に対応する CPU 側の控えと突き合わせる。番号を持たずに
/// 「たぶん 1 フレーム遅れ」で比べると、遅れそのものを食い違いとして数えてしまう。
@MainActor
final class Duet {
    struct Divergence {
        let step: UInt32
        let voices: Int
        let maxAbs: Float
        let rms: Float
        /// 声部ごとのズレ。継ぎ目の帯はこれを描く。
        /// **同じ小節どうしを引いた値**でなければ、遅れをズレとして描いてしまう。
        let perVoice: [Float]
    }

    let capacity: Int
    private(set) var count: Int

    private(set) var cpuVoices: [Voice]
    let voiceBuffer: GPUBuffer<Voice>
    let markBuffer: GPUBuffer<CircleInstance>
    let statusBuffer: GPUBuffer<UInt32>

    let single: ComputeKernel
    let accelerate: ComputeKernel
    let translate: ComputeKernel

    private(set) var step: UInt32 = 0
    /// 直近の CPU 側の控え。GPU が遅れて返してくる小節に合わせて引く。
    private var history: [(step: UInt32, count: Int, voices: [Voice])] = []
    private static let historyDepth = 12

    init(host: some Sketch, capacity: Int, count: Int) throws {
        self.capacity = capacity
        self.count = min(count, capacity)

        single = try host.createComputeKernel(source: Kernels.singlePass, function: "duetAdvance")
        accelerate = try host.createComputeKernel(source: Kernels.twoPass, function: "duetAccelerate")
        translate = try host.createComputeKernel(source: Kernels.twoPass, function: "duetTranslate")

        let opening = Score.opening(count: capacity)
        guard let voices = host.createBuffer(opening),
              let marks = host.createBuffer(count: capacity, type: CircleInstance.self),
              let status = host.createBuffer(count: 4, type: UInt32.self)
        else {
            throw DuetError.bufferAllocationFailed
        }
        voiceBuffer = voices
        markBuffer = marks
        statusBuffer = status
        cpuVoices = opening
    }

    /// 声部数を変える。**両者を同じ開幕へ戻す**（途中から数を変えると、
    /// どちらが崩れたのか分からなくなる）。
    func retune(count newCount: Int) {
        count = min(newCount, capacity)
        reset()
    }

    func reset() {
        let opening = Score.opening(count: capacity)
        cpuVoices = opening
        voiceBuffer.copyFrom(opening)
        statusBuffer[0] = 0
        step = 0
        history.removeAll(keepingCapacity: true)
    }

    // MARK: - 演奏

    /// CPU 側を 1 小節進め、その時点の控えを残す。
    func advanceCPU(at t: Float) {
        step &+= 1
        for i in 0..<count {
            cpuVoices[i] = Score.advance(cpuVoices[i], t, Score.dt)
        }
        history.append((step: step, count: count, voices: Array(cpuVoices[0..<count])))
        if history.count > Self.historyDepth { history.removeFirst() }
    }

    /// GPU 側を 1 小節ぶんエンコードする。**`compute()` の中でしか効かない**
    /// （コマンドバッファが無い場所では黙って何もしない = `G14` で測る）。
    func encodeGPU(on host: some Sketch, bars: Bars, twoPass: Bool, barrier: Bool) {
        if twoPass {
            host.dispatch(accelerate, threads: count) { encoder in
                var b = bars
                encoder.setBuffer(self.voiceBuffer.buffer, offset: 0, index: 0)
                encoder.setBytes(&b, length: MemoryLayout<Bars>.stride, index: 1)
            }
            if barrier { host.computeBarrier() }
            host.dispatch(translate, threads: count) { encoder in
                var b = bars
                encoder.setBuffer(self.voiceBuffer.buffer, offset: 0, index: 0)
                encoder.setBuffer(self.markBuffer.buffer, offset: 0, index: 1)
                encoder.setBytes(&b, length: MemoryLayout<Bars>.stride, index: 2)
                encoder.setBuffer(self.statusBuffer.buffer, offset: 0, index: 3)
            }
        } else {
            host.dispatch(single, threads: count) { encoder in
                var b = bars
                encoder.setBuffer(self.voiceBuffer.buffer, offset: 0, index: 0)
                encoder.setBuffer(self.markBuffer.buffer, offset: 0, index: 1)
                encoder.setBytes(&b, length: MemoryLayout<Bars>.stride, index: 2)
                encoder.setBuffer(self.statusBuffer.buffer, offset: 0, index: 3)
            }
        }
    }

    // MARK: - 突き合わせ

    /// GPU が返した小節に対応する CPU の控えと比べる。
    /// 対応する控えが無ければ `nil`（**無いのに比べない**）。
    func divergence() -> Divergence? {
        let gpuStep = statusBuffer[0]
        guard gpuStep > 0, let mine = history.first(where: { $0.step == gpuStep }) else { return nil }
        let theirs = voiceBuffer.toArray()
        let n = min(mine.count, theirs.count)
        guard n > 0 else { return nil }

        var worst: Float = 0
        var sum: Double = 0
        var each = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let d = mine.voices[i].pos - theirs[i].pos
            let e = (d.x * d.x + d.y * d.y).squareRoot()
            each[i] = e
            worst = max(worst, e)
            sum += Double(e) * Double(e)
        }
        return Divergence(
            step: gpuStep, voices: n, maxAbs: worst,
            rms: Float((sum / Double(n)).squareRoot()), perVoice: each)
    }

    /// CPU 側の声部を、そのまま描ける形へ。
    /// **`scoreStamp`（MSL）と同じ式**でなければ、絵の違いが譜面の違いに見えてしまう。
    func cpuMarks(center: SIMD2<Float>, scale: Float, mirror: Float, size: Float) -> [CircleInstance] {
        (0..<count).map { i in
            let v = cpuVoices[i]
            let p = center + SIMD2(mirror * v.pos.x, -v.pos.y) * scale
            let speed = (v.vel.x * v.vel.x + v.vel.y * v.vel.y).squareRoot()
            let heat = min(speed * 0.55, 1.0)
            return CircleInstance(
                position: p,
                diameter: size * (0.65 + min(speed, 2.0) * 0.5),
                color: SIMD4(0.35 + heat * 0.6, 0.55 + heat * 0.35, 0.95 - heat * 0.35, 0.85))
        }
    }
}

enum DuetError: Error, CustomStringConvertible {
    case bufferAllocationFailed

    var description: String {
        switch self {
        case .bufferAllocationFailed: return "GPU バッファを確保できなかった"
        }
    }
}
