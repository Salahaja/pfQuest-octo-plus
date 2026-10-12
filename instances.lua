-- Instance quests: every quest an instance has, the chains that lead to them
-- and the keys and attunements that open it, with where this character is
-- in each. The lists are built by tools/build.py (db/instances-turtle.lua);
-- this file only draws them. /db instances, /instq.

local ROWS, LIST, ROWH = 22, 22, 16
local STATE_ORDER = { next = 1, active = 2, low = 3, locked = 4, done = 5 }
local STATE_TEXT = {
  done   = "|cff55ff55done|r",
  active = "|cffffff00in log|r",
  next   = "|cff33ffccready|r",
  low    = "|cffff8040level|r",
  locked = "|cff888888locked|r",
}

local quests, units, objects, items
local plevel, prace, pclass
local selected, hidedone = nil, false
local rows = {}

local function db()
  quests = pfDB["quests"]["data"]
  units, objects, items = pfDB["units"], pfDB["objects"], pfDB["items"]
  plevel = UnitLevel("player")
  local _, race = UnitRace("player")
  local _, class = UnitClass("player")
  prace = pfDatabase:GetBitByRace(race)
  pclass = pfDatabase:GetBitByClass(class)
end

-- quests this character can ever take
local function forme(id)
  local q = quests[id]
  if not q then return false end
  if q.race and bit.band(q.race, prace) ~= prace then return false end
  if q.class and pclass and bit.band(q.class, pclass) ~= pclass then return false end
  return true
end

local function state(id)
  if pfQuest_history[id] then return "done" end
  if pfQuest.questlog[id] then return "active" end
  local q = quests[id]
  if q.pre then
    local one = false
    for _, p in pairs(q.pre) do
      if pfQuest_history[p] then one = true end
    end
    if not one then return "locked" end
  end
  if q.min and q.min > plevel then return "low" end
  return "next"
end

-- the quest to do now on the way to a locked one
local function nextstep(id, seen)
  if seen[id] then return nil end
  seen[id] = true
  local s = state(id)
  if s == "done" then return nil end
  if s ~= "locked" then return id end
  for _, p in pairs(quests[id].pre) do
    if forme(p) then
      local r = nextstep(p, seen)
      if r then return r end
    end
  end
  return nil
end

local function qname(id)
  local l = pfDB["quests"]["loc"][id]
  return l and l.T or ("quest " .. id)
end

-- "Giver Name, Zone" for where a quest starts
local function giver(id)
  local s = quests[id] and quests[id].start
  if not s then return "" end
  local name, zone
  if s.U and s.U[1] then
    name = units.loc[s.U[1]]
    local u = units.data[s.U[1]]
    zone = u and u.coords and u.coords[1] and u.coords[1][3]
  elseif s.O and s.O[1] then
    name = objects.loc[s.O[1]]
    local o = objects.data[s.O[1]]
    zone = o and o.coords and o.coords[1] and o.coords[1][3]
  elseif s.I and s.I[1] then
    name = (items.loc[s.I[1]] or "an item") .. " (item)"
  end
  zone = zone and pfMap:GetMapNameByID(zone)
  if name and zone then return name .. ", " .. zone end
  return name or ""
end

local function lvlcolor(id)
  local lvl = quests[id].lvl or 0
  return pfDatabase:GetHexDifficultyColor(lvl) .. "[" .. lvl .. "]|r "
end

-- ------------------------------------------------------------------ lists

local function progress(inst)
  local done, all = 0, 0
  for _, id in pairs(inst.quests) do
    if forme(id) then
      all = all + 1
      if pfQuest_history[id] then done = done + 1 end
    end
  end
  return done, all
end

local function sorted(ids)
  local out = {}
  for _, id in pairs(ids) do
    if forme(id) then table.insert(out, { id = id, state = state(id) }) end
  end
  table.sort(out, function(a, b)
    if a.state ~= b.state then return STATE_ORDER[a.state] < STATE_ORDER[b.state] end
    local la, lb = quests[a.id].lvl or 0, quests[b.id].lvl or 0
    if la ~= lb then return la < lb end
    return a.id < b.id
  end)
  return out
end

