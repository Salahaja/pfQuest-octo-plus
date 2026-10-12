-- Instance quests: every quest an instance has, the chains that lead to them
-- and the keys and attunements that open it, with where this character is
-- in each. The lists are built by tools/build.py (db/instances-turtle.lua);
-- this file only draws them. /db instances, /instq.
--
-- A chain is folded into one row: the quest it ends with, how far along it
-- is, and the step to do now. Expanding it lists the steps in order. Only
-- steps this character can reach are counted -- the other faction's half of
-- a chain is not -- and steps that share a name (the same step offered by
-- two givers, or once per class) are one step.

local ROWS, LIST, ROWH = 22, 22, 16
-- the order rows are listed in: what can be done now first
local STATE_ORDER = { next = 1, active = 2, low = 3, locked = 4, done = 5 }
-- how far along: of two quests that are the same step, the one further on counts
local PROGRESS = { locked = 1, low = 2, next = 3, active = 4, done = 5 }
local STATE_COLOR = {
  done = "|cff55ff55", active = "|cffffff00", next = "|cff33ffcc",
  low = "|cffff8040", locked = "|cff888888",
}
local STATE_WORD = { done = "done", active = "in log", next = "ready", low = "level", locked = "locked" }

local quests, units, objects, items, qloc
local plevel, prace, pclass, pfaction
local selected, hidedone = nil, false
local expanded = {}
local reach, chains, donecache = {}, {}, {}
-- quest -> the quests that need it and nothing else, built once
local followers

local function db()
  quests, qloc = pfDB["quests"]["data"], pfDB["quests"]["loc"]
  units, objects, items = pfDB["units"], pfDB["objects"], pfDB["items"]
  plevel = UnitLevel("player")
  local _, race = UnitRace("player")
  local _, class = UnitClass("player")
  prace = pfDatabase:GetBitByRace(race)
  pclass = pfDatabase:GetBitByClass(class)
  pfaction = UnitFactionGroup("player") == "Horde" and "H" or "A"
  -- what this character can reach and the chains depend on all of the above
  reach, chains, donecache = {}, {}, {}
  if not followers then
    followers = {}
    for id, q in pairs(quests) do
      if type(q) == "table" and q.pre and q.pre[1] and not q.pre[2] then
        local p = q.pre[1]
        followers[p] = followers[p] or {}
        table.insert(followers[p], id)
      end
    end
  end
end

-- done, or the only way into a quest that is done or in the log: pfQuest's
-- history misses what was finished before it was installed
local function isdone(id)
  if donecache[id] ~= nil then return donecache[id] end
  donecache[id] = false
  local done = pfQuest_history[id] and true or false
  if not done then
    for _, n in pairs(followers[id] or {}) do
      if pfQuest.questlog[n] or isdone(n) then done = true break end
    end
  end
  donecache[id] = done
  return done
end

local function qname(id)
  local l = qloc[id]
  return l and l.T or ("quest " .. id)
end

-- someone of this faction can deal with it: pfQuest's own test, where no
-- faction at all means anyone
local function friendly(rec)
  return not rec or not rec.fac or string.find(rec.fac, pfaction, 1, true)
end

-- quests this character can ever take. The race mask is not enough: 20
-- instance quests carry none and are Horde-only because only Horde NPCs give
-- them (An Earnest Proposition, Just Compensation, A Light in Dark Places)
local function forme(id)
  local q = quests[id]
  if not q then return false end
  if q.race and bit.band(q.race, prace) ~= prace then return false end
  if q.class and pclass and bit.band(q.class, pclass) ~= pclass then return false end
  local s = q.start
  if s and (s.U or s.O) then
    for _, u in pairs(s.U or {}) do
      if friendly(units.data[u]) then return true end
    end
    for _, o in pairs(s.O or {}) do
      if friendly(objects.data[o]) then return true end
    end
    return false
  end
  return true
end

