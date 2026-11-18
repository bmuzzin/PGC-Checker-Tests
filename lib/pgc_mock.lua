-- pgc_mock.lua
-- Emulates the Project-GC LuaSandbox environment and Date class for offline regression tests.

local mock = {}

-- Load profile data from JSON
function mock.load_profile(username, profile_dir)
    profile_dir = profile_dir or "/home/bmuzzin/geocaching/PGC-Checker-Tests/data/profiles"
    local file_path = profile_dir .. "/" .. username .. ".json"
    local f = io.open(file_path, "r")
    if not f then
        -- fallback empty
        return {}
    end
    local content = f:read("*a")
    f:close()

    -- Basic lightweight JSON parser for arrays of cache objects
    return mock.parse_json_array(content)
end

function mock.parse_json_array(json_str)
    -- If python/cjson is available or simple lua JSON
    -- We can use a quick helper or lua string parsing
    local items = {}
    for obj_str in json_str:gmatch("%b{}") do
        local obj = {}
        for k, v in obj_str:gmatch('"([%w_]+)"%s*:%s*([^,}]+)') do
            v = v:match('^%s*(.-)%s*$')
            if v:sub(1,1) == '"' and v:sub(-1,-1) == '"' then
                obj[k] = v:sub(2, -2):gsub('\\"', '"'):gsub('\\\\', '\\')
            elseif v == "true" then
                obj[k] = true
            elseif v == "false" then
                obj[k] = false
            elseif tonumber(v) then
                obj[k] = tonumber(v)
            end
        end
        -- Parse array fields like attributes_set / attributes_unset
        local attrs_set = obj_str:match('"attributes_set"%s*:%s*%[([^%]]*)%]')
        if attrs_set then
            obj.attributes_set = {}
            for num in attrs_set:gmatch("%d+") do
                table.insert(obj.attributes_set, tonumber(num))
            end
        else
            obj.attributes_set = {}
        end

        local attrs_unset = obj_str:match('"attributes_unset"%s*:%s*%[([^%]]*)%]')
        if attrs_unset then
            obj.attributes_unset = {}
            for num in attrs_unset:gmatch("%d+") do
                table.insert(obj.attributes_unset, tonumber(num))
            end
        else
            obj.attributes_unset = {}
        end

        table.insert(items, obj)
    end
    return items
end