-- the rows of the right-hand list: headers and quests
local function build(inst)
  local out = {}
  local function header(text) table.insert(out, { header = text }) end
  local function add(list)
    for _, e in pairs(list) do
      if not (hidedone and e.state == "done") then
        local row = { id = e.id, state = e.state }
        if e.state == "locked" then
          row.step = nextstep(e.id, {})
        end
        table.insert(out, row)
      end
    end
  end

  if inst.key and inst.key[1] then
    -- the key chain in the order it is done, not sorted by state
    local list = {}
    for _, id in pairs(inst.key) do
      if forme(id) then table.insert(list, { id = id, state = state(id) }) end
    end
    if list[1] then
      header("Key / attunement")
      add(list)
    end
  end
  local main = sorted(inst.quests)
  if main[1] then
    local done, all = progress(inst)
    header("Quests  (" .. done .. "/" .. all .. " done)")
    add(main)
  end
  return out
end

-- ------------------------------------------------------------------ frame

local frame = CreateFrame("Frame", "pfQuestOctoInstances", UIParent)
frame:Hide()
frame:SetWidth(640)
frame:SetHeight(ROWS * ROWH + 70)
frame:SetPoint("CENTER", 0, 40)
frame:SetFrameStrata("DIALOG")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function() this:StartMoving() end)
frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
frame:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
frame:SetBackdropColor(0, 0, 0, .9)
table.insert(UISpecialFrames, "pfQuestOctoInstances")

frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.title:SetPoint("TOPLEFT", 12, -10)
frame.title:SetText("|cff33ffccpf|rQuest  Instance Quests")

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 0, 0)

local hide = CreateFrame("CheckButton", "pfQuestOctoInstancesHideDone", frame, "UICheckButtonTemplate")
hide:SetWidth(20)
hide:SetHeight(20)
hide:SetPoint("TOPRIGHT", -36, -6)
getglobal(hide:GetName() .. "Text"):SetText("Hide done")
getglobal(hide:GetName() .. "Text"):ClearAllPoints()
getglobal(hide:GetName() .. "Text"):SetPoint("RIGHT", hide, "LEFT", -2, 0)

frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
frame.hint:SetPoint("BOTTOMLEFT", 12, 10)
frame.hint:SetText("Click a quest to show it on the map. A locked quest shows the step to do first.")

local function scrollframe(name, x, width, count, update)
  local sf = CreateFrame("ScrollFrame", name, frame, "FauxScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", x, -32)
  sf:SetWidth(width)
  sf:SetHeight(count * ROWH)
  sf:SetScript("OnVerticalScroll", function()
    FauxScrollFrame_OnVerticalScroll(ROWH, update)
  end)
  return sf
end

local Refresh

-- left: the instances
local instlist = {}
local instbuttons = {}
local leftscroll = scrollframe("pfQuestOctoInstancesLeft", 8, 156, LIST, function() Refresh() end)

local function InstanceClick()
  selected = this.inst
  FauxScrollFrame_SetOffset(pfQuestOctoInstancesRight, 0)
  pfQuestOctoInstancesRightScrollBar:SetValue(0)
  Refresh()
end

for i = 1, LIST do
  local b = CreateFrame("Button", nil, frame)
  b:SetWidth(154)
  b:SetHeight(ROWH)
  b:SetPoint("TOPLEFT", 10, -32 - (i - 1) * ROWH)
  b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", 2, 0)
  b.text:SetWidth(116)
  b.text:SetJustifyH("LEFT")
  b.count = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  b.count:SetPoint("RIGHT", -2, 0)
  b:SetScript("OnClick", InstanceClick)
  instbuttons[i] = b
end

-- right: the quests
local rightscroll = scrollframe("pfQuestOctoInstancesRight", 196, 410, ROWS, function() Refresh() end)
local questbuttons = {}

local function QuestClick()
  local id = this.row and (this.row.step or this.row.id)
  if not id then return end
  if IsShiftKeyDown() and pfQuestCompat and pfQuestCompat.InsertQuestLink then
    pfQuestCompat.InsertQuestLink(id)
    return
  end
  local maps = pfDatabase:SearchQuestID(id, { ["addon"] = "PFDB" })
  pfMap:ShowMapID(pfDatabase:GetBestMap(maps))
end

