#!/usr/bin/env python3
"""
update_tags.py

Updates the list of challenge tags tested in regression_test.lua (data/tags_9976.json).
Handles:
1. Removed tags: Tags in data/tags_9976.json whose files in PGC-ChallengeCheckers/tags/
   have disappeared or are empty (0 bytes).
2. Added tags: Scans PGC-ChallengeCheckers/tags/ for new tags, tests whether they are
   compatible with 9976.lua, and adds compatible ones to data/tags_9976.json.
3. Snapshot management: Cleans up orphaned snapshots for removed tags, and optionally
   seeds baseline snapshots for newly added tags (--seed).
"""

import sys
import os
import re
import json
import argparse
import subprocess
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_CHECKERS_DIR = ROOT_DIR.parent / "PGC-ChallengeCheckers"
TAGS_JSON_PATH = ROOT_DIR / "data" / "tags_9976.json"
SNAPSHOTS_DIR = ROOT_DIR / "snapshots"
FAILURES_DIR = ROOT_DIR / "failures"
COMPAT_SCRIPT = ROOT_DIR / "tests" / "check_compatibility.lua"
REGRESSION_SCRIPT = ROOT_DIR / "tests" / "regression_test.lua"

# Supported functions in 9976.lua lookup()
SUPPORTED_FUNCS = {
    "DT", "adv_number", "age", "and", "at_least", "attributes", "bingo", "bingo2",
    "calendar", "continents", "crc", "distance", "elevation", "fizzy_complete",
    "for_each", "fp", "from_home", "generate", "generic_calendar", "generic_fizzy",
    "grid", "histogram", "in_a_hidden_year", "in_a_year", "info", "jasmer", "lonely",
    "maxdist", "number", "ok", "oldest", "oldest_calendar", "oldest_fizzy", "or",
    "points", "range", "regex", "remote", "same", "sameCRC", "samex_diffy", "sequence",
    "souvenir", "span_pairs", "streak", "tb", "top_elevation", "top_elevation_calendar",
    "top_elevation_fizzy", "topfav", "topfav_calendar", "topfav_fizzy", "unique_groups",
    "unique_value", "venn", "words"
}

DISALLOWED_FUNCS = {"maybe", "types", "visit_date"}

