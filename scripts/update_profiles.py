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
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "profiles"

BASE31_CHARS = "0123456789ABCDEFGHJKMNPQRTVWXYZ"
BASE31_MAP = {c: i for i, c in enumerate(BASE31_CHARS)}

def gccode_to_cache_id(gccode):
    """
    Calculate numeric cache_id from gccode.
    - For 4 or less digit gccodes, it is the hex value of the part after GC (e.g. GCFF -> 255).
      Note: if a 4-char code contains non-hex base-31 digits (G-Z), it falls through to base 31.
    - For 5 or more digits, it is a base-31 conversion using digits
      0123456789ABCDEFGHJKMNPQRTVWXYZ, minus 411120.
    """
    if not gccode:
        return 0
    code = str(gccode).strip().upper()
    if code.startswith("GC"):
        code = code[2:]
    if not code:
        return 0

    if len(code) <= 4:
        try:
            return int(code, 16)
        except ValueError:
            pass

    val = 0
    for ch in code:
        if ch not in BASE31_MAP:
            return 0
        val = val * 31 + BASE31_MAP[ch]
    return val - 411120

def ensure_cache_id(finds_list):
    """
    Ensures all find items in finds_list have a valid cache_id computed from gccode.
    """
    updated = []
    for item in finds_list:
        if isinstance(item, dict) and 'gccode' in item:
            if 'cache_id' not in item or not item['cache_id']:
                cid = gccode_to_cache_id(item['gccode'])
                new_item = {}
                for k, v in item.items():
                    if k == 'gccode':
                        new_item['cache_id'] = cid
                        new_item['gccode'] = v
                    elif k != 'cache_id':
                        new_item[k] = v
                if 'cache_id' not in new_item:
                    new_item['cache_id'] = cid
                updated.append(new_item)
            else:
                updated.append(item)
        else:
            updated.append(item)
    return updated

def save_profile(username, finds_list):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    out_file = DATA_DIR / f"{username}.json"
    gz_file = DATA_DIR / f"{username}.json.gz"

    finds_list = ensure_cache_id(finds_list)

    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(finds_list, f, indent=2)

    with gzip.open(gz_file, "wt", encoding="utf-8") as f:
        json.dump(finds_list, f)

    print(f"[+] Saved {len(finds_list)} finds for '{username}' -> {out_file} (and .gz)")