local function QuestEnter()
  local row = this.row
  if not row or not row.id then return end
  GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
  GameTooltip:AddLine(qname(row.id), 1, 1, 1)
  local q = quests[row.id]
  GameTooltip:AddLine("Level " .. (q.lvl or "?") .. ", requires " .. (q.min or 1), .8, .8, .8)
  local g = giver(row.id)
  if g ~= "" then GameTooltip:AddLine("Starts: " .. g, .8, .8, .8) end
  if row.step and row.step ~= row.id then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Do first: " .. qname(row.step), .2, 1, .8)
    local sg = giver(row.step)
    if sg ~= "" then GameTooltip:AddLine("  from " .. sg, .8, .8, .8) end
  elseif row.state == "locked" then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Locked: the quest before it is not for you or not known.", .6, .6, .6)
  end
  GameTooltip:Show()
end

for i = 1, ROWS do
  local b = CreateFrame("Button", nil, frame)
  b:SetWidth(410)
  b:SetHeight(ROWH)
  b:SetPoint("TOPLEFT", 198, -32 - (i - 1) * ROWH)
  b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  b.state = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.state:SetPoint("LEFT", 2, 0)
  b.state:SetWidth(42)
  b.state:SetJustifyH("LEFT")
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", 46, 0)
  b.text:SetWidth(200)
  b.text:SetJustifyH("LEFT")
  b.note = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  b.note:SetPoint("RIGHT", -2, 0)
  b.note:SetWidth(160)
  b.note:SetJustifyH("RIGHT")
  b:SetScript("OnClick", QuestClick)
  b:SetScript("OnEnter", QuestEnter)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  questbuttons[i] = b
end

Refresh = function()
  if not frame:IsShown() then return end
  db()

  -- left
  local n = table.getn(instlist)
  FauxScrollFrame_Update(leftscroll, n, LIST, ROWH)
  local off = FauxScrollFrame_GetOffset(leftscroll)
  for i = 1, LIST do
    local b, inst = instbuttons[i], instlist[i + off]
    b.inst = inst
    if inst then
      local done, all = progress(inst)
      local tag = inst.kind == "r" and "|cffff8040R|r " or ""
      local col = inst == selected and "|cffffd100" or "|cffffffff"
      b.text:SetText(tag .. col .. inst.name .. "|r")
      b.count:SetText(all > 0 and (done .. "/" .. all) or "")
      b:Show()
    else
      b:Hide()
    end
  end

  -- right
  local list = selected and build(selected) or {}
  n = table.getn(list)
  FauxScrollFrame_Update(rightscroll, n, ROWS, ROWH)
  off = FauxScrollFrame_GetOffset(rightscroll)
  for i = 1, ROWS do
    local b, row = questbuttons[i], list[i + off]
    b.row = row
    if row and row.header then
      b.state:SetText("")
      b.text:SetText("|cffffd100" .. row.header .. "|r")
      b.note:SetText("")
      b:Show()
    elseif row then
      b.state:SetText(STATE_TEXT[row.state])
      b.text:SetText(lvlcolor(row.id) .. qname(row.id))
      if row.step and row.step ~= row.id then
        b.note:SetText("first: " .. qname(row.step))
      elseif row.state == "next" or row.state == "low" then
        b.note:SetText(giver(row.id))
      else
        b.note:SetText("")
      end
      b:Show()
    else
      b:Hide()
    end
  end
end

hide:SetScript("OnClick", function()
  hidedone = this:GetChecked() and true or false
  Refresh()
end)

frame:SetScript("OnShow", function()
  if not instlist[1] and pfQuestOcto_Instances then
    for _, inst in pairs(pfQuestOcto_Instances) do table.insert(instlist, inst) end
    table.sort(instlist, function(a, b)
      if a.kind ~= b.kind then return a.kind == "d" end
      if a.lvl ~= b.lvl then return a.lvl < b.lvl end
      return a.name < b.name
    end)
  end
  Refresh()
end)

-- redraw on quest log changes while open
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:SetScript("OnEvent", function() Refresh() end)

-- ------------------------------------------------------------------ commands

local function toggle()
  if frame:IsShown() then frame:Hide() else frame:Show() end
end

SLASH_PFQUESTOCTOINST1, SLASH_PFQUESTOCTOINST2 = "/instq", "/instancequests"
SlashCmdList["PFQUESTOCTOINST"] = toggle

local pfdb = SlashCmdList["PFDB"]
if pfdb then
  SlashCmdList["PFDB"] = function(input, editbox)
    local cmd = string.lower(input or "")
    if cmd == "instances" or cmd == "instance" or cmd == "inst" then
      return toggle()
    end
    return pfdb(input, editbox)
  end
end
