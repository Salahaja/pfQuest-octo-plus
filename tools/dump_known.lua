-- Dump every quest id the client resolves after the real load chain, so the
-- comparison against the site uses what pfQuest actually has rather than a
-- regex guess at these files.
pfDB = {}
for _, k in ipairs({ "areatrigger","items","meta","minimap","objects",
                     "professions","quests","quests-itemreq","refloot",
                     "units","zones" }) do pfDB[k] = {} end
local function run(p) local c = loadfile(p); if c then pcall(c) end end
for _, f in ipairs({"items","units","objects","refloot","quests-itemreq",
                    "quests","zones","minimap","areatrigger","meta"}) do
  run("pfQuest/db/"..f..".lua")
end
for _, f in ipairs({"items","units","objects","quests","zones","professions"}) do
  run("pfQuest/db/enUS/"..f..".lua")
end
pfDB.locales = { enUS = "English" }
for _, k in ipairs({"quests","units","objects","items"}) do
  pfDB[k]["loc"] = pfDB[k]["enUS"] or {}
end
for _, f in ipairs({"items","units","objects","refloot","quests-itemreq",
                    "quests","zones","minimap","areatrigger","meta"}) do
  run("pfQuest-octo/db/"..f.."-turtle.lua")
end
for _, f in ipairs({"items","units","objects","quests","zones"}) do
  run("pfQuest-octo/db/enUS/"..f.."-turtle.lua")
end
GetLocale = function() return "enUS" end
GetMapZones = function() return "Desolace" end
pfQuest, pfMap = {}, {}
pfDatabase = { icons = {}, Reload = function() end }
CreateFrame = function() return setmetatable({}, {__index=function() return function() end end}) end
run("pfQuest-octo/overwrites.lua")
run("pfQuest-octo/patchtable.lua")
run("pfQuest-octo-extra/db/data.lua")
run("pfQuest-octo-extra/db/enUS.lua")
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
SlashCmdList = {}
run("pfQuest-octo-extra/inject.lua")
local f = io.open("pfQuest-octo-extra/tools/known_quests.txt", "w")
for id in pairs(pfDB["quests"]["data"]) do f:write(id, "\n") end
f:close()
local n = 0
for _ in pairs(pfDB["quests"]["data"]) do n = n + 1 end
print("quests the client resolves: " .. n)
