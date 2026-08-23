import Foundation
import Metal
import metaphor

/// 舞台に据えた計器。**描画も時計も使わない決定論的な判定**を並べる。
///
/// 判定は真偽値ではなく**実測値を含む文字列**にする（`FAIL G3 count=65 で末尾 1 個が未書き込み`）。
/// そのまま issue に貼れば数字が証拠になる。`probe("check.<ID>", …)` と標準出力の両方へ出す
/// （MCP が使えないセッションでも `swift run` の出力から拾えるように）。
///
/// **GPU の検査は `setup()` では走らない。** `dispatch` はコマンドバッファのある
/// `compute()` の中でしか効かないので、1 フレーム目でエンコードし、2 フレーム目で読み戻す。
/// この「setup() では黙って何も起きない」こと自体も `G14` で測っている。
@MainActor
final class Instrument {
    struct Result {
        let id: String
        /// `PASS` / `FAIL` / `LOOK`（人が見て決める）/ `N/A`（この起動では測れない）
        let verdict: String
        let detail: String
    }

    private(set) var results: [Result] = []
    private var order: [String] = []

    private func record(_ id: String, _ verdict: String, _ detail: String) {
        if let i = results.firstIndex(where: { $0.id == id }) {
            results[i] = Result(id: id, verdict: verdict, detail: detail)
        } else {
            results.append(Result(id: id, verdict: verdict, detail: detail))
            order.append(id)
        }
        Log.line("\(verdict) \(id)  \(detail)")
    }

    /// 計器の外（描画フェーズでしか測れないもの）から結果を差し込む口。
    func recordExternal(_ id: String, _ verdict: String, _ detail: String) {
        record(id, verdict, detail)
    }

    var failures: Int { results.filter { $0.verdict == "FAIL" }.count }
    var passes: Int { results.filter { $0.verdict == "PASS" }.count }

    // MARK: - 計器が持つ道具

    private let stamp: ComputeKernel
    private let stamp2D: ComputeKernel
    private let chainA: ComputeKernel
    private let chainB: ComputeKernel
    private let fill: ComputeKernel
    private let single: ComputeKernel

    /// G3 用。声部数ごとに別のバッファを持たせ、番兵の後ろまで見る。
    private var tailBuffers: [Int: GPUBuffer<Float>] = [:]
    private let grid1D: GPUBuffer<Float>
    private let grid2D: GPUBuffer<Float>
    private let scratchNoBarrier: GPUBuffer<UInt32>
    private let scratchBarrier: GPUBuffer<UInt32>
    private let chainOutNoBarrier: GPUBuffer<UInt32>
    private let chainOutBarrier: GPUBuffer<UInt32>
    private let fillBuffer: GPUBuffer<Float>
    private let parityVoices: GPUBuffer<Voice>
    private let parityMarks: GPUBuffer<CircleInstance>
    private let parityStatus: GPUBuffer<UInt32>
    private let longVoices: GPUBuffer<Voice>
    private let longMarks: GPUBuffer<CircleInstance>
    private let longStatus: GPUBuffer<UInt32>

    static let tailCounts = [1, 7, 63, 64, 65, 255, 1023, 1025]
    static let gridW = 64
    static let gridH = 32
    static let chainN = 65_536
    static let parityN = 1_024
    static let longSteps = 240
    static let fillValue: Float = 12_345.0

    private var fillReadImmediately: Float = .nan
    private var fillReadAfterLoadPixels: Float = .nan
    private var loadPixelsProbed = false

    /// 検査の進み。1 = エンコード済み、2 = 読み戻し済み。
    private(set) var stage = 0

    /// エンコードした GPU の仕事が**着地したか**。
    /// 「1 フレーム待てば読める」は保証ではないので、カーネル自身が書いた
    /// 小節番号で着地を確かめてから読み戻す。
    var gpuLanded: Bool { longStatus[0] == UInt32(Self.longSteps) }