-- for this character, and every prerequisite path not cut by the other
-- faction's or another class's quest
local function reachable(id)
  if reach[id] ~= nil then return reach[id] end
  reach[id] = false
  if not forme(id) then return false end
  if isdone(id) then reach[id] = true return true end
  local pre, ok, any = quests[id].pre, true, false
  if pre then
    ok = false
    for _, p in pairs(pre) do
      if quests[p] then
        any = true
        if reachable(p) then ok = true end
      end
    end
    if not any then ok = true end
  end
  reach[id] = ok
  return ok
end

local function state(id)
  if isdone(id) then return "done" end
  if pfQuest.questlog[id] then return "active" end
  local q = quests[id]
  if q.pre then
    local one = false
    for _, p in pairs(q.pre) do
      if isdone(p) then one = true end
    end
    if not one then return "locked" end
  end
  if q.min and q.min > plevel then return "low" end
  return "next"
end

-- a step: every quest id of one name, its state the furthest along of them
local function step(ids)
  local s = { id = ids[1], ids = ids, state = state(ids[1]) }
  for i = 2, table.getn(ids) do
    local st = state(ids[i])
    if PROGRESS[st] > PROGRESS[s.state] then
      s.state, s.id = st, ids[i]
    end
  end
  return s
end

-- id's chain: its reachable prerequisites, oldest first, then id itself,
-- one step per name
local function chain(id)
  if chains[id] then return chains[id] end
  local order, seen = {}, {}
  local function walk(q)
    if seen[q] then return end
    seen[q] = true
    for _, p in pairs(quests[q].pre or {}) do
      if quests[p] and reachable(p) then walk(p) end
    end
    table.insert(order, q)
  end
  walk(id)
  local byname, steps = {}, {}
  for _, q in ipairs(order) do
    local n = qname(q)
    if byname[n] then
      table.insert(byname[n], q)
    else
      byname[n] = { q }
      table.insert(steps, byname[n])
    end
  end
  local out = { steps = {}, done = 0 }
  for _, ids in ipairs(steps) do
    table.insert(out.steps, step(ids))
  end
  out.total = table.getn(out.steps)
  -- a chain is done in order: a step done or in the log means every step
  -- before it was done, whatever pfQuest's history missed
  local last = 0
  for i, s in ipairs(out.steps) do
    if s.state == "done" or s.state == "active" then last = i end
  end
  for i = 1, last - 1 do out.steps[i].state = "done" end
  for _, s in ipairs(out.steps) do
    if s.state == "done" then out.done = out.done + 1 end
  end
  -- where it stands: done when every step is, else the first step not done
  out.state = "done"
  for _, s in ipairs(out.steps) do
    if s.state ~= "done" then
      out.state, out.now = s.state, s
      if s.state == "locked" then
        -- a locked step whose prerequisite is done elsewhere is still locked;
        -- the step to show is the first one that is not
        for _, t in ipairs(out.steps) do
          if t.state ~= "done" and t.state ~= "locked" then out.now = t break end
        end
      end
      break
    end
  end
  chains[id] = out
  return out
end

-- "Giver Name, Zone (x, y)" for where a quest starts. %.0f, not %d: the
-- client's %d is 32-bit and these are floats.
local function giver(id)
  local s = quests[id] and quests[id].start
  if not s then return "" end
  local name, c
  if s.U and s.U[1] then
    name = units.loc[s.U[1]]
    local u = units.data[s.U[1]]
    c = u and u.coords and u.coords[1]
  elseif s.O and s.O[1] then
    name = objects.loc[s.O[1]]
    local o = objects.data[s.O[1]]
    c = o and o.coords and o.coords[1]
  elseif s.I and s.I[1] then
    name = (items.loc[s.I[1]] or "an item") .. " (item)"
  end
  local zone = c and pfMap:GetMapNameByID(c[3])
  if name and zone then
    return string.format("%s, %s (%.0f, %.0f)", name, zone, c[1], c[2])
  end
  return name or ""
end

local function lvltag(id)
  local lvl = quests[id].lvl or 0
  return pfDatabase:GetHexDifficultyColor(lvl) .. "[" .. lvl .. "]|r "
end

-- ------------------------------------------------------------------ lists

