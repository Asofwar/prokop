#!/usr/bin/env python3
"""Deterministic shards for the backend regression tests (tests/*.sh).

Backend CI runs the tests on several runners at once; every runner runs its
own share one test after another, because the tests are not proven safe to
run in parallel on one machine.

  plan    --total N --index I   print the tests of shard I (0-based), after
                                checking that the shards of all N runners
                                cover every test exactly once
  check   --total N             only that coverage check
  verify  DIR                   check the result files (shard-K-of-N.tsv) the
                                shards of a run wrote into DIR: every shard
                                reported, every test ran exactly once and
                                passed; writes a run summary
  weights DIR                   print a fresh weights table from those files

Shards are balanced by the expected duration of each test, taken from
backend-test-weights.tsv next to this script (seconds measured on a hosted
runner; tests not listed count as DEFAULT_WEIGHT). Longest tests are placed
first, each on the least loaded shard; ties go by name, so every runner of a
commit computes the same split. A stale table only unbalances the shards, it
never drops or repeats a test.
"""

import argparse
import os
import re
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[2]
WEIGHTS_FILE = Path(__file__).resolve().with_name("backend-test-weights.tsv")
DEFAULT_WEIGHT = 0.5
STATUSES = ("pass", "fail")
RESULT_NAME = re.compile(r"^shard-([0-9]+)-of-([0-9]+)[.]tsv$")


def fail(message):
    print(f"backend_test_shards: {message}", file=sys.stderr)
    sys.exit(1)


def discover_tests(root):
    tests_dir = root / "tests"
    found = sorted(
        f"tests/{path.name}"
        for path in tests_dir.glob("*.sh")
        if path.is_file() and not path.name.startswith(".")
    )
    if not found:
        fail(f"no tests found in {tests_dir}")
    return found


def load_weights(path):
    weights = {}
    if not path.is_file():
        return weights
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            name, seconds = line.split("\t")
            weights[name] = float(seconds)
        except ValueError:
            fail(f"{path.name}:{number}: expected '<test><TAB><seconds>', got {line!r}")
    return weights


def partition(tests, weights, total):
    if total < 1:
        fail("--total must be at least 1")
    loads = [0.0] * total
    shards = [[] for _ in range(total)]

    def weight(test):
        return weights.get(test, DEFAULT_WEIGHT)

    for test in sorted(tests, key=lambda name: (-weight(name), name)):
        index = min(range(total), key=lambda i: (loads[i], i))
        loads[index] += weight(test)
        shards[index].append(test)
    return [sorted(shard) for shard in shards], loads


def check_coverage(tests, shards):
    seen = {}
    for index, shard in enumerate(shards):
        for test in shard:
            seen.setdefault(test, []).append(index)
    known = set(tests)
    missing = [test for test in tests if test not in seen]
    repeated = {test: where for test, where in seen.items() if len(where) > 1}
    unknown = [test for test in seen if test not in known]
    if missing or repeated or unknown:
        fail(
            "shards do not cover every test exactly once: "
            f"missing={missing} repeated={repeated} unknown={unknown}"
        )


def planned(total):
    tests = discover_tests(ROOT_DIR)
    shards, loads = partition(tests, load_weights(WEIGHTS_FILE), total)
    check_coverage(tests, shards)
    return tests, shards, loads


def cmd_plan(args):
    tests, shards, loads = planned(args.total)
    if not 0 <= args.index < args.total:
        fail(f"--index must be in 0..{args.total - 1}")
    shard = shards[args.index]
    print(
        f"shard {args.index + 1}/{args.total}: {len(shard)} of {len(tests)} tests, "
        f"~{loads[args.index]:.0f}s expected (longest shard ~{max(loads):.0f}s)",
        file=sys.stderr,
    )
    for test in shard:
        print(test)


def cmd_check(args):
    tests, _, loads = planned(args.total)
    print(
        f"{len(tests)} tests in {args.total} shards, each exactly once; "
        f"expected shard seconds: {', '.join(f'{load:.0f}' for load in loads)}"
    )