    init(host: some Sketch, single: ComputeKernel) throws {
        self.single = single

        let t0 = CFAbsoluteTimeGetCurrent()
        stamp = try host.createComputeKernel(source: Kernels.probes, function: "probeStamp")
        stamp2D = try host.createComputeKernel(source: Kernels.probes, function: "probeStamp2D")
        chainA = try host.createComputeKernel(source: Kernels.probes, function: "probeChainA")
        chainB = try host.createComputeKernel(source: Kernels.probes, function: "probeChainB")
        fill = try host.createComputeKernel(source: Kernels.probes, function: "probeFill")
        let kernelMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        guard let g1 = host.createBuffer(count: Self.gridW * Self.gridH, type: Float.self),
              let g2 = host.createBuffer(count: Self.gridW * Self.gridH, type: Float.self),
              let sNB = host.createBuffer(count: Self.chainN, type: UInt32.self),
              let sB = host.createBuffer(count: Self.chainN, type: UInt32.self),
              let oNB = host.createBuffer(count: Self.chainN, type: UInt32.self),
              let oB = host.createBuffer(count: Self.chainN, type: UInt32.self),
              let fb = host.createBuffer(count: 256, type: Float.self),
              let pv = host.createBuffer(Score.opening(count: Self.parityN)),
              let pm = host.createBuffer(count: Self.parityN, type: CircleInstance.self),
              let ps = host.createBuffer(count: 4, type: UInt32.self),
              let lv = host.createBuffer(Score.opening(count: Self.parityN)),
              let lm = host.createBuffer(count: Self.parityN, type: CircleInstance.self),
              let ls = host.createBuffer(count: 4, type: UInt32.self)
        else { throw DuetError.bufferAllocationFailed }

        grid1D = g1
        grid2D = g2
        scratchNoBarrier = sNB
        scratchBarrier = sB
        chainOutNoBarrier = oNB
        chainOutBarrier = oB
        fillBuffer = fb
        parityVoices = pv
        parityMarks = pm
        parityStatus = ps
        longVoices = lv
        longMarks = lm
        longStatus = ls

        for c in Self.tailCounts {
            guard let b = host.createBuffer(count: c + 8, type: Float.self) else {
                throw DuetError.bufferAllocationFailed
            }
            for i in 0..<(c + 8) { b[i] = -1 }  // 番兵
            tailBuffers[c] = b
        }

        record("G13.kernelBuild", "LOOK",
               "5 カーネルのビルド \(fmt(Float(kernelMs), 1))ms "
               + "（リロードのたびに払う。RSS の伸びはソークで見る）")

        // GPU を要らない検査はここで済ませる。
        checkLayout()
        checkAlloc(host: host)
        checkCopyFrom(host: host)
        checkCompileError(host: host)
        checkDispatchOutsideFrame(host: host)
        checkKernelLimits()
    }

    // MARK: - G10 レイアウト

    /// GPU 側の struct を**公開ドキュメントだけを見て書けるか**。
    ///
    /// `CircleInstance` は `GPUBuffer` に載せてカーネルから書ける公開型なのに、
    /// `llms.txt` はメンバーをアルファベット順（color / diameter / position）で並べる。
    /// 実体は position → diameter → 内部の詰め物 → color。
    /// 並び順どおりに MSL を書くと、コンパイルは通ったまま絵が 1 つも出ない
    /// （詰め物そのものは MSL 側の `float4` の 16B 境界で自動的に入るので、
    /// 効くのは**フィールドの順**）。
    private func checkLayout() {
        let stride = MemoryLayout<CircleInstance>.stride
        let posOff = MemoryLayout<CircleInstance>.offset(of: \.position) ?? -1
        let diaOff = MemoryLayout<CircleInstance>.offset(of: \.diameter) ?? -1
        let colOff = MemoryLayout<CircleInstance>.offset(of: \.color) ?? -1
        let ok = stride == 32 && posOff == 0 && diaOff == 8 && colOff == 16
        record("G10.layout", ok ? "PASS" : "FAIL",
               "CircleInstance stride=\(stride) position@\(posOff) diameter@\(diaOff) color@\(colOff) "
               + "期待 32/0/8/16 / "
               + "この並びは公開 doc から読めない（llms.txt はメンバーをアルファベット順に並べる）。"
               + "順どおりに MSL を書くと**コンパイルは通ったまま 1 つも描かれない** / "
               + "Voice stride=\(MemoryLayout<Voice>.stride) 期待 24 / "
               + "Bars stride=\(MemoryLayout<Bars>.stride) 期待 48")
    }

    // MARK: - G8 確保

    private func checkAlloc(host: some Sketch) {
        let zero = host.createBuffer(count: 0, type: Float.self)
        let huge = host.createBuffer(count: 1 << 34, type: Voice.self)  // 24B × 17e9 ≒ 412GB
        let ok = zero == nil && huge == nil
        record("G8.bufferAlloc", ok ? "PASS" : "FAIL",
               "count:0 → \(zero == nil ? "nil" : "確保された") / "
               + "count:2^34（≒412GB）→ \(huge == nil ? "nil" : "確保された") 期待 どちらも nil。"
               + " ※ stride×count が Int を溢れる大きさは乗算で trap する（DUET_TRAP=alloc）")
    }