-- an instance's quests as groups: one per chain, chains another chain
-- already holds left out, one per name
local function groups(inst)
  if inst.cache then return inst.cache end
  local tops, inside = {}, {}
  for _, id in pairs(inst.quests) do
    if reachable(id) then
      table.insert(tops, id)
      local c = chain(id)
      for i = 1, c.total - 1 do
        for _, q in pairs(c.steps[i].ids) do inside[q] = true end
      end
    end
  end
  local out, named = {}, {}
  for _, id in ipairs(tops) do
    local n = qname(id)
    if not inside[id] then
      if named[n] then
        -- another quest of the same name: keep the one furthest along
        local g = named[n]
        local c = chain(id)
        if PROGRESS[c.state] > PROGRESS[g.chain.state] then g.id, g.chain = id, c end
      else
        named[n] = { id = id, chain = chain(id) }
        table.insert(out, named[n])
      end
    end
  end
  table.sort(out, function(a, b)
    local sa, sb = STATE_ORDER[a.chain.state], STATE_ORDER[b.chain.state]
    if sa ~= sb then return sa < sb end
    local la, lb = quests[a.id].lvl or 0, quests[b.id].lvl or 0
    if la ~= lb then return la < lb end
    return qname(a.id) < qname(b.id)
  end)
  local done = 0
  for _, g in ipairs(out) do
    if g.chain.state == "done" then done = done + 1 end
  end
  -- the key chains, joined into one in order, one step per name. Built from
  -- their last quests: the ones no other quest of the key needs
  local key = { steps = {}, done = 0 }
  local keyseen, needed = {}, {}
  for _, id in pairs(inst.key or {}) do
    for _, p in pairs(quests[id] and quests[id].pre or {}) do needed[p] = true end
  end
  for _, last in pairs(inst.key or {}) do
    if not needed[last] and reachable(last) then
      for _, s in ipairs(chain(last).steps) do
        local n = qname(s.id)
        if not keyseen[n] then
          keyseen[n] = true
          table.insert(key.steps, s)
          if s.state == "done" then key.done = key.done + 1 end
        end
      end
    end
  end
  key.total = table.getn(key.steps)
  inst.cache = { groups = out, done = done, total = table.getn(out), key = key }
  return inst.cache
end

local function clearcache(list)
  for _, inst in pairs(list) do inst.cache = nil end
end

local function progress(a, b)
  local col = a == b and b > 0 and "|cff55ff55" or "|cffcccccc"
  return col .. a .. "/" .. b .. "|r"
end

-- the rows of the right-hand list
local function build(inst)
  local g = groups(inst)
  local out = {}

  if g.key.total > 0 then
    local open = expanded[inst.name .. ":key"]
    table.insert(out, { kind = "section", key = inst.name .. ":key", open = open,
                        text = "Key / attunement", done = g.key.done, total = g.key.total })
    if open then
      for _, s in ipairs(g.key.steps) do
        if not (hidedone and s.state == "done") then
          table.insert(out, { kind = "step", step = s, indent = true })
        end
      end
    end
  end

  if g.total > 0 then
    table.insert(out, { kind = "header", text = "Quests", done = g.done, total = g.total })
    for _, grp in ipairs(g.groups) do
      local c = grp.chain
      if not (hidedone and c.state == "done") then
        if c.total <= 1 then
          table.insert(out, { kind = "step", step = c.steps[1] or { id = grp.id, state = c.state } })
        else
          local key = inst.name .. ":" .. grp.id
          table.insert(out, { kind = "group", key = key, open = expanded[key], id = grp.id, chain = c })
          if expanded[key] then
            for _, s in ipairs(c.steps) do
              if not (hidedone and s.state == "done") then
                table.insert(out, { kind = "step", step = s, indent = true })
              end
            end
          end
        end
      end
    end
  end
  return out
end

-- ------------------------------------------------------------------ frame

local frame = CreateFrame("Frame", "pfQuestOctoInstances", UIParent)
frame:Hide()
frame:SetWidth(800)
frame:SetHeight(ROWS * ROWH + 96)
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

local function button(text, width, x)
  local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  b:SetWidth(width)
  b:SetHeight(20)
  b:SetPoint("TOPLEFT", x, -30)
  b:SetText(text)
  return b
