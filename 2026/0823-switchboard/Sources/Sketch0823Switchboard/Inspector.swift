import Foundation
import MetaphorSyphon
import metaphor

// MARK: - 検査結果

/// 1 件の検査。判定は真偽値ではなく**実測値を含む文字列**で残す
/// （後から issue に貼るとき、数字がそのまま証拠になる）。
struct CheckResult {
    let id: String
    let passed: Bool
    /// 実測と期待を並べた 1 行。
    let detail: String

    var line: String { "\(passed ? "PASS" : "FAIL")\t\(id)\t\(detail)" }
}

/// 決定論的な検査群。**描画も時計も使わない**ので、実行のたびに同じ数値が出る。
///
/// metaphor#792（M1 / M4 / M6）で入れ替わった出力プラグインまわりの配線を、
/// `setup()` で 1 回だけ当てる。重い検査は置かない（ホットリロードのたびに走るため）。
@MainActor
enum Inspector {
    static func runAll() -> [CheckResult] {
        var out: [CheckResult] = []
        out += renderLoopChecks()
        out += requirementsChecks()
        out += providerRegistryChecks()
        out += contextChecks()
        out += syphonChecks()
        return out
    }

    // MARK: - R: RenderLoopMode.resolve

    /// `RenderLoopMode` を「timer(30)」のように読める形にする。
    private static func label(_ mode: RenderLoopMode) -> String {
        switch mode {
        case .displayLink: return "displayLink"
        case .timer(let fps): return "timer(\(fps))"
        }
    }

    private static func renderLoopChecks() -> [CheckResult] {
        let ext: PluginRequirements = [.externalRenderLoop]
        let none = PluginRequirements()

        // R1a: 既定の displayLink を要求したときの 4 セル。
        // doc: headless は常に timer / externalRenderLoop があれば timer へ切り替え。
        let a: [(String, RenderLoopMode, RenderLoopMode)] = [
            ("req=displayLink 要件なし window", RenderLoopMode.resolve(
                requested: .displayLink, fps: 60, requirements: none, isHeadless: false), .displayLink),
            ("req=displayLink 要件あり window", RenderLoopMode.resolve(
                requested: .displayLink, fps: 60, requirements: ext, isHeadless: false), .timer(fps: 60)),
            ("req=displayLink 要件なし headless", RenderLoopMode.resolve(
                requested: .displayLink, fps: 60, requirements: none, isHeadless: true), .timer(fps: 60)),
            ("req=displayLink 要件あり headless", RenderLoopMode.resolve(
                requested: .displayLink, fps: 60, requirements: ext, isHeadless: true), .timer(fps: 60)),
        ]
        let r1a = CheckResult(
            id: "R1a.resolve.displayLink",
            passed: a.allSatisfy { $0.1 == $0.2 },
            detail: a.map { "\($0.0)→\(label($0.1))[期待\(label($0.2))]" }.joined(separator: " / ")
        )

        // R1b: 明示の timer(30) は据え置き（doc:「明示的な timer(fps:) はそのまま」）。
        let b: [(String, RenderLoopMode, RenderLoopMode)] = [
            ("req=timer(30) 要件なし window", RenderLoopMode.resolve(
                requested: .timer(fps: 30), fps: 60, requirements: none, isHeadless: false), .timer(fps: 30)),
            ("req=timer(30) 要件あり window", RenderLoopMode.resolve(
                requested: .timer(fps: 30), fps: 60, requirements: ext, isHeadless: false), .timer(fps: 30)),
        ]
        let r1b = CheckResult(
            id: "R1b.resolve.explicitTimer",
            passed: b.allSatisfy { $0.1 == $0.2 },
            detail: b.map { "\($0.0)→\(label($0.1))[期待\(label($0.2))]" }.joined(separator: " / ")
        )

        // R1c: ヘッドレスのとき、明示した timer(30) が config.fps=60 に上書きされないか。
        // doc の 3 つの規則は「headless は常に timer」「externalRenderLoop なら timer へ」
        // 「明示の timer(fps:) はそのまま」で、3 つ目が 1 つ目に食われるかどうかが論点。
        // 実配線では fps に resolveFPS(config:env:) = config.fps が渡る（SketchRunner）。
        let c1 = RenderLoopMode.resolve(
            requested: .timer(fps: 30), fps: 60, requirements: none, isHeadless: true)
        let c2 = RenderLoopMode.resolve(
            requested: .timer(fps: 30), fps: 60, requirements: ext, isHeadless: true)
        let r1c = CheckResult(
            id: "R1c.resolve.headlessKeepsExplicitFPS",
            passed: c1 == .timer(fps: 30) && c2 == .timer(fps: 30),
            detail: "req=timer(30) fps=60 headless 要件なし→\(label(c1)) 要件あり→\(label(c2))"
                + " [期待 timer(30): 明示した 30 が config.fps=60 に置き換わっていないか]"
        )

        return [r1a, r1b, r1c]
    }

    // MARK: - R2: PluginRequirements

