# PGC-Checker-Tests

Regression test suite for Project-GC challenge checker script [9976.lua](file:///home/bmuzzin/geocaching/PGC-ChallengeCheckers/scripts/009000-009999/9976.lua).

## Prerequisites

* **Lua** (Lua 5.1 / 5.2 / LuaJIT)
* **LuaRocks**
* **Penlight** (version `1.15.0-1`) is required for Date object emulation (matching Project-GC's environment):
  ```bash
  luarocks install penlight 1.15.0-1
  ```

## Structure

* `lib/pgc_mock.lua`: Offline sandbox environment emulating Project-GC `PGC.*` APIs, using Penlight (`pl.Date`), and filtering.
* `tests/regression_test.lua`: Full regression test suite executing test tag configs against historical snapshots.
* `data/profiles/`: Stores local JSON / `.json.gz` dumps of profile finds.
* `scripts/exporter_checker.lua`: Helper checker script to run on Project-GC to export `PGC.GetFinds` as JSON.
* `scripts/update_profiles.py`: Explicit script to update / import profile data.
* `scripts/update_tags.py`: Scans `PGC-ChallengeCheckers/tags/` to synchronize tags in `data/tags_9976.json`, handling removed and new compatible tags.
* `tests/check_compatibility.lua`: Batch validator that tests tags against `9976.lua` for compatibility.

## Running Tests

```bash
cd /home/bmuzzin/geocaching/PGC-Checker-Tests

# Run full regression test against snapshots
lua tests/regression_test.lua

# Test a specific tag
lua tests/regression_test.lua --tag 81236

# Test a specific tag with debug output (DebugPrint enabled)
lua tests/regression_test.lua --tag 81236 --debug

# Test a subset of tags
lua tests/regression_test.lua -n 100

# Seed or refresh baseline snapshots
lua tests/regression_test.lua --seed
```

## Browsing Snapshots (Interactive Web Viewer)

A web page is available to browse the snapshots, select profiles, and inspect the rendered HTML / logs:

```bash
cd /home/bmuzzin/geocaching/PGC-Checker-Tests
python3 scripts/viewer.py
```
Then open `http://localhost:8000/viewer.html` in your browser.

## Updating Profile Data from Project-GC

1. In Project-GC, run `scripts/exporter_checker.lua` for the desired profile (`bmuzzin`).
2. Save the output and import it:
   ```bash
   ./scripts/update_profiles.py --profile bmuzzin --import-file /path/to/bmuzzin_dump.json
   ```
3. Verify profiles:
   ```bash
   ./scripts/update_profiles.py
   ```

## Updating Challenge Tags

To synchronize the tags tested by `regression_test.lua` with the tags in `PGC-ChallengeCheckers`:

```bash
cd /home/bmuzzin/geocaching/PGC-Checker-Tests

# Scan for removed tags and new tags compatible with 9976.lua
python3 scripts/update_tags.py

# Preview changes without modifying files
python3 scripts/update_tags.py --dry-run

# Only check and remove missing/deleted tags
python3 scripts/update_tags.py --check-removed-only

# Check a single specific tag
python3 scripts/update_tags.py --tag 81236

# Scan new tags and automatically seed baseline snapshots for new additions
python3 scripts/update_tags.py --seed
```
