-- regression_test.lua
-- Comprehensive regression test runner for 9976.lua with baseline snapshotting.

local json = require("lib.json")
local pgc_mock = require("lib.pgc_mock")

local SCRIPT_PATH = "/home/bmuzzin/geocaching/PGC-ChallengeCheckers/scripts/009000-009999/9976.lua"
local TAGS_PATH = "/home/bmuzzin/geocaching/PGC-Checker-Tests/data/tags_9976.json"
local SNAPSHOTS_DIR = "/home/bmuzzin/geocaching/PGC-Checker-Tests/snapshots"
local TAGS_BASE_DIR = "/home/bmuzzin/geocaching/PGC-ChallengeCheckers/tags"

local ALL_PROFILES = {
    { username = "empty",   id = 1000 },
    { username = "bmuzzin", id = 680953 }
}

-- CLI argument parsing
local args = {...}
local is_seed_mode = false
local filter_tag_id = nil
local limit_tags = nil
local filter_profile = nil

local i = 1
while i <= #args do
    local a = args[i]
    if a == "--seed" or a == "-s" then
        is_seed_mode = true
    elseif a == "--tag" or a == "-t" then
        i = i + 1
        filter_tag_id = tonumber(args[i])
    elseif a == "--limit" or a == "-n" then
        i = i + 1
        limit_tags = tonumber(args[i])
    elseif a == "--profile" or a == "-p" then
        i = i + 1
        filter_profile = args[i]
    end
    i = i + 1
end

-- Ensure snapshots directory exists
os.execute("mkdir -p " .. SNAPSHOTS_DIR)

-- Helper to get tag JSON file path
local function get_tag_path(tag_id)
    local start = math.floor(tag_id / 1000) * 1000
    local end_num = start + 999
    local subdir = string.format("%08d-%08d", start, end_num)
    return string.format("%s/%s/%d.json", TAGS_BASE_DIR, subdir, tag_id)
end

-- Load tag list
local function load_tag_ids()
    if filter_tag_id then
        return { filter_tag_id }
    end
    local f = io.open(TAGS_PATH, "r")
    if not f then
        print("[-] Could not open " .. TAGS_PATH)
        os.exit(1)
    end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then
        print("[-] Invalid JSON in " .. TAGS_PATH)
        os.exit(1)
    end
    if limit_tags and limit_tags > 0 and limit_tags < #data then
        local sliced = {}
        for idx = 1, limit_tags do
            table.insert(sliced, data[idx])
        end
        return sliced
    end
    return data
end

-- Filter profiles
local profiles = {}
for _, p in ipairs(ALL_PROFILES) do
    if not filter_profile or filter_profile == p.username then
        table.insert(profiles, p)
    end
end

-- Preload profile data
local profile_data = {}
for _, p in ipairs(profiles) do
    profile_data[p.username] = pgc_mock.load_profile(p.username)
end

-- Compile 9976.lua
local script_fn, compile_err = loadfile(SCRIPT_PATH)
if not script_fn then
    print("[-] Fatal: failed to compile " .. SCRIPT_PATH .. ": " .. tostring(compile_err))
    os.exit(1)
end

local tag_ids = load_tag_ids()

