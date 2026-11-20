-- pgc_mock.lua
-- Emulates the Project-GC LuaSandbox environment and Date class for offline regression tests.

local json = require("lib.json")

local mock = {}

-- Load profile data from JSON
function mock.load_profile(username, profile_dir)
    profile_dir = profile_dir or "/home/bmuzzin/geocaching/PGC-Checker-Tests/data/profiles"
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
    json_data_dir = json_data_dir or "/home/bmuzzin/geocaching/PGC-ChallengeCheckers/json-data"
    profile_finds = profile_finds or {}

    -- -----------------------------------------------------------------------
    -- Date Object
    -- -----------------------------------------------------------------------
    -- make_date_obj(t) creates a Date object from a Unix timestamp.
    -- The object exposes:
    --   .tab          -> { year, month, day }
    --   :year([y])    -> getter (no arg) or mutator (sets year, returns self)
    --   :month([m])   -> getter (no arg) or mutator (sets month, returns self)
    --   :last_day()   -> returns a NEW Date object for the last day of the
    --                     object's month/year. .tab.day == last day number.
    --   :yday()       -> day of year (integer)
    --   :month_name([short])  -> full or abbreviated month name
    --   :weekday_name([short]) -> full or abbreviated weekday name
    -- -----------------------------------------------------------------------
    local function make_date_obj(t)
        t = t or os.time()
        local obj = {}
        obj.time = t
        local function refresh()
            obj.tab = {
                year  = tonumber(os.date("%Y", obj.time)),
                month = tonumber(os.date("%m", obj.time)),
                day   = tonumber(os.date("%d", obj.time)),
                hour  = tonumber(os.date("%H", obj.time)),
                min   = tonumber(os.date("%M", obj.time)),
                sec   = tonumber(os.date("%S", obj.time)),
            }
        end
        refresh()

        function obj:year(y)
            if y == nil then return self.tab.year end
            self.tab.year = tonumber(y)
            self.time = os.time({year=self.tab.year, month=self.tab.month, day=self.tab.day, hour=self.tab.hour or 12, min=self.tab.min or 0, sec=self.tab.sec or 0})
            refresh()
            return self
        end

        function obj:month(m)
            if m == nil then return self.tab.month end
            self.tab.month = tonumber(m)
            -- clamp day to valid range for the new month
            local function days_in(yr, mo)
                local d = {31,28,31,30,31,30,31,31,30,31,30,31}
                local n = d[mo] or 30
                if mo == 2 and ((yr%4==0 and yr%100~=0) or yr%400==0) then n=29 end
                return n
            end
            local max_day = days_in(self.tab.year, self.tab.month)
            if self.tab.day > max_day then self.tab.day = max_day end
            self.time = os.time({year=self.tab.year, month=self.tab.month, day=self.tab.day, hour=self.tab.hour or 12, min=self.tab.min or 0, sec=self.tab.sec or 0})
            refresh()
            return self
        end

        function obj:day(d)
            if d == nil then return self.tab.day end
            self.tab.day = tonumber(d)
            self.time = os.time({year=self.tab.year, month=self.tab.month, day=self.tab.day, hour=self.tab.hour or 12, min=self.tab.min or 0, sec=self.tab.sec or 0})
            refresh()
            return self
        end

        function obj:add(delta)
            if type(delta) == "table" then
                local y = self.tab.year + (delta.year or 0)
                local m = self.tab.month + (delta.month or 0)
                local d = self.tab.day + (delta.day or 0)
                local h = (self.tab.hour or 12) + (delta.hour or 0)
                local mi = (self.tab.min or 0) + (delta.min or 0)
                local s = (self.tab.sec or 0) + (delta.sec or 0)
                self.time = os.time({year=y, month=m, day=d, hour=h, min=mi, sec=s})
                refresh()
            end
            return self
        end

        function obj:last_day()
            local y = self.tab.year
            local m = self.tab.month
            local days_in_month = {31,28,31,30,31,30,31,31,30,31,30,31}
            local is_leap = (y%4==0 and y%100~=0) or (y%400==0)
            local last = days_in_month[m]
            if m == 2 and is_leap then last = 29 end
            local t_last = os.time({year=y, month=m, day=last, hour=12})
            return make_date_obj(t_last)
        end

        function obj:yday()
            return tonumber(os.date("%j", self.time))
        end

        function obj:month_name(short)
            local names = {"January","February","March","April","May","June","July","August","September","October","November","December"}
            local short_names = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
            return short and short_names[self.tab.month] or names[self.tab.month]
        end

        function obj:weekday_name(short)
            local wnames = {"Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"}
            local short_wnames = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"}
            local w = tonumber(os.date("%w", self.time)) + 1
            return short and short_wnames[w] or wnames[w]
        end

        return obj
    end

    -- -----------------------------------------------------------------------
    -- Global Date table
    -- -----------------------------------------------------------------------
    _G.Date = {}

    -- Date.Format(fmt) returns a "formatter" object whose :parse(str) method
    -- converts an ISO date string to a Date object.
    _G.Date.Format = function(fmt)
        local formatter = {}
        function formatter:parse(str)
            if not str then return make_date_obj(os.time()) end
            local y, m, d = tostring(str):match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
            y = tonumber(y) or 2026
            m = tonumber(m) or 1
            d = tonumber(d) or 1
            local h = tonumber(tostring(str):match("(%d%d):%d%d") or 12)
            local mi = tonumber(tostring(str):match("%d%d:(%d%d)") or 0)
            local t = os.time({year=y, month=m, day=d, hour=h, min=mi})
            return make_date_obj(t)
        end
        function formatter:tostring(dt)
            local t2 = type(dt)=="table" and dt.time or (tonumber(dt) or os.time())
            return os.date("%Y-%m-%d", t2)
        end
        return formatter
    end

    -- Date(arg) constructor – called as a function. Accepts:
    --   Date()          -> now
    --   Date(timestamp) -> from Unix time
    --   Date(dateobj)   -> passthrough (returns a copy / same obj)
    setmetatable(_G.Date, {
        __call = function(self, arg)
            if type(arg) == "table" and arg.time then
                -- Make a fresh copy so mutations don't alias
                return make_date_obj(arg.time)
            elseif type(arg) == "number" then
                return make_date_obj(arg)
            end
            return make_date_obj(os.time())
        end
    })

    -- -----------------------------------------------------------------------
    -- PGC API
    -- -----------------------------------------------------------------------
    _G.PGC = {}
    _G.PGC.print = function(...) end
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
        local f = io.open(json_data_dir .. "/" .. filename, "r")
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

    _G.PGC.GetFavorites = function(ftype, opts) return filter_top_caches(opts) end
    _G.PGC.GetHighestCaches = function(opts) return filter_top_caches(opts) end
    _G.PGC.GetLowestCaches = function(opts) return filter_top_caches(opts) end
    _G.PGC.GetOldestCaches = function(opts) return filter_top_caches(opts) end
    _G.PGC.GetPublishers                = function(...) return {}  end
    _G.PGC.GetFurthestFound             = function(...) return {}  end
    _G.PGC.GetLonelyFinds               = function(...) return {}  end
end

return mock
