#!/usr/bin/env bash
# **3 本の Syphon を外から受け取って、絵を見ずに数値で判定する。**
#
#   tools/syphon-read.sh [プレフィックス]     既定 "darkroom"
#
# この作品の一次証拠はここ。受け手（MadMapper 等）を開かなくても、
#
#   - **取り違えていないか** — 槽ごとに平均輝度・明部率・エッジ率が期待どおり違うか
#   - **連動しているか**     — 露光時計の針の角度が 3 本で揃っているか
#
# を機械で言える。作品側の内蔵検査（tools/probe.sh）では現像後の絵が読めない
# （`loadPixels()` はポストエフェクト適用前のキャンバスを返す = 判定 D5）ので、
# **現像後を読めるのは Syphon の受け手だけ**。
#
# Syphon.framework は metaphor-syphon の binary artifact（swift build で降りてくる）を直接引く。
set -euo pipefail

cd "$(dirname "$0")/.."
PREFIX="${1:-darkroom}"

FW=$(find .build/artifacts -type d -name "Syphon.framework" -path "*macos*" | head -1)
[ -n "$FW" ] || { echo "Syphon.framework が無い。先に swift build してください" >&2; exit 1; }
FWDIR=$(dirname "$FW")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat >"$WORK/read.m" <<'OBJC'
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Syphon/Syphon.h>
#import <math.h>

// 原版の寸法と目印の位置（作品側の Plate と揃える）。
static const int   kPlateW = 1920;
static const int   kPlateH = 1080;
static const float kWedgeH = 96.0f;      // ステップウェッジ帯の高さ
static const int   kWedgeSteps = 11;     // 段数
// 針は中心から先端まで伸びる 1 本の帯なので、**半径方向に積分**してから角度を選ぶ。
// 円周 1 本だけで測ると、輪郭槽（sobel）では針が 2 本の細い縁になり、
// 散らばった粒のエッジに負ける（初回の実測で B だけ 126.5° ずれた。metaphor ではなく
// こちらの測り方の問題だった）。
static const float kHandRMin = 80.0f;    // 積分の内側（中心の丸を避ける）
static const float kHandRMax = 340.0f;   // 積分の外側（文字盤の目盛りより内側）
static const int   kHandRSteps = 34;
static const int   kAngleBins = 720;     // 円周の分解能（0.5 度）
static const int   kSmoothBins = 20;     // 移動平均の幅（≈10 度。針の角幅ぶん）

typedef struct {
    int   ok;
    int   w, h;
    float luma;        // 全画素の平均輝度 0…255
    float brightPct;   // luma > 128 の画素の割合 %
    float edge;        // 水平方向の隣接差の平均 0…255（輪郭の量）
    float wedgeTop;    // 上端の帯の平均輝度
    float wedgeBottom; // 下端の帯の平均輝度
    int   wedgeMonoTop;    // 上端の帯が左から右へ単調増加か
    int   wedgeMonoBottom; // 下端の帯が左から右へ単調増加か
    float angle;       // 針の角度（度、テクスチャ座標系）
} Stats;

static inline float lumaAt(const uint8_t *px, size_t bpr, int x, int y, int bgra) {
    const uint8_t *p = px + (size_t)y * bpr + (size_t)x * 4;
    float r = bgra ? p[2] : p[0];
    float g = p[1];
    float b = bgra ? p[0] : p[2];
    return (r + g + b) / 3.0f;
}

