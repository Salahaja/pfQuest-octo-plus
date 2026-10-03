--[[ pfQuest-octo-extra

     Fills the quests pfQuest-turtle carries and pfQuest-octo does not.

     WHY THIS IS A SEPARATE ADDON rather than edits inside pfQuest-octo:
     pfQuest-octo's db/ is generated upstream and its own README says editing
     it loses the changes on the next export. OctoLauncher has also been seen
     to force-reset managed addon folders. A folder of our own survives both,
     and removing it is the whole uninstall.

     WHY IT PATCHES AT LOAD rather than shipping a replacement database:
     pfQuest merges extensions by mutating pfDB[kind]["data"] in place -- see
     patchtable.lua in pfQuest-octo -- and looks entries up per call rather
     than building an index at load. So adding entries to the same tables
     after that merge is exactly as visible as being in it, and costs no
     duplicated database.

     Load order comes from "## Dependencies: pfQuest, pfQuest-octo" in the
     .toc. Without it this would run before there is anything to patch. ]]

local ADDED = { quests = 0, units = 0, objects = 0, items = 0, zones = 0 }
local SKIPPED = { quests = 0, units = 0, objects = 0, items = 0, zones = 0 }

--[[ Add-only, never overwrite.

     The point is to fill holes, not to win arguments with pfQuest-octo. If an
     id is already present it came from the vanilla database or from octo's own
     Octo-specific corrections, and either is a better authority on this server
     than a Turtle export is. A future octo update that adds one of these
     quests therefore takes precedence automatically, and the skip count is
     how you can tell that happened. ]]
local function fill(into, from, kind)
  if not into or not from then return end
  for id, entry in pairs(from) do
    if into[id] == nil then
      into[id] = entry
      ADDED[kind] = (ADDED[kind] or 0) + 1
    else
      SKIPPED[kind] = (SKIPPED[kind] or 0) + 1
    end
  end
end

local function apply()
  if not pfDB or not pfQuestOctoExtra then return false end

  for _, kind in ipairs({ "quests", "units", "objects", "items" }) do
    if pfDB[kind] then
      fill(pfDB[kind]["data"], pfQuestOctoExtra.data[kind], kind)
      --[[ "loc" is the live locale table pfQuest picked at load, and the one
           every lookup actually reads. Writing to pfDB[kind]["enUS"] instead
           would land in a table that has already been freed on a non-enUS
           client. The names here are enUS only -- as is pfQuest-octo -- so on
           another locale these read as English rather than as nothing. ]]
      fill(pfDB[kind]["loc"], pfQuestOctoExtra.enUS[kind], kind .. "-names")
    end
  end

  --[[ Registering a map that pfQuest has never heard of.

       pfQuest identifies a map by NAME, not by number: pfMap:GetMapID takes
       whatever GetMapZones() calls the zone and looks that string up in
       pfDB["zones"]["loc"] to get an id. A zone missing from that table has no
       id at all, so nothing can be stored against it and nothing can be drawn
       on it -- which is exactly why Moonwhisper Coast's map came up blank
       while the same pins showed correctly on Winterspring's.

       The minimap goes through the same lookup with GetRealZoneText(), and
       then needs the zone's size in yards to turn a world position into an
       offset on the dial. Both halves are required; with the name alone the
       world map works and the minimap stays empty. ]]
  if pfQuestOctoExtra.zones and pfDB["zones"] then
    fill(pfDB["zones"]["loc"], pfQuestOctoExtra.zones, "zones")
    --[[ Also into the raw locale table where it exists. pfQuest nils the
         inactive ones at load, so this is skipped rather than resurrecting a
         table it deliberately freed. ]]
    if pfDB["zones"]["enUS"] and pfDB["zones"]["enUS"] ~= pfDB["zones"]["loc"] then
      fill(pfDB["zones"]["enUS"], pfQuestOctoExtra.zones, "zones-enUS")
    end
  end

  if pfQuestOctoExtra.minimap and pfDB["minimap"] then
    fill(pfDB["minimap"], pfQuestOctoExtra.minimap, "minimap")
  end

  -- The database is in memory now; the generated tables are just a second copy.
  pfQuestOctoExtra.data = nil
  pfQuestOctoExtra.enUS = nil
  pfQuestOctoExtra.zones = nil
  pfQuestOctoExtra.minimap = nil
  collectgarbage()
  return true
end

--[[ Two databases, one set of tables.

     pfQuest-octo and pfQuest-turtle both assign pfDB[kind]["data-turtle"] and
     both declare the same SavedVariables, so this bundle and either of them
     cannot coexist: whichever loads last silently wins and the other's work is
     thrown away. Nothing errors, the data is simply wrong, which is the worst
     way for it to go.

     Checked rather than documented, because "do not run both" in a readme is
     read by the people who were never going to. ]]
local function conflicts()
    local found = {}
    for _, name in ipairs({ "pfQuest-octo", "pfQuest-turtle" }) do
        if IsAddOnLoaded and IsAddOnLoaded(name) then
            table.insert(found, name)
        end
    end
    return found
end

local clash = conflicts()

pfQuestOctoExtra = pfQuestOctoExtra or {}
pfQuestOctoExtra.conflicts = clash
pfQuestOctoExtra.applied = apply()

if table.getn(clash) > 0 then
    --[[ On PLAYER_LOGIN rather than now: printing during load goes to a chat
         frame that does not exist yet, so the one person who most needs to see
         this would be the one person who never does. ]]
    local warn = CreateFrame("Frame")
    warn:RegisterEvent("PLAYER_LOGIN")
    warn:SetScript("OnEvent", function()
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff33ffccpf|cffffffffQuest |cffcccccc[Octo DB+]|r: " ..
            "|cffff5179" .. table.concat(clash, " and ") .. " is also enabled|r. " ..
            "They use the same database tables, so one of them is being " ..
            "discarded. Disable " .. table.concat(clash, " and ") ..
            " - this addon already contains the Octo database.")
    end)
end

function pfQuestOctoExtra:Status()
  local parts = {}
  for _, kind in ipairs({ "quests", "units", "objects", "items", "zones" }) do
    table.insert(parts, string.format("%s %d", kind, ADDED[kind] or 0))
  end
  return table.concat(parts, ", ")
end

SLASH_PFQUESTOCTOEXTRA1 = "/pfoe"
SlashCmdList["PFQUESTOCTOEXTRA"] = function()
  local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccpf|cffffffffQuest-octo-extra: |r" .. msg)
  end
  if not pfQuestOctoExtra.applied then
    say("|cffff5179did not load|r - pfQuest or pfQuest-octo is missing or " ..
      "loaded after this. Check both are enabled.")
    return
  end
  say("added " .. pfQuestOctoExtra:Status())
  local skipped = 0
  for _, n in pairs(SKIPPED) do skipped = skipped + n end
  if skipped > 0 then
    --[[ Not a problem, and worth being able to see: it means octo (or the
         vanilla database) has since grown its own entry for something in
         here, and theirs was kept. ]]
    say("|cff888888" .. skipped .. " entr(ies) already known and left alone.|r")
  end
end
