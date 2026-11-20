-- pgc_mock.lua
-- Emulates the Project-GC LuaSandbox environment and Date class for offline regression tests.

local json = require("lib.json")
local Date = require("pl.Date")

local mock = {}

-- Functions that call unsupported top/ranking PGC stubs
mock.EXCLUDED_FUNCS = {
    ["oldest"] = "PGC.GetOldestCaches",
    ["oldest_fizzy"] = "PGC.GetOldestCaches",
    ["oldest_calendar"] = "PGC.GetOldestCaches",
    ["topfav"] = "PGC.GetFavorites",
    ["topfav_fizzy"] = "PGC.GetFavorites",
    ["topfav_calendar"] = "PGC.GetFavorites",
    ["top_elevation"] = "PGC.GetHighestCaches / PGC.GetLowestCaches",
    ["top_elevation_fizzy"] = "PGC.GetHighestCaches / PGC.GetLowestCaches",
    ["top_elevation_calendar"] = "PGC.GetHighestCaches / PGC.GetLowestCaches",
    ["remote"] = "PGC.GetFavorites",
}

-- Recursively check if a configuration uses any excluded functions
function mock.check_excluded_config(conf)
    if type(conf) ~= "table" then return nil end
    if type(conf.func) == "string" and mock.EXCLUDED_FUNCS[conf.func] then
        return conf.func, mock.EXCLUDED_FUNCS[conf.func]
    end
    if type(conf.default_func) == "string" and mock.EXCLUDED_FUNCS[conf.default_func] then
        return conf.default_func, mock.EXCLUDED_FUNCS[conf.default_func]
    end
    for _, v in pairs(conf) do
        if type(v) == "table" then
            local f, m = mock.check_excluded_config(v)
            if f then return f, m end
        end
    end
    return nil
end

mock.debug_enabled = false

function mock.set_debug_output(enable)
    mock.debug_enabled = (enable == true)
end

mock.unsupported_called = false
mock.unsupported_func = nil

function mock.reset_unsupported()
    mock.unsupported_called = false
    mock.unsupported_func = nil
end

function mock.get_unsupported_call()
    return mock.unsupported_called, mock.unsupported_func
end

-- Resolve default paths dynamically relative to lib/
local src_path = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local lib_dir = src_path:match("(.*)/") or "."
local default_root = lib_dir:match("(.*)/lib$") or "."
local default_parent = default_root:match("(.*)/[^/]+$") or (default_root .. "/..")

