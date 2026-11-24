-- check_compatibility.lua
-- Fast batch tester to determine if challenge tags are compatible with 9976.lua.

local src_path = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local script_dir = src_path:match("(.*)/") or "."
local root_dir = script_dir:match("(.*)/tests$") or script_dir:match("(.*)/scripts$") or "."
local parent_dir = root_dir:match("(.*)/[^/]+$") or (root_dir .. "/..")
local checkers_dir = parent_dir .. "/PGC-ChallengeCheckers"

package.path = root_dir .. "/?.lua;" .. root_dir .. "/lib/?.lua;" .. root_dir .. "/?/init.lua;" .. package.path

local json = require("lib.json")
local pgc_mock = require("lib.pgc_mock")

-- Parse CLI arguments
local args = {...}
local input_file = nil
local use_stdin = false
local tag_ids = {}

local i = 1
while i <= #args do
    local a = args[i]
    if a == "--stdin" then
        use_stdin = true
    elseif a == "--file" or a == "-f" then
        i = i + 1
        input_file = args[i]
    elseif a == "--checkers-dir" then
        i = i + 1
        checkers_dir = args[i]
    elseif tonumber(a) then
        table.insert(tag_ids, tonumber(a))
    end
    i = i + 1
end

if input_file then
    local f = io.open(input_file, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(json.decode, content)
        if ok and type(data) == "table" then
            for _, id in ipairs(data) do
                if tonumber(id) then table.insert(tag_ids, tonumber(id)) end
            end
        end
    end
elseif use_stdin then
    local content = io.read("*a")
    if content and not content:match("^%s*$") then
        local ok, data = pcall(json.decode, content)
        if ok and type(data) == "table" then
            for _, id in ipairs(data) do
                if tonumber(id) then table.insert(tag_ids, tonumber(id)) end
            end
        end
    end
end

local SCRIPT_PATH = checkers_dir .. "/scripts/009000-009999/9976.lua"
if package.config:sub(1,1) == '\\' then
    SCRIPT_PATH = SCRIPT_PATH:gsub('/', '\\')
end

local script_fn, compile_err = loadfile(SCRIPT_PATH)
if not script_fn then
    io.stderr:write("[-] Fatal: failed to compile " .. SCRIPT_PATH .. ": " .. tostring(compile_err) .. "\n")
    os.exit(1)
end

-- Preload test profiles
local empty_finds = pgc_mock.load_profile("empty", root_dir .. "/data/profiles")
local bmuzzin_finds = pgc_mock.load_profile("bmuzzin", root_dir .. "/data/profiles")

local function get_tag_path(tag_id)
    local start = math.floor(tag_id / 1000) * 1000
    local end_num = start + 999
    local subdir = string.format("%08d-%08d", start, end_num)
    return string.format("%s/tags/%s/%d.json", checkers_dir, subdir, tag_id)
end

local function clean_error(err_str)
    if not err_str then return "unknown error" end
    err_str = tostring(err_str)
    -- Remove local file paths from error messages for clean reporting
    err_str = err_str:gsub("^.-%d+%.lua:%d+:%s*", "")
    err_str = err_str:gsub("%s+", " ")
    return err_str
end

local TIMEOUT_SECONDS = 60
local function pcall_with_timeout(fn, ...)
    local p_args = {...}
    local start_cpu = os.clock()
    local start_wall = os.time()
    debug.sethook(function()
        if (os.clock() - start_cpu >= TIMEOUT_SECONDS) or (os.time() - start_wall > TIMEOUT_SECONDS) then
            error(string.format("Timed out after %d seconds", TIMEOUT_SECONDS))
        end
    end, "", 10000)

    local status, res = pcall(fn, unpack(p_args))
    debug.sethook()
    return status, res
end

local compatible_tags = {}
local incompatible_tags = {}

for _, tid in ipairs(tag_ids) do
    local tag_path = get_tag_path(tid)
    local tf = io.open(tag_path, "r")
    if not tf then
        incompatible_tags[tostring(tid)] = "file not found"
    else
        local content = tf:read("*a")
        tf:close()
        if not content or content:match("^%s*$") then
            incompatible_tags[tostring(tid)] = "empty file"
        else
            local ok_parse, tag_config = pcall(json.decode, content)
            if not ok_parse or type(tag_config) ~= "table" then
                incompatible_tags[tostring(tid)] = "invalid JSON"
            elseif not tag_config.func and not tag_config.default_func then
                incompatible_tags[tostring(tid)] = "missing 'func' or 'default_func'"
            else
                -- 1. Test against empty profile
                pgc_mock.init_env("empty", 1000, empty_finds, checkers_dir .. "/json-data")
                pgc_mock.set_debug_output(false)
                pgc_mock.reset_unsupported()

                local run_args1 = {
                    {
                        config = tag_config,
                        profileName = "empty",
                        profileId = 1000,
                        environmentSettings = { token = "compat-test-token" }
                    }
                }
                local ok1, res1 = pcall_with_timeout(script_fn, unpack(run_args1))
                if not ok1 then
                    incompatible_tags[tostring(tid)] = clean_error(res1)
                else
                    -- 2. Test against bmuzzin profile
                    pgc_mock.init_env("bmuzzin", 680953, bmuzzin_finds, checkers_dir .. "/json-data")
                    pgc_mock.set_debug_output(false)
                    pgc_mock.reset_unsupported()

                    -- Re-parse tag_config fresh to avoid mutations from run 1
                    local _, fresh_config = pcall(json.decode, content)
                    local run_args2 = {
                        {
                            config = fresh_config or tag_config,
                            profileName = "bmuzzin",
                            profileId = 680953,
                            environmentSettings = { token = "compat-test-token" }
                        }
                    }
                    local ok2, res2 = pcall_with_timeout(script_fn, unpack(run_args2))
                    if not ok2 then
                        incompatible_tags[tostring(tid)] = clean_error(res2)
                    else
                        table.insert(compatible_tags, tid)
                    end
                end
            end
        end
    end
end

local output_result = {
    compatible = compatible_tags,
    incompatible = incompatible_tags
}

io.write(json.encode(output_result))
