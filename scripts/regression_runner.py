#!/usr/bin/env python3
"""
Parallel regression test runner for 9976.lua.
Splits test tags across worker threads/processes for high throughput.
Usage:
    python3 scripts/regression_runner.py [options]
    lua tests/regression_test.lua [options]
"""

import sys
import os
import json
import time
import argparse
import subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_TAGS_PATH = ROOT_DIR / "data" / "tags_9976.json"
FAILURES_DIR = ROOT_DIR / "failures"
SNAPSHOTS_DIR = ROOT_DIR / "snapshots"
LUA_TEST_SCRIPT = ROOT_DIR / "tests" / "regression_test.lua"

def parse_args():
    parser = argparse.ArgumentParser(
        description="Parallel regression test runner for Project-GC checker script 9976.lua"
    )
    parser.add_argument("--seed", "-s", action="store_true", help="Seed baseline snapshots")
    parser.add_argument("--tag", "-t", type=int, help="Test a single tag ID")
    parser.add_argument("--tags", type=str, help="Comma-separated list of tag IDs to test")
    parser.add_argument("--tags-file", type=str, help="Path to JSON file containing tag IDs")
    parser.add_argument("--limit", "-n", type=int, help="Limit number of tags tested")
    parser.add_argument("--profile", "-p", type=str, help="Filter profile ('bmuzzin' or 'empty')")
    parser.add_argument("--include-excluded", action="store_true", help="Include dynamic excluded tags")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    parser.add_argument("--debug", "-d", action="store_true", help="Enable debug print")
    parser.add_argument("--no-debug", action="store_true", help="Disable debug print")
    parser.add_argument("--timeout", "-T", type=int, default=60, help="Per-tag execution timeout in seconds")
    parser.add_argument("--no-timeout", action="store_true", help="Disable per-tag timeout")
    parser.add_argument("--date", type=str, help="Override pinned mock date (YYYY-MM-DD or 'real')")
    parser.add_argument("--script", type=str, help="Path to alternate 9976.lua checker script")
    parser.add_argument("--workers", "-w", type=int, default=None, help="Number of worker threads (default: CPU cores)")
    parser.add_argument("--single-thread", action="store_true", help="Run with 1 worker")
    return parser.parse_known_args()

