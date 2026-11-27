-- regression_test.lua
-- Comprehensive regression test runner for 9976.lua with baseline snapshotting.

-- Hook VS Code Local Lua Debugger if active
local has_lldbg, lldbg = pcall(require, "lldebugger")
local is_running_in_vscode = false
if has_lldbg then
    lldbg.start()
    is_running_in_vscode = true
end

-- Resolve paths dynamically relative to this script so it works on Windows and Linux
local src_path = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local script_dir = src_path:match("(.*)/") or "."
local root_dir = script_dir:match("(.*)/tests$") or "."
local parent_dir = root_dir:match("(.*)/[^/]+$") or (root_dir .. "/..")
local checkers_dir = parent_dir .. "/PGC-ChallengeCheckers"

package.path = root_dir .. "/?.lua;" .. root_dir .. "/lib/?.lua;" .. root_dir .. "/?/init.lua;" .. package.path

local json = require("lib.json")
local pgc_mock = require("lib.pgc_mock")

local TAGS_BASE_DIR = checkers_dir .. "/tags"

local ALL_PROFILES = {
    { username = "empty",   id = 1000 },
    { username = "bmuzzin", id = 680953 }
}

-- CLI argument parsing
local args = {...}
local is_seed_mode = false
local is_accept_mode = false
local is_worker = false
local is_single_thread = false
local num_workers = nil
local filter_tag_id = nil
local filter_tags = nil
local limit_tags = nil
local filter_profile = nil
local include_excluded = false
local is_verbose = false
local is_debug = is_running_in_vscode
local timeout_seconds = 60
local script_arg = nil

local i = 1
while i <= #args do
    local a = args[i]
    if a == "--worker" then
        is_worker = true
    elseif a == "--single-thread" then
        is_single_thread = true
    elseif a == "--workers" or a == "-w" then
        i = i + 1
        num_workers = tonumber(args[i])
        if num_workers == 1 then
            is_single_thread = true
        end
    elseif a == "--seed" or a == "-s" then
        is_seed_mode = true
    elseif a == "--accept-failures" or a == "--accept" or a == "-a" then
        is_accept_mode = true
    elseif a == "--tag" or a == "-t" then
        i = i + 1
        filter_tag_id = tonumber(args[i])
    elseif a == "--tags" then
        i = i + 1
        filter_tags = {}
        for tid in args[i]:gmatch("%d+") do
            table.insert(filter_tags, tonumber(tid))
        end
    elseif a == "--tags-file" then
        i = i + 1
        local tf = io.open(args[i], "r")
        if tf then
            local tcontent = tf:read("*a")
            tf:close()
            local tok, tdata = pcall(json.decode, tcontent)
            if tok and type(tdata) == "table" then
                filter_tags = {}
                for _, id in ipairs(tdata) do
                    if tonumber(id) then table.insert(filter_tags, tonumber(id)) end
                end
            end
        end
    elseif a == "--limit" or a == "-n" then
        i = i + 1
        limit_tags = tonumber(args[i])
    elseif a == "--profile" or a == "-p" then
        i = i + 1
        filter_profile = args[i]
    elseif a == "--include-excluded" then
        include_excluded = true
    elseif a == "--verbose" or a == "-v" then
        is_verbose = true
    elseif a == "--debug" or a == "-d" then
        is_debug = true
    elseif a == "--no-debug" then
        is_debug = false
    elseif a == "--timeout" or a == "-T" then
        i = i + 1
        timeout_seconds = tonumber(args[i]) or 60
    elseif a == "--no-timeout" then
        timeout_seconds = 0
    elseif a == "--date" then
        i = i + 1
        pgc_mock.set_mock_date(args[i])
    elseif a == "--script" then
        i = i + 1
        script_arg = args[i]
    end
    i = i + 1
end

