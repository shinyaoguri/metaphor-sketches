import Foundation
import metaphor

/// OSC を「外部からの演出指示」として受ける。
///
/// 対応アドレス:
/// - `/scene <int|string>` — シーンを切り替える（index か名前）
/// - `/scene/next` — 次のシーンへ
/// - `/param/<name> <float>` — Parameter Store のパラメータを書く
/// - `/regenerate [<int>]` — 地形の静的成分を作り直す（省略時は時刻由来のシード）
/// - `/ping` — 生存確認。受信数だけ増える
///
/// `poll()` を `draw()` の中で呼ぶまでメッセージは配送されない（受信自体は
/// バックグラウンド）。ハンドラはメインスレッドで走る。
@MainActor
final class OSCControl {
    /// 受け取った指示。draw() 側が読んで消費する。
    struct Commands {
        var sceneIndex: Int?
        var sceneName: String?
        var advance = false
        var regenerateSeed: UInt64?
        var paramWrites: [(name: String, value: Float)] = []
    }

    private let receiver: OSCReceiver?
    private(set) var isRunning = false
    private(set) var messageCount = 0
    private(set) var lastAddress = "-"
    private(set) var startupError: String?

    let port: UInt16

    init(port: UInt16) {
        self.port = port
        let r = OSCReceiver(port: port)
        do {
            try r.start()
            receiver = r
            isRunning = true
        } catch {
            // ポート衝突などで受けられなくても作品は自律的に動き続ける
            receiver = nil
            startupError = String(describing: error)
        }
    }

    /// draw() の先頭で呼ぶ。届いていた指示をまとめて返す。
    func poll() -> Commands {
        var commands = Commands()
        guard let receiver else { return commands }

        for message in receiver.poll() {
            messageCount += 1
            lastAddress = message.address

            switch message.address {
            case "/scene":
                switch message.values.first {
                case .int(let i):
                    commands.sceneIndex = Int(i)
                case .float(let f):
                    commands.sceneIndex = Int(f)
                case .string(let s):
                    commands.sceneName = s
                default:
                    break
                }
            case "/scene/next":
                commands.advance = true
            case "/regenerate":
                if case .int(let i)? = message.values.first {
                    commands.regenerateSeed = UInt64(bitPattern: Int64(i))
                } else {
                    commands.regenerateSeed = UInt64(Date().timeIntervalSince1970)
                }
            case "/ping":
                break
            default:
                if message.address.hasPrefix("/param/") {
                    let name = String(message.address.dropFirst("/param/".count))
                    switch message.values.first {
                    case .float(let f):
                        commands.paramWrites.append((name, f))
                    case .int(let i):
                        commands.paramWrites.append((name, Float(i)))
                    default:
                        break
                    }
                }
            }
        }
        return commands
    }
}
