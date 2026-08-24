#!/usr/bin/env python3
"""作品を候補ビルドの metaphor に差し替えて自己検査を回し、報告時の基準値と突き合わせる。

    recheck.py 2026/0816-marionette --metaphor-path ~/Repos/metaphor
    recheck.py 2026/0816-marionette --branch main
    recheck.py 2026/0816-marionette --release v0.10.0
    recheck.py 2026/0816-marionette                    # 差し替えず、今の pin のまま測る

依存の差し替えは `swift package edit` で行い、**終わったら必ず `unedit` で戻す**
（中断・失敗・Ctrl-C でも戻す）。作品の Package.resolved は触らないので、
再検証したあとも作品は報告時のバージョンに pin されたまま。

判定は台帳 verification/upstream.json の `sketches` に書いた
`verdictCommand` / `verdictPattern` で拾う。作品ごとに出し方が違う
（marionette は標準出力、adversary は frame.json 経由）ため、台帳側に持たせている。
"""

import argparse
import json
import pathlib
import re
import signal
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[4]
LEDGER = ROOT / "verification" / "upstream.json"


def run(args: list[str], cwd: pathlib.Path, timeout: int = 900) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def swap_in(sketch_dir: pathlib.Path, opts: argparse.Namespace) -> bool:
    """metaphor を候補ビルドへ差し替える。差し替えたら True。"""
    if opts.metaphor_path:
        args = ["swift", "package", "edit", "metaphor", "--path", str(pathlib.Path(opts.metaphor_path).expanduser())]
    elif opts.branch:
        args = ["swift", "package", "edit", "metaphor", "--branch", opts.branch]
    elif opts.release:
        args = ["swift", "package", "edit", "metaphor", "--revision", opts.release]
    else:
        return False

    print(f"==> 差し替え: {' '.join(args[3:])}")
    result = run(args, sketch_dir, timeout=300)
    if result.returncode != 0:
        sys.exit(f"swift package edit に失敗した:\n{result.stderr.strip()}")
    return True


def swap_out(sketch_dir: pathlib.Path) -> None:
    result = run(["swift", "package", "unedit", "metaphor", "--force"], sketch_dir, timeout=300)
    if result.returncode == 0:
        print("==> 依存を元に戻した")
    else:
        print(f"!! unedit に失敗した。手で戻すこと: {result.stderr.strip()}", file=sys.stderr)


def build_errors(build: subprocess.CompletedProcess, limit: int = 40) -> list[str]:
    """ビルド出力から `error:` 行だけを重複なしで抜き出す。

    同じ診断がサブプロセスごとに繰り返し出るので畳む。1 件も拾えなければ空を返す
    （呼び出し側が生ログへ案内する）。
    """
    output = (build.stdout or "") + "\n" + (build.stderr or "")
    seen: set[str] = set()
    errors: list[str] = []
    for line in output.splitlines():
        line = line.strip()
        if ": error:" not in line or line in seen:
            continue
        seen.add(line)
        errors.append(line)
    return errors[:limit]


def verdict_source(entry: dict, config: dict) -> tuple[str, str]:
    """このエントリの判定に使うコマンドとパターン。

    既定は作品単位（台帳の `sketches`）。ただし入力注入が要る検査のように
    **同じ作品でも検査 ID ごとに出し方が違う**ものがあるので、
    エントリの `oracle` 側で上書きできるようにしている。
    """
    oracle = entry["oracle"]
    return (oracle.get("verdictCommand", config["verdictCommand"]),
            oracle.get("verdictPattern", config["verdictPattern"]))


def collect_verdicts(sketch_dir: pathlib.Path, command: str, pattern: str) -> tuple[dict[str, str], str]:
    """判定コマンドを走らせ、{検査 ID: PASS/FAIL} と生ログを返す。"""
    print(f"==> 判定: {command}")
    try:
        result = subprocess.run(
            command, cwd=sketch_dir, shell=True, capture_output=True, text=True, timeout=900
        )
    except subprocess.TimeoutExpired as exc:
        return {}, f"（タイムアウト）\n{exc.stdout or ''}"

    log = (result.stdout or "") + (result.stderr or "")
    regex = re.compile(pattern)
    verdicts: dict[str, str] = {}
    for line in log.splitlines():
        if m := regex.search(line):
            verdicts[m.group("id")] = m.group("verdict")
    return verdicts, log


# 作品ごとの集計行（全体で何件通ったか）。個別の判定だけ見ていると、
# 直した箇所の隣で退行していても気付けないので、総数も並べて出す。
SUMMARY = re.compile(r"^(summary\.\S+\s+\S+|\[.*self-check.*PASS.*)$")


