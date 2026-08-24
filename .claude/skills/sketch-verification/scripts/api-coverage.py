#!/usr/bin/env python3
"""既存作品が metaphor の公開 API をどれだけ名前として通したかを測る。

**これは「未使用リスト」であって「やることリスト」ではない。**
誰かが 1 度通したからといってその API が正しいわけではなく、引数・順番・規模・
他モジュールとの併用を変えれば別の検証になる。実際 #755 も #756 も、単体では
素直に見える API が組み合わせで壊れていた事例だった。

使い道は「手つかずの領域を見落とさないための補助」。着手時と完了時に検証 issue へ
貼っておくと、なぜその領域を選んだのかと、次に何が残っているのかが同じ場所に残る。

    .claude/skills/sketch-verification/scripts/api-coverage.py                 # 未使用をモジュール別に要約
    .claude/skills/sketch-verification/scripts/api-coverage.py --list Physics  # そのモジュールの API を全部出す
    .claude/skills/sketch-verification/scripts/api-coverage.py --self-test     # 抽出器の自己テスト

llms.txt は作品が解決した `.build/checkouts/*/llms.txt` から読む。metaphor 本体だけでなく
**プラグインパッケージ（metaphor-syphon など）も対象**で、パッケージごとにいちばん新しく
解決されたものを採る（作品ごとに metaphor のバージョンが違うので、metaphor は A の作品から、
プラグインは B の作品から、という混成になりうる）。

**どのファイルを読んだかは出力の先頭に出る。issue へ貼るときはヘッダごと貼る** —
版とプラグインの解決状況で母数が動くので、着手前 / 完了後を並べるときの前提になる。

注意: 名前の一致で数えるだけなので、同名の別物や自前のヘルパを拾うことがある。
同じ名前が複数パッケージに出てきた場合は先に読んだ側のモジュールに数える
（`isActive` や `stop` のような一般名は本体側に寄る）。
数字は「どの領域が手つかずか」を掴むための当たりであって、厳密なカバレッジではない。
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[4]

# --- metaphor 本体の書式（モジュール見出し + 宣言の箇条書き） ---
# llms.txt の宣言行から名前を取り出す（`- \`func foo(...)\` -- 説明` の形）
DECL = re.compile(r"^- `(?:func|var|let|class|struct|enum|protocol|init|static|typealias|@\w+)\s*([A-Za-z_][A-Za-z0-9_]*)")
# 型の見出し（`### \`final class Foo\` -- 説明`）
TYPE_HEADING = re.compile(r"^#{2,3} `(?:final |@\w+ )*(?:class|struct|enum|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)")
# モジュールの見出し（`## MetaphorPhysics`）
MODULE_HEADING = re.compile(r"^## ([A-Za-z]+)\s*$")

# --- プラグインパッケージの書式（機能見出し + ```swift フェンス内の生シグネチャ） ---
SWIFT_DECL = re.compile(
    r"^\s*public\s+(?:static\s+|final\s+|class\s+)*"
    r"(?:func|var|let|class|struct|enum|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"
)


def find_llms_files() -> dict[str, pathlib.Path]:
    """パッケージ名 → そのパッケージのいちばん新しく解決された llms.txt。"""
    newest: dict[str, pathlib.Path] = {}
    for path in ROOT.glob("*/*/.build/checkouts/*/llms.txt"):
        package = path.parent.name
        known = newest.get(package)
        if known is None or path.stat().st_mtime > known.stat().st_mtime:
            newest[package] = path
    if not newest:
        sys.exit(
            "llms.txt が見つからない。どれか 1 つの作品ディレクトリで `swift package resolve` を走らせてから再実行する"
        )
    return dict(sorted(newest.items()))


def module_name(package: str) -> str:
    """チェックアウト先のディレクトリ名からモジュール名を作る（metaphor-syphon → MetaphorSyphon）。"""
    return "".join(part[:1].upper() + part[1:] for part in re.split(r"[-_]", package))


def is_metaphor_style(text: str) -> bool:
    """metaphor 本体の書式か。

    プラグイン側も `## Setup` のような見出しを持つので、見出しの有無だけでは判別できない。
    宣言の箇条書きが揃っていることまで見る。
    """
    lines = text.splitlines()
    return any(MODULE_HEADING.match(line) for line in lines) and any(DECL.match(line) for line in lines)


def extract_metaphor_style(text: str, names: dict[str, str]) -> None:
    """モジュール見出しで区切られた宣言の箇条書きから名前を拾う。"""
    module = "MetaphorCore"
    for line in text.splitlines():
        if m := MODULE_HEADING.match(line):
            module = m.group(1)
            continue
        if m := TYPE_HEADING.match(line):
            names.setdefault(m.group(1), module)
            continue
        if m := DECL.match(line):
            names.setdefault(m.group(1), module)


def extract_plugin_style(text: str, names: dict[str, str], module: str) -> None:
    """```swift フェンスの中だけから名前を拾う。

    地の文やマイグレーション表に出てくる使用例を宣言と取り違えないため、フェンス内に限る。
    """
    in_fence = False
    for line in text.splitlines():
        if line.startswith("```"):
            in_fence = not in_fence
            continue
        if not in_fence:
            continue
        if m := SWIFT_DECL.match(line):
            names.setdefault(m.group(1), module)