    // MARK: - G9 コピー長

    private func checkCopyFrom(host: some Sketch) {
        guard let buf = host.createBuffer([Float](repeating: -1, count: 8)) else {
            record("G9.copyFromLen", "N/A", "検査用バッファを確保できなかった")
            return
        }
        buf.copyFrom([Float](repeating: 7, count: 3))          // 短い
        let shortOK = buf[0] == 7 && buf[2] == 7 && buf[3] == -1
        let tailBefore = buf[7]
        buf.copyFrom([Float](repeating: 9, count: 32))         // 長い
        let longOK = buf[0] == 9 && buf[7] == 9
        record("G9.copyFromLen", shortOK && longOK ? "PASS" : "FAIL",
               "短い配列(3/8): 先頭 3 個だけ入り残りは元のまま=\(shortOK ? "はい" : "いいえ")"
               + "（元の末尾 \(fmt(tailBefore, 0)) は保たれた）/ "
               + "長い配列(32/8): 先頭 8 個で切り詰め=\(longOK ? "はい" : "いいえ") / "
               + "どちらも min(data.count, count) にクランプされる想定")
    }

    // MARK: - G12 壊れた MSL

    private func checkCompileError(host: some Sketch) {
        do {
            _ = try host.createComputeKernel(source: Kernels.broken, function: "probeBroken")
            record("G12.compileError", "FAIL", "壊れた MSL が throw せずに通った")
        } catch {
            let text = String(describing: error)
            let first = text.split(separator: "\n").first.map(String.init) ?? text
            let pointsAtCause = text.contains("undefined_symbol_on_purpose")
            record("G12.compileError", pointsAtCause ? "PASS" : "LOOK",
                   "throw した / メッセージが原因の識別子を含む=\(pointsAtCause ? "はい" : "いいえ") / "
                   + "先頭行: \(first.prefix(160))")
        }
    }

    // MARK: - G14 フレームの外の dispatch

    /// `setup()` から `dispatch` を呼ぶと**警告も出さずに何も起きない**。
    ///
    /// `threads: 0` は警告を出すのに、コマンドバッファが無い場合は
    /// `ensureComputeEncoder()` が黙って nil を返して終わる。
    /// GPU 計算の初期化を setup() に書きたくなるのは自然なので、ここは踏みやすい。
    private func checkDispatchOutsideFrame(host: some Sketch) {
        fillBuffer[0] = -1
        host.dispatch(fill, threads: 16) { encoder in
            var v = Self.fillValue
            encoder.setBuffer(self.fillBuffer.buffer, offset: 0, index: 0)
            encoder.setBytes(&v, length: MemoryLayout<Float>.stride, index: 1)
        }
        host.computeBarrier()
        let after = fillBuffer[0]
        record("G14.dispatchOutsideFrame", after == -1 ? "LOOK" : "FAIL",
               "setup() から dispatch → 書き込み無し=\(after == -1 ? "はい" : "いいえ")（実測 \(fmt(after, 0))）。"
               + " 期待どおり何も起きないが**警告も出ない**（threads:0 は警告する）。"
               + " compute() の外では効かないと知らないと気付けない")
        fillBuffer[0] = 0
    }

    private func checkKernelLimits() {
        record("G3.limits", "LOOK",
               "threadExecutionWidth=\(single.threadExecutionWidth) "
               + "maxTotalThreadsPerThreadgroup=\(single.maxTotalThreadsPerThreadgroup)"
               + "（1D は threadExecutionWidth を、2D は width×(max/width) をグループに使う）")
    }

    // MARK: - 1 フレーム目: エンコード

    func encodeChecks(on host: some Sketch) {
        guard stage == 0 else { return }
        stage = 1

        encodeParity(on: host)
        encodeLong(on: host)
        encodeTail(on: host)
        encodeGrids(on: host)
        encodeChain(on: host)
        encodeFill(on: host)
        encodeTraps(on: host)
    }

    private func bars(t: Float, count: Int, step: UInt32) -> Bars {
        Bars(t: t, dt: Score.dt, count: UInt32(count), flags: 0,
             center: SIMD2(0, 0), scale: 1, mirror: 1, size: 1, step: step)
    }

