-- The dungeon map panel: a dungeon's map drawn from the client's own tiles
-- (Interface\WorldMap\<Name>\<Name>1..12, the pictures the world map shows
-- inside), with a quest's targets pinned on it and the painted boss skulls
-- named on hover. It opens from /instq for a quest whose targets are in a
-- dungeon you are not in: the game cannot open a dungeon's map from outside
-- it (SetMapZoom crashes on it), but any frame can show a picture.
--
-- Nothing here re-anchors a frame while the panel can be dragged: moving a
-- frame mid-drag has crashed this client. Pins are placed when the panel is
-- filled, and the marker only pulses.

local M = pfQuestOctoMaps
if not M then return end

local SCALE = .68
local W, H = 1002 * SCALE, 668 * SCALE
local MAXPINS = 200

local KIND = {
  kill   = { .9, .25, .2, "kill" },
  use    = { 1, .85, .2, "use" },
  drop   = { 1, .55, .15, "" },
  giver  = { .3, 1, .4, "quest giver" },
  ender  = { .3, .8, 1, "turn in" },
}

local panel = CreateFrame("Frame", "pfQuestOctoDungeonMap", UIParent)
panel:Hide()
panel:SetWidth(W + 20)
panel:SetHeight(H + 60)
panel:SetPoint("CENTER", 0, 0)
panel:SetFrameStrata("DIALOG")
panel:SetToplevel(true)
panel:SetMovable(true)
panel:EnableMouse(true)
panel:SetClampedToScreen(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", function() this:StartMoving() end)
panel:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
panel:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
panel:SetBackdropColor(0, 0, 0, .95)
table.insert(UISpecialFrames, "pfQuestOctoDungeonMap")

panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panel.title:SetPoint("TOPLEFT", 12, -10)
panel.title:SetWidth(W - 220)
panel.title:SetJustifyH("LEFT")

panel.hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
panel.hint:SetPoint("BOTTOMLEFT", 12, 10)
panel.hint:SetText("Hover a pin or a skull for what it is. Red: kill, yellow: use, orange: drops what you need.")

local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 0, 0)

-- the map: twelve tiles, the last column and row cut where the picture ends
local map = CreateFrame("Frame", nil, panel)
map:SetWidth(W)
map:SetHeight(H)
map:SetPoint("TOPLEFT", 10, -32)
local tiles = {}
for i = 1, 12 do
  local t = map:CreateTexture(nil, "BACKGROUND")
  local col, row = math.mod(i - 1, 4), math.floor((i - 1) / 4)
  local tw = col == 3 and (1002 - 768) or 256
  local th = row == 2 and (668 - 512) or 256
  t:SetWidth(tw * SCALE)
  t:SetHeight(th * SCALE)
  t:SetTexCoord(0, tw / 256, 0, th / 256)
  t:SetPoint("TOPLEFT", map, "TOPLEFT", col * 256 * SCALE, -row * 256 * SCALE)
  tiles[i] = t
end

-- floor buttons, for maps with floors
local floors = {}
local function floorbutton(i)
  if floors[i] then return floors[i] end
  local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  b:SetWidth(64)
  b:SetHeight(18)
  b:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -30 - (4 - i) * 66, -8)
  floors[i] = b
  return b
end

-- ------------------------------------------------------------------ pins

local pins = {}
local function PinEnter()
  GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
  GameTooltip:AddLine(this.name, 1, 1, 1)
  for _, line in ipairs(this.what) do
    GameTooltip:AddLine(line, .8, .8, .8)
  end
  GameTooltip:Show()
end
local function PinLeave() GameTooltip:Hide() end

local function pin(i)
  if pins[i] then return pins[i] end
  local f = CreateFrame("Button", nil, map)
  f:SetFrameLevel(map:GetFrameLevel() + 5)
  f:SetWidth(12)
  f:SetHeight(12)
  f.tex = f:CreateTexture(nil, "OVERLAY")
  f.tex:SetAllPoints(f)
  f.tex:SetTexture(pfQuestConfig and (pfQuestConfig.path .. "\\img\\node") or "Interface\\Minimap\\ObjectIcons")
  f:SetScript("OnEnter", PinEnter)
  f:SetScript("OnLeave", PinLeave)
  pins[i] = f
  return f