def collect_declarations(files: dict[str, pathlib.Path]) -> dict[str, str]:
    """API 名 → 属するモジュール名。書式はパッケージ名ではなく中身で判定する。"""
    names: dict[str, str] = {}
    for package, path in files.items():
        text = path.read_text()
        if is_metaphor_style(text):
            extract_metaphor_style(text, names)
        else:
            extract_plugin_style(text, names, module_name(package))
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


# --- 自己テスト用の最小サンプル（このリポジトリにはテスト基盤が無いので同居させる） ---

METAPHOR_SAMPLE = """\
# metaphor

## MetaphorPhysics

### `final class PhysicsWorld2D` -- 2D の物理世界

- `func step(dt: Float)` -- 1 ステップ進める
- `var gravity: SIMD2<Float> { get set }` -- 重力
"""

PLUGIN_SAMPLE = '''\
# metaphor-syphon

## Setup

## Migration from metaphor <= 0.11

フェンスの外に置かれた（インデントだけの）旧シグネチャは、もう存在しない宣言なので拾ってはいけない:

    public func removedInThisVersion()

## API

### PluginFactory.syphon(name:) — declare the output

```swift
extension PluginFactory {
    public static func syphon(name: String? = nil) -> PluginFactory
}
```

### SyphonOutput — the server wrapper

```swift
public final class SyphonOutput {
    public init(device: MTLDevice, name: String)
    public var serverName: String? { get }
}
```
'''