    private func encodeParity(on host: some Sketch) {
        var b = bars(t: 0, count: Self.parityN, step: 1)
        host.dispatch(single, threads: Self.parityN) { encoder in
            encoder.setBuffer(self.parityVoices.buffer, offset: 0, index: 0)
            encoder.setBuffer(self.parityMarks.buffer, offset: 0, index: 1)
            encoder.setBytes(&b, length: MemoryLayout<Bars>.stride, index: 2)
            encoder.setBuffer(self.parityStatus.buffer, offset: 0, index: 3)
        }
    }

    private func encodeLong(on host: some Sketch) {
        for k in 0..<Self.longSteps {
            var b = bars(t: Float(k) * Score.dt, count: Self.parityN, step: UInt32(k + 1))
            host.dispatch(single, threads: Self.parityN) { encoder in
                encoder.setBuffer(self.longVoices.buffer, offset: 0, index: 0)
                encoder.setBuffer(self.longMarks.buffer, offset: 0, index: 1)
                encoder.setBytes(&b, length: MemoryLayout<Bars>.stride, index: 2)
                encoder.setBuffer(self.longStatus.buffer, offset: 0, index: 3)
            }
            // 次の小節は前の小節の結果を読む。バリアが無いと連鎖が壊れる。
            host.computeBarrier()
        }
    }

    private func encodeTail(on host: some Sketch) {
        for c in Self.tailCounts {
            guard let buf = tailBuffers[c] else { continue }
            host.dispatch(stamp, threads: c) { encoder in
                encoder.setBuffer(buf.buffer, offset: 0, index: 0)
            }
        }
    }

    private func encodeGrids(on host: some Sketch) {
        host.dispatch(stamp, threads: Self.gridW * Self.gridH) { encoder in
            encoder.setBuffer(self.grid1D.buffer, offset: 0, index: 0)
        }
        host.dispatch(stamp2D, width: Self.gridW, height: Self.gridH) { encoder in
            var w = UInt32(Self.gridW)
            encoder.setBuffer(self.grid2D.buffer, offset: 0, index: 0)
            encoder.setBytes(&w, length: MemoryLayout<UInt32>.stride, index: 1)
        }
    }

    private func encodeChain(on host: some Sketch) {
        var n = UInt32(Self.chainN)
        // バリア無し: 前段の書き込みを後段が読む保証が無い
        host.dispatch(chainA, threads: Self.chainN) { encoder in
            encoder.setBuffer(self.scratchNoBarrier.buffer, offset: 0, index: 0)
        }
        host.dispatch(chainB, threads: Self.chainN) { encoder in
            encoder.setBuffer(self.scratchNoBarrier.buffer, offset: 0, index: 0)
            encoder.setBuffer(self.chainOutNoBarrier.buffer, offset: 0, index: 1)
            encoder.setBytes(&n, length: MemoryLayout<UInt32>.stride, index: 2)
        }
        // バリアあり
        host.computeBarrier()
        host.dispatch(chainA, threads: Self.chainN) { encoder in
            encoder.setBuffer(self.scratchBarrier.buffer, offset: 0, index: 0)
        }
        host.computeBarrier()
        host.dispatch(chainB, threads: Self.chainN) { encoder in
            encoder.setBuffer(self.scratchBarrier.buffer, offset: 0, index: 0)
            encoder.setBuffer(self.chainOutBarrier.buffer, offset: 0, index: 1)
            encoder.setBytes(&n, length: MemoryLayout<UInt32>.stride, index: 2)
        }
    }

    private func encodeFill(on host: some Sketch) {
        host.dispatch(fill, threads: 256) { encoder in
            var v = Self.fillValue
            encoder.setBuffer(self.fillBuffer.buffer, offset: 0, index: 0)
            encoder.setBytes(&v, length: MemoryLayout<Float>.stride, index: 1)
        }
        // **投げた直後**に読む。完了していないのだから初期値のはず。
        fillReadImmediately = fillBuffer[0]
    }

    /// 頼まれたときだけ走る、落ちうる口。
    private func encodeTraps(on host: some Sketch) {
        guard let trap = Env.string("DUET_TRAP") else { return }
        switch trap {
        case "oob":
            // バッファ長を越えるスレッド数。カーネルに境界検査が無いので範囲外へ書く。
            guard let small = host.createBuffer(count: 64, type: Float.self) else { return }
            Log.line("TRAP oob: count=64 のバッファへ threads=96 を投げる")
            host.dispatch(stamp, threads: 96) { encoder in
                encoder.setBuffer(small.buffer, offset: 0, index: 0)
            }
        case "alloc":
            Log.line("TRAP alloc: stride×count が Int を溢れる大きさで createBuffer する")
            _ = host.createBuffer(count: Int.max / 8, type: Voice.self)
        case "index":
            Log.line("TRAP index: GPUBuffer の範囲外添字を読む")
            _ = fillBuffer[fillBuffer.count + 1]
        default:
            Log.line("TRAP \(trap): 知らない名前（oob / alloc / index）")
        }
    }