print("==================================================")
if is_seed_mode then
    print(string.format(" SEEDING BASELINE SNAPSHOTS for 9976.lua (%d tags)", #tag_ids))
else
    print(string.format(" REGRESSION TESTING 9976.lua against snapshots (%d tags)", #tag_ids))
end
print("==================================================")

local total_checks = 0
local passed_checks = 0
local failed_checks = 0
local missing_snapshots = 0
local script_errors = 0

local start_clock = os.clock()

for tag_idx, tag_id in ipairs(tag_ids) do
    local tag_file_path = get_tag_path(tag_id)
    local tf = io.open(tag_file_path, "r")
    if not tf then
        print(string.format("[Tag %d] File missing: %s", tag_id, tag_file_path))
        failed_checks = failed_checks + 1
    else
        local tag_content = tf:read("*a")
        tf:close()

        if not tag_content or tag_content:match("^%s*$") then
            -- Empty tag file (permitted by Project-GC as disabled/empty tag)
            -- Skip quietly
        else
            local ok_parse, base_config = pcall(json.decode, tag_content)
            if not ok_parse or type(base_config) ~= "table" then
                print(string.format("[Tag %d] Invalid JSON config in %s", tag_id, tag_file_path))
                failed_checks = failed_checks + 1
            else
                local snapshot_file = string.format("%s/%d.json", SNAPSHOTS_DIR, tag_id)
                local existing_snapshot = nil
                local sf = io.open(snapshot_file, "r")
                if sf then
                    local scontent = sf:read("*a")
                    sf:close()
                    local ok_s, sdata = pcall(json.decode, scontent)
                    if ok_s and type(sdata) == "table" then existing_snapshot = sdata end
                end

                local tag_results = { tag_id = tag_id, profiles = {} }

                for _, prof in ipairs(profiles) do
                    total_checks = total_checks + 1

                    -- Re-init mock environment
                    pgc_mock.init_env(prof.username, prof.id, profile_data[prof.username])

                    -- Parse fresh config per profile to prevent cross-profile mutation
                    local _, tag_config = pcall(json.decode, tag_content)

                    local run_args = {
                        {
                            config = tag_config,
                            profileName = prof.username,
                            profileId = prof.id,
                            environmentSettings = { token = "regression-test-token" }
                        }
                    }

                local status, res = pcall(script_fn, unpack(run_args))
                if not status then
                    script_errors = script_errors + 1
                    failed_checks = failed_checks + 1
                    print(string.format("  [FAIL] Tag %d (%s): Runtime error: %s", tag_id, prof.username, tostring(res)))
                elseif type(res) ~= "table" then
                    script_errors = script_errors + 1
                    failed_checks = failed_checks + 1
                    print(string.format("  [FAIL] Tag %d (%s): Expected table return, got %s", tag_id, prof.username, type(res)))
                else
                    local run_output = {
                        ok = (res.ok == true),
                        log = res.log or "",
                        html = res.html or ""
                    }
                    tag_results.profiles[prof.username] = run_output

                    if is_seed_mode then
                        passed_checks = passed_checks + 1
                    else
                        if not existing_snapshot or not existing_snapshot.profiles or not existing_snapshot.profiles[prof.username] then
                            missing_snapshots = missing_snapshots + 1
                            print(string.format("  [MISSING SNAPSHOT] Tag %d (%s): Run with --seed to record baseline.", tag_id, prof.username))
                        else
                            local exp = existing_snapshot.profiles[prof.username]
                            local ok_match = (exp.ok == run_output.ok)
                            local log_match = (exp.log == run_output.log)
                            local html_match = (exp.html == run_output.html)

                            if ok_match and log_match and html_match then
                                passed_checks = passed_checks + 1
                            else
                                failed_checks = failed_checks + 1
                                print(string.format("  [REGRESSION FAIL] Tag %d (%s):", tag_id, prof.username))
                                if not ok_match then
                                    print(string.format("    - ok: expected %s, got %s", tostring(exp.ok), tostring(run_output.ok)))
                                end
                                if not log_match then
                                    print("    - log output mismatch")
                                end
                                if not html_match then
                                    print("    - html output mismatch")
                                end
                            end
                        end
                    end
                end
            end

            if is_seed_mode then
                local to_save = existing_snapshot or { tag_id = tag_id, profiles = {} }
                to_save.tag_id = tag_id
                to_save.profiles = to_save.profiles or {}
                for prof_k, prof_v in pairs(tag_results.profiles) do
                    to_save.profiles[prof_k] = prof_v
                end
                local sf = io.open(snapshot_file, "w")
                if sf then
                    sf:write(json.encode(to_save))
                    sf:close()
                end
            end
        end
    end
end

    if tag_idx % 100 == 0 or tag_idx == #tag_ids then
        local mode_str = is_seed_mode and "Seeded" or "Checked"
        print(string.format("  [%s %d / %d tags... elapsed: %.2fs]", mode_str, tag_idx, #tag_ids, os.clock() - start_clock))
    end
end

local total_elapsed = os.clock() - start_clock
print("\n==================================================")
print(string.format("Finished in %.2f seconds", total_elapsed))
print(string.format("Checks: %d total, %d passed, %d failed", total_checks, passed_checks, failed_checks))
if missing_snapshots > 0 then
    print(string.format("Missing snapshots: %d (run with --seed to generate)", missing_snapshots))
end
print("==================================================")

if failed_checks > 0 then
    os.exit(1)
end