def parse_gpx(source):
    tree = ET.parse(source)
    root = tree.getroot()

    NS = {
        'gpx': 'http://www.topografix.com/GPX/1/0',
        'groundspeak': 'http://www.groundspeak.com/cache/1/0/1'
    }

    finds = []
    wpts = root.findall('gpx:wpt', NS) or root.findall('{http://www.topografix.com/GPX/1/0}wpt') or root.findall('wpt')

    for wpt in wpts:
        lat = float(wpt.get('lat', 0.0))
        lon = float(wpt.get('lon', 0.0))
        name_elem = wpt.find('gpx:name', NS)
        if name_elem is None:
            name_elem = wpt.find('{http://www.topografix.com/GPX/1/0}name')
        if name_elem is None:
            name_elem = wpt.find('name')
        gccode = name_elem.text.strip() if name_elem is not None and name_elem.text else ''

        time_elem = wpt.find('gpx:time', NS)
        if time_elem is None:
            time_elem = wpt.find('{http://www.topografix.com/GPX/1/0}time')
        if time_elem is None:
            time_elem = wpt.find('time')
        time_str = time_elem.text.strip() if time_elem is not None and time_elem.text else ''
        hidden = time_str.split('T')[0] if time_str else ''

        cache = wpt.find('groundspeak:cache', NS)
        if cache is None:
            cache = wpt.find('{http://www.groundspeak.com/cache/1/0/1}cache')

        if cache is None:
            continue

        c_name = cache.findtext('groundspeak:name', '', NS) or cache.findtext('{http://www.groundspeak.com/cache/1/0/1}name', '')
        c_type = cache.findtext('groundspeak:type', '', NS) or cache.findtext('{http://www.groundspeak.com/cache/1/0/1}type', '')
        c_size = cache.findtext('groundspeak:container', '', NS) or cache.findtext('{http://www.groundspeak.com/cache/1/0/1}container', '')
        diff_str = cache.findtext('groundspeak:difficulty', '1', NS) or cache.findtext('{http://www.groundspeak.com/cache/1/0/1}difficulty', '1')
        terr_str = cache.findtext('groundspeak:terrain', '1', NS) or cache.findtext('{http://www.groundspeak.com/cache/1/0/1}terrain', '1')
        country = cache.findtext('groundspeak:country', '', NS) or cache.findtext('{http://www.groundspeak.com/cache/1/0/1}country', '')
        state = cache.findtext('groundspeak:state', '', NS) or cache.findtext('{http://www.groundspeak.com/cache/1/0/1}state', '')

        try:
            diff = float(diff_str)
        except ValueError:
            diff = 1.0
        try:
            terr = float(terr_str)
        except ValueError:
            terr = 1.0

        owner_elem = cache.find('groundspeak:owner', NS)
        if owner_elem is None:
            owner_elem = cache.find('{http://www.groundspeak.com/cache/1/0/1}owner')
        owner_id = 0
        if owner_elem is not None:
            oid_val = owner_elem.get('id', '')
            if oid_val.isdigit():
                owner_id = int(oid_val)

        attrs_set = []
        attrs_unset = []
        attrs_elem = cache.find('groundspeak:attributes', NS)
        if attrs_elem is None:
            attrs_elem = cache.find('{http://www.groundspeak.com/cache/1/0/1}attributes')
        if attrs_elem is not None:
            for attr in (attrs_elem.findall('groundspeak:attribute', NS) or attrs_elem.findall('{http://www.groundspeak.com/cache/1/0/1}attribute')):
                aid = attr.get('id', '')
                if aid.isdigit():
                    attr_id = int(aid)
                    inc = attr.get('inc', '1')
                    if inc == '1':
                        attrs_set.append(attr_id)
                    else:
                        attrs_unset.append(attr_id)

        visitdate = ''
        logs_elem = cache.find('groundspeak:logs', NS)
        if logs_elem is None:
            logs_elem = cache.find('{http://www.groundspeak.com/cache/1/0/1}logs')
        if logs_elem is not None:
            for log in (logs_elem.findall('groundspeak:log', NS) or logs_elem.findall('{http://www.groundspeak.com/cache/1/0/1}log')):
                ldate_elem = log.find('groundspeak:date', NS)
                if ldate_elem is None:
                    ldate_elem = log.find('{http://www.groundspeak.com/cache/1/0/1}date')
                if ldate_elem is not None and ldate_elem.text:
                    visitdate = ldate_elem.text.strip().split('T')[0]
                    break

        finds.append({
            'cache_id': gccode_to_cache_id(gccode),
            'gccode': gccode,
            'cache_name': c_name.strip(),
            'visitdate': visitdate,
            'type': c_type.strip(),
            'size': c_size.strip(),
            'difficulty': diff,
            'terrain': terr,
            'country': country.strip(),
            'region': state.strip(),
            'county': '',
            'latitude': lat,
            'longitude': lon,
            'elevation': 0,
            'favorite_points': 0,
            'hidden': hidden,
            'owner_id': owner_id,
            'attributes_set': attrs_set,
            'attributes_unset': attrs_unset
        })

    finds.sort(key=lambda x: (x.get('visitdate') or '9999-99-99', x.get('gccode') or ''))
    return finds

def import_from_file(username, filepath):
    path = Path(filepath)
    if not path.exists():
        print(f"[-] File not found: {filepath}", file=sys.stderr)
        sys.exit(1)

    print(f"[*] Reading data from {filepath} for {username}...")

    # Check if zip file
    if zipfile.is_zipfile(path):
        all_finds = []
        with zipfile.ZipFile(path) as zf:
            for name in zf.namelist():
                if name.lower().endswith('.gpx'):
                    print(f"[*] Extracting and parsing {name} from zip...")
                    with zf.open(name) as gpx_file:
                        all_finds.extend(parse_gpx(gpx_file))
        if not all_finds:
            print("[-] No GPX files found in zip archive.", file=sys.stderr)
            sys.exit(1)
        save_profile(username, all_finds)
        return

    # Check if gpx file directly
    if path.suffix.lower() == '.gpx':
        with open(path, 'rb') as f:
            all_finds = parse_gpx(f)
        save_profile(username, all_finds)
        return

    # Otherwise treat as JSON or wrapped HTML
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
    parser.add_argument("--profile", choices=["bmuzzin", "empty"], help="Profile to update")
    parser.add_argument("--import-file", help="Path to JSON or exported file to load")
    parser.add_argument("--all", action="store_true", help="Process/verify all profiles")
    parser.add_argument("--update-existing", action="store_true", help="Re-save existing profile data ensuring fields like cache_id are populated")
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

    profiles_to_process = [args.profile] if args.profile else ["bmuzzin", "empty"]

    if args.update_existing:
        for p in profiles_to_process:
            f = DATA_DIR / f"{p}.json"
            if f.exists():
                print(f"[*] Updating existing profile '{p}'...")
                with open(f, "r", encoding="utf-8") as fp:
                    data = json.load(fp)
                save_profile(p, data)

    print(f"Profiles directory: {DATA_DIR}")
    for p in ["bmuzzin", "empty"]:
        f = DATA_DIR / f"{p}.json"
        if f.exists():
            with open(f) as fp:
                data = json.load(fp)
            print(f" - {p}: {len(data)} finds present ({f.stat().st_size} bytes)")
        else:
            print(f" - {p}: NOT FOUND (use --profile {p} --import-file <file> to import)")

if __name__ == "__main__":
    main()
