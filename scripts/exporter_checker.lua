-- Helper script for Project-GC to dump finds for profile as JSON.
-- Run this in Project-GC Challenge Checker test tool for a given profile.
local args = {...}
local profileId = args[1].profileId
local profileName = args[1].profileName

-- Fetch all finds with relevant fields
local finds = PGC.GetFinds(profileId, {
    fields = {
        'cache_id', 'gccode', 'cache_name', 'visitdate', 'type', 'size',
        'difficulty', 'terrain', 'country', 'region', 'county',
        'latitude', 'longitude', 'elevation', 'favorite_points',
        'hidden', 'owner_id', 'attributes_set', 'attributes_unset'
    },
    order = "OLDESTFIRST"
})

-- Format finds as JSON
local items = {}
for _, f in ipairs(finds) do
    local set_attrs = table.concat(f.attributes_set or {}, ",")
    local unset_attrs = table.concat(f.attributes_unset or {}, ",")
    local name = (f.cache_name or ""):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', ' ')
    local item = string.format(
        '{"cache_id":%s,"gccode":"%s","cache_name":"%s","visitdate":"%s","type":"%s","size":"%s","difficulty":%s,"terrain":%s,"country":"%s","region":"%s","county":"%s","latitude":%s,"longitude":%s,"elevation":%s,"favorite_points":%s,"hidden":"%s","owner_id":%s,"attributes_set":[%s],"attributes_unset":[%s]}',
        tostring(f.cache_id or 0), f.gccode or "", name, f.visitdate or "", f.type or "", f.size or "",
        tostring(f.difficulty or 1), tostring(f.terrain or 1),
        (f.country or ""):gsub('"', '\\"'), (f.region or ""):gsub('"', '\\"'), (f.county or ""):gsub('"', '\\"'),
        tostring(f.latitude or 0), tostring(f.longitude or 0), tostring(f.elevation or 0),
        tostring(f.favorite_points or 0), f.hidden or "", tostring(f.owner_id or 0),
        set_attrs, unset_attrs
    )
    table.insert(items, item)
end

local json_payload = "[" .. table.concat(items, ",\n") .. "]"

return {
    ok = true,
    log = "FIND_COUNT:" .. #finds,
    html = "<pre id='profile-data-json'>" .. json_payload .. "</pre>"
}
