-- Dungeon maps. Turtle's client has a map for every instance, shown while
-- you are inside it, but pfQuest only knows maps by the names in each
-- continent's zone list, where dungeons are not: it drew no pins on a
-- dungeon map. This file teaches it the dungeon maps (the list is built from
-- the client's own WorldMapArea table, db/instances-turtle.lua), names the
-- boss icons on them, and flashes a marker where /instq sends you.
--
-- A dungeon map can't be opened from outside the dungeon. 2.2.0 to 2.2.4
-- tried SetMapZoom(<dungeon map id>, 1): the client takes the number as a
-- continent, reads past its continent list, shows whatever it finds there
-- (never the right map) and soon crashes (ERROR #132 at 0x004A6D1E,
-- 2026-10-12). SetMapZoom here only ever gets numbers from the game's own
-- lists; a dungeon map otherwise opens with SetMapToCurrentZone() from
-- inside it.

pfQuestOctoMaps = {}
local M = pfQuestOctoMaps

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

--[[ The map pfQuest draws on. A dungeon map is known by its file name, and
  that comes first: inside Zul'Farrak the game reports continent 5, zone 1,
  "Zul'Farrak", which pfQuest's name lookup turns into 978 -- the id quests
  are filed under -- while every spawn there is placed on 1176, the map's
  own. pfQuest then found no pins on 978 and drew nothing. ]]
if pfMap and pfMap.GetMapID then
  local GetMapID = pfMap.GetMapID
  M.pfGetMapID = GetMapID
  pfMap.GetMapID = function(self, cid, mid)
    local m = M.Current()
    if m then return m.zone end
    return GetMapID(self, cid, mid)
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
-- map, for five seconds or until the map changes or closes
local markers = {}
local function marker(i)
  if markers[i] then return markers[i] end
  local f = CreateFrame("Frame", nil, WorldMapButton)
  f:SetFrameLevel(WorldMapButton:GetFrameLevel() + 20)
  f:SetWidth(40)
  f:SetHeight(40)
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
    f.x, f.y, f.start, f.stop, f.map = p[1], p[2], now, now + 5, GetMapInfo()
    f.label:SetText(i == 1 and label or "")
    f:Show()
  end
end

local probe = CreateFrame("Frame")
probe:RegisterEvent("PLAYER_ENTERING_WORLD")
probe:SetScript("OnEvent", function() readlists() end)

-- /instq mapdebug: what the client and pfQuest see on the open map, for a
-- dungeon map that shows no pins. Run it with the world map open.
function M.Debug()
  local say = function(t) DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccpf|rQuest map: " .. t) end
  local name = GetMapInfo()
  local c, z = GetCurrentMapContinent(), GetCurrentMapZone()
  local m = name and byname[name]
  say(string.format("file %s, continent %s, zone %s, in instance %s", tostring(name), tostring(c),
    tostring(z), tostring(IsInInstance and IsInInstance())))
  say(string.format("our dungeon entry: %s", m and (m.name .. " -> zone " .. m.zone) or "none"))
  say(string.format("pfQuest's own id %s, with ours %s, wrapper in place %s",
    tostring(M.pfGetMapID and M.pfGetMapID(pfMap, c, z)), tostring(pfMap:GetMapID(c, z)),
    tostring(pfMap.GetMapID ~= M.pfGetMapID)))
  local id = pfMap:GetMapID(c, z)
  local nodes, addons = 0, {}
  for addon, maps in pairs(pfMap.nodes or {}) do
    local n = 0
    for _ in pairs(id and maps[id] or {}) do n = n + 1 end
    if n > 0 then table.insert(addons, addon .. "=" .. n) nodes = nodes + n end
  end
  say(string.format("pfQuest nodes on map %s: %d %s", tostring(id), nodes, table.concat(addons, " ")))
  local shown = 0
  for _, pin in pairs(pfMap.pins or {}) do
    if pin:IsShown() then shown = shown + 1 end
  end
  say(string.format("pins shown %d, map button %.0fx%.0f", shown, WorldMapButton:GetWidth(), WorldMapButton:GetHeight()))
end
