-- The quest log: a button that opens /instq, and pfQuest's Show button made
-- to find the quest the way /instq does -- the flashing ! on the turn-in
-- once it is complete, on the nearest objectives otherwise, and the dungeon
-- map panel for objectives in a dungeon you are not in.

local M = pfQuestOctoMaps
if not M then return end

-- the selected quest's id and whether it is complete
local function selected()
  local index = GetQuestLogSelection()
  if not index or index == 0 then return nil end
  local _, _, _, header, _, complete = GetQuestLogTitle(index)
  if header then return nil end
  local ids = pfDatabase:GetQuestIDs(index)
  local id = ids and tonumber(ids[1])
  return id, complete and complete == 1
end

-- spots of these kinds on a zone, nearest the player first when they are on
-- that map; the name of the first
local function spots(id, zone, kinds)
  local out, name = {}, nil
  for _, t in ipairs(M.Targets(id)) do
    if t.zone == zone and kinds[t.kind] then
      table.insert(out, { t.x, t.y })
      name = name or t.name
    end
  end
  local px, py = GetPlayerMapPosition("player")
  if px and px > 0 then
    px, py = px * 100, py * 100
    table.sort(out, function(a, b)
      local ax, ay, bx, by = a[1] - px, a[2] - py, b[1] - px, b[2] - py
      return ax * ax + ay * ay < bx * bx + by * by
    end)
  end
  return out, name
end

local TURNIN = { ender = true }
local OBJECTIVES = { kill = true, use = true, drop = true }

-- after pfQuest's Show has pinned the quest and opened its best map
function M.FindQuest(id, complete)
  if not id then return end
  if not complete then
    local d = M.DungeonOf(id)
    if d and not M.Inside(d) then
      M.ShowDungeon(id, d, true)
      return
    end
  end
  local zone = pfMap:GetMapID(GetCurrentMapContinent(), GetCurrentMapZone())
  local kinds = complete and TURNIN or OBJECTIVES
  local pts, name = spots(id, zone, kinds)
  if not pts[1] then
    -- not on the map pfQuest opened: the map of the first such spot
    for _, t in ipairs(M.Targets(id)) do
      if kinds[t.kind] and M.Open(t.zone) then
        zone = t.zone
        pts, name = spots(id, zone, kinds)
        break
      end
    end
  end
  if pts[1] then
    M.Flash(pts, (name or "") .. (complete and "  (turn in)" or ""))
  end
end

-- ------------------------------------------------------------------ buttons

local hooked
local function hook()
  if hooked or not pfQuest or not pfQuest.buttonShow then return end
  hooked = true
  local show = pfQuest.buttonShow:GetScript("OnClick")
  pfQuest.buttonShow:SetScript("OnClick", function()
    if show then show() end
    local id, complete = selected()
    M.FindQuest(id, complete)
  end)
end

local open = CreateFrame("Button", "pfQuestOctoInstancesButton", QuestLogFrame, "UIPanelButtonTemplate")
open:SetWidth(110)
open:SetHeight(20)
if QuestLogQuestCount then
  open:SetPoint("RIGHT", QuestLogQuestCount, "LEFT", -16, 0)
else
  open:SetPoint("TOPRIGHT", QuestLogFrame, "TOPRIGHT", -150, -40)
end
open:SetText("Instance Quests")
open:SetScript("OnClick", function()
  if pfQuestOctoInstances:IsShown() then pfQuestOctoInstances:Hide() else pfQuestOctoInstances:Show() end
end)
if pfUI and pfUI.api and pfUI.api.SkinButton then pfUI.api.SkinButton(open) end

-- pfQuest makes its Show button when the log first opens; take it then
local watch = CreateFrame("Frame", nil, QuestLogFrame)
watch:SetScript("OnShow", hook)
watch:SetScript("OnUpdate", function()
  hook()
  if hooked then this:SetScript("OnUpdate", nil) end
end)