static Stats analyze(const uint8_t *px, size_t bpr, int w, int h, int bgra) {
    Stats s;
    memset(&s, 0, sizeof(s));
    s.ok = 1; s.w = w; s.h = h;

    // 平均輝度・明部率・エッジ量。4 画素おきで足りる（1920×1080 の全走査は要らない）。
    double sum = 0, edge = 0; long n = 0, bright = 0, en = 0;
    for (int y = 0; y < h; y += 4) {
        for (int x = 0; x < w; x += 4) {
            float l = lumaAt(px, bpr, x, y, bgra);
            sum += l; n++;
            if (l > 128.0f) bright++;
            if (x + 4 < w) { edge += fabsf(lumaAt(px, bpr, x + 4, y, bgra) - l); en++; }
        }
    }
    s.luma = n ? (float)(sum / n) : 0;
    s.brightPct = n ? (float)bright * 100.0f / (float)n : 0;
    s.edge = en ? (float)(edge / en) : 0;

    // ステップウェッジ。上端と下端の両方を測る（Syphon 経由で上下が返っているかもここで分かる）。
    float scaleX = (float)w / (float)kPlateW;
    float scaleY = (float)h / (float)kPlateH;
    int bandH = (int)(kWedgeH * scaleY);
    int stepW = w / kWedgeSteps;
    float top[kWedgeSteps], bottom[kWedgeSteps];
    for (int i = 0; i < kWedgeSteps; i++) {
        int x = i * stepW + stepW / 2;
        int yTop = bandH / 2;
        int yBottom = h - 1 - bandH / 2;
        top[i] = lumaAt(px, bpr, x, yTop, bgra);
        bottom[i] = lumaAt(px, bpr, x, yBottom, bgra);
    }
    float st = 0, sb = 0; int monoT = 1, monoB = 1;
    for (int i = 0; i < kWedgeSteps; i++) {
        st += top[i]; sb += bottom[i];
        // 単調増加の判定は少し緩める（現像を通ると段の高さは変わる。順序だけ見る）。
        if (i > 0 && top[i] + 6 < top[i - 1]) monoT = 0;
        if (i > 0 && bottom[i] + 6 < bottom[i - 1]) monoB = 0;
    }
    // 段差がまるで無いものを「階段」と呼ばない（輪郭槽は面を落とすので上下とも平ら）。
    if (top[kWedgeSteps - 1] - top[0] < 40) monoT = 0;
    if (bottom[kWedgeSteps - 1] - bottom[0] < 40) monoB = 0;
    s.wedgeTop = st / kWedgeSteps;
    s.wedgeBottom = sb / kWedgeSteps;
    s.wedgeMonoTop = monoT;
    s.wedgeMonoBottom = monoB;

    // 露光時計の針。中心のまわりの円周を舐めて、**幅 10 度の移動平均が最大**の向きを針とする。
    // 針は連続して明るいので平均で勝ち、粒（点在する明点）は平均で薄まる。
    // sobel を通ると針は 2 本の縁になるが、縁は針の中心に対称なのでこの平均は向きを保つ。
    float cx = w * 0.5f;
    float cy = (h - bandH) * 0.5f;   // 帯を除いた領域の中央（作品側と同じ取り方）
    float rs = (scaleX + scaleY) * 0.5f;
    float ring[kAngleBins];
    for (int i = 0; i < kAngleBins; i++) {
        float a = (float)i / kAngleBins * 2.0f * (float)M_PI;
        float ca = cosf(a), sa = sinf(a);
        float acc = 0; int m = 0;
        for (int k = 0; k < kHandRSteps; k++) {
            float r = (kHandRMin + (kHandRMax - kHandRMin) * k / (kHandRSteps - 1)) * rs;
            int x = (int)(cx + ca * r);
            int y = (int)(cy + sa * r);
            if (x >= 0 && x < w && y >= 0 && y < h) { acc += lumaAt(px, bpr, x, y, bgra); m++; }
        }
        ring[i] = m ? acc / m : 0;
    }
    float best = -1; int bestI = 0;
    for (int i = 0; i < kAngleBins; i++) {
        float acc = 0;
        for (int k = 0; k < kSmoothBins; k++) acc += ring[(i + k) % kAngleBins];
        acc /= kSmoothBins;
        if (acc > best) { best = acc; bestI = i; }
    }
    // 窓の中心を指すよう半幅ぶん戻す。
    int center = (bestI + kSmoothBins / 2) % kAngleBins;
    s.angle = (float)center / kAngleBins * 360.0f;
    return s;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *prefix = (argc > 1) ? [NSString stringWithUTF8String:argv[1]] : @"darkroom";

        // ディレクトリは非同期に埋まるので、少し回してから読む。
        [SyphonServerDirectory sharedDirectory];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];

        NSMutableArray *targets = [NSMutableArray array];
        for (NSDictionary *d in [[SyphonServerDirectory sharedDirectory] servers]) {
            NSString *name = [d objectForKey:SyphonServerDescriptionNameKey] ?: @"";
            if ([name rangeOfString:prefix].location != NSNotFound) [targets addObject:d];
        }
        if (targets.count == 0) {
            printf("「%s」を含む Syphon サーバーが 1 本も見つからない\n", prefix.UTF8String);
            printf("（作品を起動してから実行する: tools/probe.sh start）\n");
            return 2;
        }
        [targets sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [[a objectForKey:SyphonServerDescriptionNameKey]
                    compare:[b objectForKey:SyphonServerDescriptionNameKey]];
        }];

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];

        NSMutableArray *clients = [NSMutableArray array];
        for (NSDictionary *d in targets) {
            SyphonMetalClient *c = [[SyphonMetalClient alloc]
                initWithServerDescription:d device:device options:nil newFrameHandler:nil];
            [clients addObject:c];
        }

        // 全員が最初のフレームを持つまで待つ（最大 5 秒）。**3 本を同じ瞬間に読むため**、
        // ここで揃えてから一気に取りにいく。
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
        BOOL ready = NO;
        while (!ready && [deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            ready = YES;
            for (SyphonMetalClient *c in clients) { if (!c.hasNewFrame) { ready = NO; } }
        }

        Stats stats[16];
        NSMutableArray *names = [NSMutableArray array];
        int count = 0;
        for (NSUInteger i = 0; i < clients.count && count < 16; i++) {
            SyphonMetalClient *c = clients[i];
            NSString *name = [targets[i] objectForKey:SyphonServerDescriptionNameKey] ?: @"(nil)";
            [names addObject:name];

            id<MTLTexture> tex = [c newFrameImage];
            if (!tex) { Stats s; memset(&s, 0, sizeof(s)); stats[count++] = s; continue; }

            NSUInteger w = tex.width, h = tex.height;
            NSUInteger bpr = w * 4;
            id<MTLBuffer> buf = [device newBufferWithLength:bpr * h
                                                   options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(w, h, 1)
                         toBuffer:buf destinationOffset:0
            destinationBytesPerRow:bpr destinationBytesPerImage:bpr * h];
            [blit endEncoding];
            [cb commit];
            [cb waitUntilCompleted];

            int bgra = (tex.pixelFormat == MTLPixelFormatBGRA8Unorm ||
                        tex.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB);
            stats[count++] = analyze((const uint8_t *)buf.contents, bpr, (int)w, (int)h, bgra);
        }

        printf("Syphon サーバー %d 本（プレフィックス「%s」）\n\n", count, prefix.UTF8String);
        printf("%-18s %7s %7s %8s %7s %8s %9s %8s\n",
               "server", "size", "luma", "bright%", "edge", "wedge↑", "wedge↓", "angle°");
        for (int i = 0; i < count; i++) {
            Stats s = stats[i];
            if (!s.ok) { printf("%-18s  フレームを受け取れなかった\n",
                                [names[i] UTF8String]); continue; }
            char size[32];
            snprintf(size, sizeof(size), "%dx%d", s.w, s.h);
            printf("%-18s %7s %7.1f %8.1f %7.2f %8.1f%s %8.1f%s %8.1f\n",
                   [names[i] UTF8String], size, s.luma, s.brightPct, s.edge,
                   s.wedgeTop, s.wedgeMonoTop ? "*" : " ",
                   s.wedgeBottom, s.wedgeMonoBottom ? "*" : " ",
                   s.angle);
        }
        printf("\n* = その帯が左から右へ濃度の階段になっている（ステップウェッジはこちら側）\n");
        printf("  作品はウェッジを**下辺**に敷いている。受け取ったテクスチャで階段が上端に出るなら、\n");
        printf("  Syphon 経由で上下が返っている（metaphor-syphon は flipped: true で publish する）。\n");

        // --- 判定 1: 連動（針の角度が揃っているか）
        if (count >= 2) {
            float minA = 1e9f, maxA = -1e9f;
            for (int i = 0; i < count; i++) {
                if (!stats[i].ok) continue;
                if (stats[i].angle < minA) minA = stats[i].angle;
                if (stats[i].angle > maxA) maxA = stats[i].angle;
            }
            float spread = maxA - minA;
            if (spread > 180.0f) spread = 360.0f - spread;  // 0°/360° をまたぐ場合
            // 針は 8 秒で 1 周 = 45°/s。10° は 0.22 秒ぶんのずれにあたる。
            printf("\n%s 連動: 針の角度の開き %.1f° （期待 < 10.0°、45°/s なので 10° ≈ 0.22s）\n",
                   spread < 10.0f ? "PASS" : "FAIL", spread);
        }

        // --- 判定 2: 取り違え（槽ごとに違う顔をしているか）
        if (count == 3) {
            // 名前順に A / B / C が並ぶ前提（"darkroom - A" < "- B" < "- C"）。
            float a = stats[0].luma, b = stats[1].luma, c = stats[2].luma;
            int ok = (b < a) && (a < c);
            printf("%s 取り違え: 平均輝度 A=%.1f B=%.1f C=%.1f "
                   "（期待 B<A<C — 輪郭槽は面を落とし、肉付け槽は太らせる）\n",
                   ok ? "PASS" : "FAIL", a, b, c);
            printf("     エッジ率 A=%.2f B=%.2f C=%.2f （輪郭槽が最も高く、肉付け槽が最も低いはず）\n",
                   stats[0].edge, stats[1].edge, stats[2].edge);
        }
    }
    return 0;
}
OBJC

clang -fobjc-arc -O2 -F "$FWDIR" \
  -framework Foundation -framework Metal -framework Syphon \
  -rpath "$FWDIR" -o "$WORK/read" "$WORK/read.m"
DYLD_FRAMEWORK_PATH="$FWDIR" "$WORK/read" "$PREFIX"