def load_tag_ids(args):
    if args.tag is not None:
        return [args.tag]
    if args.tags:
        return [int(x.strip()) for x in args.tags.split(",") if x.strip().isdigit()]
    if args.tags_file:
        with open(args.tags_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        tags = [int(x) for x in data if str(x).isdigit()]
        if args.limit and args.limit > 0:
            tags = tags[:args.limit]
        return tags
    if DEFAULT_TAGS_PATH.exists():
        with open(DEFAULT_TAGS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        tags = [int(x) for x in data if str(x).isdigit()]
        if args.limit and args.limit > 0:
            tags = tags[:args.limit]
        return tags
    print(f"[-] Tag list file not found: {DEFAULT_TAGS_PATH}", file=sys.stderr)
    sys.exit(1)

def get_default_mock_date():
    mock_file = ROOT_DIR / "data" / "mock_date.txt"
    if mock_file.exists():
        d = mock_file.read_text().strip()
        if d:
            return d
    return "real"

def build_worker_cmd(args, tag_chunk, extra_unknown):
    cmd = [
        "lua",
        str(LUA_TEST_SCRIPT),
        "--worker",
        "--tags",
        ",".join(map(str, tag_chunk))
    ]
    if args.seed:
        cmd.append("--seed")
    if args.profile:
        cmd.extend(["--profile", args.profile])
    if args.include_excluded:
        cmd.append("--include-excluded")
    if args.verbose:
        cmd.append("--verbose")
    if args.debug:
        cmd.append("--debug")
    if args.no_debug:
        cmd.append("--no-debug")
    if args.timeout and not args.no_timeout:
        cmd.extend(["--timeout", str(args.timeout)])
    if args.no_timeout:
        cmd.append("--no-timeout")
    if args.date:
        cmd.extend(["--date", args.date])
    if args.script:
        cmd.extend(["--script", args.script])
    for arg in extra_unknown:
        if arg not in cmd:
            cmd.append(arg)
    return cmd

def main():
    args, unknown = parse_args()
    tag_ids = load_tag_ids(args)

    if not tag_ids:
        print("[-] No tags to test.", file=sys.stderr)
        sys.exit(0)

    # Determine worker count
    if args.single_thread:
        num_workers = 1
    elif args.workers is not None and args.workers > 0:
        num_workers = args.workers
    else:
        cpu_count = os.cpu_count() or 4
        num_workers = max(1, min(cpu_count, 16))

    # Single tag shortcut or single worker
    if len(tag_ids) == 1:
        num_workers = 1

    mode_title = "SEEDING BASELINE SNAPSHOTS" if args.seed else "REGRESSION TESTING"
    mock_date = args.date or get_default_mock_date()

    print("==================================================")
    print(f" {mode_title} 9976.lua against snapshots ({len(tag_ids)} tags)")
    print(f" Workers: {num_workers} | Mock Date: {mock_date}")
    print("==================================================")

    # Clean failures dir if full run
    if not args.seed and args.tag is None and not args.tags and not args.limit:
        if FAILURES_DIR.exists():
            for f in FAILURES_DIR.glob("*.json"):
                try:
                    f.unlink()
                except OSError:
                    pass

    # Batch tags into chunks for worker pool
    if len(tag_ids) <= num_workers:
        chunk_size = 1
    else:
        # Dynamic chunk size to balance fast tags with heavy tags
        chunk_size = max(10, min(25, len(tag_ids) // (num_workers * 4) or 1))

    chunks = [tag_ids[i:i + chunk_size] for i in range(0, len(tag_ids), chunk_size)]

    start_time = time.time()
    total_checks = 0
    passed_checks = 0
    failed_checks = 0
    excluded_tags_count = 0
    missing_snapshots = 0
    script_errors = 0
    processed_tags = 0

    def run_worker_chunk(chunk):
        cmd = build_worker_cmd(args, chunk, unknown)
        res = subprocess.run(cmd, capture_output=True, text=True)
        return chunk, res.stdout, res.stderr, res.returncode

    with ThreadPoolExecutor(max_workers=num_workers) as executor:
        for chunk, stdout, stderr, retcode in executor.map(run_worker_chunk, chunks):
            processed_tags += len(chunk)
            lines = stdout.splitlines()
            for line in lines:
                if line.startswith("__WORKER_SUMMARY__:"):
                    try:
                        summary = json.loads(line.replace("__WORKER_SUMMARY__:", ""))
                        total_checks += summary.get("checks", 0)
                        passed_checks += summary.get("passed", 0)
                        failed_checks += summary.get("failed", 0)
                        excluded_tags_count += summary.get("excluded", 0)
                        missing_snapshots += summary.get("missing", 0)
                        script_errors += summary.get("errors", 0)
                    except Exception:
                        pass
                else:
                    # Echo failure or pass logs directly to terminal
                    if "[FAIL]" in line or "[REGRESSION FAIL]" in line or (args.verbose and "[PASS]" in line):
                        print(line)

            if stderr and stderr.strip():
                print(stderr.strip(), file=sys.stderr)

            # Progress update
            elapsed = time.time() - start_time
            if processed_tags % 100 == 0 or processed_tags == len(tag_ids) or chunk_size > 100:
                mode_str = "Seeded" if args.seed else "Checked"
                print(f"  [{mode_str} {processed_tags} / {len(tag_ids)} tags... elapsed: {elapsed:.2f}s]")

    total_elapsed = time.time() - start_time
    print("\n==================================================")
    print(f"Finished in {total_elapsed:.2f} seconds")
    print(f"Checks: {total_checks} total, {passed_checks} passed, {failed_checks} failed")
    if excluded_tags_count > 0:
        print(f"Excluded tags: {excluded_tags_count} (calling PGC.GetOldestCaches / GetFavorites / GetHighestCaches / GetLowestCaches)")
    if failed_checks > 0:
        print(f"Recorded failure diff details in: {FAILURES_DIR}")
        print("Run 'python3 scripts/viewer.py' to inspect the regression diffs interactively.")
    if missing_snapshots > 0:
        print(f"Missing snapshots: {missing_snapshots} (run with --seed to generate)")
    print("==================================================")

    if failed_checks > 0:
        sys.exit(1)
    sys.exit(0)

if __name__ == "__main__":
    main()
