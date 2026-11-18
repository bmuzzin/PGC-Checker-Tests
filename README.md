# PGC-Checker-Tests

Regression test suite for Project-GC challenge checker script [9976.lua](file:///home/bmuzzin/geocaching/PGC-ChallengeCheckers/scripts/009000-009999/9976.lua).

## Structure

* `lib/pgc_mock.lua`: Offline sandbox environment emulating Project-GC `PGC.*` APIs, date parsing (`Date.Format`), and filtering.
* `tests/run_tests.lua`: Regression test runner executing test tag configs against:
  * `bmuzzin` (local cached profile data)
  * `mondou2` (high-finds profile data)
  * `empty` (stub 0-finds profile)
* `data/profiles/`: Stores local JSON / `.json.gz` dumps of profile finds.
* `scripts/exporter_checker.lua`: Helper checker script to run on Project-GC to export `PGC.GetFinds` as JSON.
* `scripts/update_profiles.py`: Explicit script to update / import profile data.

## Running Tests

```bash
cd /home/bmuzzin/geocaching/PGC-Checker-Tests
lua tests/run_tests.lua
```

## Updating Profile Data from Project-GC

1. In Project-GC, run `scripts/exporter_checker.lua` for the desired profile (`bmuzzin` or `mondou2`).
2. Save the output and import it:
   ```bash
   ./scripts/update_profiles.py --profile bmuzzin --import-file /path/to/bmuzzin_dump.json
   ./scripts/update_profiles.py --profile mondou2 --import-file /path/to/mondou2_dump.json
   ```
3. Verify profiles:
   ```bash
   ./scripts/update_profiles.py
   ```
