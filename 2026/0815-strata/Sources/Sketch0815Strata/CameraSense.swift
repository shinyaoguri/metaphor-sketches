import AVFoundation
import Foundation
import metaphor

/// カメラ由来の駆動値。地形の隆起と色温度へ流す。
struct SenseDrive {
    /// 動き量から作る 0..1 のエネルギー。隆起へ効く。
    var energy: Float = 0
    /// -1（寒色）..1（暖色）。明るさの偏りから作る。
    var tint: Float = 0
    /// 直近の平均輝度 0..1。
    var luminance: Float = 0
    /// 直近の動き量 0..1（生値）。
    var motion: Float = 0
    /// カメラが使えているか。TCC 不許可・デバイス無しでは false のまま。
    var available: Bool = false
}

/// カメラを「入力センサ」として使う。映像は出さず、粗い統計だけ取り出す。
///
/// コスト管理:
/// - キャプチャ解像度を落とす（既定 320×180）
/// - 毎フレームではなく `sampleInterval` フレームごとにしか読まない
/// - `pixels` 配列は 1 ピクセルずつ `get()` せず生バイトを stride 走査する
///
/// `loadPixels()` は GPU → CPU の読み戻しで、metaphor#267（pixels 経路の常駐増）が
/// 既知。ここは「実運用で許容できる頻度か」を 30 分ソークで確かめる対象でもある。
@MainActor
final class CameraSense {
    private let capture: CaptureDevice?
    private let sampleInterval: Int
    /// ピクセル走査の間引き（縦横ともこの間隔で 1 点だけ読む）。
    private let pixelStride: Int

    /// 前回サンプルの輝度グリッド。動き量は今回との差分で作る。
    private var previous: [Float] = []
    private var smoothedEnergy: Float = 0

    private(set) var drive = SenseDrive()
    /// 読み取りに成功した回数。無人稼働でカメラが死んでいないかの指標。
    private(set) var sampleCount: Int = 0
    /// カメラが落ちた（切断された）回数。
    private(set) var dropoutCount: Int = 0

    init(capture: CaptureDevice?, sampleInterval: Int = 6, pixelStride: Int = 8) {
        self.capture = capture
        self.sampleInterval = max(1, sampleInterval)
        self.pixelStride = max(1, pixelStride)

        if let capture, capture.isAvailable {
            drive.available = true
            capture.onDisconnect = { [weak self] in
                guard let self else { return }
                self.drive.available = false
                self.dropoutCount += 1
            }
        }
    }

    /// カメラの説明。HUD と README 用。
    var deviceLabel: String {
        guard let capture, capture.isAvailable else { return "unavailable" }
        return capture.deviceInfo?.name ?? "camera"
    }

    /// TCC の許可状態。
    ///
    /// `CaptureDevice.isAvailable` は「拒否されていない」までしか見ておらず、
    /// `.notDetermined`（＝ダイアログにまだ答えていない）でも true になる。
    /// 常設運用では「カメラが繋がっているのに絵が動かない」の原因がここに
    /// 集中するので、作品側で状態を持って HUD と Probe に出す。
    var authorizationLabel: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// 未応答なら明示的に許可を求める。
    ///
    /// ライブラリはセッション開始時のシステム任せで、`swift run` で起動した
    /// 実行ファイルだと出ないことがある。無人運用の前に一度だけ叩く。
    func requestAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            print("[strata] camera access granted=\(granted)")
        }
    }

    /// 毎フレーム呼ぶ。実際の読み取りは `sampleInterval` フレームに 1 回。
    func update(frameCount: Int, decay: Float) {
        // エネルギーは動きが止まったら自然に落ちる（無人時に固まらないように）
        smoothedEnergy *= decay
        defer { drive.energy = min(smoothedEnergy, 1) }

        guard drive.available, frameCount % sampleInterval == 0 else { return }
        guard let capture else { return }

        capture.read()
        guard let image = capture.toImage() else { return }
        image.loadPixels()
        let pixels = image.pixels
        guard !pixels.isEmpty else { return }

        let w = Int(image.width)
        let h = Int(image.height)
        guard w > 0, h > 0, pixels.count >= w * h * 4 else { return }

        var grid: [Float] = []
        grid.reserveCapacity((w / pixelStride + 1) * (h / pixelStride + 1))
        var sum: Float = 0
        var warmSum: Float = 0

        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let o = (y * w + x) * 4
                // BGRA/RGBA いずれでも「赤み - 青み」の符号だけ使うため、
                // 並びが逆でも tint の向きが反転するだけで破綻しない。
                let c0 = Float(pixels[o]) / 255
                let c1 = Float(pixels[o + 1]) / 255
                let c2 = Float(pixels[o + 2]) / 255
                let lum = 0.299 * c0 + 0.587 * c1 + 0.114 * c2
                grid.append(lum)
                sum += lum
                warmSum += c2 - c0
                x += pixelStride
            }
            y += pixelStride
        }

        guard !grid.isEmpty else { return }
        sampleCount += 1

        let mean = sum / Float(grid.count)
        drive.luminance = mean
        drive.tint = min(max(warmSum / Float(grid.count) * 2, -1), 1)

        if previous.count == grid.count {
            var diff: Float = 0
            for i in 0..<grid.count {
                diff += abs(grid[i] - previous[i])
            }
            // 平均絶対差はごく小さい値になるので、実用域（0..1）へ持ち上げる
            let motion = min(diff / Float(grid.count) * 12, 1)
            drive.motion = motion
            smoothedEnergy = max(smoothedEnergy, motion)
        }
        previous = grid
    }
}
