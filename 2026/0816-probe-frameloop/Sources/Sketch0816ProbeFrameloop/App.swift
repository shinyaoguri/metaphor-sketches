import Foundation
import metaphor

/// フレームループの縁で起きることだけを見る最小スケッチ。
///
/// 0816-escapement で見つかった 2 件を、作品の文脈（文字盤・機構・自己検査）を全部剥がして
/// 再現する。上流へ出す再現コードであり、metaphor が上がったあとの再検査盤でもある。
///
///   PROBE=pmouse    stdin から 1 回だけマウスを動かし、mouseX / pmouseX を毎フレーム出す
///   PROBE=resume    noLoop() → 0.8 秒 → loop() のあと、最初の deltaTime を出す
///
/// どちらも描画は背景 1 枚だけ。判定は標準出力のテキストで足りる。
@main
final class Sketch0816ProbeFrameloop: Sketch {
    private let mode = ProcessInfo.processInfo.environment["PROBE"] ?? "pmouse"

    var config: SketchConfig {
        var plugins: [PluginFactory] = []
        if mode == "pmouse" {
            // 窓ありモードでは自動登録されないので明示的に入れる
            plugins.append(PluginFactory { InputInjectionPlugin() })
        }
        return SketchConfig(width: 480, height: 270, title: "0816-probe-frameloop", plugins: plugins)
    }

    // MARK: - PROBE=resume

    private var resumeFrame: Int?
    private var pauseAt: Float = 0

    // MARK: - PROBE=pmouse

    private var moved = false

    func setup() {
        frameRate(60)
        print("mode=\(mode)")
        fflush(stdout)

        guard mode == "resume" else { return }

        // 止める → 何も描かずに 0.8 秒待つ → 再開する。
        // ループ制御は draw() の外から呼ぶ（redraw() は MTKView.draw() を同期的に呼ぶので
        // draw() の中から呼ぶと再入する）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.pauseAt = self.time
            print("noLoop at frame=\(self.frameCount) time=\(self.time)")
            fflush(stdout)
            self.noLoop()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            guard let self else { return }
            self.resumeFrame = self.frameCount
            print("loop  at frame=\(self.frameCount) time=\(self.time)（0.8 秒止めていた）")
            fflush(stdout)
            self.loop()
        }
    }

    func draw() {
        background(12, 14, 18)

        switch mode {
        case "resume":
            if let rf = resumeFrame, frameCount > rf {
                resumeFrame = nil
                print("再開後 最初の frame=\(frameCount) deltaTime=\(deltaTime)s time=\(time)s")
                print("  期待: 1 フレームぶん = 0.01667s / 止めていた実時間 = 0.8s")
                print("  time の進み: \(time - pauseAt)s")
                fflush(stdout)
            }
        default:
            // 注入は 1 回だけ。その前後 4 フレームを出す
            if moved || frameCount % 30 == 0 {
                print("frame=\(frameCount) mouse=(\(mouseX),\(mouseY)) pmouse=(\(pmouseX),\(pmouseY))")
                fflush(stdout)
            }
        }
    }

    func mouseMoved() {
        moved = true
        print("[event] mouseMoved 到着 frame=\(frameCount) mouse=(\(mouseX),\(mouseY)) pmouse=(\(pmouseX),\(pmouseY))")
        fflush(stdout)
    }
}
