-- Quest-giver capture. Opening any NPC's gossip or quest window notes, quietly,
-- what the database does not know: an NPC it has no position for (or has
-- somewhere else), a quest offered here that the database does not start
-- here, a quest handed in here that it does not end here. Each find is one
-- line in pfQuestOcto_Finds (SavedVariables), shown in /instq report and read
-- by tools/reports.py, which turns them into corrections the build applies.
-- Standing at an NPC to talk is standing within a few yards of it, so the
-- player's position is the NPC's.

local M = pfQuestOctoMaps
if not M then return end

local NEAR = 3 -- map units: a database spot this close is the same spot

local function say(t) DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccpf|rQuest: " .. t) end
local function fmt(v) return v and string.format("%.1f", v) or "-" end

-- the NPC talked to: name and ids (GUID where SuperWoW gives one)
local function npc()
  if not UnitExists("npc") or UnitIsPlayer("npc") then return nil end
  local name = UnitName("npc")
  if not name then return nil end
  local _, guid = UnitExists("npc")
  local ids = {}
  if type(guid) == "string" and string.len(guid) >= 18 then
    local id = tonumber(string.sub(guid, 7, 12), 16)
    if id and id > 0 then table.insert(ids, id) end
  end
  if not ids[1] then
    for id, n in pairs(pfDB["units"]["loc"]) do
      if n == name then table.insert(ids, id) end
    end
  end
  return name, ids
end

-- where the player stands: zone id and position, nil when the world map is
-- open on another map (moving it would change what someone is looking at)
local function position()
  if WorldMapFrame and WorldMapFrame:IsShown() then return nil end
  SetMapToCurrentZone()
  local x, y = GetPlayerMapPosition("player")
  if not x or x == 0 then return nil end
  local zone = pfMap:GetMapID(GetCurrentMapContinent(), GetCurrentMapZone())
  return zone, x * 100, y * 100
end

-- quest ids with this title, the ones this character could take first
local function questids(title)
  local out = {}
  if not title then return out end
  for id, l in pairs(pfDB["quests"]["loc"]) do
    if type(l) == "table" and l.T == title then table.insert(out, id) end
  end
  table.sort(out)
  return out
end

local function has(list, ids)
  for _, a in pairs(list or {}) do
    for _, b in ipairs(ids) do
      if a == b then return true end
    end
  end
  return false
end

local seen = {}
local function find(line, key, msg)
  if seen[key] then return end
  seen[key] = true
  pfQuestOcto_Finds = pfQuestOcto_Finds or {}
  for _, l in ipairs(pfQuestOcto_Finds) do
    if l == line then return end
  end
  table.insert(pfQuestOcto_Finds, line)
  say(msg .. " (noted for the database; /instq report to share)")
end

-- the NPC itself: unknown, or not where we have it
local function checknpc(name, ids, zone, x, y)
  local placed, far = false, nil
  for _, id in ipairs(ids) do
    local u = pfDB["units"]["data"][id]
    for _, c in pairs(u and u.coords or {}) do
      if c[3] == zone then
        local dx, dy = c[1] - x, c[2] - y
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= NEAR then placed = true end
        far = far and math.min(far, d) or d
      end
    end
  end
  if placed then return end
  local why = not ids[1] and "unknown npc" or (far and string.format("npc %.0f away", far) or "npc not placed here")
  find(string.format("find: %s;%s;%s;%s;%s;npc;;;%s", zone, name, table.concat(ids, ","), fmt(x), fmt(y), why),
    "npc" .. name .. zone, name .. ": " .. why)
end

-- a quest offered here (start) or handed in here (end)
local function checkquest(name, ids, zone, x, y, title, part)
  local qids = questids(title)
  if not qids[1] then
    find(string.format("find: %s;%s;%s;%s;%s;%s;;%s;unknown quest", zone, name, table.concat(ids, ","),
      fmt(x), fmt(y), part, title), part .. title .. name, name .. ": quest \"" .. title .. "\" is not in the database")
    return
  end
  for _, q in ipairs(qids) do
    local p = pfDB["quests"]["data"][q] and pfDB["quests"]["data"][q][part]
    if p and has(p.U, ids) then return end
  end
  find(string.format("find: %s;%s;%s;%s;%s;%s;%s;%s;not the %s here", zone, name, table.concat(ids, ","),
    fmt(x), fmt(y), part, table.concat(qids, ","), title, part == "start" and "giver" or "turn-in"),
    part .. title .. name, name .. ": \"" .. title .. "\" " .. (part == "start" and "starts" or "ends") .. " here")
