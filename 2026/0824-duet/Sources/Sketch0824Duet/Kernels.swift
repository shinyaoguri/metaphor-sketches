import Foundation
import metaphor

/// GPU 側へ渡す拍子記号。**Swift 側と MSL 側で 1 バイトも違ってはいけない**。
///
/// `float2` は 8 バイト境界なので、`center` の手前が 16 バイトで割り切れるように
/// 並べてある。末尾の詰め物は 8 バイト境界へ切り上げるため。
struct Bars {
    var t: Float
    var dt: Float
    var count: UInt32
    var flags: UInt32
    var center: SIMD2<Float>
    var scale: Float
    var mirror: Float
    var size: Float
    var step: UInt32
    var pad0: Float = 0
    var pad1: Float = 0
}

/// MSL のソース。**`Score.swift` の式をここへ書き写している**のが二重奏の要で、
/// 書き写しの狂いも含めて測るのが `G1` / `G2`。
enum Kernels {
    /// 両方のカーネルが読む前置き。`Voice` と `CircleInstance` のレイアウトは
    /// Swift 側と対で保つ（`G10` が実測で突き合わせる）。
    ///
    /// **`CircleInstance` の実メモリ順は公開ドキュメントからは読めない。**
    /// `llms.txt` はメンバーをアルファベット順（color / diameter / position）で並べるが、
    /// 実体は position → diameter → 詰め物 → color。並び順を信じて書くと、
    /// コンパイルは通ったまま**右手が黙る**（絵が 1 つも出ない。警告も出ない）。
    /// なお `_pad` の明示は MSL では必須ではない（`float4` が 16B 境界を強いるので
    /// 同じ位置に自動で入る）。読む人のために置いてある。
    static let prelude = """
    #include <metal_stdlib>
    using namespace metal;

    struct Voice {
        float2 pos;
        float2 vel;
        uint   seed;
        uint   pad;
    };

    struct CircleInstance {
        float2 position;
        float  diameter;
        float  _pad;
        float4 color;
    };

    struct Bars {
        float  t;
        float  dt;
        uint   count;
        uint   flags;
        float2 center;
        float  scale;
        float  mirror;
        float  size;
        uint   step;
        float  pad0;
        float  pad1;
    };

    constant float kBound   = 1.55;
    constant float kDamping = 0.995;

    uint scoreHash(uint v) {
        uint h = v * 747796405u + 2891336453u;
        h = ((h >> ((h >> 28) + 4u)) ^ h) * 277803737u;
        return (h >> 22) ^ h;
    }

    float scoreUnit(uint h) {
        return float(h & 0x00FFFFFFu) / float(0x01000000);
    }

    float2 scoreField(float2 p, float t) {
        float r2 = p.x * p.x + p.y * p.y;
        float2 swirl  = float2(-p.y, p.x) * (1.2 / (0.35 + r2));
        float2 breath = float2(sin(p.y * 3.1 + t * 0.7), cos(p.x * 3.1 - t * 0.9)) * 0.55;
        float2 pull   = p * (-0.45 * r2);
        return swirl + breath + pull;
    }

    Voice scoreRespawn(uint seed) {
        uint h1 = scoreHash(seed);
        uint h2 = scoreHash(h1);
        float angle  = scoreUnit(h1) * 6.2831853;
        float radius = 0.12 + scoreUnit(h2) * 0.18;
        Voice v;
        v.pos  = float2(cos(angle) * radius, sin(angle) * radius);
        v.vel  = float2(0.0, 0.0);
        v.seed = h2;
        v.pad  = 0u;
        return v;
    }

    // 舞台座標 → 画面座標。y は画面が下向きなので反転し、mirror で左右を映す。
    CircleInstance scoreStamp(Voice v, constant Bars &bars) {
        CircleInstance c;
        c.position = bars.center + float2(bars.mirror * v.pos.x, -v.pos.y) * bars.scale;
        float speed = length(v.vel);
        c.diameter = bars.size * (0.65 + min(speed, 2.0) * 0.5);
        c._pad = 0.0;
        float heat = min(speed * 0.55, 1.0);
        c.color = float4(0.35 + heat * 0.6, 0.55 + heat * 0.35, 0.95 - heat * 0.35, 0.85);
        return c;
    }
    """