end

local query = button("Query server", 100, 10)
local expandall = button("Expand all", 84, 114)
local collapseall = button("Collapse all", 84, 202)

local hide = CreateFrame("CheckButton", "pfQuestOctoInstancesHideDone", frame, "UICheckButtonTemplate")
hide:SetWidth(20)
hide:SetHeight(20)
hide:SetPoint("TOPLEFT", 292, -30)
getglobal(hide:GetName() .. "Text"):SetText("Hide done")

-- progress of the selected instance
local bar = CreateFrame("StatusBar", nil, frame)
bar:SetPoint("TOPLEFT", 400, -34)
bar:SetWidth(372)
bar:SetHeight(12)
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
bar:SetStatusBarColor(.2, 1, .8)
bar:SetMinMaxValues(0, 1)
bar.bg = bar:CreateTexture(nil, "BACKGROUND")
bar.bg:SetAllPoints(bar)
bar.bg:SetTexture(.15, .15, .15, .9)
bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
bar.text:SetPoint("CENTER", 0, 0)

frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
frame.hint:SetPoint("BOTTOMLEFT", 12, 10)
frame.hint:SetText("Click a chain to open it, a quest to show it on the map. Right-click: the dungeon map. Shift-click links it.")

local TOP = -58

local function scrollframe(name, x, width, count, update)
  local sf = CreateFrame("ScrollFrame", name, frame, "FauxScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", x, TOP)
  sf:SetWidth(width)
  sf:SetHeight(count * ROWH)
  sf:SetScript("OnVerticalScroll", function()
    FauxScrollFrame_OnVerticalScroll(ROWH, update)
  end)
  return sf
end

local Refresh, Redraw

-- left: the instances
local instlist = {}
local instbuttons = {}
local leftscroll = scrollframe("pfQuestOctoInstancesLeft", 8, 156, LIST, function() Redraw() end)

local function InstanceClick()
  selected = this.inst
  FauxScrollFrame_SetOffset(pfQuestOctoInstancesRight, 0)
  pfQuestOctoInstancesRightScrollBar:SetValue(0)
  Redraw()
end

for i = 1, LIST do
  local b = CreateFrame("Button", nil, frame)
  b:SetWidth(154)
  b:SetHeight(ROWH)
  b:SetPoint("TOPLEFT", 10, TOP - (i - 1) * ROWH)
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
local rightscroll = scrollframe("pfQuestOctoInstancesRight", 196, 570, ROWS, function() Redraw() end)
local questbuttons = {}

-- where a quest's start (or end) stands: every spot, and a name
local function where(id, part)
  local p = quests[id] and quests[id][part]
  if not p then return nil end
  for _, ident in pairs(p.U or {}) do
    local rec = units.data[ident]
    if rec and rec.coords and rec.coords[1] then
      return rec.coords, units.loc[ident]
    end
  end
  for _, ident in pairs(p.O or {}) do
    local rec = objects.data[ident]
    if rec and rec.coords and rec.coords[1] then
      return rec.coords, objects.loc[ident]
    end
  end
  return nil
end

local function points(coords, zone)
  local out = {}
  for _, c in pairs(coords) do
    if c[3] == zone then table.insert(out, { c[1], c[2] }) end
  end
  return out
end

