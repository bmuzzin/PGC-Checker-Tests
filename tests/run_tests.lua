-- run_tests.lua
-- Test runner for 9976.lua across bmuzzin and empty profile stubs.

-- Resolve paths dynamically relative to this script so it works on Windows and Linux
local src_path = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local script_dir = src_path:match("(.*)/") or "."
local root_dir = script_dir:match("(.*)/tests$") or "."
local parent_dir = root_dir:match("(.*)/[^/]+$") or (root_dir .. "/..")
local checkers_dir = parent_dir .. "/PGC-ChallengeCheckers"

package.path = root_dir .. "/?.lua;" .. root_dir .. "/lib/?.lua;" .. root_dir .. "/?/init.lua;" .. package.path

local pgc_mock = require("lib.pgc_mock")

local SCRIPT_PATH = checkers_dir .. "/scripts/009000-009999/9976.lua"
local PROFILES = {
    { username = "empty",   id = 1000 },
    { username = "bmuzzin", id = 1001 }
}

-- Representative challenge tag configs for 9976.lua regression testing
local TEST_CONFIGS = {
    {
        name = "Number: 25 Caches with D2.5 / T2.5",
        config = {
            func = "number",
            conf = { limit = 25, difficulties = { 2.5 }, terrains = { 2.5 } }
        }
    },
    {
        name = "Number: 10 Traditional Caches",
        config = {
            func = "number",
            conf = { limit = 10 },
            filter = { types = { "Traditional Cache" } }
        }
    },
    {
        name = "Same: Same cache type limit",
        config = {
            func = "same",
            opt = { field = "type", limit = 5 },
            conf = { func = "number", conf = { limit = 1 } }
        }
    }
}

print("==================================================")
print(" Running Regression Tests for 9976.lua")
print("==================================================")

local total_tests = 0
local passed_tests = 0
local failed_tests = 0

for _, prof in ipairs(PROFILES) do
    print(string.format("\n[Profile: %s (id: %d)]", prof.username, prof.id))
    local finds = pgc_mock.load_profile(prof.username, root_dir .. "/data/profiles")
    print(string.format("  Loaded %d finds", #finds))

    for _, test in ipairs(TEST_CONFIGS) do
        local excl_func, excl_method = pgc_mock.check_excluded_config(test.config)
        if excl_func then
            print(string.format("  [SKIP] %s: Excluded (uses '%s' which calls %s)", test.name, excl_func, excl_method))
        else
            total_tests = total_tests + 1
            -- Re-initialize sandbox environment
            pgc_mock.init_env(prof.username, prof.id, finds, checkers_dir .. "/json-data")
            pgc_mock.reset_unsupported()

            -- Load script
            local fn, err = loadfile(SCRIPT_PATH)
            if not fn then
                print(string.format("  [FAIL] %s: Compilation error: %s", test.name, tostring(err)))
                failed_tests = failed_tests + 1
            else
                local args = {
                    {
                        config = test.config,
                        profileName = prof.username,
                        profileId = prof.id,
                        environmentSettings = { token = "test-token" }
                    }
                }

                local status, result = pcall(fn, unpack(args))
                local dyn_called, dyn_method = pgc_mock.get_unsupported_call()
                if dyn_called then
                    print(string.format("  [SKIP] %s: Excluded (called %s at runtime)", test.name, dyn_method))
                    total_tests = total_tests - 1
                elseif not status then
                    print(string.format("  [FAIL] %s: Runtime error: %s", test.name, tostring(result)))
                    failed_tests = failed_tests + 1
                elseif type(result) ~= "table" then
                    print(string.format("  [FAIL] %s: Expected table return, got %s", test.name, type(result)))
                    failed_tests = failed_tests + 1
                else
                    local ok_flag = result.ok and "MET" or "NOT MET"
                    print(string.format("  [PASS] %s -> status=%s", test.name, ok_flag))
                    passed_tests = passed_tests + 1
                end
            end
        end
    end
end

print("\n==================================================")
print(string.format("Summary: %d total, %d passed, %d failed", total_tests, passed_tests, failed_tests))
print("==================================================")

if failed_tests > 0 then
    os.exit(1)
end