    /// 単一パス。速度と位置を 1 度に進め、描画用のインスタンスも書く。
    static let singlePass = prelude + """

    kernel void duetAdvance(device Voice *voices          [[buffer(0)]],
                            device CircleInstance *marks  [[buffer(1)]],
                            constant Bars &bars           [[buffer(2)]],
                            device uint *status           [[buffer(3)]],
                            uint gid                      [[thread_position_in_grid]])
    {
        if (gid == 0) { status[0] = bars.step; }
        if (gid >= bars.count) { return; }
        Voice v = voices[gid];
        float2 a = scoreField(v.pos, bars.t);
        v.vel = (v.vel + a * bars.dt) * kDamping;
        v.pos = v.pos + v.vel * bars.dt;
        if (v.pos.x * v.pos.x + v.pos.y * v.pos.y > kBound * kBound) {
            v = scoreRespawn(v.seed);
        }
        voices[gid] = v;
        marks[gid]  = scoreStamp(v, bars);
    }
    """

    /// 2 パス。速度だけ進める前半と、位置を進めて描く後半。
    /// 間に `computeBarrier()` を入れるかどうかが第 III 楽章の主題。
    static let twoPass = prelude + """

    kernel void duetAccelerate(device Voice *voices [[buffer(0)]],
                               constant Bars &bars  [[buffer(1)]],
                               uint gid             [[thread_position_in_grid]])
    {
        if (gid >= bars.count) { return; }
        Voice v = voices[gid];
        float2 a = scoreField(v.pos, bars.t);
        v.vel = (v.vel + a * bars.dt) * kDamping;
        voices[gid] = v;
    }

    kernel void duetTranslate(device Voice *voices         [[buffer(0)]],
                              device CircleInstance *marks [[buffer(1)]],
                              constant Bars &bars          [[buffer(2)]],
                              device uint *status          [[buffer(3)]],
                              uint gid                     [[thread_position_in_grid]])
    {
        if (gid == 0) { status[0] = bars.step; }
        if (gid >= bars.count) { return; }
        Voice v = voices[gid];
        v.pos = v.pos + v.vel * bars.dt;
        if (v.pos.x * v.pos.x + v.pos.y * v.pos.y > kBound * kBound) {
            v = scoreRespawn(v.seed);
        }
        voices[gid] = v;
        marks[gid]  = scoreStamp(v, bars);
    }
    """

    // MARK: - 計器用

    /// 検査だけが使う小さなカーネル群。作品の絵には出ない。
    static let probes = """
    #include <metal_stdlib>
    using namespace metal;

    // 番兵を上書きしたかで「そのスレッドが走ったか」を見る（G3 / G4）。
    kernel void probeStamp(device float *out [[buffer(0)]],
                           uint gid          [[thread_position_in_grid]])
    {
        out[gid] = float(gid) + 1.0;
    }

    // 2D グリッドの索引が行優先かどうかを見る（G5）。
    kernel void probeStamp2D(device float *out   [[buffer(0)]],
                             constant uint &w    [[buffer(1)]],
                             uint2 gid           [[thread_position_in_grid]])
    {
        out[gid.y * w + gid.x] = float(gid.y * w + gid.x) + 1.0;
    }

    // 連鎖の前半。自分の位置に自分の番号を置くだけ。
    kernel void probeChainA(device uint *scratch [[buffer(0)]],
                            uint gid             [[thread_position_in_grid]])
    {
        scratch[gid] = gid;
    }

    // 連鎖の後半。**他のスレッドが書いた場所**を読む（バリアが要る形）。
    kernel void probeChainB(device const uint *scratch [[buffer(0)]],
                            device uint *out           [[buffer(1)]],
                            constant uint &n           [[buffer(2)]],
                            uint gid                   [[thread_position_in_grid]])
    {
        out[gid] = scratch[(gid + n / 2) % n];
    }

    // 読み戻しの時点を見るための、ただの書き込み（G7）。
    kernel void probeFill(device float *out    [[buffer(0)]],
                          constant float &v    [[buffer(1)]],
                          uint gid             [[thread_position_in_grid]])
    {
        out[gid] = v;
    }
    """

    /// わざと壊した MSL。`createComputeKernel` が throw するか、
    /// メッセージが原因を指すかを見る（G12）。
    static let broken = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void probeBroken(device float *out [[buffer(0)]],
                            uint gid          [[thread_position_in_grid]])
    {
        out[gid] = undefined_symbol_on_purpose(gid);
    }
    """
}