-- Show a quest: pfQuest's pins, the map they are on, and a flashing marker
-- for five seconds on whoever to see -- the giver, or once the quest is in
-- the log the one to speak to or turn in to, which pfQuest may not pin.
-- A quest whose targets are in a dungeon you are not in opens the dungeon
-- map panel (panel.lua) instead: once it is in the log, or on a right-click,
-- or when even its giver is in there.
local function showquest(id, st, button)
  if IsShiftKeyDown() and pfQuestCompat and pfQuestCompat.InsertQuestLink then
    pfQuestCompat.InsertQuestLink(id)
    return
  end
  local maps = pfDatabase:SearchQuestID(id, { ["addon"] = "PFDB" })
  local M = pfQuestOctoMaps
  local inlog = st == "active"
  local coords, who = where(id, inlog and "end" or "start")
  local d = M and M.DungeonOf and M.DungeonOf(id)
  if d and not M.Inside(d) then
    local giverinside = coords and M.byzone[coords[1][3]]
    if inlog or button == "RightButton" or giverinside or not coords then
      M.ShowDungeon(id, d, inlog)
      return
    end
  end
  if not M or not coords then
    pfMap:ShowMapID(pfDatabase:GetBestMap(maps))
    return
  end
  local label = (who or "") .. (inlog and "  (turn in)" or "  (quest giver)")
  local zone = coords[1][3]
  if inlog and quests[id].obj then
    -- objectives still to do: their map, and the marker if it is there too
    zone = pfDatabase:GetBestMap(maps) or zone
  end
  if not M.Open(zone) then
    -- a dungeon map the game will not open from here: show where the quest
    -- is given or taken instead, if that is outside
    zone = coords[1][3]
    if M.byzone[zone] or not M.Open(zone) then return end
  end
  M.Flash(points(coords, zone), label)
end

local function QuestClick()
  local row = this.row
  if not row then return end
  if row.kind == "section" or row.kind == "group" then
    expanded[row.key] = not expanded[row.key]
    Redraw()
  elseif row.kind == "step" then
    showquest(row.step.id, row.step.state, arg1)
  end
end

local function QuestEnter()
  local row = this.row
  if not row or row.kind == "header" or row.kind == "section" then return end
  local id = row.kind == "group" and row.id or row.step.id
  GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
  GameTooltip:AddLine(qname(id), 1, 1, 1)
  local q = quests[id]
  GameTooltip:AddLine("Level " .. (q.lvl or "?") .. ", requires " .. (q.min or 1), .8, .8, .8)
  local g = giver(id)
  if g ~= "" then GameTooltip:AddLine("Starts: " .. g, .8, .8, .8) end
  if row.kind == "group" then
    local c = row.chain
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Chain: " .. c.done .. " of " .. c.total .. " steps done", .2, 1, .8)
    for _, s in ipairs(c.steps) do
      local col = STATE_COLOR[s.state]
      GameTooltip:AddLine(col .. STATE_WORD[s.state] .. "|r  " .. qname(s.id), 1, 1, 1)
    end
    if c.now then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Now: " .. qname(c.now.id), .2, 1, .8)
      local ng = giver(c.now.id)
      if ng ~= "" then GameTooltip:AddLine("  from " .. ng, .8, .8, .8) end
    end
  end
  GameTooltip:Show()
end

for i = 1, ROWS do
  local b = CreateFrame("Button", nil, frame)
  b:SetWidth(570)
  b:SetHeight(ROWH)
  b:SetPoint("TOPLEFT", 198, TOP - (i - 1) * ROWH)
  b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  b.state = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.state:SetPoint("LEFT", 2, 0)
  b.state:SetWidth(44)
  b.state:SetJustifyH("LEFT")
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", 48, 0)
  b.text:SetWidth(220)
  b.text:SetJustifyH("LEFT")
  b.note = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  b.note:SetPoint("RIGHT", -2, 0)
  b.note:SetWidth(290)
  b.note:SetJustifyH("RIGHT")
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", QuestClick)
  b:SetScript("OnEnter", QuestEnter)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  questbuttons[i] = b
end

local function drawrow(b, row)
  b.row = row
  b.text:ClearAllPoints()
  b.text:SetPoint("LEFT", row and row.indent and 60 or 48, 0)
  if row.kind == "header" then
    b.state:SetText(progress(row.done, row.total))
    b.text:SetText("|cffffd100" .. row.text .. "|r")
    b.note:SetText("")
  elseif row.kind == "section" then
    b.state:SetText(progress(row.done, row.total))
    b.text:SetText("|cffffd100" .. (row.open and "[-] " or "[+] ") .. row.text .. "|r")
    b.note:SetText("")
  elseif row.kind == "group" then
    local c = row.chain
    b.state:SetText(STATE_COLOR[c.state] .. c.done .. "/" .. c.total .. "|r")
    b.text:SetText((row.open and "[-] " or "[+] ") .. lvltag(row.id) .. qname(row.id))
    if c.now and c.now.id ~= row.id then
      b.note:SetText("now: " .. qname(c.now.id))
    elseif c.now then
      b.note:SetText(giver(row.id))
    else
      b.note:SetText("")
    end
  else
    local s = row.step
    b.state:SetText(STATE_COLOR[s.state] .. STATE_WORD[s.state] .. "|r")
    b.text:SetText(lvltag(s.id) .. qname(s.id))
    if s.state == "next" or s.state == "low" then
      b.note:SetText(giver(s.id))
    else
      b.note:SetText("")
    end
  end