-- Resolve script ID and path
local function resolve_script(arg, base_checkers_dir)
    if not arg then
        return 9976, string.format("%s/scripts/009000-009999/9976.lua", base_checkers_dir)
    end
    local arg_str = tostring(arg):gsub("^%s*(.-)%s*$", "%1")
    if arg_str:match("^%d+$") then
        local sid = tonumber(arg_str)
        local start = math.floor(sid / 1000) * 1000
        local end_num = start + 999
        local subdir = string.format("%06d-%06d", start, end_num)
        return sid, string.format("%s/scripts/%s/%d.lua", base_checkers_dir, subdir, sid)
    end
    local filename = arg_str:match("([^/\\]+)$") or arg_str
    local sid = tonumber(filename:match("^(%d+)%.lua$")) or filename:gsub("%.lua$", "")
    return sid, arg_str
end

local script_id, SCRIPT_PATH = resolve_script(script_arg, checkers_dir)
if package.config:sub(1,1) == '\\' then
    SCRIPT_PATH = SCRIPT_PATH:gsub('/', '\\')
end

local TAGS_PATH = root_dir .. "/data/tags_" .. tostring(script_id) .. ".json"

local function get_snapshot_dir(root, sid)
    local sdir = root .. "/snapshots/" .. tostring(sid)
    local probe = io.open(sdir .. "/.probe", "r")
    if probe then probe:close() return sdir end
    local p2 = io.open(sdir, "r")
    if p2 then p2:close() return sdir end
    if sid == 9976 or sid == "9976" then
        return root .. "/snapshots"
    end
    return sdir
end

local function get_failure_dir(root, sid)
    local fdir = root .. "/failures/" .. tostring(sid)
    local probe = io.open(fdir .. "/.probe", "r")
    if probe then probe:close() return fdir end
    local p2 = io.open(fdir, "r")
    if p2 then p2:close() return fdir end
    if sid == 9976 or sid == "9976" then
        return root .. "/failures"
    end
    return fdir
end

local SNAPSHOTS_DIR = get_snapshot_dir(root_dir, script_id)
local FAILURES_DIR = get_failure_dir(root_dir, script_id)

local function get_snapshot_file(snapshots_dir, root, sid, tid)
    local f1 = string.format("%s/%d.json", snapshots_dir, tid)
    local sf = io.open(f1, "r")
    if sf then
        sf:close()
        return f1
    end
    if sid == 9976 or sid == "9976" then
        local f2 = string.format("%s/snapshots/%d.json", root, tid)
        local sf2 = io.open(f2, "r")
        if sf2 then
            sf2:close()
            return f2
        end
    end
    return f1
end

