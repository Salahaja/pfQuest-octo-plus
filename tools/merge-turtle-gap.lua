--[[ Pull the quests pfQuest-turtle has and pfQuest-octo does not into a
     standalone extension addon.

     Loaded with Lua rather than parsed with regex, because these files ARE
     Lua: the base database is minified onto single lines and the extension
     ones are pretty-printed, and a parser that copes with both is a worse
     version of the interpreter already present.

     Run from the AddOns directory:
       lua merge239.lua <output-dir>
]]

local OUT = (...) or "pfQuest-octo-extra"

pfDB = {}
for _, k in ipairs({ "areatrigger", "items", "meta", "minimap", "objects",
                     "professions", "quests", "quests-itemreq", "refloot",
                     "units", "zones" }) do
  pfDB[k] = {}
end

local function load(path)
  local chunk, err = loadfile(path)
  if not chunk then return nil, err end
  local ok, rerr = pcall(chunk)
  if not ok then return nil, rerr end
  return true
end

local function loadAll(paths, label)
  for _, p in ipairs(paths) do
    local ok, err = load(p)
    if not ok then print(string.format("  !! %s: %s", p, tostring(err))) end
  end
end

-- ---------------------------------------------------------------- base
local BASE = "pfQuest/db/"
loadAll({
  BASE .. "items.lua", BASE .. "units.lua", BASE .. "objects.lua",
  BASE .. "refloot.lua", BASE .. "quests-itemreq.lua", BASE .. "quests.lua",
  BASE .. "zones.lua", BASE .. "minimap.lua", BASE .. "areatrigger.lua",
  BASE .. "meta.lua",
  BASE .. "enUS/items.lua", BASE .. "enUS/units.lua",
  BASE .. "enUS/objects.lua", BASE .. "enUS/quests.lua",
  BASE .. "enUS/zones.lua", BASE .. "enUS/professions.lua",
}, "base")

-- ---------------------------------------------------------------- octo
local OCTO = "pfQuest-octo/db/"
loadAll({
  OCTO .. "items-turtle.lua", OCTO .. "units-turtle.lua",
  OCTO .. "objects-turtle.lua", OCTO .. "refloot-turtle.lua",
  OCTO .. "quests-itemreq-turtle.lua", OCTO .. "quests-turtle.lua",
  OCTO .. "zones-turtle.lua", OCTO .. "minimap-turtle.lua",
  OCTO .. "areatrigger-turtle.lua", OCTO .. "meta-turtle.lua",
  OCTO .. "enUS/items-turtle.lua", OCTO .. "enUS/units-turtle.lua",
  OCTO .. "enUS/objects-turtle.lua", OCTO .. "enUS/quests-turtle.lua",
  OCTO .. "enUS/zones-turtle.lua",
}, "octo")

--[[ Move octo's tables aside. Turtle's files assign to the very same keys, so
     without this the second load simply replaces the first and there is
     nothing left to compare against. ]]
local KINDS = { "quests", "units", "objects", "items" }
local octo = {}
for _, k in ipairs(KINDS) do
  octo[k] = { data = pfDB[k]["data-turtle"] or {}, loc = pfDB[k]["enUS-turtle"] or {} }
  pfDB[k]["data-turtle"], pfDB[k]["enUS-turtle"] = nil, nil
end

-- ---------------------------------------------------------------- turtle
local TURTLE = "pfQuest-turtle/db/"
loadAll({
  TURTLE .. "items-turtle.lua", TURTLE .. "units-turtle.lua",
  TURTLE .. "objects-turtle.lua", TURTLE .. "refloot-turtle.lua",
  TURTLE .. "quests-itemreq-turtle.lua", TURTLE .. "quests-turtle.lua",
  TURTLE .. "zones-turtle.lua", TURTLE .. "minimap-turtle.lua",
  TURTLE .. "areatrigger-turtle.lua", TURTLE .. "meta-turtle.lua",
  TURTLE .. "enUS/items-turtle.lua", TURTLE .. "enUS/units-turtle.lua",
  TURTLE .. "enUS/objects-turtle.lua", TURTLE .. "enUS/quests-turtle.lua",
  TURTLE .. "enUS/zones-turtle.lua",
}, "turtle")

local turtle = {}
for _, k in ipairs(KINDS) do
  turtle[k] = { data = pfDB[k]["data-turtle"] or {}, loc = pfDB[k]["enUS-turtle"] or {} }
end