def self_test() -> None:
    """抽出器の振る舞いを固定する。llms.txt も作品も要らないので単体で回せる。"""
    failures: list[str] = []

    def check(label: str, actual: object, expected: object) -> None:
        if actual != expected:
            failures.append(f"{label}\n      期待: {expected}\n      実際: {actual}")

    check("モジュール名（プラグイン）", module_name("metaphor-syphon"), "MetaphorSyphon")
    check("書式判定（本体）", is_metaphor_style(METAPHOR_SAMPLE), True)
    check("書式判定（プラグイン）", is_metaphor_style(PLUGIN_SAMPLE), False)

    core: dict[str, str] = {}
    extract_metaphor_style(METAPHOR_SAMPLE, core)
    check(
        "本体書式の抽出",
        core,
        {"PhysicsWorld2D": "MetaphorPhysics", "step": "MetaphorPhysics", "gravity": "MetaphorPhysics"},
    )

    plugin: dict[str, str] = {}
    extract_plugin_style(PLUGIN_SAMPLE, plugin, "MetaphorSyphon")
    check(
        "プラグイン書式の抽出（フェンス内だけ・init は名前を持たないので拾わない）",
        plugin,
        {"syphon": "MetaphorSyphon", "SyphonOutput": "MetaphorSyphon", "serverName": "MetaphorSyphon"},
    )
    check("フェンス外のインデント済みシグネチャは拾わない", "removedInThisVersion" in plugin, False)

    merged: dict[str, str] = {}
    extract_metaphor_style(METAPHOR_SAMPLE, merged)
    extract_plugin_style(PLUGIN_SAMPLE.replace("serverName", "gravity"), merged, "MetaphorSyphon")
    check("名前の衝突は先に読んだ側が勝つ", merged["gravity"], "MetaphorPhysics")

    if failures:
        print("self-test 失敗:")
        for failure in failures:
            print(f"  - {failure}")
        sys.exit(1)
    print("self-test 通過（本体書式 / プラグイン書式 / 書式判定 / モジュール名 / 名前衝突）")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", metavar="MODULE", help="モジュール名の一部を渡すと、その API を全部出す（使用済みは [済]）")
    parser.add_argument("--self-test", action="store_true", help="抽出器の自己テストだけ走らせる（llms.txt も作品も要らない）")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return

    files = find_llms_files()
    declarations = collect_declarations(files)
    source = collect_usage()

    # 語境界つきで 1 度に全部探す（1 名前ずつ grep すると遅い）
    used = set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", source))

    # モジュール名 → [(API 名, 使われているか)]。使用済みで埋まったモジュールも残す
    modules: dict[str, list[tuple[str, bool]]] = {}
    for name, module in sorted(declarations.items()):
        modules.setdefault(module, []).append((name, name in used))

    total = len(declarations)
    used_count = sum(1 for name in declarations if name in used)

    width = max(len(package) for package in files)
    print("llms.txt:")
    for package, path in files.items():
        print(f"  {package:{width}}  {path.relative_to(ROOT)}")
    print(f"公開 API {total} 個中 {used_count} 個 ({used_count * 100 // max(total, 1)}%) が既存作品で使われている\n")

    if args.list:
        needle = args.list.lower()
        hit = [module for module in modules if needle in module.lower()]
        if not hit:
            sys.exit(f"モジュール名に '{args.list}' を含むものが無い。候補: {', '.join(sorted(modules))}")
        for module in sorted(hit):
            entries = modules[module]
            unused = sum(1 for _, is_used in entries if not is_used)
            print(f"## {module} の公開 API {len(entries)} 個（未使用 {unused} 個）")
            for name, is_used in entries:
                print(f"  [{'済' if is_used else '未'}] {name}")
        return

    unused: dict[str, list[str]] = {
        module: [name for name, is_used in entries if not is_used] for module, entries in modules.items()
    }
    covered = sorted((module, len(modules[module])) for module, names in unused.items() if not names)

    print("未使用が多い順（手つかずの領域。ただし使用済み = 検証済みではない）:")
    for module, names in sorted(unused.items(), key=lambda kv: -len(kv[1])):
        if not names:
            continue
        head = ", ".join(names[:8])
        more = f" ほか {len(names) - 8} 個" if len(names) > 8 else ""
        print(f"  {module:22} {len(names):4} / {len(modules[module]):<4}  {head}{more}")
    if covered:
        print("\n全 API 使用済み（未使用ゼロ。上の表には出ない）:")
        print("  " + ", ".join(f"{module} ({count})" for module, count in covered))

    print("\n特定モジュールの全件は --list <モジュール名> で出す")
    print("※ 名前の一致で数えるだけなので絶対数は抽出方法に依る。領域の当たりを付けるための相対値として読む")
    print("※ 使用済みの API も、別の引数・規模・組み合わせで当て直す価値がある")


if __name__ == "__main__":
    main()
