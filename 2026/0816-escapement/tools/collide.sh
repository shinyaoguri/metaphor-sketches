#!/bin/bash
# Constants の 21 個が、素の型注釈なしで書けるかを調べる。
#
# metaphor の Constants はモジュール直下のグローバル `let` なので、Darwin が同名の
# マクロを持つものは `import Foundation` を足した瞬間に「ambiguous use of 'X'」になる。
# 型推論の効く文脈（`case RETURN:` など）では通るが、文字列補間や `print` のように
# 型が定まらない場所では通らない。
#
#   tools/collide.sh          21 個を 2 通りの import で当てる
#
# 実測は README と検証 issue（#12）に載せてある。metaphor が上がったら、これを走らせるだけで
# 直ったかが分かる。
set -uo pipefail

cd "$(dirname "$0")/.."

modules=".build/debug/Modules"
frameworks=".build/arm64-apple-macosx/debug"
modulemap="$frameworks/CMetaphorSyphonBootstrap.build/module.modulemap"

if [ ! -d "$modules" ]; then
    echo "先に swift build を通しておくこと（$modules が要る）"
    exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

names=(RETURN TAB DELETE BACKSPACE CONTROL UP DOWN LEFT RIGHT SPACE ESCAPE
       SHIFT COMMAND OPTION ALT ENTER PI TAU TWO_PI HALF_PI QUARTER_PI)

scan() {
    local pre="$1" found=0
    for n in "${names[@]}"; do
        printf '%s\nimport metaphor\nfunc f() { print("\\(%s)") }\n' "$pre" "$n" > "$tmp/collide.swift"
        # swiftc は失敗時に非 0 で終わる。pipefail を効かせているのでパイプで
        # grep に渡すと判定がひっくり返る。出力を変数に取ってから当てる
        local diag
        diag=$(swiftc -typecheck -I "$modules" -F "$frameworks" \
            -Xcc -fmodule-map-file="$modulemap" "$tmp/collide.swift" 2>&1 || true)
        if [[ "$diag" == *"ambiguous use"* ]]; then
            echo "    $n"
            found=$((found + 1))
        fi
    done
    [ "$found" -eq 0 ] && echo "    （曖昧なものは無い）"
    echo "  → ${found}/${#names[@]} 個が曖昧"
}

echo "== import metaphor だけ =="
scan ""
echo
echo "== import Foundation + import metaphor =="
scan "import Foundation"