end

-- GetGossipAvailableQuests/ActiveQuests give title, level, title, level...
local function titles(list)
  local out = {}
  for i = 1, table.getn(list), 2 do
    if list[i] then table.insert(out, list[i]) end
  end
  return out
end

local f = CreateFrame("Frame")
f:RegisterEvent("GOSSIP_SHOW")
f:RegisterEvent("QUEST_GREETING")
f:RegisterEvent("QUEST_DETAIL")
f:RegisterEvent("QUEST_PROGRESS")
f:RegisterEvent("QUEST_COMPLETE")
f:SetScript("OnEvent", function()
  local name, ids = npc()
  if not name then return end
  local zone, x, y = position()
  if not zone then return end
  checknpc(name, ids, zone, x, y)
  local starts, ends = {}, {}
  if event == "GOSSIP_SHOW" then
    starts = titles({ GetGossipAvailableQuests() })
    ends = titles({ GetGossipActiveQuests() })
  elseif event == "QUEST_GREETING" then
    for i = 1, GetNumAvailableQuests() do table.insert(starts, GetAvailableTitle(i)) end
    for i = 1, GetNumActiveQuests() do table.insert(ends, GetActiveTitle(i)) end
  elseif event == "QUEST_DETAIL" then
    starts = { GetTitleText() }
  else
    ends = { GetTitleText() }
  end
  for _, t in ipairs(starts) do checkquest(name, ids, zone, x, y, t, "start") end
  -- an active quest in gossip may be one still in progress: only a quest
  -- being handed in (progress/complete) is sure to end here
  if event == "QUEST_PROGRESS" or event == "QUEST_COMPLETE" then
    for _, t in ipairs(ends) do checkquest(name, ids, zone, x, y, t, "end") end
  end
end)

-- ------------------------------------------------------------------ loot

--[[ A quest item looted from a mob the database does not list as dropping
  it. That is how Lost to the Sands' Perfect Obsidian Shard was missed: the
  site has it from Moam in Ahn'Qiraj, and on OctoWoW it drops in Zul'Gurub.
  The mob is the dead target being looted; loot from anything else (a chest,
  an area loot of several corpses) is not attributed. ]]
local function looted()
  if not UnitExists("target") or not UnitIsDead("target") or UnitIsPlayer("target") then return end
  local mob = UnitName("target")
  local _, guid = UnitExists("target")
  local ids = {}
  if type(guid) == "string" and string.len(guid) >= 18 then
    local id = tonumber(string.sub(guid, 7, 12), 16)
    if id and id > 0 then table.insert(ids, id) end
  end
  if not ids[1] then
    for id, n in pairs(pfDB["units"]["loc"]) do
      if n == mob then table.insert(ids, id) end
    end
  end
  local zone, x, y = position()
  for i = 1, GetNumLootItems() do
    local link = GetLootSlotLink and GetLootSlotLink(i)
    local _, _, item = string.find(link or "", "item:(%d+)")
    item = tonumber(item)
    local rec = item and pfDB["items"]["data"][item]
    -- an item pfQuest knows is one some quest asks for
    if rec then
      local listed = false
      for npc in pairs(rec.U or {}) do
        for _, id in ipairs(ids) do
          if tonumber(npc) == id then listed = true end
        end
      end
      if not listed then
        local iname = pfDB["items"]["loc"][item] or ("item " .. item)
        find(string.format("find: %s;%s;%s;%s;%s;drop;%d;%s;not a known source", zone or 0, mob,
          table.concat(ids, ","), fmt(x), fmt(y), item, iname),
          "drop" .. item .. mob, mob .. " dropped " .. iname)
      end
    end
  end
end

local l = CreateFrame("Frame")
l:RegisterEvent("LOOT_OPENED")
l:SetScript("OnEvent", looted)

function M.ClearFinds()
  pfQuestOcto_Finds = {}
  seen = {}
  say("finds cleared.")
end