    private static func requirementsChecks() -> [CheckResult] {
        let empty = PluginRequirements()
        let ext: PluginRequirements = [.externalRenderLoop]
        var merged = empty
        merged.formUnion(ext)

        let ok = empty.isEmpty
            && !empty.contains(.externalRenderLoop)
            && ext.contains(.externalRenderLoop)
            && merged == ext
            && PluginRequirements.externalRenderLoop.rawValue == 1
        return [CheckResult(
            id: "R2.pluginRequirements.optionSet",
            passed: ok,
            detail: "empty.isEmpty=\(empty.isEmpty) empty.contains=\(empty.contains(.externalRenderLoop))"
                + " ext.contains=\(ext.contains(.externalRenderLoop))"
                + " empty∪ext==ext=\(merged == ext)"
                + " externalRenderLoop.rawValue=\(PluginRequirements.externalRenderLoop.rawValue)[期待 1]"
        )]
    }

    // MARK: - P: MetaphorOutputProviders

    private static func providerRegistryChecks() -> [CheckResult] {
        var out: [CheckResult] = []
        let baseline = MetaphorOutputProviders.registered.map(\.id)

        // P1: 3 本を続けて登録したら 3 本とも残り、登録順も保つ。
        // 旧 MetaphorOutputRegistry は単一ファクトリで、後から登録した 1 本しか残らなかった
        // （metaphor#792 M1 が直した点。この作品の主眼）。
        let trio = ["org.switchboard.check.a", "org.switchboard.check.b", "org.switchboard.check.c"]
        for id in trio { MetaphorOutputProviders.register(DummyProvider(id: id)) }
        let afterTrio = MetaphorOutputProviders.registered.map(\.id)
        let appended = Array(afterTrio.suffix(3))
        out.append(CheckResult(
            id: "P1.providers.coexist",
            passed: appended == trio && afterTrio.count == baseline.count + 3,
            detail: "3 本登録後の末尾3件=\(appended)[期待\(trio)]"
                + " 総数 \(baseline.count)→\(afterTrio.count)[期待 \(baseline.count + 3)]"
        ))

        // P2: 同じ id の再登録は「置換」。件数は増えず、位置も動かない。
        let replacedIndexBefore = MetaphorOutputProviders.registered.firstIndex { $0.id == trio[1] }
        MetaphorOutputProviders.register(
            DummyProvider(id: trio[1], requirements: [.externalRenderLoop]))
        let afterReplace = MetaphorOutputProviders.registered
        let replacedIndexAfter = afterReplace.firstIndex { $0.id == trio[1] }
        let replacedReq = afterReplace.first { $0.id == trio[1] }?.requirements ?? []
        out.append(CheckResult(
            id: "P2.providers.replaceByID",
            passed: afterReplace.count == afterTrio.count
                && replacedIndexBefore == replacedIndexAfter
                && replacedReq.contains(.externalRenderLoop),
            detail: "再登録後の総数=\(afterReplace.count)[期待\(afterTrio.count)]"
                + " 位置 \(replacedIndexBefore.map(String.init) ?? "nil")→\(replacedIndexAfter.map(String.init) ?? "nil")[期待 同じ]"
                + " 差し替わった要件 externalRenderLoop=\(replacedReq.contains(.externalRenderLoop))[期待 true]"
        ))

        // P3: unregister で消える。存在しない id は no-op。最後は baseline へ戻る。
        MetaphorOutputProviders.unregister(id: "org.switchboard.check.nonexistent")
        let afterNoop = MetaphorOutputProviders.registered.count
        for id in trio { MetaphorOutputProviders.unregister(id: id) }
        let restored = MetaphorOutputProviders.registered.map(\.id)
        out.append(CheckResult(
            id: "P3.providers.unregister",
            passed: afterNoop == afterReplace.count && restored == baseline,
            detail: "存在しない id の unregister 後の総数=\(afterNoop)[期待\(afterReplace.count)]"
                + " 3 本外した後=\(restored)[期待\(baseline)]"
        ))

        // P4: makeOutput が nil を返す provider は、どちらの scope でも出力を返さない。
        let silent = SilentProvider()
        let primaryOut = silent.makeOutput(context: primaryContext())
        let windowOut = silent.makeOutput(context: windowContext())
        out.append(CheckResult(
            id: "P4.provider.returnsNil",
            passed: primaryOut == nil && windowOut == nil,
            detail: "primary→\(primaryOut == nil ? "nil" : "plugin") window→\(windowOut == nil ? "nil" : "plugin")[期待 どちらも nil]"
        ))

        return out
    }

    // MARK: - C: MetaphorOutputContext

    private static func primaryContext() -> MetaphorOutputContext {
        MetaphorOutputContext(
            scope: .primary(SketchConfig(title: "switchboard-check")),
            environment: ["SWITCHBOARD_CHECK": "1"], isHeadless: false)
    }

    private static func windowContext() -> MetaphorOutputContext {
        MetaphorOutputContext(
            scope: .window(SketchWindowConfig(title: "switchboard-window-check")),
            environment: ["SWITCHBOARD_CHECK": "1"], isHeadless: true)
    }

