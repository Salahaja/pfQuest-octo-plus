--[[ MoonwhisperMap -- measure the mapping between two world maps.

     Why this exists: octowow.st gives Moonwhisper Coast NPC positions in
     WINTERSPRING map space, because that is the map its data computes against.
     The game, however, gives Moonwhisper Coast a map of its own. So pins land
     correctly on the Winterspring map and nowhere at all on the Moonwhisper
     one, and pfQuest's minimap, which looks the zone up by its real name,
     finds nothing.

     Converting one space to the other needs the rectangle Moonwhisper occupies
     inside Winterspring. That is not in any file here, but it is measurable:
     stand anywhere inside both maps and the game will report your position in
     each. Two positions give the scale and offset per axis; a third shows
     whether the relationship is really linear rather than only looking like it
     from two points.

     Samples go to SavedVariables rather than the chat frame so they can be
     read off disk exactly as recorded, with no transcription in between.

     Usage, standing inside Moonwhisper Coast:
       /mwmap            take a sample here
       /mwmap solve      show the transform from the samples so far
       /mwmap clear      throw the samples away
       /mwmap zones      list what the client calls the nearby maps
     Take 3 samples, well apart, then /reload so the file is written.
]]

MoonwhisperMap_Samples = MoonwhisperMap_Samples or {}

local MW = {}
local PARENT = "Winterspring"
local TARGET = "Moonwhisper Coast"

local function say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff7fd5ffMoonwhisperMap|r: " .. msg)
end

--[[ Find a map by the name the client itself uses, since that is the only
     name pfQuest will ever match against. Returns continent and zone index. ]]
function MW.FindMap(name)
  local continents = { GetMapContinents() }
  for cid = 1, table.getn(continents) do
    local zones = { GetMapZones(cid) }
    for mid = 1, table.getn(zones) do
      if zones[mid] == name then return cid, mid end
    end
  end
  return nil
end

--[[ Where the player is on a given map, as the game reports it.

     Returns nil when the player is outside that map's rectangle -- the API
     answers 0,0 for that, which is indistinguishable from the top-left corner
     and would quietly poison the fit. The caller has to know the difference. ]]
function MW.PositionOn(cid, mid)
  local oc, oz = GetCurrentMapContinent(), GetCurrentMapZone()
  SetMapZoom(cid, mid)
  local x, y = GetPlayerMapPosition("player")
  SetMapZoom(oc, oz)
  if not x or (x == 0 and y == 0) then return nil end
  return x * 100, y * 100
end

function MW.Sample()
  local pc, pm = MW.FindMap(PARENT)
  local tc, tm = MW.FindMap(TARGET)

  if not tc then
    say("|cffff5179the client has no map called '" .. TARGET .. "'|r. " ..
      "Run |cffffffff/mwmap zones|r and tell me what it is called instead.")
    return
  end
  if not pc then
    say("|cffff5179no map called '" .. PARENT .. "'|r - that should not happen.")
    return
  end

  local tx, ty = MW.PositionOn(tc, tm)
  local px, py = MW.PositionOn(pc, pm)

  if not tx then
    say("you are not inside the " .. TARGET .. " map. Stand in the zone first.")
    return
  end
  if not px then
    --[[ The interesting failure. It would mean Moonwhisper is NOT inside
         Winterspring's rectangle, so the site's coordinates cannot be
         converted at all and must be re-derived some other way. Worth saying
         plainly rather than recording a zero. ]]
    say("|cffffcc00you are inside " .. TARGET .. " but NOT inside " .. PARENT ..
      "'s map rectangle.|r That changes the approach - tell me this happened.")
    table.insert(MoonwhisperMap_Samples,
      { note = "outside parent", zone = GetRealZoneText(),
        tx = tx, ty = ty, subzone = GetSubZoneText() })
    return
  end

  table.insert(MoonwhisperMap_Samples, {
    tx = tx, ty = ty, px = px, py = py,
    zone = GetRealZoneText(), subzone = GetSubZoneText(),
    mapfile = GetMapInfo(),
  })

  say(string.format("sample %d: %s (%.2f, %.2f)  =  %s (%.2f, %.2f)",
    table.getn(MoonwhisperMap_Samples), TARGET, tx, ty, PARENT, px, py))
  if table.getn(MoonwhisperMap_Samples) < 3 then
    say("walk a good distance and do it again - " ..
      (3 - table.getn(MoonwhisperMap_Samples)) .. " more, then |cffffffff/reload|r.")
  else
    say("that is enough. |cffffffff/mwmap solve|r, then |cffffffff/reload|r.")
  end
