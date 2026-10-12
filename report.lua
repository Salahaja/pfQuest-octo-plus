-- Reports testers can share. /instq report opens a window of plain text to
-- copy (Ctrl+A, Ctrl+C) into Discord or an issue: the addon version, the
-- character, what the open map is to the game, to pfQuest and to this addon,
-- and every mark. /instq mark, with an NPC targeted, records where it really
-- stands: which map and floor, and the player's position next to it -- the
-- data the multi-floor dungeon maps are fixed from. Marks are kept in
-- pfQuestOcto_Marks (SavedVariables) as the same lines the report shows;
-- tools/reports.py reads either.

local M = pfQuestOctoMaps
if not M then return end

local VERSION = GetAddOnMetadata and GetAddOnMetadata("pfQuest-octo-plus", "Version") or "?"

local function say(t) DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccpf|rQuest: " .. t) end
local function fmt(v) return v and string.format("%.1f", v) or "-" end

-- the map of where the player stands, and their position on it (0-100)
local function here()
  SetMapToCurrentZone()
  local x, y = GetPlayerMapPosition("player")
  local name = GetMapInfo()
  local c, z = GetCurrentMapContinent(), GetCurrentMapZone()
  local m = name and M.byname[name]
  local id = pfMap:GetMapID(c, z)
  local own = M.pfGetMapID and M.pfGetMapID(pfMap, c, z)
  return {
    name = name or "?", c = c, z = z, m = m, id = id, own = own,
    x = x and x > 0 and x * 100 or nil, y = y and y > 0 and y * 100 or nil,
    zonetext = GetRealZoneText and GetRealZoneText() or "?",
    subzone = GetSubZoneText and GetSubZoneText() or "",
  }
end

local function mapline(h)
  local nodes = 0
  for _, maps in pairs(pfMap.nodes or {}) do
    for _ in pairs(h.id and maps[h.id] or {}) do nodes = nodes + 1 end
  end
  return string.format("map: %s floor %s (map %s) ours %s | game %s/%s \"%s\" sub \"%s\" | pfQuest %s (own %s), %d nodes",
    h.name, h.m and h.m.floor or "-", h.m and h.m.map or "-", h.m and h.m.zone or "none",
    tostring(h.c), tostring(h.z), h.zonetext, h.subzone, tostring(h.id), tostring(h.own), nodes)
end

-- the target's NPC id: from its GUID where SuperWoW gives one, else every
-- database NPC of that name
local function targetids(name)
  local _, guid = UnitExists("target")
  if type(guid) == "string" and string.len(guid) >= 18 then
    local id = tonumber(string.sub(guid, 7, 12), 16)
    if id and pfDB["units"]["loc"][id] == name then return { id } end
  end
  local out = {}
  for id, n in pairs(pfDB["units"]["loc"]) do
    if n == name then table.insert(out, id) end
  end
  return out
end

-- /instq mark: where the targeted NPC stands, against the database
function M.Mark()
  if not UnitExists("target") or UnitIsPlayer("target") then
    say("target an NPC first, then /instq mark")
    return
  end
  local name = UnitName("target")
  local h = here()
  local ids = targetids(name)
  -- where the database puts it, on any zone
  local db = {}
  for _, id in ipairs(ids) do
    local u = pfDB["units"]["data"][id]
    for _, c in pairs(u and u.coords or {}) do
      table.insert(db, string.format("%d@%d:%s,%s", id, c[3], fmt(c[1]), fmt(c[2])))
      if table.getn(db) >= 4 then break end
    end
  end
  local line = string.format("mark: %s|%s|%s|%s|%s|%s|%s|%s|db %s",
    h.name, h.m and h.m.zone or 0, name, table.concat(ids, ","), fmt(h.x), fmt(h.y),
    tostring(h.c) .. "/" .. tostring(h.z), h.subzone, table.concat(db, " "))
  pfQuestOcto_Marks = pfQuestOcto_Marks or {}
  table.insert(pfQuestOcto_Marks, line)
  say(string.format("marked %s at %s, %s on %s (%d marks). /instq report to copy them.",
    name, fmt(h.x), fmt(h.y), h.name, table.getn(pfQuestOcto_Marks)))
