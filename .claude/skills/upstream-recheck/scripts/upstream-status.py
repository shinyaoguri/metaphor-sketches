#!/usr/bin/env python3
"""台帳と GitHub の実状態を突き合わせて、再検証が要るものを出す。

    upstream-status.py            # 再検証が要るものだけ
    upstream-status.py --all      # 台帳の全件

「要る」の判定はこの 2 つ。

  - 上流の Issue が閉じているのに、こちらで一度も再検証していない
  - 再検証はしたが、そのあとで Issue が閉じ直された（再オープン → 再修正）

修正が**リリース済みか main 止まりか**も出す。作品はリリースに pin されているので、
main 止まりのものは `recheck.py --metaphor-path <チェックアウト>` でしか確かめられない。

GitHub への問い合わせはリポジトリ単位で一括にしてある（週次で回すため）。
"""

import argparse
import json
import pathlib
import subprocess
import sys
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parents[4]
LEDGER = ROOT / "verification" / "upstream.json"


def gh_json(args: list[str]) -> list | dict:
    result = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=180)
    if result.returncode != 0:
        sys.exit(f"gh に失敗した: {' '.join(args)}\n{result.stderr.strip()}")
    return json.loads(result.stdout or "[]")


def fetch_issues(repo: str, wanted: set[int]) -> dict[int, dict]:
    """台帳が参照している Issue の状態を集める。

    `issue list` は新しい順に打ち切られるので、上流が育つと**古い Issue が窓から
    こぼれて「見つからない」になる**（metaphor が #929 まで伸びた 2026-08-17 に実際に
    #266 / #267 / #271 で起きた）。一覧で拾えなかったぶんは番号で直接引き直す。
    """
    rows = gh_json([
        "issue", "list", "--repo", repo, "--state", "all", "--limit", "300",
        "--json", "number,state,closedAt,title",
    ])
    found = {r["number"]: r for r in rows}

    for number in sorted(wanted - set(found)):
        result = subprocess.run(
            ["gh", "issue", "view", str(number), "--repo", repo,
             "--json", "number,state,closedAt,title"],
            capture_output=True, text=True, timeout=180,
        )
        # 消された・移された Issue はここでも引けない。その場合は従来どおり
        # 「見つからない」として呼び出し側に判定させる
        if result.returncode == 0:
            found[number] = json.loads(result.stdout)
    return found


def fetch_latest_release(repo: str) -> dict | None:
    rows = gh_json(["release", "list", "--repo", repo, "--limit", "1", "--json", "tagName,publishedAt"])
    return rows[0] if rows else None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--all", action="store_true", help="再検証が要らないものも出す")
    args = parser.parse_args()

    ledger = json.loads(LEDGER.read_text())
    entries = ledger["entries"]

    repos = sorted({e["repo"] for e in entries})
    issues = {
        repo: fetch_issues(repo, {e["issue"] for e in entries if e["repo"] == repo})
        for repo in repos
    }
    releases = {repo: fetch_latest_release(repo) for repo in repos}

    for repo, release in releases.items():
        if release:
            print(f"{repo} の最新リリース: {release['tagName']}（{release['publishedAt'][:10]}）")
    print()

    by_sketch: dict[str, list[tuple[dict, str, str]]] = defaultdict(list)
    fine = 0

    for entry in entries:
        remote = issues[entry["repo"]].get(entry["issue"])
        if remote is None:
            by_sketch[entry["sketch"]].append((entry, "?", "Issue が見つからない"))
            continue

        closed_at = (remote.get("closedAt") or "")[:10]
        rechecked_at = entry["recheck"]["at"]

        if remote["state"] != "CLOSED":
            state = "上流で未解決"
            needed = False
        elif rechecked_at is None:
            state = f"閉じた（{closed_at}）が未再検証"
            needed = True
        elif rechecked_at < closed_at:
            state = f"再検証（{rechecked_at}）より後に閉じ直された（{closed_at}）"
            needed = True
        else:
            state = f"再検証済み（{rechecked_at} / {entry['recheck']['against']} で {entry['recheck']['verdict']}）"
            needed = False

        # リリース済みか main 止まりか
        release = releases[entry["repo"]]
        shipped = ""
        if remote["state"] == "CLOSED" and release:
            shipped = "リリース済み" if closed_at <= release["publishedAt"][:10] else "main 止まり（未リリース）"

        if needed or args.all:
            by_sketch[entry["sketch"]].append((entry, state, shipped))
        if not needed:
            fine += 1

    if not by_sketch:
        print(f"再検証が要るものは無い（台帳 {len(entries)} 件）")
        return

    total = sum(len(v) for v in by_sketch.values())
    print(f"再検証が要るもの {total - (fine if args.all else 0)} 件 / 台帳 {len(entries)} 件\n")

    for sketch in sorted(by_sketch):
        rows = by_sketch[sketch]
        config = ledger["sketches"].get(sketch)
        how = "recheck.py で自動判定できる" if config else "自己検査が無いので手作業（台帳の how を読む）"
        print(f"## {sketch}  — {how}")
        for entry, state, shipped in rows:
            label = f"{entry['repo'].split('/')[-1]}#{entry['issue']}"
            kind = entry["oracle"]["kind"]
            print(f"  {label:<18} [{kind:<6}] {state}{'  / ' + shipped if shipped else ''}")
            print(f"  {'':<18}          {entry['title'][:70]}")
        print()

    print("次にやること:")
    print("  自動判定できる作品:  .claude/skills/upstream-recheck/scripts/recheck.py <作品> --metaphor-path <metaphor のチェックアウト>")
    print("  手作業のもの:        台帳 verification/upstream.json の oracle.how に従って確かめる")
    print("  手順の全体:          .claude/skills/upstream-recheck/SKILL.md")


if __name__ == "__main__":
    main()
