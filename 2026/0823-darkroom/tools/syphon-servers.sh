#!/usr/bin/env bash
# いま machine 上に立っている Syphon サーバーを列挙する。
#
#   tools/syphon-servers.sh
#
# MadMapper 等の受け手を開かなくても「サーバーが本当に立っているか」を**テキストで**確かめられる。
# Syphon.framework は metaphor-syphon の binary artifact（swift build で降りてくる）を直接引く。
set -euo pipefail

cd "$(dirname "$0")/.."
FW=$(find .build/artifacts -type d -name "Syphon.framework" -path "*macos*" | head -1)
[ -n "$FW" ] || { echo "Syphon.framework が無い。先に swift build してください" >&2; exit 1; }
FWDIR=$(dirname "$FW")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat >"$WORK/list.m" <<'OBJC'
#import <Foundation/Foundation.h>
#import <Syphon/Syphon.h>

int main(void) {
    @autoreleasepool {
        // ディレクトリは非同期に埋まるので、少し回してから読む。
        [SyphonServerDirectory sharedDirectory];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
        NSArray *servers = [[SyphonServerDirectory sharedDirectory] servers];
        printf("Syphon サーバー %lu 件\n", (unsigned long)servers.count);
        for (NSDictionary *s in servers) {
            printf("  name=%s\tapp=%s\tuuid=%s\n",
                   [[s objectForKey:SyphonServerDescriptionNameKey] ?: @"(nil)" UTF8String],
                   [[s objectForKey:SyphonServerDescriptionAppNameKey] ?: @"(nil)" UTF8String],
                   [[s objectForKey:SyphonServerDescriptionUUIDKey] ?: @"(nil)" UTF8String]);
        }
    }
    return 0;
}
OBJC

clang -fobjc-arc -F "$FWDIR" -framework Foundation -framework Syphon \
  -rpath "$FWDIR" -o "$WORK/list" "$WORK/list.m"
DYLD_FRAMEWORK_PATH="$FWDIR" "$WORK/list"