end

--[[ Least-squares fit of parent = a * target + b, per axis.

     Two points would determine it exactly; the extra ones are there to expose
     a relationship that is not actually linear -- which is what the residual
     reports. A large residual means the maps are not a simple scale and offset
     of one another and nothing built on this fit would be trustworthy. ]]
function MW.Solve()
  local n = table.getn(MoonwhisperMap_Samples)
  local usable = {}
  for i = 1, n do
    local s = MoonwhisperMap_Samples[i]
    if s.px and s.tx then table.insert(usable, s) end
  end
  local m = table.getn(usable)
  if m < 2 then
    say("need at least 2 usable samples, have " .. m)
    return
  end

  local function fit(get_t, get_p)
    local st, sp, stt, stp = 0, 0, 0, 0
    for i = 1, m do
      local t, p = get_t(usable[i]), get_p(usable[i])
      st = st + t; sp = sp + p; stt = stt + t * t; stp = stp + t * p
    end
    local denom = m * stt - st * st
    if denom == 0 then return nil end
    local a = (m * stp - st * sp) / denom
    local b = (sp - a * st) / m
    local worst = 0
    for i = 1, m do
      local t, p = get_t(usable[i]), get_p(usable[i])
      local err = math.abs(a * t + b - p)
      if err > worst then worst = err end
    end
    return a, b, worst
  end

  local ax, bx, ex = fit(function(s) return s.tx end, function(s) return s.px end)
  local ay, by, ey = fit(function(s) return s.ty end, function(s) return s.py end)

  if not ax or not ay then
    say("samples are all at the same spot on one axis - walk further apart.")
    return
  end

  say(string.format("x: parent = %.5f * target + %.5f   (worst miss %.3f)", ax, bx, ex))
  say(string.format("y: parent = %.5f * target + %.5f   (worst miss %.3f)", ay, by, ey))
  if ex > 0.5 or ey > 0.5 then
    say("|cffffcc00the fit is poor|r - the maps may not be a plain scale and offset.")
  end
  MoonwhisperMap_Samples.fit = { ax = ax, bx = bx, ay = ay, by = by,
                                 ex = ex, ey = ey, n = m }
end

function MW.Zones()
  --[[ What the client calls things, which is the only naming pfQuest matches
       on. Printed for the continent we are on, plus anything whose name looks
       related, in case the zone is called something other than I assumed. ]]
  local cid = GetCurrentMapContinent()
  say("you are in |cffffffff" .. tostring(GetRealZoneText()) .. "|r" ..
    " (subzone " .. tostring(GetSubZoneText()) .. ", map file " ..
    tostring(GetMapInfo()) .. ")")
  local zones = { GetMapZones(cid) }
  local out = {}
  for i = 1, table.getn(zones) do
    table.insert(out, i .. "=" .. zones[i])
  end
  say("continent " .. cid .. " maps: " .. table.concat(out, ", "))
end

SLASH_MOONWHISPERMAP1 = "/mwmap"
SlashCmdList["MOONWHISPERMAP"] = function(msg)
  local cmd = string.lower(msg or "")
  if cmd == "solve" then
    MW.Solve()
  elseif cmd == "clear" then
    MoonwhisperMap_Samples = {}
    say("samples cleared.")
  elseif cmd == "zones" then
    MW.Zones()
  else
    MW.Sample()
  end
end

MoonwhisperMap = MW
