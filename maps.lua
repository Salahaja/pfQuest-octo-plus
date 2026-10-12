-- Dungeon maps. Turtle's client has a map for every instance, shown while
-- you are inside it, but pfQuest only knows maps by the names in each
-- continent's zone list, where dungeons are not: it drew no pins on a
-- dungeon map. This file teaches it the dungeon maps (the list is built from
-- the client's own WorldMapArea table, db/instances-turtle.lua), names the
-- boss icons on them, and flashes a marker where /instq sends you.
--
-- Turtle's client opens SOME dungeon maps from anywhere with
-- SetMapZoom(map id, 1), and crashes on others: map 47, Razorfen Kraul, took
-- the client down (ERROR #132 at 0x004A6D1E, 2026-10-12) after the first
-- seven opened fine. No game table says which -- WorldMapContinent.dbc holds
-- only the continents -- so a map id is used only once it has been seen to
-- open in game (SAFE below). Any other dungeon map opens with
-- SetMapToCurrentZone() from inside it. /instq maptest tries the untested
-- ones, one click at a time, writing each to the chat log before trying it.

pfQuestOctoMaps = {}
local M = pfQuestOctoMaps

-- map ids seen to open with SetMapZoom(id, 1) in game, and seen to crash
local SAFE = { [27] = true, [30] = true, [33] = true, [34] = true, [35] = true, [36] = true, [43] = true }
local CRASH = { [47] = true }
M.safe, M.crash = SAFE, CRASH

local byname, byzone = {}, {}
for _, m in pairs(pfQuestOcto_DungeonMaps or {}) do
  byname[m.name] = m
  if not byzone[m.zone] then byzone[m.zone] = m end
end
M.byname, M.byzone = byname, byzone

-- the dungeon map open now, if any
function M.Current()
  local name = GetMapInfo()
  return name and byname[name]
end

-- dungeons the game lists as a zone of some continent: title -> {c, z}
local listed = {}
local function readlists()
  listed = {}
  local continents = { GetMapContinents() }
  for c = 1, table.getn(continents) do
    local zones = { GetMapZones(c) }
    for z = 1, table.getn(zones) do
      listed[zones[z]] = { c, z }
    end
  end
end

local function showmap()
  if not WorldMapFrame:IsShown() then
    if ToggleWorldMap then ToggleWorldMap() else WorldMapFrame:Show() end
  end
end

-- open the world map on a zone. A dungeon: through the game's own list, or
-- from inside it; false when neither can, and the map is left alone.
function M.Open(zone)
  local m = byzone[zone]
  if not m then
    return pfMap:ShowMapID(zone)
  end
  local where = m.title and listed[m.title]
  if where then
    showmap()
    SetMapZoom(where[1], where[2])
    pfMap:UpdateNodes()
    return true
  end
  if SAFE[m.map] then
    showmap()
    SetMapZoom(m.map, 1)
    pfMap:UpdateNodes()
    return true
  end
  -- is the player in this dungeon? the map of where you stand says
  SetMapToCurrentZone()
  local cur = M.Current()
  if cur and cur.map == m.map then
    showmap()
    SetMapToCurrentZone()
    pfMap:UpdateNodes()
    return true
  end
  return false
end

-- ------------------------------------------------------------------ pfQuest

-- the map pfQuest draws on: a dungeon map is known by its file name
if pfMap and pfMap.GetMapID then
  local GetMapID = pfMap.GetMapID
  pfMap.GetMapID = function(self, cid, mid)
    local id = GetMapID(self, cid, mid)
    if id then return id end
    local m = M.Current()
    return m and m.zone
  end
end

-- and its Show buttons open one, when the game can
if pfMap and pfMap.SetMapByID then
  local SetMapByID = pfMap.SetMapByID
  pfMap.SetMapByID = function(self, id)
    local m = byzone[tonumber(id)]
    if m then
      local where = m.title and listed[m.title]
      if where then
        SetMapZoom(where[1], where[2])
      elseif SAFE[m.map] then
        SetMapZoom(m.map, 1)
      else
        SetMapToCurrentZone()
      end
      return
    end
    return SetMapByID(self, id)
  end
end

-- ------------------------------------------------------------------ boss names

-- the bosses on a dungeon map: elite, one spawn there, a weekly respawn
local bosscache = {}
local function bosses(zone)
  if bosscache[zone] then return bosscache[zone] end
  local out = {}
  for id, u in pairs(pfDB["units"]["data"]) do
    if type(u) == "table" and u.rnk and u.coords then
      local here, n = nil, 0
      for _, c in pairs(u.coords) do
        if c[3] == zone then here = c n = n + 1 end
      end
      if here and n == 1 and (here[4] or 0) >= 86400 then
        table.insert(out, { name = pfDB["units"]["loc"][id], x = here[1], y = here[2] })
      end
    end
  end
  bosscache[zone] = out
  return out
end

-- the boss nearest a point (0-100), if one is close
local function nearestboss(zone, x, y)
  local best, bestd
  for _, b in pairs(bosses(zone)) do
    local dx, dy = b.x - x, b.y - y
    local d = dx * dx + dy * dy
    if b.name and (not bestd or d < bestd) then best, bestd = b, d end
  end
  if best and bestd < 64 then return best.name end
  return nil
end

local function POIEnter()
  if this.octoEnter then this.octoEnter() end
  local name = this.name
  if not name or name == "" then
    local m = M.Current()
    name = m and this.octoX and nearestboss(m.zone, this.octoX, this.octoY)
  end
  if not name or name == "" then return end
  WorldMapTooltip:SetOwner(this, "ANCHOR_RIGHT")
  WorldMapTooltip:AddLine(name, 1, .82, 0)
  if this.description and this.description ~= "" and this.description ~= name then
    WorldMapTooltip:AddLine(this.description, 1, 1, 1, 1)
  end
  WorldMapTooltip:Show()
end

local function POILeave()
  if this.octoLeave then this.octoLeave() end
  WorldMapTooltip:Hide()
end

-- the map's icons are drawn by WorldMapFrame_Update, which the map's events
-- call by name: after it, give each icon a tooltip and remember where it is
if WorldMapFrame_Update then
  local Update = WorldMapFrame_Update
  WorldMapFrame_Update = function()
    Update()
    if not M.Current() then return end
    local n = GetNumMapLandmarks and GetNumMapLandmarks() or 0
    for i = 1, n do
      local poi = getglobal("WorldMapFramePOI" .. i)
      if poi then
        if not poi.octo then
          poi.octo = true
          poi.octoEnter = poi:GetScript("OnEnter")
          poi.octoLeave = poi:GetScript("OnLeave")
          poi:SetScript("OnEnter", POIEnter)
          poi:SetScript("OnLeave", POILeave)
        end
        local _, _, _, x, y = GetMapLandmarkInfo(i)
        poi.octoX, poi.octoY = x and x * 100, y and y * 100
      end
    end
  end
end

-- ------------------------------------------------------------------ marker

-- a flashing ! with a bouncing arrow over it, at x, y (0-100) on the open
-- map, for ten seconds or until the map changes or closes
local markers = {}
local function marker(i)
  if markers[i] then return markers[i] end
  local f = CreateFrame("Frame", nil, WorldMapButton)
  f:SetFrameLevel(WorldMapButton:GetFrameLevel() + 20)
  f:SetWidth(40)
  f:SetHeight(40)
  f.ring = f:CreateTexture(nil, "ARTWORK")
  f.ring:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
  f.ring:SetBlendMode("ADD")
  f.ring:SetVertexColor(1, .82, 0)
  f.ring:SetWidth(72)
  f.ring:SetHeight(72)
  f.ring:SetPoint("CENTER", 0, 0)
  f.bang = f:CreateTexture(nil, "OVERLAY")
  f.bang:SetTexture(pfQuestConfig and (pfQuestConfig.path .. "\\img\\available") or "Interface\\GossipFrame\\AvailableQuestIcon")
  f.bang:SetVertexColor(1, .9, .1)
  f.bang:SetWidth(32)
  f.bang:SetHeight(32)
  f.bang:SetPoint("CENTER", 0, 0)
  f.arrow = f:CreateTexture(nil, "OVERLAY")
  f.arrow:SetTexture("Interface\\Buttons\\UI-MicroStream-Yellow")
  f.arrow:SetWidth(32)
  f.arrow:SetHeight(32)
  f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.label:SetPoint("TOP", f, "BOTTOM", 0, -2)
  f:SetScript("OnUpdate", function()
    local now = GetTime()
    if now > this.stop or not WorldMapFrame:IsShown() or GetMapInfo() ~= this.map then
      this:Hide()
      return
    end
    local w, h = WorldMapButton:GetWidth(), WorldMapButton:GetHeight()
    this:ClearAllPoints()
    this:SetPoint("CENTER", WorldMapButton, "TOPLEFT", this.x / 100 * w, -this.y / 100 * h)
    -- flash twice a second, the arrow bobbing above
    local t = now - this.start
    local a = .55 + .45 * math.abs(math.sin(t * math.pi * 2))
    this.bang:SetAlpha(a)
    this.ring:SetAlpha(a)
    this.arrow:ClearAllPoints()
    this.arrow:SetPoint("BOTTOM", this, "TOP", 0, 2 + 6 * math.abs(math.sin(t * math.pi * 2)))
  end)
  markers[i] = f
  return f
end

function M.HideMarkers()
  for _, f in pairs(markers) do f:Hide() end
end

-- points: { {x, y}, ... } on the open map; label under the first
function M.Flash(points, label)
  M.HideMarkers()
  local now = GetTime()
  for i, p in ipairs(points) do
    if i > 5 then break end
    local f = marker(i)
    f.x, f.y, f.start, f.stop, f.map = p[1], p[2], now, now + 10, GetMapInfo()
    f.label:SetText(i == 1 and label or "")
    f:Show()
  end
end

-- ------------------------------------------------------------------ map test

--[[ /instq maptest: try the dungeon maps nobody has opened yet, ONE per click,
  no automatic run -- a map the client cannot open crashes it. Each try is
  written to chat before and after (with the chat log on, it is in
  Logs\WoWChatLog.txt), and the panel shows the map it is about to try, so
  a crash still names the map. Results also go to pfQuestOcto_MapTest. ]]
local untested = {}
local function pickuntested()
  untested = {}
  local seen = {}
  for _, m in ipairs(pfQuestOcto_DungeonMaps or {}) do
    if m.floor == 1 and not SAFE[m.map] and not CRASH[m.map] and not seen[m.map] then
      seen[m.map] = true
      table.insert(untested, m)
    end
  end
end

local test = CreateFrame("Frame", "pfQuestOctoMapTest", UIParent)
test:Hide()
test:SetWidth(340)
test:SetHeight(70)
test:SetPoint("TOP", 0, -80)
test:SetFrameStrata("FULLSCREEN_DIALOG")
test:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
test:SetBackdropColor(0, 0, 0, .9)
test:EnableMouse(true)
test.text = test:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
test.text:SetPoint("TOP", 0, -10)
test.text:SetWidth(320)

local function say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccpf|rQuest map test: " .. msg)
end

local function describe()
  local m = untested[test.i]
  if m then
    test.text:SetText(string.format("Next: %d of %d untested  -  %s (map %d)\nIf the game crashes on it, tell Claude this name.",
      test.i, table.getn(untested), m.name, m.map))
  else
    test.text:SetText("No untested maps left.")
  end
end

local function try()
  local m = untested[test.i]
  if not m then return end
  say(string.format("trying %s (map %d)...", m.name, m.map))
  if not WorldMapFrame:IsShown() then
    if ToggleWorldMap then ToggleWorldMap() else WorldMapFrame:Show() end
  end
  SetMapZoom(m.map, 1)
  test.read = GetTime() + .5
end

test:SetScript("OnUpdate", function()
  if not this.read or GetTime() < this.read then return end
  this.read = nil
  local m = untested[this.i]
  local got = GetMapInfo() or "?"
  pfQuestOcto_MapTest = pfQuestOcto_MapTest or {}
  pfQuestOcto_MapTest[m.map] = got
  say(string.format("%s (map %d) opened %s %s", m.name, m.map, got,
    got == m.name and "|cff55ff55- right|r" or "|cffff5555- WRONG|r"))
  this.i = this.i + 1
  describe()
end)

local function tbutton(text, x, fn)
  local b = CreateFrame("Button", nil, test, "UIPanelButtonTemplate")
  b:SetWidth(90)
  b:SetHeight(20)
  b:SetPoint("BOTTOMLEFT", x, 8)
  b:SetText(text)
  b:SetScript("OnClick", fn)
  return b
end
tbutton("Try it", 10, function() try() end)
tbutton("Skip", 104, function() test.i = test.i + 1 describe() end)
tbutton("Close", 236, function() test:Hide() end)

-- /instq maptest [n]: start at untested map n
function M.MapTest(args)
  pickuntested()
  local _, _, n = string.find(args or "", "(%d+)")
  test.i = tonumber(n) or test.i or 1
  if LoggingChat and not LoggingChat() then
    LoggingChat(1)
    say("chat log on (Logs/WoWChatLog.txt)")
  end
  describe()
  test:Show()
end

local probe = CreateFrame("Frame")
probe:RegisterEvent("PLAYER_ENTERING_WORLD")
probe:SetScript("OnEvent", function() readlists() end)