def get_tag_path(checkers_dir, tag_id):
    start = (tag_id // 1000) * 1000
    end_num = start + 999
    subdir = f"{start:08d}-{end_num:08d}"
    return Path(checkers_dir) / "tags" / subdir / f"{tag_id}.json"

def load_existing_tags():
    if not TAGS_JSON_PATH.exists():
        return []
    try:
        with open(TAGS_JSON_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            return [int(x) for x in data if isinstance(x, (int, str)) and str(x).isdigit()]
    except Exception as e:
        print(f"[-] Error loading {TAGS_JSON_PATH}: {e}", file=sys.stderr)
    return []

def quick_schema_check(data):
    """
    Fast pre-filter: Returns (is_candidate, reason_if_not)
    Checks if JSON object has 'func' or 'default_func' matching supported 9976 functions.
    """
    if not isinstance(data, dict):
        return False, "not a JSON object"
    func = data.get("func") or data.get("default_func")
    if not func:
        return False, "missing 'func' or 'default_func'"
    if func in DISALLOWED_FUNCS:
        return False, f"uses deprecated/unsupported func '{func}'"
    if func not in SUPPORTED_FUNCS:
        return False, f"unsupported func '{func}'"
    return True, "candidate"

def run_compatibility_batch(checkers_dir, candidate_ids, verbose=False):
    """
    Runs tests/check_compatibility.lua for candidate IDs in batches.
    Returns (compatible_ids, incompatible_dict)
    """
    if not candidate_ids:
        return [], {}

    compatible = []
    incompatible = {}

    batch_size = 200
    total_batches = (len(candidate_ids) + batch_size - 1) // batch_size

    for b_idx in range(total_batches):
        batch = candidate_ids[b_idx * batch_size : (b_idx + 1) * batch_size]
        payload = json.dumps(batch)

        cmd = [
            "lua",
            str(COMPAT_SCRIPT),
            "--stdin",
            "--checkers-dir",
            str(checkers_dir)
        ]

        try:
            res = subprocess.run(cmd, input=payload, capture_output=True, text=True, check=True)
            out_data = json.loads(res.stdout.strip())
            b_compat = out_data.get("compatible", [])
            b_incompat = out_data.get("incompatible", {})

            compatible.extend(b_compat)
            incompatible.update(b_incompat)

            if verbose or len(candidate_ids) > 50:
                print(f"  [*] Batch {b_idx + 1}/{total_batches}: {len(b_compat)} compatible, {len(b_incompat)} incompatible")

        except Exception as e:
            print(f"[-] Error running compatibility test batch: {e}", file=sys.stderr)
            if hasattr(e, 'stderr') and e.stderr:
                print(f"    Stderr: {e.stderr}", file=sys.stderr)

    return compatible, incompatible

def scan_tags(checkers_dir, existing_tags, min_tag=0, limit=None, specific_tag=None, verbose=False):
    tags_base = Path(checkers_dir) / "tags"
    if not tags_base.exists():
        print(f"[-] Tags directory not found: {tags_base}", file=sys.stderr)
        sys.exit(1)

    existing_set = set(existing_tags)

    # 1. Identify removed tags
    removed_tags = []
    for tid in existing_tags:
        p = get_tag_path(checkers_dir, tid)
        if not p.exists() or p.stat().st_size == 0:
            removed_tags.append(tid)

    # 2. Identify new candidate tags
    candidate_ids = []
    schema_rejected = {}

    if specific_tag is not None:
        p = get_tag_path(checkers_dir, specific_tag)
        if not p.exists() or p.stat().st_size == 0:
            print(f"[-] Tag {specific_tag} does not exist or is empty in {p}", file=sys.stderr)
            sys.exit(1)
        try:
            data = json.loads(p.read_text(encoding="utf-8", errors="replace"))
            is_cand, reason = quick_schema_check(data)
            if is_cand:
                candidate_ids.append(specific_tag)
            else:
                schema_rejected[specific_tag] = reason
        except Exception as e:
            schema_rejected[specific_tag] = f"JSON parse error: {e}"
    elif limit == 0:
        pass
    else:
        print("[*] Scanning tags in PGC-ChallengeCheckers/tags/...")
        for p in tags_base.rglob("*.json"):
            try:
                tid = int(p.stem)
            except ValueError:
                continue

            if tid < min_tag:
                continue
            if tid in existing_set:
                continue
            if p.stat().st_size == 0:
                continue

            try:
                txt = p.read_text(encoding="utf-8", errors="replace").strip()
                if not txt:
                    continue
                # Quick string check before json decoding
                if '"func"' not in txt and '"default_func"' not in txt:
                    continue
                data = json.loads(txt)
                is_cand, reason = quick_schema_check(data)
                if is_cand:
                    candidate_ids.append(tid)
                else:
                    schema_rejected[tid] = reason
            except Exception as e:
                schema_rejected[tid] = f"JSON parse error: {e}"

            if limit is not None and len(candidate_ids) >= limit:
                break

    # Sort candidate IDs
    candidate_ids.sort()
    print(f"[*] Found {len(candidate_ids)} new candidate tags to test for compatibility.")

    # 3. Test compatibility of candidate tags with 9976.lua
    compatible_ids, runtime_rejected = run_compatibility_batch(checkers_dir, candidate_ids, verbose)

    incompatible_all = {}
    incompatible_all.update(schema_rejected)
    incompatible_all.update(runtime_rejected)

    return removed_tags, compatible_ids, incompatible_all

def main():
    parser = argparse.ArgumentParser(description="Update tags list for regression testing against 9976.lua")
    parser.add_argument("--checkers-dir", default=str(DEFAULT_CHECKERS_DIR), help="Path to PGC-ChallengeCheckers repository")
    parser.add_argument("--tag", type=int, help="Check and add a specific tag ID")
    parser.add_argument("--min-tag", type=int, default=0, help="Minimum tag ID to consider when scanning for new tags")
    parser.add_argument("--limit", type=int, help="Limit number of new candidate tags to scan/test")
    parser.add_argument("--check-removed-only", action="store_true", help="Only check and remove missing/deleted tags without scanning for new ones")
    parser.add_argument("--dry-run", action="store_true", help="Report additions and removals without updating files")
    parser.add_argument("--clean-snapshots", action="store_true", default=True, help="Remove orphaned snapshots for deleted tags (default: True)")
    parser.add_argument("--no-clean-snapshots", action="store_false", dest="clean_snapshots", help="Do not remove orphaned snapshots")
    parser.add_argument("--seed", action="store_true", help="Automatically seed snapshots for newly added compatible tags")
    parser.add_argument("--sort-descending", action="store_true", default=True, help="Sort final tag list in descending order (default: True)")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print detailed information and rejection reasons")
    args = parser.parse_args()

    checkers_dir = Path(args.checkers_dir).resolve()
    print(f"==================================================")
    print(f" PGC-ChallengeCheckers Tag Sync for 9976.lua")
    print(f" Checkers dir: {checkers_dir}")
    print(f" Tags config:  {TAGS_JSON_PATH}")
    print(f"==================================================")

    existing_tags = load_existing_tags()
    print(f"[*] Loaded {len(existing_tags)} tags currently in data/tags_9976.json")

    scan_limit = 0 if args.check_removed_only else args.limit

    removed_tags, compatible_new, incompatible = scan_tags(
        checkers_dir=checkers_dir,
        existing_tags=existing_tags,
        min_tag=args.min_tag,
        limit=scan_limit,
        specific_tag=args.tag,
        verbose=args.verbose
    )

    print("\n--------------------------------------------------")
    print(f" RESULTS SUMMARY:")
    print(f"   Removed tags:     {len(removed_tags)}")
    print(f"   New compatible:   {len(compatible_new)}")
    print(f"   Incompatible:     {len(incompatible)}")
    print("--------------------------------------------------")

    if removed_tags:
        print(f"\n[-] Removed tags ({len(removed_tags)}):")
        sample_removed = removed_tags[:20]
        print("    " + ", ".join(str(t) for t in sample_removed) + ("..." if len(removed_tags) > 20 else ""))

    if compatible_new:
        print(f"\n[+] Newly compatible tags ({len(compatible_new)}):")
        sample_new = compatible_new[:20]
        print("    " + ", ".join(str(t) for t in sample_new) + ("..." if len(compatible_new) > 20 else ""))

    if incompatible and args.verbose:
        print(f"\n[!] Sample incompatible tags ({len(incompatible)}):")
        for tid, reason in list(incompatible.items())[:15]:
            print(f"    Tag {tid}: {reason}")

    # Build updated tag list
    removed_set = set(removed_tags)
    remaining_tags = [t for t in existing_tags if t not in removed_set]
    updated_set = set(remaining_tags)
    for tid in compatible_new:
        if tid not in updated_set:
            remaining_tags.append(tid)
            updated_set.add(tid)

    if args.sort_descending:
        final_tags = sorted(remaining_tags, reverse=True)
    else:
        final_tags = remaining_tags

    print(f"\n[*] Total tags after update: {len(final_tags)} (net change: {len(final_tags) - len(existing_tags):+d})")

    if args.dry_run:
        print("\n[!] Dry run enabled: no files modified.")
        return

    # Write updated tags_9976.json
    TAGS_JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(TAGS_JSON_PATH, "w", encoding="utf-8") as f:
        json.dump(final_tags, f, indent=2)
    print(f"[+] Saved updated tag list to {TAGS_JSON_PATH}")

    # Clean orphaned snapshots if requested
    if args.clean_snapshots and removed_tags:
        cleaned_snaps = 0
        cleaned_fails = 0
        for tid in removed_tags:
            snap_file = SNAPSHOTS_DIR / f"{tid}.json"
            if snap_file.exists():
                snap_file.unlink()
                cleaned_snaps += 1
            fail_file = FAILURES_DIR / f"{tid}.json"
            if fail_file.exists():
                fail_file.unlink()
                cleaned_fails += 1
        if cleaned_snaps > 0 or cleaned_fails > 0:
            print(f"[+] Cleaned up {cleaned_snaps} orphaned snapshots and {cleaned_fails} failure files.")

    # Seed baseline snapshots if requested
    if args.seed and compatible_new:
        print(f"\n[*] Seeding baseline snapshots for {len(compatible_new)} new tags...")
        for tid in compatible_new:
            cmd = ["lua", str(REGRESSION_SCRIPT), "--seed", "--tag", str(tid)]
            subprocess.run(cmd, check=False)
        print("[+] Finished seeding baseline snapshots.")

if __name__ == "__main__":
    main()
