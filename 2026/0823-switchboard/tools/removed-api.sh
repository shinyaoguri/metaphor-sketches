#!/usr/bin/env bash
# metaphor#792 M6 で削除された API が、本当にコンパイルを通らないことを確かめる。
#
#   tools/removed-api.sh
#
# 削除は「書けないこと」でしか確認できないので、1 行ずつ一時ターゲットに書いて
# swift build させ、**全件が失敗する**ことを見る（1 つでも通ったら削除が効いていない）。
# ついでに「素の import metaphor が Syphon の binary artifact を引かない」ことも見る
# （metaphor#792 の主目的。M4 / ADR-0014）。
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

METAPHOR_VERSION=$(python3 -c '
import json, sys
pins = json.load(open("Package.resolved"))["pins"]
print(next(p["state"]["version"] for p in pins if p["identity"] == "metaphor"))
')
[ -n "$METAPHOR_VERSION" ] || { echo "Package.resolved から metaphor の版が読めない" >&2; exit 1; }

mkdir -p "$WORK/probe/Sources/Probe"
cat >"$WORK/probe/Package.swift" <<EOF
// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "Probe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/shinyaoguri/metaphor.git", exact: "$METAPHOR_VERSION")],
    targets: [.executableTarget(name: "Probe", dependencies: [.product(name: "metaphor", package: "metaphor")])]
)
EOF

# 削除された 4 つの綴り。いずれも「コンパイルが通らない」が期待値。
declare -a NAMES=(
  "SketchConfig(syphon:)"
  "SketchConfig(syphonName:)"
  "SketchWindowConfig(syphonName:)"
  "MetaphorOutputRegistry"
)
declare -a SNIPPETS=(
  '_ = SketchConfig(syphon: true)'
  '_ = SketchConfig(syphonName: "X")'
  '_ = SketchWindowConfig(syphonName: "X")'
  '_ = MetaphorOutputRegistry.self'
)

echo "metaphor $METAPHOR_VERSION に対して、削除された API が書けないことを確かめる"
echo

# 正の対照。ここが通らないなら、以下の「ビルド不能」は削除の証拠にならない
# （マニフェスト不正・依存解決の失敗でも同じように失敗するため）。
cat >"$WORK/probe/Sources/Probe/main.swift" <<'EOF'
import metaphor
@MainActor func probeControl() {
    _ = SketchConfig(title: "control", plugins: [])
    _ = MetaphorOutputProviders.registered
}
EOF
if (cd "$WORK/probe" && swift build >"$WORK/err.txt" 2>&1); then
  echo -e "PASS\tCONTROL 新 API がビルドできる\t以降の「ビルド不能」は削除の証拠として読める"
else
  echo -e "FAIL\tCONTROL 新 API がビルドできる\t検査そのものが壊れている:"
  head -5 "$WORK/err.txt"
  exit 1
fi
echo

fails=0
for i in "${!NAMES[@]}"; do
  cat >"$WORK/probe/Sources/Probe/main.swift" <<EOF
import metaphor
@MainActor func probeRemovedAPI() {
    ${SNIPPETS[$i]}
}
EOF
  if (cd "$WORK/probe" && swift build >"$WORK/err.txt" 2>&1); then
    echo -e "FAIL\t${NAMES[$i]}\tビルドが通ってしまった（削除されていない）"
  else
    reason=$(grep -m1 "error:" "$WORK/err.txt" | sed 's/^.*error: //' | cut -c1-90)
    echo -e "PASS\t${NAMES[$i]}\tビルド不能: $reason"
    fails=$((fails + 1))
  fi
done

echo
# 素の import metaphor で Syphon.xcframework が降ってこないこと。
cat >"$WORK/probe/Sources/Probe/main.swift" <<'EOF'
import metaphor
@MainActor func probeUmbrella() {
    _ = SketchConfig(title: "plain")
}
EOF
(cd "$WORK/probe" && swift build >/dev/null 2>&1) || true
if find "$WORK/probe/.build" -iname "Syphon.xcframework" -o -iname "Syphon.framework" 2>/dev/null | grep -q .; then
  echo -e "FAIL\timport metaphor が Syphon を引かない\t.build に Syphon が居る"
else
  echo -e "PASS\timport metaphor が Syphon を引かない\t.build に Syphon.xcframework/framework は無い"
fi

echo
echo "削除済み 4 件のうち $fails 件がビルド不能（期待 4）"