end

-- boss spots over the painted skulls
local skulls = {}
local function SkullEnter()
  GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
  for i, n in ipairs(this.names) do
    local lvl = this.lvls[i]
    GameTooltip:AddLine(n .. (lvl and lvl ~= "" and ("  |cffaaaaaa" .. lvl .. "|r") or ""),
      1, i == 1 and .82 or 1, i == 1 and 0 or 1)
  end
  GameTooltip:Show()
end
local function skull(i)
  if skulls[i] then return skulls[i] end
  local f = CreateFrame("Button", nil, map)
  f:SetFrameLevel(map:GetFrameLevel() + 3)
  f:SetWidth(18)
  f:SetHeight(18)
  f:SetScript("OnEnter", SkullEnter)
  f:SetScript("OnLeave", PinLeave)
  skulls[i] = f
  return f
end

-- the marker: a pulsing ! on the giver or the one to turn in to, five seconds
local mark = CreateFrame("Frame", nil, map)
mark:SetFrameLevel(map:GetFrameLevel() + 8)
mark:SetWidth(28)
mark:SetHeight(28)
mark.tex = mark:CreateTexture(nil, "OVERLAY")
mark.tex:SetAllPoints(mark)
mark.tex:SetTexture(pfQuestConfig and (pfQuestConfig.path .. "\\img\\available") or "Interface\\GossipFrame\\AvailableQuestIcon")
mark.tex:SetVertexColor(1, .9, .1)
mark:Hide()
mark:SetScript("OnUpdate", function()
  local t = GetTime() - this.start
  if t > 5 then this:Hide() return end
  this.tex:SetAlpha(.55 + .45 * math.abs(math.sin(t * math.pi * 2)))
end)

local function place(f, x, y)
  f:ClearAllPoints()
  f:SetPoint("CENTER", map, "TOPLEFT", x / 100 * W, -y / 100 * H)
end

-- ------------------------------------------------------------------ targets

-- everything a quest points at, wherever it stands: { zone, x, y, kind, name, what }
local function targets(id)
  local q = pfDB["quests"]["data"][id]
  local out = {}
  if not q then return out end
  local units, objects, items = pfDB["units"], pfDB["objects"], pfDB["items"]
  local function add(rec, name, kind, what)
    for _, c in pairs(rec and rec.coords or {}) do
      table.insert(out, { zone = c[3], x = c[1], y = c[2], kind = kind, name = name or "?", what = what })
    end
  end
  local obj = q.obj or {}
  for _, u in pairs(obj.U or {}) do add(units.data[u], units.loc[u], "kill", "kill or speak to") end
  for _, o in pairs(obj.O or {}) do add(objects.data[o], objects.loc[o], "use", "use") end
  for _, i in pairs(obj.I or {}) do
    local it, iname = items.data[i], items.loc[i] or "the quest item"
    for u in pairs(it and it.U or {}) do add(units.data[u], units.loc[u], "drop", "drops " .. iname) end
    for o in pairs(it and it.O or {}) do add(objects.data[o], objects.loc[o], "drop", "holds " .. iname) end
  end
  for _, part in ipairs({ { "start", "giver" }, { "end", "ender" } }) do
    local p = q[part[1]] or {}
    for _, u in pairs(p.U or {}) do add(units.data[u], units.loc[u], part[2], KIND[part[2]][4]) end
    for _, o in pairs(p.O or {}) do add(objects.data[o], objects.loc[o], part[2], KIND[part[2]][4]) end
  end
  return out
end

-- the dungeon a quest's targets are mostly in, if any: its map entry
function M.DungeonOf(id)
  local count, best, bestn = {}, nil, 0
  for _, t in ipairs(targets(id)) do
    local m = M.byzone[t.zone]
    if m and t.kind ~= "giver" and t.kind ~= "ender" then
      count[m.map] = (count[m.map] or 0) + 1
      if count[m.map] > bestn then best, bestn = m, count[m.map] end
    end
  end
  return best
