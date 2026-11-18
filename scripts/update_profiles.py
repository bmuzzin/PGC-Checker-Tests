#!/usr/bin/env python3
"""
update_profiles.py

Updates profile data for regression testing.
Can import from:
1) An exported JSON file from Project-GC
2) An interactive or curl-based fetch if checker test URLs/tokens are available
"""

import sys
import os
import json
import gzip
import argparse
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "profiles"

def save_profile(username, finds_list):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    out_file = DATA_DIR / f"{username}.json"
    gz_file = DATA_DIR / f"{username}.json.gz"

    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(finds_list, f, indent=2)

    with gzip.open(gz_file, "wt", encoding="utf-8") as f:
        json.dump(finds_list, f)

    print(f"[+] Saved {len(finds_list)} finds for '{username}' -> {out_file} (and .gz)")

def import_from_file(username, filepath):
    path = Path(filepath)
    if not path.exists():
        print(f"[-] File not found: {filepath}", file=sys.stderr)
        sys.exit(1)

    print(f"[*] Reading data from {filepath} for {username}...")
    content = path.read_text(encoding="utf-8", errors="replace")

    # If it's wrapped in HTML from exporter_checker.lua
    if "<pre id='profile-data-json'>" in content:
        start = content.index("<pre id='profile-data-json'>") + len("<pre id='profile-data-json'>")
        end = content.index("</pre>", start)
        raw_json = content[start:end].strip()
    else:
        raw_json = content.strip()

    data = json.loads(raw_json)
    if not isinstance(data, list):
        print("[-] Expected a JSON array of finds.", file=sys.stderr)
        sys.exit(1)

    save_profile(username, data)

def main():
    parser = argparse.ArgumentParser(description="Update profile data from Project-GC")
    parser.add_argument("--profile", choices=["bmuzzin", "mondou2", "empty"], help="Profile to update")
    parser.add_argument("--import-file", help="Path to JSON or exported file to load")
    parser.add_argument("--all", action="store_true", help="Process/verify all profiles")
    args = parser.parse_args()

    if args.import_file:
        if not args.profile:
            print("[-] Please specify --profile when using --import-file", file=sys.stderr)
            sys.exit(1)
        import_from_file(args.profile, args.import_file)
        return

    # Check existing data
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    empty_file = DATA_DIR / "empty.json"
    if not empty_file.exists():
        save_profile("empty", [])

    print(f"Profiles directory: {DATA_DIR}")
    for p in ["bmuzzin", "mondou2", "empty"]:
        f = DATA_DIR / f"{p}.json"
        if f.exists():
            with open(f) as fp:
                data = json.load(fp)
            print(f" - {p}: {len(data)} finds present ({f.stat().st_size} bytes)")
        else:
            print(f" - {p}: NOT FOUND (use --profile {p} --import-file <file> to import)")

if __name__ == "__main__":
    main()
