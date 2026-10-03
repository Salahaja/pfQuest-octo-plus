--[[ test_bundle.lua -- does this addon work on its own?

     Run from the AddOns directory, with pfQuest installed beside it:
       lua pfQuest-octo-plus/tools/test_bundle.lua

     The other test (test_inject.lua) covers the pieces. This one covers the
     claim the package makes: that pfQuest plus THIS, and nothing else, gives
     you the Octo database, the quests pfQuest-octo is missing, and Moonwhisper
     Coast as a map you can see pins on.

     Everything is loaded in exactly the order the .toc lists it, because that
     order is the whole design: the additions patch tables that patchtable.lua
     has just finished merging, and running them a moment earlier would patch
     tables that are about to be replaced. ]]

local failures, checks = 0, 0
local function check(label, got, want)
  checks = checks + 1
  if got ~= want then
    failures = failures + 1
    print("  FAIL " .. label .. ": got " .. tostring(got) ..
      ", wanted " .. tostring(want))
  end
end

local function size(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

-- ------------------------------------------------------------------ stubs
-- 1.12 has table.getn and no "#"; this desktop Lua is the reverse. Shimmed so
-- the addon stays correct for the client it actually runs on.
table.getn = table.getn or function(t) return #t end

GetLocale = function() return "enUS" end
GetMapZones = function() return "Desolace", "Winterspring" end
GetRealZoneText = function() return "Moonwhisper Coast" end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
SlashCmdList = {}
IsAddOnLoaded = function() return nil end        -- nothing conflicting
IsInInstance = function() return nil end
GetCurrentMapContinent = function() return 1 end
CreateFrame = function()
  return setmetatable({}, { __index = function() return function() end end })
end

local HERE = "pfQuest-octo-plus/"

pfDB = {}
for _, k in ipairs({ "areatrigger", "items", "meta", "minimap", "objects",
                     "professions", "quests", "quests-itemreq", "refloot",
                     "units", "zones" }) do
  pfDB[k] = {}
end

local function run(path, optional)
  local chunk, err = loadfile(path)
  if not chunk then
    if not optional then print("  !! load " .. path .. ": " .. tostring(err)) end
    return false
  end
  local ok, rerr = pcall(chunk)
  if not ok then print("  !! run " .. path .. ": " .. tostring(rerr)) end
  return ok
end

print("\npfQuest-octo-plus: does the package stand on its own?\n")

-- -------------------------------------------------- 1. pfQuest (dependency)
for _, f in ipairs({ "items", "units", "objects", "refloot", "quests-itemreq",
                     "quests", "zones", "minimap", "areatrigger", "meta" }) do
  run("pfQuest/db/" .. f .. ".lua")
end
for _, f in ipairs({ "items", "units", "objects", "quests", "zones",
                     "professions" }) do
  run("pfQuest/db/enUS/" .. f .. ".lua")
end
pfDB.locales = { ["enUS"] = "English" }
for _, k in ipairs({ "quests", "units", "objects", "items", "zones" }) do
  pfDB[k]["loc"] = pfDB[k]["enUS"] or {}
end
pfQuest, pfMap = {}, {}
pfDatabase = { icons = {}, Reload = function() end }

local vanilla = size(pfDB["quests"]["data"])
check("pfQuest's own database loaded", vanilla > 4000, true)
check("and Moonwhisper Coast is NOT a map it knows yet",
  pfDB["zones"]["loc"][5642], nil)

-- ------------------------------------------------------ 2. this addon alone
for _, f in ipairs({ "items", "units", "objects", "refloot",
                     "quests-itemreq", "quests", "zones", "minimap",
                     "areatrigger", "meta" }) do
  run(HERE .. "db/" .. f .. "-turtle.lua")
end
for _, f in ipairs({ "items", "units", "objects", "quests", "zones" }) do
  run(HERE .. "db/enUS/" .. f .. "-turtle.lua")
end
run(HERE .. "db/enUS/professions-turtle.lua", true)
run(HERE .. "overwrites.lua")
run(HERE .. "patchtable.lua")

local withOcto = size(pfDB["quests"]["data"])
check("the Octo database merged in", withOcto > vanilla, true)

for _, f in ipairs({ "data", "enUS", "octo", "octo-enUS" }) do
  run(HERE .. "extra/" .. f .. ".lua")
end
run(HERE .. "extra/inject.lua")

local final = size(pfDB["quests"]["data"])
check("and the additions on top", final > withOcto, true)
print(string.format("  (%d vanilla -> %d with Octo -> %d complete)",
  vanilla, withOcto, final))

-- ------------------------------------------------------------ 3. the claims
check("inject ran", pfQuestOctoExtra.applied, true)
check("no conflict reported when nothing else is loaded",
  size(pfQuestOctoExtra.conflicts), 0)

--[[ The three things this package exists to provide, each checked the way the
     game would arrive at it rather than by reading the table it came from. ]]

-- (a) the quests pfQuest-octo is missing
check("a quest only pfQuest-turtle had is present",
  pfDB["quests"]["data"][41310] ~= nil, true)
check("with its title",
  pfDB["quests"]["loc"][41310] and pfDB["quests"]["loc"][41310].T,
  "Clutch of Thanlar")

-- (b) Moonwhisper's quests, which no published database has
check("a Moonwhisper quest is present", pfDB["quests"]["data"][42079] ~= nil, true)
check("with its title",
  pfDB["quests"]["loc"][42079] and pfDB["quests"]["loc"][42079].T,
  "Secrets of Moonwhisper")

-- (c) Moonwhisper as a MAP -- pfMap:GetMapIDByName, verbatim
local function getMapIDByName(search)
  for id, name in pairs(pfDB["zones"]["loc"]) do
    if name == search then return id end
  end
end
check("Moonwhisper Coast resolves to a map id",
  getMapIDByName("Moonwhisper Coast"), 5642)
check("and Winterspring still does too", getMapIDByName("Winterspring"), 618)
check("the map has minimap dimensions",
  pfDB["minimap"][5642] ~= nil, true)

local mwNodes = 0
for _, u in pairs(pfDB["units"]["data"]) do
  for _, c in pairs(u.coords or {}) do
    if c[3] == 5642 then mwNodes = mwNodes + 1 end
  end
end
check("and nodes to draw on it", mwNodes >= 20, true)

--[[ Coordinate width. Three values instead of four throws inside pfQuest's
     map node loop and blanks the entire map, not just this zone. ]]
local badCoords = 0
for _, kind in ipairs({ "units", "objects" }) do
  for _, e in pairs(pfDB[kind]["data"]) do
    for _, c in pairs(e.coords or {}) do
      if size(c) ~= 4 or type(c[4]) ~= "number" then badCoords = badCoords + 1 end
    end
  end
end
check("every coordinate in the merged database is four values wide", badCoords, 0)

-- ------------------------------------------------------- 4. the conflict check
--[[ Silent data loss is the failure mode here: two databases assigning the
     same tables, last one wins, nothing errors. The warning is the only thing
     between a user and counts that are quietly from the wrong server. ]]
IsAddOnLoaded = function(name) return name == "pfQuest-turtle" and 1 or nil end
-- inject.lua frees the generated tables once they are in memory, on purpose,
-- so they have to be put back before it can run a second time.
for _, f in ipairs({ "data", "enUS", "octo", "octo-enUS" }) do
  run(HERE .. "extra/" .. f .. ".lua")
end
pfQuestOctoExtra.applied = nil
run(HERE .. "extra/inject.lua")
check("a conflicting database is noticed",
  size(pfQuestOctoExtra.conflicts), 1)
check("and named", pfQuestOctoExtra.conflicts[1], "pfQuest-turtle")

print(string.format("\n%d checks, %d failed\n", checks, failures))
if failures > 0 then os.exit(1) end