    // MARK: - 描画フェーズでの読み戻し（G7b）

    /// `loadPixels()` は GPU の完了を待つ。**待てば同じフレームで読めるのか**を見る。
    /// compute が書いた結果を CPU から安全に読む口は公開 API に無いので、
    /// これが実質の抜け道になるかどうかは知っておく価値がある。
    func probeLoadPixels(on host: some Sketch) {
        guard stage == 1, !loadPixelsProbed else { return }
        loadPixelsProbed = true
        host.loadPixels()
        fillReadAfterLoadPixels = fillBuffer[0]
    }

    // MARK: - 2 フレーム目: 読み戻して判定

    func settleChecks() {
        guard stage == 1 else { return }
        stage = 2

        settleParity()
        settleLong()
        settleTail()
        settleGrids()
        settleChain()
        settleFill()
    }

    private func settleParity() {
        var mine = Score.opening(count: Self.parityN)
        for i in 0..<Self.parityN { mine[i] = Score.advance(mine[i], 0, Score.dt) }
        let theirs = parityVoices.toArray()
        let d = compare(mine, theirs)
        // 同じ式・同じ順番なので、差は float の丸めぶん（数 ULP）に収まるはず。
        // 実測は位置 1.5e-08 / 速度 1.5e-08 程度なので、100 倍の余裕を見て 1e-06。
        let ok = d.maxAbs <= 1e-6 && d.maxVel <= 1e-6
        record("G1.parity", ok ? "PASS" : "FAIL",
               "1 小節・\(Self.parityN) 声部 / 位置の最大差 \(sci(d.maxAbs)) RMS \(sci(d.rms)) / "
               + "速度の最大差 \(sci(d.maxVel)) / 期待 どちらも ≤1.0e-06 / "
               + "種の一致 \(d.seedMatches)/\(Self.parityN)")
    }

    private func settleLong() {
        var mine = Score.opening(count: Self.parityN)
        for k in 0..<Self.longSteps {
            let t = Float(k) * Score.dt
            for i in 0..<Self.parityN { mine[i] = Score.advance(mine[i], t, Score.dt) }
        }
        let theirs = longVoices.toArray()
        let d = compare(mine, theirs)
        let step = longStatus[0]
        // 240 小節ぶんの丸めが積み上がる。発散していなければ 1e-2 に収まる想定。
        let ok = d.maxAbs <= 1e-2 && step == UInt32(Self.longSteps)
        record("G2.parityLong", ok ? "PASS" : "FAIL",
               "\(Self.longSteps) 小節連鎖（間に computeBarrier）/ GPU が数えた小節 \(step) "
               + "期待 \(Self.longSteps) / 位置の最大差 \(sci(d.maxAbs)) RMS \(sci(d.rms)) 期待 ≤1.0e-02 / "
               + "速度の最大差 \(sci(d.maxVel)) / "
               + "種の一致 \(d.seedMatches)/\(Self.parityN)（整数なので丸めでは説明できない）")
    }

    private struct Diff {
        var maxAbs: Float = 0
        var rms: Float = 0
        var maxVel: Float = 0
        var seedMatches = 0
    }

    private func compare(_ mine: [Voice], _ theirs: [Voice]) -> Diff {
        var d = Diff()
        var sum: Double = 0
        let n = min(mine.count, theirs.count)
        for i in 0..<n {
            let e = mine[i].pos - theirs[i].pos
            let m = (e.x * e.x + e.y * e.y).squareRoot()
            d.maxAbs = max(d.maxAbs, m)
            sum += Double(m) * Double(m)
            // 位置は 1 小節ぶんの dt が掛かって差が縮む。**速度の側が先に効く**ので、
            // 1 小節の検査は速度も見ないと式の取り違えを見逃す（0.995 → 0.994 を
            // 位置だけでは拾えなかった）。
            let ev = mine[i].vel - theirs[i].vel
            d.maxVel = max(d.maxVel, (ev.x * ev.x + ev.y * ev.y).squareRoot())
            if mine[i].seed == theirs[i].seed { d.seedMatches += 1 }
        }
        d.rms = n > 0 ? Float((sum / Double(n)).squareRoot()) : 0
        return d
    }

