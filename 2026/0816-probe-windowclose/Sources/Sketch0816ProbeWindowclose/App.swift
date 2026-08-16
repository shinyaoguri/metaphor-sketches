import Foundation
import metaphor

/// # 0816-probe-windowclose
///
/// [0816-triptych](../0816-triptych/) から切り出した最小再現。
/// **セカンダリウィンドウを閉じるとプロセスが落ちる**のが metaphor 側の問題か、
/// 作品側の持ち方の問題かを切り分けるためだけのスケッチ。
///
/// やることはこれだけ:
///
/// 1. `setup()` で `createWindow` を 1 枚
/// 2. 120 フレーム目に `close()`
/// 3. その後 300 フレームまで何もせずに回し続ける
///
/// 描画も入力も物理も持たない。**これで落ちるなら作品の文脈は無関係**。
///
/// ```bash
/// swift run                      # 既定: close() で閉じる
/// PROBE_MODE=closeall swift run  # closeAllWindows() で閉じる
/// PROBE_MODE=keep swift run      # 閉じない（対照。落ちなければ「閉じること」が原因）
/// PROBE_MODE=fixed swift run     # 閉じる前に isReleasedWhenClosed = false を立てる（対照）
/// ```
///
/// 判定は終了コードで読む。`exit=0` なら 300 フレーム完走、`exit=139`（SIGSEGV）なら落ちた。
@main
final class Sketch0816ProbeWindowclose: Sketch {
    var config: SketchConfig {
        SketchConfig(width: 480, height: 320, title: "probe-windowclose")
    }

    private var secondary: SketchWindow?
    private let mode = ProcessInfo.processInfo.environment["PROBE_MODE"] ?? "close"

    private let closeAtFrame = 120
    private let quitAtFrame = 300

    func setup() {
        frameRate(60)
        say("mode=\(mode) / metaphor \(Metaphor.version)")

        // setup() の中で作ってすぐ閉じる系。draw() が 1 度も回らないうちに開閉が終わる。
        switch mode {
        case "burst":
            // 4 枚まとめて開いて、同じ runloop ターンでまとめて閉じる
            for i in 0..<4 {
                _ = createWindow(SketchWindowConfig(width: 240, height: 180,
                                                    title: "probe-burst-\(i)", windowScale: 0.5))
            }
            say("4 枚開いた → closeAllWindows()")
            closeAllWindows()
            return
        case "cycle":
            // 1 枚ずつ「開いて閉じる」を 3 回。0816-triptych の L5 検査と同じ形
            for i in 0..<3 {
                let w = createWindow(SketchWindowConfig(width: 240, height: 180,
                                                        title: "probe-cycle-\(i)", windowScale: 0.5))
                w?.close()
            }
            say("開いて閉じるを 3 回繰り返した")
            return
        case "openclose":
            // 1 枚だけ、開いて同じターンで閉じる（cycle の最小形）
            let w = createWindow(SketchWindowConfig(width: 240, height: 180,
                                                    title: "probe-openclose", windowScale: 0.5))
            w?.close()
            say("開いて同じターンで閉じた")
            return
        case "openclose-fixed":
            // 同じ形だが、閉じる前に isReleasedWhenClosed = false を立てる。
            // これで落ちなくなるなら、原因は「ARC 下で NSWindow を既定のまま閉じたこと」。
            let w = createWindow(SketchWindowConfig(width: 240, height: 180,
                                                    title: "probe-openclose", windowScale: 0.5))
            NSApplicationWindows.find(titled: "probe-openclose")?.isReleasedWhenClosed = false
            w?.close()
            say("isReleasedWhenClosed=false を立ててから同じターンで閉じた")
            return
        case "openclose-nodefer":
            // 対照: 閉じずにウィンドウを 1 枚開いたまま帰る（開くこと自体は無害かの確認）
            _ = createWindow(SketchWindowConfig(width: 240, height: 180,
                                                title: "probe-openclose", windowScale: 0.5))
            say("開いたまま帰った")
            return
        default:
            break
        }

        secondary = createWindow(
            SketchWindowConfig(width: 320, height: 240, title: "probe-secondary")
        )
        say("createWindow → \(secondary == nil ? "nil" : "非nil (isOpen=\(secondary!.isOpen))")")

        // 閉じたウィンドウを触らないよう、描画クロージャは置かない。
        // （置いても置かなくても再現するが、疑いを 1 つ減らしておく）
    }

    func draw() {
        background(12, 14, 18)
        fill(220)
        textSize(14)
        text("frame \(frameCount) / mode \(mode)", 20, 40)

        // 閉じてから開き直す系。0816-triptych の「祭壇画の翼が開閉する」に相当する。
        if mode == "reopen" || mode == "reopen-fixed" {
            if frameCount == closeAtFrame {
                if mode == "reopen-fixed" {
                    // 唯一の違い。metaphor が SketchWindow.setupWindow() でやっていない
                    // 「ARC 下で必要な 1 行」を、閉じる直前に外から立てる。
                    NSApplicationWindows.find(titled: "probe-secondary")?
                        .isReleasedWhenClosed = false
                }
                say("frame \(frameCount): close()")
                secondary?.close()
                secondary = nil
            }
            if frameCount == closeAtFrame + 60 {
                say("frame \(frameCount): 開き直す")
                secondary = createWindow(
                    SketchWindowConfig(width: 320, height: 240, title: "probe-secondary")
                )
                say("再 createWindow → \(secondary == nil ? "nil" : "非nil")")
            }
            if frameCount == quitAtFrame + 600 {
                say("frame \(frameCount): 完走した（落ちなかった）")
                exit(0)
            }
            return
        }

        // 閉じたあと長く回す（遅れて落ちないかの確認）。
        if mode == "closelong" {
            if frameCount == closeAtFrame {
                say("frame \(frameCount): close()")
                secondary?.close()
                secondary = nil
            }
            if frameCount == 1200 {
                say("frame \(frameCount): 完走した（落ちなかった）")
                exit(0)
            }
            return
        }

        if frameCount == closeAtFrame {
            switch mode {
            case "keep":
                say("frame \(frameCount): 閉じない（対照）")
            case "closeall":
                say("frame \(frameCount): closeAllWindows()")
                closeAllWindows()
            case "fixed":
                // AppKit の NSWindow は既定で isReleasedWhenClosed = true。ARC 下では
                // close() でウィンドウが解放され、Swift 側の参照が二重解放になる。
                // metaphor は SketchWindow.setupWindow() でこれを false にしていない。
                // ここだけ外から false に倒して、同じ close() が落ちなくなるかを見る。
                if let w = NSApplicationWindows.find(titled: "probe-secondary") {
                    w.isReleasedWhenClosed = false
                    say("frame \(frameCount): isReleasedWhenClosed=false を立ててから close()")
                } else {
                    say("frame \(frameCount): NSWindow が見つからない")
                }
                secondary?.close()
            default:
                say("frame \(frameCount): close()")
                secondary?.close()
            }
            say("close 直後 isOpen=\(secondary?.isOpen.description ?? "n/a")")
        }

        if frameCount == quitAtFrame {
            say("frame \(frameCount): 完走した（落ちなかった）")
            exit(0)
        }
    }

    private func say(_ s: String) {
        print("[probe] \(s)")
        fflush(stdout)
    }
}

import AppKit

/// metaphor はセカンダリウィンドウの `NSWindow` を公開していないので、タイトルで引く。
enum NSApplicationWindows {
    @MainActor
    static func find(titled title: String) -> NSWindow? {
        NSApplication.shared.windows.first { $0.title == title }
    }
}
