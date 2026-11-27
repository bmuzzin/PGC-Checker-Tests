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
* `data/mock_date.txt`: Stores the pinned current date (`YYYY-MM-DD`) used by the test runner so date-dependent checks remain consistent across runs.
* `tests/regression_test.lua`: Full regression test suite executing test tag configs against historical snapshots.
* `data/profiles/`: Stores local JSON / `.json.gz` dumps of profile finds.
* `scripts/exporter_checker.lua`: Helper checker script to run on Project-GC to export `PGC.GetFinds` as JSON.
* `scripts/export_tags.js`: Browser console script to query Project-GC and export all tags authored specifically for script 9976 as `tags_9976.json`.
* `scripts/update_profiles.py`: Explicit script to update / import profile data.
* `scripts/update_tags.py`: Scans `PGC-ChallengeCheckers/tags/` to synchronize tags in `data/tags_9976.json`, handling removed and new compatible tags.
* `tests/check_compatibility.lua`: Batch validator that tests tags against `9976.lua` for compatibility.

## Running Tests

```bash
cd /home/bmuzzin/geocaching/PGC-Checker-Tests

# Run full regression test against snapshots (automatically splits across worker threads)
lua tests/regression_test.lua

# Run with explicit number of worker threads (default: CPU cores, up to 16)
lua tests/regression_test.lua --workers 8

# Run in single-threaded mode
lua tests/regression_test.lua --single-thread

# Test a specific tag (runs directly in single process)
lua tests/regression_test.lua --tag 81236

# Test a specific tag with debug output (DebugPrint enabled)
lua tests/regression_test.lua --tag 81236 --debug

# Test a different Project-GC checker script by ID (defaults to 9976)
lua tests/regression_test.lua --script 9016 --tag 73235
# Or pass a path to a custom script
lua tests/regression_test.lua --script /path/to/custom_checker.lua

# Test a subset of tags
lua tests/regression_test.lua -n 100

# Seed or refresh baseline snapshots (parallelized across workers)
lua tests/regression_test.lua --seed

# Accept failures from latest regression run as new baseline seeds
lua tests/regression_test.lua --accept-failures
# Or accept a specific tag's failure
lua tests/regression_test.lua --accept-failures --tag 80789

# Override the pinned mock date from data/mock_date.txt (use 'real' for system clock)
lua tests/regression_test.lua --date 2026-11-24
```

## Browsing Snapshots (Interactive Web Viewer)

A web page is available to browse the snapshots, select profiles, and inspect the rendered HTML / logs:

```bash
cd /home/bmuzzin/geocaching/PGC-Checker-Tests
python3 scripts/viewer.py
```
Then open `http://localhost:8000/viewer.html` (or `http://localhost:8000/viewer.html?script=12345` for another script) in your browser.

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

### Method 1: Export Tags Authored for 9976 from Project-GC (Recommended)

Because tags in `PGC-ChallengeCheckers/tags/` do not store which script they belong to, scanning the filesystem can match compatible tags authored for other scripts. To ensure only tags authored specifically for script 9976 are included:

1. Open [https://project-gc.com/Tools/Challenges?edit&scriptId=9976](https://project-gc.com/Tools/Challenges?edit&scriptId=9976) in your browser while logged in.
2. Open DevTools (**F12** or right-click -> **Inspect**) and navigate to the **Console** tab.
3. Paste the contents of [scripts/export_tags.js](file:///home/bmuzzin/geocaching/PGC-Checker-Tests/scripts/export_tags.js) and press Enter.
4. The browser will download `tags_9976.json`. Move it into `data/tags_9976.json`.
5. Clean up orphaned snapshots from tags that were removed or belonged to other scripts:
   ```bash
   python3 scripts/update_tags.py --check-removed-only
   ```

### Method 2: Synchronize with Local PGC-ChallengeCheckers/tags/

To synchronize the tags tested by `regression_test.lua` with the local checkout in `PGC-ChallengeCheckers`:

```bash
cd /home/bmuzzin/geocaching/PGC-Checker-Tests

# Scan for removed tags and new tags compatible with 9976.lua (minimum tag: 72559)
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