function mock.init_env(username, profile_id, profile_finds, json_data_dir)
    json_data_dir = json_data_dir or "/home/bmuzzin/geocaching/PGC-ChallengeCheckers/json-data"
    profile_finds = profile_finds or {}

    -- Mock Date Object
    _G.Date = {}
    local DateMeta = {}
    DateMeta.__index = DateMeta

    function DateMeta:parse(str)
        local y, m, d = str:match("(%d%d%d%d)-(%d%d)-(%d%d)")
        y, m, d = tonumber(y) or 2026, tonumber(m) or 1, tonumber(d) or 1
        local t = os.time({year=y, month=m, day=d, hour=12})
        local obj = {
            time = t,
            tab = {year=y, month=m, day=d}
        }
        function obj:month_name(short)
            local names = {"January","February","March","April","May","June","July","August","September","October","November","December"}
            local short_names = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
            return short and short_names[m] or names[m]
        end
        function obj:weekday_name(short)
            local wnames = {"Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"}
            local short_wnames = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"}
            local w = tonumber(os.date("%w", t)) + 1
            return short and short_wnames[w] or wnames[w]
        end
        function obj:yday()
            return tonumber(os.date("%j", t))
        end
        function obj:year()
            return y
        end
        function obj:last_day()
            local days_in_month = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
            local is_leap = (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
            local last = days_in_month[m]
            if m == 2 and is_leap then last = 29 end
            return {
                time = os.time({year=y, month=m, day=last, hour=12}),
                tab = {year=y, month=m, day=last}
            }
        end
        return obj
    end

    function DateMeta:tostring(dt)
        local t = type(dt) == "table" and dt.time or (tonumber(dt) or os.time())
        return os.date("%Y-%m-%d", t)
    end

    setmetatable(_G.Date, {
        __call = function(self, arg)
            if type(arg) == "table" and arg.time then
                return arg
            elseif type(arg) == "number" then
                local y = tonumber(os.date("%Y", arg))
                local m = tonumber(os.date("%m", arg))
                local d = tonumber(os.date("%d", arg))
                return { time = arg, tab = {year=y, month=m, day=d} }
            end
            local t = os.time()
            local y = tonumber(os.date("%Y", t))
            local m = tonumber(os.date("%m", t))
            local d = tonumber(os.date("%d", t))
            return { time = t, tab = {year=y, month=m, day=d} }
        end
    })

    _G.Date.Format = function(fmt)
        local f = {}
        setmetatable(f, DateMeta)
        return f
    end

    -- Mock PGC API
    _G.PGC = {}
    _G.PGC.print = function(...) end
    _G.PGC.Log = function(...) end

    _G.PGC.Icon = {
        GeocacheType = function(t) return "[TYPE:" .. tostring(t) .. "]" end,
        GeocacheSize = function(s) return "[SIZE:" .. tostring(s) .. "]" end,
        CountryFlag = function(c) return "[FLAG:" .. tostring(c) .. "]" end,
        Attribute = function(n, y) return "[ATTR:" .. tostring(n) .. ":" .. tostring(y) .. "]" end,
        Stop = function() return "[STOP]" end,
        Check = function() return "[OK]" end
    }

    _G.PGC.GetAttributeList = function()
        return {
            {id=1, name="Dogs"}, {id=2, name="Access or parking fee"}, {id=3, name="Climbing gear"},
            {id=4, name="Boat"}, {id=5, name="Scuba gear"}, {id=6, name="Recommended for kids"}
        }
    end

    _G.PGC.DistanceHaversine = function(lat1, lon1, lat2, lon2)
        lat1, lon1, lat2, lon2 = tonumber(lat1) or 0, tonumber(lon1) or 0, tonumber(lat2) or 0, tonumber(lon2) or 0
        local dlat = math.rad(lat2 - lat1)
        local dlon = math.rad(lon2 - lon1)
        local a = math.sin(dlat/2)^2 + math.cos(math.rad(lat1)) * math.cos(math.rad(lat2)) * math.sin(dlon/2)^2
        local c = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
        return 6371000 * c
    end

    _G.PGC.DistanceVincenty = _G.PGC.DistanceHaversine

    _G.PGC.ProfileId2Name = function(id)
        if tostring(id) == tostring(profile_id) then return username end
        return "User_" .. tostring(id)
    end

    _G.PGC.GetFinds = function(pid, query)
        local result = {}
        local filter = query and query.filter or {}
        local fields = query and query.fields

        for _, cache in ipairs(profile_finds) do
            local match = true
            if filter.country and cache.country ~= filter.country then match = false end
            if filter.types and #filter.types > 0 then
                local found_type = false
                for _, t in ipairs(filter.types) do
                    if cache.type == t then found_type = true; break end
                end
                if not found_type then match = false end
            end
            if match then
                -- shallow copy cache
                local item = {}
                for k, v in pairs(cache) do item[k] = v end
                table.insert(result, item)
            end
        end
        return result
    end

    _G.PGC.GetHides = function(pid, query)
        return {}
    end

    _G.PGC.GetJsonData = function(filename)
        local f = io.open(json_data_dir .. "/" .. filename, "r")
        if not f then return {} end
        local content = f:read("*a")
        f:close()
        -- rudimentary JSON or load
        return {}
    end

    _G.PGC.UTF8SubStr = function(str, s, l)
        return string.sub(str, s, l and (s + l - 1) or -1)
    end

    _G.PGC.UTF8ToLower = function(str) return string.lower(str) end
    _G.PGC.UTF8ToUpper = function(str) return string.upper(str) end

    _G.PGC.GetNumberOfCountiesInRegion = function(...) return 10 end
    _G.PGC.GetNumberOfRegionsInCountry = function(...) return 10 end
    _G.PGC.GetNumberOfCountiesInCountry = function(...) return 100 end
    _G.PGC.GetSouvenirs = function(...) return {} end
    _G.PGC.GetNumTrackablesDiscovered = function(...) return 0 end
    _G.PGC.GetBookmarklist = function(...) return {} end
    _G.PGC.GetFavorites = function(...) return {} end
    _G.PGC.GetHighestCaches = function(...) return {} end
    _G.PGC.GetLowestCaches = function(...) return {} end
    _G.PGC.GetOldestCaches = function(...) return {} end
    _G.PGC.GetPublishers = function(...) return {} end
    _G.PGC.GetFurthestFound = function(...) return {} end
    _G.PGC.GetLonelyFinds = function(...) return {} end
end

return mock