    private static func contextChecks() -> [CheckResult] {
        let p = primaryContext()
        let w = windowContext()

        let c1ok = p.sketchConfig?.title == "switchboard-check"
            && p.windowConfig == nil
            && w.windowConfig?.title == "switchboard-window-check"
            && w.sketchConfig == nil
            && p.isHeadless == false && w.isHeadless == true
            && p.environment["SWITCHBOARD_CHECK"] == "1"
        let c1 = CheckResult(
            id: "C1.outputContext.scope",
            passed: c1ok,
            detail: "primary: sketchConfig.title=\(p.sketchConfig?.title ?? "nil") windowConfig=\(p.windowConfig == nil ? "nil" : "有")"
                + " / window: windowConfig.title=\(w.windowConfig?.title ?? "nil") sketchConfig=\(w.sketchConfig == nil ? "nil" : "有")"
                + " / isHeadless \(p.isHeadless)|\(w.isHeadless) env=\(p.environment["SWITCHBOARD_CHECK"] ?? "nil")"
        )

        // C2: requirements を書かない provider は protocol extension の既定値（空）を得る。
        let silent = SilentProvider()
        let c2 = CheckResult(
            id: "C2.provider.defaultRequirements",
            passed: silent.requirements.isEmpty,
            detail: "requirements を宣言しない provider の rawValue=\(silent.requirements.rawValue)[期待 0]"
        )
        return [c1, c2]
    }

    // MARK: - S: metaphor-syphon（別パッケージ）

    private static func syphonChecks() -> [CheckResult] {
        var out: [CheckResult] = []

        // S1: import しただけで provider がロード時に登録されている（C コンストラクタ）。
        // metaphor#792 M4 で Syphon は本体から外れたので、この登録が効いていなければ
        // .syphon(name:) も METAPHOR_SYPHON_NAME も黙って無効になる。
        let ids = MetaphorOutputProviders.registered.map(\.id)
        let syphonProvider = MetaphorOutputProviders.registered.first { $0.id == "org.metaphor.syphon" }
        out.append(CheckResult(
            id: "S1.syphon.autoRegistered",
            passed: syphonProvider != nil,
            detail: "registered=\(ids) に org.metaphor.syphon が\(syphonProvider == nil ? "無い" : "有る")"
                + " / MetaphorSyphon.version=\(MetaphorSyphon.version)"
        ))

        // S2: provider と factory の両方が externalRenderLoop を宣言している
        //（宣言はプラグイン生成より前に集計されるので、ここが空だと displayLink のままになる）。
        let providerReq = syphonProvider?.requirements ?? []
        let factoryReq = PluginFactory.syphon(name: "check").requirements
        out.append(CheckResult(
            id: "S2.syphon.externalRenderLoop",
            passed: providerReq.contains(.externalRenderLoop) && factoryReq.contains(.externalRenderLoop),
            detail: "provider.requirements.rawValue=\(providerReq.rawValue)"
                + " .syphon(name:).requirements.rawValue=\(factoryReq.rawValue)[期待 どちらも 1]"
        ))

        // S3: enable() を重ねても二重登録にならない（id で置換されるはず）。
        // enable() は登録を**復活させる**ので、対照実験（SWITCHBOARD_SOLO）で外した状態を
        // 壊さないよう、検査の前後で登録の有無を元に戻す。
        let syphonCount = { MetaphorOutputProviders.registered.filter { $0.id == "org.metaphor.syphon" }.count }
        let before = syphonCount()
        MetaphorSyphon.enable()
        MetaphorSyphon.enable()
        let after = syphonCount()
        if before == 0 { MetaphorOutputProviders.unregister(id: "org.metaphor.syphon") }
        out.append(CheckResult(
            id: "S3.syphon.enableIdempotent",
            passed: after == 1 && syphonCount() == before,
            detail: "enable() 前の org.metaphor.syphon の件数=\(before) 2 回呼んだ後=\(after)[期待 1]"
                + " 検査後に復元=\(syphonCount())[期待\(before)]"
        ))

        return out
    }

    // MARK: - A: 実配線へ渡る入力の再現

    /// 実際の起動でレンダーループを決める材料（`SketchConfig.plugins` の要件 ∪ provider の要件）を
    /// 公開 API だけで組み直し、この起動で timer へ切り替わるはずかを出す。
    ///
    /// `SketchRunner.aggregateRequirements` は internal なので、同じ規則を外から再現している。
    static func wiringSummary(config: SketchConfig) -> (requirements: PluginRequirements, resolved: RenderLoopMode) {
        var requirements = PluginRequirements()
        for factory in config.plugins { requirements.formUnion(factory.requirements) }
        let context = MetaphorOutputContext(
            scope: .primary(config),
            environment: ProcessInfo.processInfo.environment,
            isHeadless: false)
        for provider in MetaphorOutputProviders.registered where provider.makeOutput(context: context) != nil {
            requirements.formUnion(provider.requirements)
        }
        let resolved = RenderLoopMode.resolve(
            requested: config.renderLoopMode, fps: config.fps,
            requirements: requirements, isHeadless: false)
        return (requirements, resolved)
    }
}