-- Accept recorded failures as new baseline seeds if requested
local function accept_failures(tag_id_filter, tags_filter)
    local target_set = nil
    if tag_id_filter then
        target_set = { [tag_id_filter] = true }
    elseif tags_filter then
        target_set = {}
        for _, tid in ipairs(tags_filter) do
            target_set[tid] = true
        end
    end

    local file_list = {}
    if target_set then
        for tid in pairs(target_set) do
            local fpath = string.format("%s/%d.json", FAILURES_DIR, tid)
            local f = io.open(fpath, "r")
            if f then
                f:close()
                table.insert(file_list, { tag_id = tid, path = fpath })
            end
        end
    else
        local p
        if package.config:sub(1,1) == '\\' then
            p = io.popen('dir /b "' .. FAILURES_DIR:gsub('/', '\\') .. '\\*.json" 2>nul')
        else
            p = io.popen('ls -1 "' .. FAILURES_DIR .. '"/*.json 2>/dev/null')
        end
        if p then
            for line in p:lines() do
                local filename = line:match("([^/\\]+%.json)$") or line
                local tid = tonumber(filename:match("(%d+)%.json"))
                if tid then
                    local fpath = line:find("[/\\]") and line or string.format("%s/%s", FAILURES_DIR, filename)
                    table.insert(file_list, { tag_id = tid, path = fpath })
                end
            end
            p:close()
        end
    end

    table.sort(file_list, function(a, b) return a.tag_id < b.tag_id end)

    if #file_list == 0 then
        if target_set then
            local ids = {}
            for tid in pairs(target_set) do table.insert(ids, tostring(tid)) end
            table.sort(ids)
            print("[-] No recorded failures found for tag(s): " .. table.concat(ids, ", "))
        else
            print("[-] No recorded failures found in failures/")
        end
        os.exit(0)
    end

    print("==================================================")
    print(string.format(" ACCEPTING FAILURES AS NEW BASELINE SEEDS (%d tag(s))", #file_list))
    print("==================================================")

    local accepted_count = 0
    local skipped_count = 0

    for _, item in ipairs(file_list) do
        local tid = item.tag_id
        local ff = io.open(item.path, "r")
        if not ff then
            print(string.format("  [-] Tag %d: Could not open failure file %s", tid, item.path))
            skipped_count = skipped_count + 1
        else
            local content = ff:read("*a")
            ff:close()
            local ok_f, fdata = pcall(json.decode, content)
            if not ok_f or type(fdata) ~= "table" or type(fdata.profiles) ~= "table" then
                print(string.format("  [-] Tag %d: Invalid JSON in %s", tid, item.path))
                skipped_count = skipped_count + 1
            else
                local actual_profiles = {}
                local missing_actual = {}
                for prof_name, prof_data in pairs(fdata.profiles) do
                    if type(prof_data) == "table" and prof_data.actual then
                        actual_profiles[prof_name] = prof_data.actual
                    else
                        table.insert(missing_actual, prof_name)
                    end
                end

                local has_actual = false
                for _ in pairs(actual_profiles) do has_actual = true break end

                if not has_actual then
                    print(string.format("  [-] Tag %d: No valid actual results to accept (e.g. runtime errors / timeouts)", tid))
                    skipped_count = skipped_count + 1
                else
                    local snapshot_path = get_snapshot_file(SNAPSHOTS_DIR, root_dir, script_id, tid)
                    local snapshot_data = { tag_id = tid, profiles = {} }
                    local sf = io.open(snapshot_path, "r")
                    if sf then
                        local scontent = sf:read("*a")
                        sf:close()
                        local ok_s, sdata = pcall(json.decode, scontent)
                        if ok_s and type(sdata) == "table" then
                            snapshot_data = sdata
                        end
                    end
                    snapshot_data.tag_id = tid
                    snapshot_data.profiles = snapshot_data.profiles or {}
                    local accepted_names = {}
                    for prof_name, actual_data in pairs(actual_profiles) do
                        snapshot_data.profiles[prof_name] = actual_data
                        table.insert(accepted_names, prof_name)
                    end
                    table.sort(accepted_names)

                    if package.config:sub(1,1) == '\\' then
                        os.execute('if not exist "' .. SNAPSHOTS_DIR:gsub('/', '\\') .. '" mkdir "' .. SNAPSHOTS_DIR:gsub('/', '\\') .. '" 2>nul')
                    else
                        os.execute('mkdir -p "' .. SNAPSHOTS_DIR .. '" 2>/dev/null')
                    end
                    local target_snapshot_path = string.format("%s/%d.json", SNAPSHOTS_DIR, tid)
                    local out_sf = io.open(target_snapshot_path, "w")
                    if out_sf then
                        out_sf:write(json.encode(snapshot_data))
                        out_sf:close()
                        os.remove(item.path)
                        local warn_str = ""
                        if #missing_actual > 0 then
                            warn_str = string.format(" (skipped: %s)", table.concat(missing_actual, ", "))
                        end
                        print(string.format("  [+] Tag %d: Accepted profiles [%s]%s", tid, table.concat(accepted_names, ", "), warn_str))
                        accepted_count = accepted_count + 1
                    else
                        print(string.format("  [-] Tag %d: Could not write snapshot %s", tid, snapshot_path))
                        skipped_count = skipped_count + 1
                    end
                end
            end
        end
    end

    print("==================================================")
    print(string.format("Accepted %d tag(s) as new baseline seeds.", accepted_count))
    if skipped_count > 0 then
        print(string.format("Skipped %d tag(s) due to errors or missing actual output.", skipped_count))
    end
    print("==================================================")
    os.exit(0)
end

if is_accept_mode then
    accept_failures(filter_tag_id, filter_tags)
end

-- Delegate to parallel worker coordinator unless running in worker mode, single tag, or single-thread/debug
if not is_worker and not is_single_thread and not is_running_in_vscode and not is_debug and (filter_tag_id == nil) then
    local escaped_args = {}
    for _, arg in ipairs(args) do
        if arg:find('[ %"\']') then
            table.insert(escaped_args, '"' .. arg:gsub('"', '\\"') .. '"')
        else
            table.insert(escaped_args, arg)
        end
    end
    local runner_script = root_dir .. "/scripts/regression_runner.py"
    local cmd = 'python3 "' .. runner_script .. '" ' .. table.concat(escaped_args, " ")
    local status = os.execute(cmd)
    if type(status) == "number" then
        local exit_code = math.floor(status / 256)
        if exit_code == 0 and status ~= 0 then exit_code = status end
        os.exit(exit_code)
    else
        os.exit(status == true and 0 or 1)
    end
end

-- Ensure snapshots and failures directories exist
local probe = io.open(SNAPSHOTS_DIR .. "/100000.json", "r")
if probe then
    probe:close()
else
    if package.config:sub(1,1) == '\\' then
        os.execute('if not exist "' .. SNAPSHOTS_DIR:gsub('/', '\\') .. '" mkdir "' .. SNAPSHOTS_DIR:gsub('/', '\\') .. '"')
    else
        os.execute('mkdir -p "' .. SNAPSHOTS_DIR .. '"')
    end
end

if package.config:sub(1,1) == '\\' then
    os.execute('if not exist "' .. FAILURES_DIR:gsub('/', '\\') .. '" mkdir "' .. FAILURES_DIR:gsub('/', '\\') .. '"')
else
    os.execute('mkdir -p "' .. FAILURES_DIR .. '"')
end

-- Helper to get tag JSON file path
local function get_tag_path(tag_id)
    local start = math.floor(tag_id / 1000) * 1000
    local end_num = start + 999
    local subdir = string.format("%08d-%08d", start, end_num)
    return string.format("%s/%s/%d.json", TAGS_BASE_DIR, subdir, tag_id)
end

-- Load tag list
local function load_tag_ids()
    if filter_tags then
        return filter_tags
    end
    if filter_tag_id then
        return { filter_tag_id }
    end
    local f = io.open(TAGS_PATH, "r")
    if not f then
        print("[-] Tag list file not found: " .. TAGS_PATH)
        print("    Export tags using scripts/export_tags.js or specify --tag / --tags / --tags-file")
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
    profile_data[p.username] = pgc_mock.load_profile(p.username, root_dir .. "/data/profiles")
end

-- Compile 9976.lua
local script_fn, compile_err = loadfile(SCRIPT_PATH)
if not script_fn then
    print("[-] Fatal: failed to compile " .. SCRIPT_PATH .. ": " .. tostring(compile_err))
    os.exit(1)
end

local tag_ids = load_tag_ids()

if not is_worker then
    print("==================================================")
    if is_seed_mode then
        print(string.format(" SEEDING BASELINE SNAPSHOTS for %s.lua (%d tags)", tostring(script_id), #tag_ids))
    else
        print(string.format(" REGRESSION TESTING %s.lua against snapshots (%d tags)", tostring(script_id), #tag_ids))
    end
    print(string.format(" Mock Date: %s", tostring(pgc_mock.get_mock_date() or "real")))
    print("==================================================")
end

local total_checks = 0
local passed_checks = 0
local failed_checks = 0
local missing_snapshots = 0
local script_errors = 0
local excluded_tags_count = 0

-- Clear previous failure records if running a full suite run
if not is_worker and not is_seed_mode and not filter_tag_id and not filter_tags and not limit_tags then
    if package.config:sub(1,1) == '\\' then
        os.execute('del /q "' .. FAILURES_DIR:gsub('/', '\\') .. '\\*.json" 2>nul')
    else
        os.execute('rm -f "' .. FAILURES_DIR .. '"/*.json 2>/dev/null')
    end
end

local start_clock = os.clock()

for tag_idx, tag_id in ipairs(tag_ids) do
    local tag_file_path = get_tag_path(tag_id)
    local tf = io.open(tag_file_path, "r")
    if not tf then
        print(string.format("  [FAIL] Tag %d: File missing: %s", tag_id, tag_file_path))
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
                print(string.format("  [FAIL] Tag %d: Invalid JSON config in %s", tag_id, tag_file_path))
                failed_checks = failed_checks + 1
            else
                local excl_func, excl_method = nil, nil
                if script_id == 9976 or script_id == "9976" then
                    excl_func, excl_method = pgc_mock.check_excluded_config(base_config)
                end
                if excl_func and not include_excluded then
                    excluded_tags_count = excluded_tags_count + 1
                    if filter_tag_id or is_verbose then
                        print(string.format("  [SKIP] Tag %d: Excluded (uses '%s' which calls %s)", tag_id, excl_func, excl_method))
                    end
                else
                    local snapshot_file = get_snapshot_file(SNAPSHOTS_DIR, root_dir, script_id, tag_id)
                    local existing_snapshot = nil
                    local sf = io.open(snapshot_file, "r")
                    if sf then
                        local scontent = sf:read("*a")
                        sf:close()
                        local ok_s, sdata = pcall(json.decode, scontent)
                        if ok_s and type(sdata) == "table" then existing_snapshot = sdata end
                    end

                    local tag_results = { tag_id = tag_id, profiles = {} }
                    local tag_excluded_dynamically = false
                    local tag_failures = nil
                    local tag_passed = true

                    for _, prof in ipairs(profiles) do
                        -- Re-init mock environment
                        pgc_mock.init_env(prof.username, prof.id, profile_data[prof.username], checkers_dir .. "/json-data")
                        pgc_mock.set_debug_output(is_debug)
                        pgc_mock.reset_unsupported()

                        -- Parse fresh config per profile to prevent cross-profile mutation
                        local _, tag_config = pcall(json.decode, tag_content)
                        if type(tag_config) == "table" then
                            tag_config.debug = is_debug
                        end

                        local run_args = {
                            {
                                config = tag_config,
                                profileName = prof.username,
                                profileId = prof.id,
                                environmentSettings = { token = "regression-test-token" }
                            }
                        }

                        local test_timed_out = false
                        if timeout_seconds > 0 and not is_running_in_vscode then
                            local start_cpu = os.clock()
                            local start_wall = os.time()
                            debug.sethook(function()
                                if (os.clock() - start_cpu >= timeout_seconds) or (os.time() - start_wall > timeout_seconds) then
                                    test_timed_out = true
                                    error(string.format("Timed out after %d seconds", timeout_seconds))
                                end
                            end, "", 10000)
                        end

                        local status, res = pcall(script_fn, unpack(run_args))

                        if timeout_seconds > 0 and not is_running_in_vscode then
                            debug.sethook()
                        end

                        local dyn_called, dyn_method = pgc_mock.get_unsupported_call()
                        if dyn_called and not include_excluded then
                            tag_excluded_dynamically = true
                            excluded_tags_count = excluded_tags_count + 1
                            if filter_tag_id or is_verbose then
                                print(string.format("  [SKIP] Tag %d (%s): Excluded (called %s at runtime)", tag_id, prof.username, dyn_method))
                            end
                            break
                        end

                        total_checks = total_checks + 1
                        if not status then
                            script_errors = script_errors + 1
                            failed_checks = failed_checks + 1
                            tag_passed = false
                            local err_msg = test_timed_out and string.format("Timed out after %d seconds", timeout_seconds) or tostring(res)
                            if test_timed_out then
                                print(string.format("  [FAIL] Tag %d (%s): %s", tag_id, prof.username, err_msg))
                            else
                                print(string.format("  [FAIL] Tag %d (%s): Runtime error: %s", tag_id, prof.username, tostring(res)))
                            end
                            if not is_seed_mode then
                                tag_failures = tag_failures or { tag_id = tag_id, timestamp = os.time(), profiles = {} }
                                tag_failures.profiles[prof.username] = {
                                    passed = false,
                                    error = err_msg,
                                    expected = existing_snapshot and existing_snapshot.profiles and existing_snapshot.profiles[prof.username] or nil
                                }
                            end
                        elseif type(res) ~= "table" then
                            script_errors = script_errors + 1
                            failed_checks = failed_checks + 1
                            tag_passed = false
                            print(string.format("  [FAIL] Tag %d (%s): Expected table return, got %s", tag_id, prof.username, type(res)))
                            if not is_seed_mode then
                                tag_failures = tag_failures or { tag_id = tag_id, timestamp = os.time(), profiles = {} }
                                tag_failures.profiles[prof.username] = {
                                    passed = false,
                                    error = "Expected table return, got " .. type(res),
                                    expected = existing_snapshot and existing_snapshot.profiles and existing_snapshot.profiles[prof.username] or nil
                                }
                            end
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
                                    tag_passed = false
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
                                        tag_passed = false
                                        tag_failures = tag_failures or { tag_id = tag_id, timestamp = os.time(), profiles = {} }
                                        tag_failures.profiles[prof.username] = {
                                            passed = false,
                                            ok_match = ok_match,
                                            log_match = log_match,
                                            html_match = html_match,
                                            expected = exp,
                                            actual = run_output
                                        }
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

                    local failure_file = string.format("%s/%d.json", FAILURES_DIR, tag_id)
                    if not is_seed_mode and not tag_excluded_dynamically then
                        if tag_failures ~= nil then
                            local ff = io.open(failure_file, "w")
                            if ff then
                                ff:write(json.encode(tag_failures))
                                ff:close()
                            end
                        else
                            os.remove(failure_file)
                        end
                    end

                    if is_seed_mode and not tag_excluded_dynamically then
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

                    if not tag_excluded_dynamically then
                        if not tag_passed then
                            print(string.format("  [FAIL] Tag %d", tag_id))
                        elseif is_verbose then
                            print(string.format("  [PASS] Tag %d", tag_id))
                        end
                    end
                end
            end
    end
end

    if not is_worker then
        if tag_idx % 100 == 0 or tag_idx == #tag_ids then
            local mode_str = is_seed_mode and "Seeded" or "Checked"
            print(string.format("  [%s %d / %d tags... elapsed: %.2fs]", mode_str, tag_idx, #tag_ids, os.clock() - start_clock))
        end
    end
end

if is_worker then
    print(string.format("__WORKER_SUMMARY__:%s", json.encode({
        checks = total_checks,
        passed = passed_checks,
        failed = failed_checks,
        excluded = excluded_tags_count,
        missing = missing_snapshots,
        errors = script_errors
    })))
    if failed_checks > 0 then
        os.exit(1)
    else
        os.exit(0)
    end
end

local total_elapsed = os.clock() - start_clock
print("\n==================================================")
print(string.format("Finished in %.2f seconds", total_elapsed))
print(string.format("Checks: %d total, %d passed, %d failed", total_checks, passed_checks, failed_checks))
if excluded_tags_count > 0 then
    print(string.format("Excluded tags: %d (calling PGC.GetOldestCaches / GetFavorites / GetHighestCaches / GetLowestCaches)", excluded_tags_count))
end
if failed_checks > 0 then
    print(string.format("Recorded failure diff details in: %s", FAILURES_DIR))
    print("Run 'python3 scripts/viewer.py' to inspect the regression diffs interactively.")
end
if missing_snapshots > 0 then
    print(string.format("Missing snapshots: %d (run with --seed to generate)", missing_snapshots))
end
print("==================================================")

if failed_checks > 0 then
    os.exit(1)
end