def summary_lines(log: str) -> list[str]:
    return [line.strip() for line in log.splitlines() if SUMMARY.match(line.strip())]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sketch", help="作品ディレクトリ（例: 2026/0816-marionette）")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--metaphor-path", help="ローカルの metaphor チェックアウトへ差し替える")
    group.add_argument("--branch", help="metaphor の指定ブランチへ差し替える")
    group.add_argument("--release", help="metaphor の指定タグへ差し替える（例: v0.10.0）")
    parser.add_argument("--log", action="store_true", help="判定コマンドの生ログも出す")
    args = parser.parse_args()

    ledger = json.loads(LEDGER.read_text())
    # 自己検査を持たない作品でも、差し替えてビルドが通るかは確かめる価値がある
    # （破壊的変更はビルドで出る）。判定は台帳の how に従って人がやる。
    config = ledger["sketches"].get(args.sketch)

    sketch_dir = ROOT / args.sketch
    if not sketch_dir.is_dir():
        sys.exit(f"{sketch_dir} が無い")

    mine = [e for e in ledger["entries"] if e["sketch"] == args.sketch]
    entries = [e for e in mine if e["oracle"]["kind"] == "check"]
    manual = [e for e in mine if e["oracle"]["kind"] == "manual"]

    swapped = False
    interrupted = False

    def on_signal(_signum, _frame):
        nonlocal interrupted
        interrupted = True
        raise KeyboardInterrupt

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    try:
        swapped = swap_in(sketch_dir, args)

        build = run(["swift", "build"], sketch_dir)
        if build.returncode != 0:
            # 破壊的変更はここで出る。上流が壊したのか作品が古いのかを人が見る材料になる。
            # **stdout と stderr の両方**から拾うこと — SwiftPM は診断を stdout へ出すことが
            # あり、stderr だけを見ると「通らない」としか出ず原因が分からない。
            print("==> ビルドが通らない（破壊的変更の可能性）\n")
            print("\n".join(build_errors(build)) or "（error 行を拾えなかった。--log で生ログを見る）")
            return

        print("==> ビルドは通った")

        if config is None:
            print("\nこの作品は自己検査を持たないので、ここから先は手作業。")
            for entry in manual:
                label = f"{entry['repo'].split('/')[-1]}#{entry['issue']}"
                print(f"\n  {label}  {entry['title']}")
                print(f"    報告時: {entry['baseline']['verdict']} — {entry['baseline'].get('note') or ''}")
                print(f"    見方  : {entry['oracle']['how']}")
            return

        # 既定のコマンドは必ず 1 回走らせ、出し方を上書きしているエントリのぶんだけ足す。
        sources = {(config["verdictCommand"], config["verdictPattern"])}
        sources.update(verdict_source(entry, config) for entry in entries)

        verdicts: dict[str, str] = {}
        logs: list[str] = []
        for command, pattern in sorted(sources):
            got, one = collect_verdicts(sketch_dir, command, pattern)
            verdicts.update(got)
            logs.append(one)
        log = "\n".join(logs)

        if args.log:
            print("\n--- 生ログ ---\n" + log + "\n--------------\n")
        if not verdicts:
            print("!! 判定を 1 件も拾えなかった。verdictPattern と実際の出力を突き合わせること", file=sys.stderr)
            return

        for line in summary_lines(log):
            print(f"  {line}")
        print(f"\n拾えた判定 {len(verdicts)} 件\n")
        header = f"{'上流':>16}  {'検査':<28} {'報告時':<8} {'今回':<8} 変化"
        print(header)
        print("-" * len(header))

        for entry in entries:
            label = f"{entry['repo'].split('/')[-1]}#{entry['issue']}"
            for check_id in entry["oracle"]["ids"]:
                # adversary の ID は "F8.graphics-placement" のように後半が付く
                now = verdicts.get(check_id) or next(
                    (v for k, v in verdicts.items() if k.split(".")[0] == check_id), None
                )
                before = entry["baseline"]["verdict"]
                if now is None:
                    change = "検査が見つからない"
                elif before == now:
                    change = "変化なし"
                elif before == "FAIL" and now == "PASS":
                    change = "★ 直った"
                elif now == "LOOK" or before == "LOOK":
                    # LOOK は「自動判定に落とせないので目視へ回す」区分。
                    # PASS/FAIL との行き来を退行と呼ぶと、直っていないのに直ったように、
                    # あるいはその逆に読める。判定区分が変わったことだけを伝える。
                    change = f"判定区分が変わった（{before} → {now}・目視で見る）"
                else:
                    change = "!! 退行"
                print(f"{label:>16}  {check_id:<28} {before:<8} {str(now):<8} {change}")

        print("\n※ 直っていれば台帳の recheck を更新し、こちらの検証 issue と上流 PR へ書く")
    except KeyboardInterrupt:
        print("\n中断された", file=sys.stderr)
    finally:
        if swapped:
            swap_out(sketch_dir)
        if interrupted:
            sys.exit(130)


if __name__ == "__main__":
    main()
