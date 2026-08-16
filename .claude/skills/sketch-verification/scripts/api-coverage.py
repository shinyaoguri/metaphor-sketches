#!/usr/bin/env python3
"""既存作品が metaphor の公開 API をどれだけ名前として通したかを測る。

**これは「未使用リスト」であって「やることリスト」ではない。**
誰かが 1 度通したからといってその API が正しいわけではなく、引数・順番・規模・
他モジュールとの併用を変えれば別の検証になる。実際 #755 も #756 も、単体では
素直に見える API が組み合わせで壊れていた事例だった。

使い道は「手つかずの領域を見落とさないための補助」。着手時と完了時に検証 issue へ
貼っておくと、なぜその領域を選んだのかと、次に何が残っているのかが同じ場所に残る。

    .claude/skills/sketch-verification/scripts/api-coverage.py            # 未使用をモジュール別に要約
    .claude/skills/sketch-verification/scripts/api-coverage.py --list Physics   # そのモジュールの未使用を全部出す

llms.txt は作品が解決した `.build/checkouts/metaphor/llms.txt` から読む（作品ごとに
metaphor のバージョンが違うので、いちばん新しく解決されたものを使う）。

注意: 名前の一致で数えるだけなので、同名の別物や自前のヘルパを拾うことがある。
数字は「どの領域が手つかずか」を掴むための当たりであって、厳密なカバレッジではない。
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[4]

# llms.txt の宣言行から名前を取り出す（`- \`func foo(...)\` -- 説明` の形）
DECL = re.compile(r"^- `(?:func|var|let|class|struct|enum|protocol|init|static|typealias|@\w+)\s*([A-Za-z_][A-Za-z0-9_]*)")
# 型の見出し（`### \`final class Foo\` -- 説明`）
TYPE_HEADING = re.compile(r"^#{2,3} `(?:final |@\w+ )*(?:class|struct|enum|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)")
# モジュールの見出し（`## MetaphorPhysics`）
MODULE_HEADING = re.compile(r"^## ([A-Za-z]+)\s*$")


def find_llms() -> pathlib.Path:
    """いちばん新しく解決された llms.txt を返す。"""
    candidates = sorted(
        ROOT.glob("*/*/.build/checkouts/metaphor/llms.txt"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        sys.exit(
            "llms.txt が見つからない。どれか 1 つの作品ディレクトリで `swift package resolve` を走らせてから再実行する"
        )
    return candidates[0]


def collect_declarations(llms: pathlib.Path) -> dict[str, str]:
    """API 名 → 属するモジュール名。"""
    names: dict[str, str] = {}
    module = "MetaphorCore"
    for line in llms.read_text().splitlines():
        if m := MODULE_HEADING.match(line):
            module = m.group(1)
            continue
        if m := TYPE_HEADING.match(line):
            names.setdefault(m.group(1), module)
            continue
        if m := DECL.match(line):
            names.setdefault(m.group(1), module)
    return names


def collect_usage() -> str:
    """全作品の Swift ソースを 1 本に連結して返す。"""
    chunks = []
    for path in sorted(ROOT.glob("*/*/Sources/**/*.swift")):
        if ".build" in path.parts:
            continue
        chunks.append(path.read_text(errors="replace"))
    if not chunks:
        sys.exit("作品の Swift ソースが 1 つも見つからない")
    return "\n".join(chunks)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", metavar="MODULE", help="モジュール名の一部を渡すと、その未使用 API を全部出す")
    args = parser.parse_args()

    llms = find_llms()
    declarations = collect_declarations(llms)
    source = collect_usage()

    # 語境界つきで 1 度に全部探す（1 名前ずつ grep すると遅い）
    used = set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", source))

    by_module: dict[str, list[str]] = {}
    used_count = 0
    for name, module in sorted(declarations.items()):
        if name in used:
            used_count += 1
        else:
            by_module.setdefault(module, []).append(name)

    total = len(declarations)
    print(f"llms.txt: {llms.relative_to(ROOT)}")
    print(f"公開 API {total} 個中 {used_count} 個 ({used_count * 100 // max(total, 1)}%) が既存作品で使われている\n")

    if args.list:
        needle = args.list.lower()
        hit = [m for m in by_module if needle in m.lower()]
        if not hit:
            sys.exit(f"モジュール名に '{args.list}' を含むものが無い。候補: {', '.join(sorted(by_module))}")
        for module in sorted(hit):
            print(f"## {module} の未使用 {len(by_module[module])} 個")
            for name in by_module[module]:
                print(f"  {name}")
        return

    print("未使用が多い順（手つかずの領域。ただし使用済み = 検証済みではない）:")
    for module, names in sorted(by_module.items(), key=lambda kv: -len(kv[1])):
        head = ", ".join(names[:8])
        more = f" ほか {len(names) - 8} 個" if len(names) > 8 else ""
        print(f"  {module:22} {len(names):4}  {head}{more}")
    print("\n特定モジュールの全件は --list <モジュール名> で出す")
    print("※ 名前の一致で数えるだけなので絶対数は抽出方法に依る。領域の当たりを付けるための相対値として読む")
    print("※ 使用済みの API も、別の引数・規模・組み合わせで当て直す価値がある")


if __name__ == "__main__":
    main()