    private func settleTail() {
        var broken: [String] = []
        var guardsHit: [String] = []
        for c in Self.tailCounts {
            guard let buf = tailBuffers[c] else { continue }
            let a = buf.toArray()
            for i in 0..<c where a[i] != Float(i) + 1 {
                broken.append("count=\(c) の \(i) 番目")
                break
            }
            for i in c..<(c + 8) where a[i] != -1 {
                guardsHit.append("count=\(c) の \(i) 番目")
                break
            }
        }
        let ok = broken.isEmpty && guardsHit.isEmpty
        record("G3.tail", ok ? "PASS" : "FAIL",
               "threads=\(Self.tailCounts.map(String.init).joined(separator: "/")) "
               + "（threadExecutionWidth=\(single.threadExecutionWidth) の倍数・±1・素数）/ "
               + "未書き込み: \(broken.isEmpty ? "無し" : broken.joined(separator: ", ")) / "
               + "番兵の破壊: \(guardsHit.isEmpty ? "無し" : guardsHit.joined(separator: ", ")) / "
               + "dispatchThreads を使うので端数のスレッドは湧かない想定")
    }

    private func settleGrids() {
        let a = grid1D.toArray()
        let b = grid2D.toArray()
        var mismatch = -1
        for i in 0..<min(a.count, b.count) where a[i] != b[i] {
            mismatch = i
            break
        }
        record("G5.dispatch2D", mismatch < 0 ? "PASS" : "FAIL",
               "1D threads=\(Self.gridW * Self.gridH) と 2D width=\(Self.gridW) height=\(Self.gridH) が "
               + "同じ索引を書くか / "
               + (mismatch < 0
                  ? "全 \(a.count) 要素一致（gid.y*width+gid.x = 行優先）"
                  : "\(mismatch) 番目で食い違い 1D=\(fmt(a[mismatch], 0)) 2D=\(fmt(b[mismatch], 0))"))
    }

    private func settleChain() {
        let n = Self.chainN
        let expected = { (i: Int) in UInt32((i + n / 2) % n) }
        let nb = chainOutNoBarrier.toArray()
        let wb = chainOutBarrier.toArray()
        var nbBad = 0
        var wbBad = 0
        for i in 0..<n {
            if nb[i] != expected(i) { nbBad += 1 }
            if wb[i] != expected(i) { wbBad += 1 }
        }
        // バリアありは 0 でなければならない。バリア無しで 0 でも「競合が無い」証明にはならない。
        let ok = wbBad == 0
        record("G6.barrier", ok ? "PASS" : "FAIL",
               "\(n) 要素の連鎖（後段が前段の書いた別スレッドの位置を読む）/ "
               + "バリアあり 不一致 \(wbBad) 件 期待 0 / "
               + "バリア無し 不一致 \(nbBad) 件"
               + (nbBad == 0
                  ? "（競合は現れなかった。metaphor はエンコーダを既定の直列ディスパッチで作るので、"
                    + "同じエンコーダ内のディスパッチは順序が保証される = このバリアは要らない）"
                  : "（競合が現れた）"))
    }

    private func settleFill() {
        let later = fillBuffer[0]
        let stale = fillReadImmediately != Self.fillValue
        let arrived = later == Self.fillValue
        record("G7.readback", stale && arrived ? "PASS" : "FAIL",
               "dispatch 直後の読み \(fmt(fillReadImmediately, 0))（未完了なので初期値のはず）/ "
               + "次フレームの読み \(fmt(later, 0)) 期待 \(fmt(Self.fillValue, 0)) / "
               + "**GPU の完了を待つ公開 API が無い**ので、compute が書いた値をその場では読めない")
        let viaPixels = fillReadAfterLoadPixels == Self.fillValue
        record("G7b.loadPixelsSync", loadPixelsProbed ? (viaPixels ? "PASS" : "LOOK") : "N/A",
               loadPixelsProbed
               ? "同じフレームの draw() で loadPixels() を挟んでから読むと \(fmt(fillReadAfterLoadPixels, 0)) / "
                 + "期待 \(fmt(Self.fillValue, 0))（loadPixels は GPU 完了を待つので抜け道になるか）"
               : "draw() の口を通っていない")
    }

    // MARK: - probe への出し口

    func publish(to host: some Sketch) {
        for r in results {
            host.probe("check.\(r.id)", "\(r.verdict) \(r.detail)")
        }
        host.probe("check.pass", passes)
        host.probe("check.fail", failures)
    }
}