-- Load profile data from JSON
function mock.load_profile(username, profile_dir)
    profile_dir = profile_dir or (default_root .. "/data/profiles")
    local file_path = profile_dir .. "/" .. username .. ".json"
    local f = io.open(file_path, "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()
    if not content or content:match("^%s*$") then
        return {}
    end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

function mock.init_env(username, profile_id, profile_finds, json_data_dir)
    json_data_dir = json_data_dir or (default_parent .. "/PGC-ChallengeCheckers/json-data")
    profile_finds = profile_finds or {}

    -- -----------------------------------------------------------------------
    -- Date Object (Penlight library: pl.Date)
    -- -----------------------------------------------------------------------
    _G.Date = Date

    -- -----------------------------------------------------------------------
    -- PGC API
    -- -----------------------------------------------------------------------
    _G.PGC = {}
    _G.PGC.print = function(...)
        if not mock.debug_enabled then return end
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            io.stdout:write(tostring(v))
        end
        io.stdout:flush()
    end
    _G.PGC.Log   = function(...) end

    _G.PGC.Icon = {
        GeocacheType = function(t) return "[TYPE:" .. tostring(t) .. "]" end,
        GeocacheSize = function(s) return "[SIZE:" .. tostring(s) .. "]" end,
        CountryFlag  = function(c) return "[FLAG:" .. tostring(c) .. "]" end,
        Attribute    = function(n, y) return "[ATTR:" .. tostring(n) .. ":" .. tostring(y) .. "]" end,
        Stop  = function() return "[STOP]" end,
        Check = function() return "[OK]" end,
    }

    -- Full attribute list (IDs 1-66) with the imageSet / imageUnset fields
    -- that some tags read via attributes[n].imageSet / .imageUnset.
    local attr_names = {
        [1]="Dogs",[2]="Access or parking fee",[3]="Climbing gear",[4]="Boat",
        [5]="Scuba gear",[6]="Recommended for kids",[7]="Takes less than an hour",
        [8]="Scenic view",[9]="Significant Hike",[10]="Difficult climbing",
        [11]="May require wading",[12]="May require swimming",[13]="Available at all times",
        [14]="Recommended at night",[15]="Available during winter",[16]="Cactus",
        [17]="Poison plants",[18]="Dangerous animals",[19]="Ticks",[20]="Abandoned mines",
        [21]="Cliff / falling rocks",[22]="Hunting",[23]="Dangerous area",
        [24]="Wheelchair accessible",[25]="Parking available",[26]="Public transportation",
        [27]="Drinking water nearby",[28]="Public restrooms nearby",[29]="Telephone nearby",
        [30]="Picnic tables nearby",[31]="Camping nearby",[32]="Bicycles",[33]="Motorcycles",
        [34]="Quads",[35]="Off-road vehicles",[36]="Snowmobiles",[37]="Horses",
        [38]="Campfires",[39]="Thorns",[40]="Stealth required",[41]="Stroller accessible",
        [42]="Needs maintenance",[43]="Watch for livestock",[44]="Flashlight required",
        [45]="Lost And Found Tour",[46]="Truck Driver/RV",[47]="Field Puzzle",
        [48]="UV light required",[49]="Snowshoes",[50]="Cross country skis",
        [51]="Special tool required",[52]="Night cache",[53]="Park and Grab",
        [54]="Abandoned structure",[55]="Short hike (less than 1km)",[56]="Medium hike (1km-10km)",
        [57]="Long hike (+10km)",[58]="Fuel Nearby",[59]="Food Nearby",
        [60]="Wireless Beacon",[61]="Partnership cache",[62]="Seasonal Access",
        [63]="Tourist Friendly",[64]="Tree Climbing",[65]="Geocaching.com Block Party",
        [66]="Night Cache",
    }
    local attr_table = {}
    for id = 1, 150 do
        local name = attr_names[id] or ("Attribute " .. id)
        local item = {
            id = id,
            name = name,
            attributeName = name,
            imageSet = "[ATTR:" .. id .. ":yes]",
            imageUnset = "[ATTR:" .. id .. ":no]",
        }
        attr_table[id] = item
    end
    _G.PGC.GetAttributeList = function() return attr_table end

    _G.PGC.DistanceHaversine = function(lat1, lon1, lat2, lon2)
        lat1,lon1,lat2,lon2 = tonumber(lat1) or 0, tonumber(lon1) or 0, tonumber(lat2) or 0, tonumber(lon2) or 0
        local dlat = math.rad(lat2-lat1)
        local dlon = math.rad(lon2-lon1)
        local a = math.sin(dlat/2)^2 + math.cos(math.rad(lat1))*math.cos(math.rad(lat2))*math.sin(dlon/2)^2
        local c = 2*math.atan2(math.sqrt(a), math.sqrt(1-a))
        return 6371000*c
    end
    _G.PGC.DistanceVincenty = _G.PGC.DistanceHaversine

    _G.PGC.ProfileId2Name = function(id)
        if tostring(id) == tostring(profile_id) then return username end
        return "User_" .. tostring(id)
    end

    -- GetFinds – filter profile_finds according to the query
    _G.PGC.GetFinds = function(pid, query)
        local result = {}
        local filter = (query and query.filter) or {}

        local function check_field(filter_val, cache_val)
            if filter_val == nil then return true end
            if type(filter_val) == "table" then
                if filter_val[cache_val] ~= nil then return true end
                for _, v in ipairs(filter_val) do
                    if v == cache_val then return true end
                end
                return false
            else
                return filter_val == cache_val
            end
        end

        for _, cache in ipairs(profile_finds) do
            local match = true
            if not check_field(filter.country,     cache.country)     then match = false end
            if not check_field(filter.region,      cache.region)      then match = false end
            if not check_field(filter.county,      cache.county)      then match = false end
            if not check_field(filter.types,       cache.type)        then match = false end
            if not check_field(filter.sizes,       cache.size)        then match = false end
            if not check_field(filter.difficulties,cache.difficulty)  then match = false end
            if not check_field(filter.terrains,    cache.terrain)     then match = false end

            if filter.minVisitDate and cache.visitdate and cache.visitdate < filter.minVisitDate then match = false end
            if filter.maxVisitDate and cache.visitdate and cache.visitdate > filter.maxVisitDate then match = false end
            if filter.minHiddenDate and cache.hidden   and cache.hidden   < filter.minHiddenDate then match = false end
            if filter.maxHiddenDate and cache.hidden   and cache.hidden   > filter.maxHiddenDate then match = false end

            if filter.attributeFilter and type(filter.attributeFilter) == "table" then
                local af      = filter.attributeFilter
                local attr_id = af.opt and af.opt.attribute
                if attr_id then
                    local set_map, unset_map = {}, {}
                    for _, a in ipairs(cache.attributes_set   or {}) do set_map[a]   = true end
                    for _, a in ipairs(cache.attributes_unset or {}) do unset_map[a] = true end
                    if af.func == "set"   and not set_map[attr_id]   then match = false end
                    if af.func == "unset" and not unset_map[attr_id] then match = false end
                end
            end

            if match then
                local item = {}
                for k, v in pairs(cache) do item[k] = v end
                item.log_id = item.log_id or 1
                item.archived = item.archived or 0
                item.last_archive_date = item.last_archive_date or "2099-12-31"
                item.last_publish_date = item.last_publish_date or "2000-01-01"

                -- Populate legacy bitfield representations for c_attributes
                local s1, s2, s3 = 0, 0, 0
                for _, aid in ipairs(cache.attributes_set or {}) do
                    if aid >= 1 and aid <= 32 then
                        s1 = s1 + 2^(aid - 1)
                    elseif aid >= 33 and aid <= 64 then
                        s2 = s2 + 2^(aid - 33)
                    elseif aid >= 65 and aid <= 96 then
                        s3 = s3 + 2^(aid - 65)
                    end
                end
                item.attributes_set_1 = s1
                item.attributes_set_2 = s2
                item.attributes_set_3 = s3

                local u1, u2, u3 = 0, 0, 0
                for _, aid in ipairs(cache.attributes_unset or {}) do
                    if aid >= 1 and aid <= 32 then
                        u1 = u1 + 2^(aid - 1)
                    elseif aid >= 33 and aid <= 64 then
                        u2 = u2 + 2^(aid - 33)
                    elseif aid >= 65 and aid <= 96 then
                        u3 = u3 + 2^(aid - 65)
                    end
                end
                item.attributes_unset_1 = u1
                item.attributes_unset_2 = u2
                item.attributes_unset_3 = u3

                table.insert(result, item)
            end
        end
        return result
    end

    _G.PGC.GetHides = function(pid, query) return {} end

    _G.PGC.GetJsonData = function(filename)
        local f = io.open(json_data_dir .. "/" .. filename, "r") or io.open(json_data_dir .. "/" .. filename .. ".json", "r")
        if not f then return {} end
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(json.decode, content)
        return ok and data or {}
    end

    _G.PGC.UTF8SubStr  = function(str, s, l) return string.sub(str, s, l and (s+l-1) or -1) end
    _G.PGC.UTF8ToLower = function(str) return string.lower(str) end
    _G.PGC.UTF8ToUpper = function(str) return string.upper(str) end

    _G.PGC.GetNumberOfCountiesInRegion  = function(...) return 10  end
    _G.PGC.GetNumberOfRegionsInCountry  = function(...) return 10  end
    _G.PGC.GetNumberOfCountiesInCountry = function(...) return 100 end
    _G.PGC.GetSouvenirs                 = function(...) return {}  end
    _G.PGC.GetNumTrackablesDiscovered   = function(...) return 0   end
    _G.PGC.GetBookmarklist              = function(...) return {}  end
    local stub_caches = {}
    local s_idx = 1
    for m = 1, 12 do
        local days_in_m = ({31,29,31,30,31,30,31,31,30,31,30,31})[m]
        for d = 1, days_in_m do
            local diff = ((s_idx % 9) + 1) * 0.5 + 0.5
            local terr = ((math.floor((s_idx-1) / 9) % 9) + 1) * 0.5 + 0.5
            table.insert(stub_caches, {
                gccode = string.format("GC%05d", s_idx),
                cache_name = "Stub Cache " .. s_idx,
                hidden = string.format("2000-%02d-%02d", m, d),
                difficulty = tostring(diff),
                terrain = tostring(terr),
                elevation = tostring(s_idx * 10),
                favorite_points = s_idx * 5,
                favorite_points_pct = s_idx,
                favorite_points_wilson = s_idx * 0.01,
                archived = 0,
                owner_id = 999999,
                latitude = 45.0 + (s_idx * 0.001),
                longitude = -75.0 + (s_idx * 0.001),
                type = "Traditional Cache",
                country = "Canada",
                region = "Ontario",
            })
            s_idx = s_idx + 1
        end
    end

    local function filter_top_caches(opts)
        local min_h = opts and opts.filter and opts.filter.minHiddenDate
        local out = {}
        for _, c in ipairs(stub_caches) do
            if not min_h or c.hidden >= min_h then
                table.insert(out, c)
            end
        end
        return out
    end

    _G.PGC.GetFavorites = function(ftype, opts)
        mock.unsupported_called = true
        mock.unsupported_func = "PGC.GetFavorites"
        return filter_top_caches(opts)
    end
    _G.PGC.GetHighestCaches = function(opts)
        mock.unsupported_called = true
        mock.unsupported_func = "PGC.GetHighestCaches"
        return filter_top_caches(opts)
    end
    _G.PGC.GetLowestCaches = function(opts)
        mock.unsupported_called = true
        mock.unsupported_func = "PGC.GetLowestCaches"
        return filter_top_caches(opts)
    end
    _G.PGC.GetOldestCaches = function(opts)
        mock.unsupported_called = true
        mock.unsupported_func = "PGC.GetOldestCaches"
        return filter_top_caches(opts)
    end
    _G.PGC.GetPublishers                = function(...) return {}  end
    _G.PGC.GetFurthestFound             = function(...) return {}  end
    _G.PGC.GetLonelyFinds               = function(...) return {}  end
end

return mock