def read_results(directory):
    """Rows (shard, test, status, seconds), the shard count and the shards seen."""
    rows = []
    totals = set()
    shards_seen = set()
    for path in sorted(Path(directory).glob("*.tsv")):
        match = RESULT_NAME.match(path.name)
        if not match:
            fail(f"unexpected result file {path.name}")
        shard, total = int(match.group(1)), int(match.group(2))
        totals.add(total)
        shards_seen.add(shard)
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip():
                continue
            parts = line.split("\t")
            if len(parts) != 3 or parts[1] not in STATUSES:
                fail(f"{path.name}:{number}: malformed result line {line!r}")
            rows.append((shard, parts[0], parts[1], float(parts[2])))
    if len(totals) > 1:
        fail(f"result files disagree on the shard count: {sorted(totals)}")
    total = totals.pop() if totals else 0
    return rows, total, shards_seen


def cmd_verify(args):
    tests = discover_tests(ROOT_DIR)
    known = set(tests)
    rows, total, shards_seen = read_results(args.directory)
    ran = {}
    for shard, test, status, seconds in rows:
        ran.setdefault(test, []).append((shard, status, seconds))

    missing = [test for test in tests if test not in ran]
    repeated = sorted(test for test, runs in ran.items() if len(runs) > 1)
    unknown = sorted(test for test in ran if test not in known)
    failed = sorted(test for test, runs in ran.items() if any(r[1] != "pass" for r in runs))
    silent = sorted(set(range(1, total + 1)) - shards_seen)

    by_shard = {shard: [0, 0, 0.0] for shard in shards_seen}
    for shard, _, status, seconds in rows:
        entry = by_shard[shard]
        entry[0] += 1
        entry[1] += status != "pass"
        entry[2] += seconds

    lines = ["## Backend tests", ""]
    lines.append(
        f"{len(ran)} of {len(tests)} tests ran in {len(shards_seen)} of {total or '?'} shards; "
        f"{len(failed)} failed."
    )
    lines += ["", "| Shard | Tests | Failed | Seconds |", "| --- | ---: | ---: | ---: |"]
    for shard in sorted(by_shard):
        count, bad, seconds = by_shard[shard]
        lines.append(f"| {shard}/{total} | {count} | {bad} | {seconds:.0f} |")
    slowest = sorted(rows, key=lambda row: (-row[3], row[1]))[:10]
    lines += ["", "<details><summary>Slowest tests</summary>", ""]
    lines += ["| Test | Seconds |", "| --- | ---: |"]
    lines += [f"| `{test}` | {seconds:.1f} |" for _, test, _, seconds in slowest]
    lines += ["", "</details>", ""]

    problems = []
    if not rows:
        problems.append("no shard reported any result")
    if silent:
        problems.append(f"no results from shard {', '.join(map(str, silent))}")
    if missing:
        problems.append(f"never ran: {', '.join(missing)}")
    if repeated:
        problems.append(f"ran more than once: {', '.join(repeated)}")
    if unknown:
        problems.append(f"not in tests/: {', '.join(unknown)}")
    if failed:
        problems.append(f"failed: {', '.join(failed)}")
    lines += [f"- **{problem}**" for problem in problems]

    report = "\n".join(lines) + "\n"
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write(report)
    print(report)
    for problem in problems:
        print(f"::error::Backend tests {problem}")
    if problems:
        sys.exit(1)


def cmd_weights(args):
    rows, _, _ = read_results(args.directory)
    print("# Seconds per backend test on a hosted runner; regenerate with")
    print("# backend_test_shards.py weights <downloaded backend-test-results-*>.")
    print(f"# Tests not listed here count as {DEFAULT_WEIGHT:g} seconds.")
    for _, test, _, seconds in sorted(rows, key=lambda row: (-row[3], row[1])):
        if seconds >= 1.0:
            print(f"{test}\t{seconds:.0f}" if seconds >= 10 else f"{test}\t{seconds:.1f}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan")
    plan.add_argument("--total", type=int, required=True)
    plan.add_argument("--index", type=int, required=True)
    plan.set_defaults(func=cmd_plan)
    check = sub.add_parser("check")
    check.add_argument("--total", type=int, required=True)
    check.set_defaults(func=cmd_check)
    verify = sub.add_parser("verify")
    verify.add_argument("directory")
    verify.set_defaults(func=cmd_verify)
    weights = sub.add_parser("weights")
    weights.add_argument("directory")
    weights.set_defaults(func=cmd_weights)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