local function size(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

print("loaded:")
for _, k in ipairs(KINDS) do
  print(string.format("  %-8s base=%-6d octo=%-6d turtle=%-6d",
    k, size(pfDB[k]["data"]), size(octo[k].data), size(turtle[k].data)))
end

-- ---------------------------------------------------------------- the gap
--[[ What the client already knows is base patched with octo, which is exactly
     what pfQuest-octo's patchtable.lua produces at load. ]]
local function known(kind, id)
  return (pfDB[kind]["data"] and pfDB[kind]["data"][id] ~= nil)
      or (octo[kind].data[id] ~= nil)
end

local missingQuests = {}
for id in pairs(turtle.quests.data) do
  if not known("quests", id) then table.insert(missingQuests, id) end
end
table.sort(missingQuests)
print(string.format("\nquests in turtle but not in base+octo: %d", #missingQuests))

--[[ Those quests point at NPCs, objects and items for their start, end and
     objectives. A quest whose questgiver is unknown is a quest with nothing to
     draw, so the referenced entries have to come across as well -- that is
     where the coordinates live. ]]
local need = { units = {}, objects = {}, items = {} }
local SECTIONS = { "start", "end", "obj" }
local LETTER = { U = "units", O = "objects", I = "items" }

for _, qid in ipairs(missingQuests) do
  local q = turtle.quests.data[qid]
  for _, section in ipairs(SECTIONS) do
    local s = q[section]
    if type(s) == "table" then
      for letter, kind in pairs(LETTER) do
        local list = s[letter]
        if type(list) == "table" then
          for _, ref in ipairs(list) do
            local id = ref
            -- An objective can be {id, count}; the id is what we want.
            if type(ref) == "table" then id = ref[1] end
            if type(id) == "number" and not known(kind, id)
               and turtle[kind].data[id] then
              need[kind][id] = true
            end
          end
        end
      end
    end
  end
end

for _, kind in ipairs({ "units", "objects", "items" }) do
  print(string.format("  referenced %-8s to bring across: %d", kind, size(need[kind])))
end

-- ---------------------------------------------------------------- emit
--[[ Serialized in a stable order. The files are generated, so a regeneration
     that changed nothing should produce no diff -- otherwise there is no way
     to see what an update actually did. ]]
local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do table.insert(keys, k) end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function quote(s)
  s = string.gsub(s, "\\", "\\\\")
  s = string.gsub(s, '"', '\\"')
  s = string.gsub(s, "\n", "\\n")
  s = string.gsub(s, "\r", "")
  return '"' .. s .. '"'
end

local function ser(v)
  local t = type(v)
  if t == "number" then
    -- %s on an integer-valued float would print 1.0; keep ids as integers.
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      return string.format("%d", v)
    end
    return tostring(v)
  elseif t == "string" then
    return quote(v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "table" then
    local parts = {}
    -- Array part first, then the rest by key, so output is deterministic.
    local n = 0
    for i = 1, #v do parts[#parts + 1] = ser(v[i]); n = i end
    for _, k in ipairs(sortedKeys(v)) do
      if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
        parts[#parts + 1] = "[" .. ser(k) .. "]=" .. ser(v[k])
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end

os.execute('mkdir "' .. string.gsub(OUT .. "/db", "/", "\\") .. '" 2>nul')

-- A level-1 long bracket, because the text itself contains ]] and a plain
-- [[ ... ]] would end at the first one.
local HEADER = [=[
--[[ GENERATED -- do not edit by hand.

     Quests that pfQuest-turtle carries and pfQuest-octo does not, with the
     NPCs, objects and items they refer to, so the markers have somewhere to
     point. Regenerate with tools/merge-turtle-gap.lua.
]]
]=] .. "\n"

-- data
local f = io.open(OUT .. "/db/data.lua", "w")
f:write(HEADER)
f:write("pfQuestOctoExtra = pfQuestOctoExtra or {}\n")
f:write("pfQuestOctoExtra.data = {\n")
for _, kind in ipairs({ "quests", "units", "objects", "items" }) do
  local ids
  if kind == "quests" then
    ids = missingQuests
  else
    ids = sortedKeys(need[kind])
  end
  f:write(string.format("  [%q] = {\n", kind))
  for _, id in ipairs(ids) do
    f:write(string.format("    [%d]=%s,\n", id, ser(turtle[kind].data[id])))
  end
  f:write("  },\n")
end
f:write("}\n")
f:close()

-- names
local g = io.open(OUT .. "/db/enUS.lua", "w")
g:write(HEADER)
g:write("pfQuestOctoExtra = pfQuestOctoExtra or {}\n")
g:write("pfQuestOctoExtra.enUS = {\n")
for _, kind in ipairs({ "quests", "units", "objects", "items" }) do
  local ids = (kind == "quests") and missingQuests or sortedKeys(need[kind])
  g:write(string.format("  [%q] = {\n", kind))
  for _, id in ipairs(ids) do
    local v = turtle[kind].loc[id]
    if v ~= nil then
      g:write(string.format("    [%d]=%s,\n", id, ser(v)))
    end
  end
  g:write("  },\n")
end
g:write("}\n")
g:close()

print(string.format("\nwrote %s/db/data.lua and %s/db/enUS.lua", OUT, OUT))

-- A couple of samples, so "it ran" and "it produced the right thing" are not
-- the same claim.
print("\nsample quests:")
for i = 1, math.min(5, #missingQuests) do
  local id = missingQuests[i]
  print(string.format("  %-7d %s", id, tostring(turtle.quests.loc[id]
    and turtle.quests.loc[id].T or "?")))
end