end

-- is the player in the dungeon of this map entry?
function M.Inside(m)
  SetMapToCurrentZone()
  local cur = M.Current()
  return cur and cur.map == m.map
end

-- ------------------------------------------------------------------ fill

local function fill(id, m, inlog)
  panel.id, panel.m, panel.inlog = id, m, inlog
  for i = 1, 12 do
    tiles[i]:SetTexture("Interface\\WorldMap\\" .. m.name .. "\\" .. m.name .. i)
  end
  local title = pfDB["quests"]["loc"][id] and pfDB["quests"]["loc"][id].T or ("quest " .. id)
  panel.title:SetText((m.title or m.name) .. ":  |cffffffff" .. title .. "|r")

  -- one pin per creature or object spot, what it is for gathered on it
  local bykey, n = {}, 0
  for _, t in ipairs(targets(id)) do
    if t.zone == m.zone then
      local key = t.name .. "|" .. t.x .. "|" .. t.y
      local p = bykey[key]
      if not p and n < MAXPINS then
        n = n + 1
        p = pin(n)
        bykey[key] = p
        p.name, p.what, p.kind = t.name, {}, t.kind
        place(p, t.x, t.y)
        p:Show()
      end
      if p then
        local seen = false
        for _, w in ipairs(p.what) do if w == t.what then seen = true end end
        if not seen then table.insert(p.what, t.what) end
        -- the colour of what matters most there: giver/turn in, kill, use, drop
        if t.kind == "giver" or t.kind == "ender" or (p.kind == "drop" and t.kind ~= "drop") then p.kind = t.kind end
      end
    end
  end
  for i = 1, n do
    local c = KIND[pins[i].kind]
    pins[i].tex:SetVertexColor(c[1], c[2], c[3])
  end
  for i = n + 1, table.getn(pins) do pins[i]:Hide() end

  -- the painted skulls
  local spots = pfQuestOcto_BossSpots and pfQuestOcto_BossSpots[m.name] or {}
  for i, sp in ipairs(spots) do
    local f = skull(i)
    f.names, f.lvls = sp.n, sp.l
    place(f, sp.x, sp.y)
    f:Show()
  end
  for i = table.getn(spots) + 1, table.getn(skulls) do skulls[i]:Hide() end

  -- the ! on whoever to see, if they stand on this floor
  mark:Hide()
  local q = pfDB["quests"]["data"][id]
  local who = q and q[inlog and "end" or "start"]
  for _, u in pairs(who and who.U or {}) do
    for _, c in pairs(pfDB["units"]["data"][u] and pfDB["units"]["data"][u].coords or {}) do
      if c[3] == m.zone then
        place(mark, c[1], c[2])
        mark.start = GetTime()
        mark:Show()
        break
      end
    end
  end

  -- the floors of this map
  local i = 0
  for _, f in ipairs(pfQuestOcto_DungeonMaps or {}) do
    if f.map == m.map then
      i = i + 1
      if i <= 4 then
        local b = floorbutton(i)
        b:SetText("Floor " .. f.floor)
        b.m = f
        b:SetScript("OnClick", function() fill(panel.id, this.m, panel.inlog) end)
        if f.name == m.name then b:Disable() else b:Enable() end
        b:Show()
      end
    end
  end
  for k = 1, 4 do
    if floors[k] and (i < 2 or k > i) then floors[k]:Hide() end
  end
end

-- open the panel on a quest: the floor with most of its targets
function M.ShowDungeon(id, m, inlog)
  local count, best, bestn = {}, m, -1
  for _, t in ipairs(targets(id)) do
    count[t.zone] = (count[t.zone] or 0) + 1
  end
  for _, f in ipairs(pfQuestOcto_DungeonMaps or {}) do
    if f.map == m.map and (count[f.zone] or 0) > bestn then best, bestn = f, count[f.zone] or 0 end
  end
  fill(id, best, inlog)
  panel:Show()
end