end

-- draw what is already worked out: scrolling, opening a chain
Redraw = function()
  if not frame:IsShown() then return end

  local n = table.getn(instlist)
  FauxScrollFrame_Update(leftscroll, n, LIST, ROWH)
  local off = FauxScrollFrame_GetOffset(leftscroll)
  for i = 1, LIST do
    local b, inst = instbuttons[i], instlist[i + off]
    b.inst = inst
    if inst then
      local g = groups(inst)
      local tag = inst.kind == "r" and "|cffff8040R|r " or ""
      local col = inst == selected and "|cffffd100" or "|cffffffff"
      b.text:SetText(tag .. col .. inst.name .. "|r")
      b.count:SetText(g.total > 0 and progress(g.done, g.total) or "")
      b:Show()
    else
      b:Hide()
    end
  end

  if selected then
    local g = groups(selected)
    local all, done = g.total + g.key.total, g.done + g.key.done
    bar:SetValue(all > 0 and done / all or 0)
    bar.text:SetText(selected.name .. ": " .. done .. "/" .. all)
    bar:Show()
  else
    bar:Hide()
  end

  local list = selected and build(selected) or {}
  n = table.getn(list)
  FauxScrollFrame_Update(rightscroll, n, ROWS, ROWH)
  off = FauxScrollFrame_GetOffset(rightscroll)
  for i = 1, ROWS do
    local b, row = questbuttons[i], list[i + off]
    if row then
      drawrow(b, row)
      b:Show()
    else
      b.row = nil
      b:Hide()
    end
  end
end

-- work everything out again: the quest log, history or level changed
Refresh = function()
  if not frame:IsShown() then return end
  db()
  clearcache(instlist)
  Redraw()
end

hide:SetScript("OnClick", function()
  hidedone = this:GetChecked() and true or false
  Redraw()
end)

local function setall(open)
  if not selected then return end
  local g = groups(selected)
  expanded[selected.name .. ":key"] = open or nil
  for _, grp in ipairs(g.groups) do
    expanded[selected.name .. ":" .. grp.id] = open or nil
  end
  Redraw()
end
expandall:SetScript("OnClick", function() setall(true) end)
collapseall:SetScript("OnClick", function() setall(false) end)

query:SetScript("OnClick", function()
  pfDatabase:QueryServer()
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

-- the quest log fires often; work it out again at most twice a second, and
-- a moment after the server's answer to a query, once pfQuest has stored it
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("QUEST_QUERY_COMPLETE")
frame:SetScript("OnEvent", function()
  frame.due = GetTime() + (event == "QUEST_QUERY_COMPLETE" and 1 or .5)
end)
frame:SetScript("OnUpdate", function()
  if this.due and GetTime() >= this.due then
    this.due = nil
    Refresh()
  end
end)

-- ------------------------------------------------------------------ commands

local function toggle()
  if frame:IsShown() then frame:Hide() else frame:Show() end
end

SLASH_PFQUESTOCTOINST1, SLASH_PFQUESTOCTOINST2 = "/instq", "/instancequests"
SlashCmdList["PFQUESTOCTOINST"] = function(input)
  local cmd = string.lower(input or "")
  local M = pfQuestOctoMaps
  if M and cmd == "mapdebug" then return M.Debug() end
  if M and M.Report and cmd == "report" then return M.Report() end
  if M and M.Mark and cmd == "mark" then return M.Mark() end
  if M and M.ClearMarks and cmd == "marks clear" then return M.ClearMarks() end
  toggle()
end

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