end

function M.ClearMarks()
  pfQuestOcto_Marks = {}
  say("marks cleared.")
end

-- ------------------------------------------------------------------ window

local win = CreateFrame("Frame", "pfQuestOctoReport", UIParent)
win:Hide()
win:SetWidth(620)
win:SetHeight(360)
win:SetPoint("CENTER", 0, 60)
win:SetFrameStrata("DIALOG")
win:SetMovable(true)
win:EnableMouse(true)
win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", function() this:StartMoving() end)
win:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
win:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
win:SetBackdropColor(0, 0, 0, .95)
table.insert(UISpecialFrames, "pfQuestOctoReport")

win.title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
win.title:SetPoint("TOPLEFT", 12, -10)
win.title:SetText("|cff33ffccpf|rQuest report  -  Ctrl+A then Ctrl+C to copy")
local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 0, 0)

local scroll = CreateFrame("ScrollFrame", "pfQuestOctoReportScroll", win, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 12, -32)
scroll:SetPoint("BOTTOMRIGHT", -32, 12)
local edit = CreateFrame("EditBox", nil, scroll)
edit:SetMultiLine(true)
edit:SetAutoFocus(false)
edit:SetFontObject(GameFontHighlightSmall)
edit:SetWidth(570)
edit:SetHeight(300)
edit:SetScript("OnEscapePressed", function() win:Hide() end)
-- keep the text as it was if someone types into it
edit:SetScript("OnTextChanged", function()
  if this.text and this:GetText() ~= this.text then this:SetText(this.text) this:HighlightText() end
end)
scroll:SetScrollChild(edit)

function M.Report()
  local h = here()
  local _, race = UnitRace("player")
  local _, class = UnitClass("player")
  local lines = {
    string.format("pfQuest-octo-plus %s report, %s  -  The Iron Hammers: and the hammer falls", VERSION,
      date and date("%Y-%m-%d %H:%M") or ""),
    string.format("char: level %d %s %s %s", UnitLevel("player"), UnitFactionGroup("player") or "?",
      race or "?", class or "?"),
    mapline(h),
    string.format("pos: %s %s", fmt(h.x), fmt(h.y)),
  }
  for _, l in ipairs(pfQuestOcto_Marks or {}) do table.insert(lines, l) end
  for _, l in ipairs(pfQuestOcto_Finds or {}) do table.insert(lines, l) end
  if not (pfQuestOcto_Marks and pfQuestOcto_Marks[1]) then
    table.insert(lines, "(no marks: target an NPC and /instq mark to add one)")
  end
  edit.text = table.concat(lines, "\n")
  edit:SetText(edit.text)
  win:Show()
  edit:SetFocus()
  edit:HighlightText()
end

-- ------------------------------------------------------------------ quest log

-- Mark and Report beside the quest log's Instance Quests button
local function logbutton(text, width, anchor, fn, tip)
  local b = CreateFrame("Button", nil, QuestLogFrame, "UIPanelButtonTemplate")
  b:SetWidth(width)
  b:SetHeight(20)
  b:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
  b:SetText(text)
  b:SetScript("OnClick", fn)
  b:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(text, 1, 1, 1)
    GameTooltip:AddLine(tip, .8, .8, .8, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  if pfUI and pfUI.api and pfUI.api.SkinButton then pfUI.api.SkinButton(b) end
  return b
end

if pfQuestOctoInstancesButton then
  local report = logbutton("Report", 64, pfQuestOctoInstancesButton, function() M.Report() end,
    "Opens a report to copy and share: your map, floor and position, and every mark. (/instq report)")
  logbutton("Mark", 52, report, function() M.Mark() end,
    "Target an NPC first. Records where it really stands on this map and floor, for fixing dungeon maps. (/instq mark)")
end
