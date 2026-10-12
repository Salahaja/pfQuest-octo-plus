-- Drives the instance quest window (instances.lua) the way a player would,
-- once as an Alliance character and once as a Horde one: opens every
-- instance, expands every chain, scrolls through and hovers every row. Fails
-- on any Lua error, a step listed twice in one chain, or a quest for the
-- other faction -- by race mask, or because only the other faction's NPCs
-- give it.
--
--   lua tools/test_window.lua <pfQuest dir> <build-cache dir>     (from the repo root)
--
-- The database is loaded by test_build.lua's own code, so the two agree.

local f = assert(io.open('tools/test_build.lua', 'rb'))
local loader = f:read('a'):gsub('\nif failures > 0 then.*$', '\n')
f:close()
local f2 = assert(io.open('tools/test_window.lua', 'rb'))
local drive = f2:read('a'):match('%-%-%[==%[DRIVE\r?\n(.*)\n%-%- DRIVE %]==%]')
f2:close()

local bad = 0
for _, side in ipairs({ { 'Alliance', 'Human', 1 }, { 'Horde', 'Orc', 2 } }) do
	local prelude = ("FACTION, RACE, RACEBIT = %q, %q, %d\n"):format(side[1], side[2], side[3])
	local quiet = print
	print = function(s) if type(s) == 'string' and s:match('^  ui ') or tostring(s):match('ERROR') or tostring(s):match('OTHER') or tostring(s):match('FAIL') then quiet(s) end end
	local chunk = assert(load(prelude .. loader .. drive, '@test_window', 't'))
	local ok, err = pcall(chunk)
	print = quiet
	if not ok then print('  FAIL ' .. tostring(err)) bad = bad + 1 end
	if (WINDOW_ERRORS or 0) + (WINDOW_DUPES or 0) + (WINDOW_OTHER or 0) > 0 or (WINDOW_ROWS or 0) < 300 then bad = bad + 1 end
end
if bad > 0 then
	print('test_window: failed')
	os.exit(1)
end
print('test_window: both factions clean')

--[==[DRIVE
-- ---------------------------------------------------------------- drive the window
-- FACTION, RACE, RACEBIT set by the caller
frame = function()
	return setmetatable({}, { __index = function(_, k)
		if k == 'SetScript' then return function(self, what, fn) handlers[#handlers + 1] = { self, what, fn } end end
		if k:match('^Create') then return function() return frame() end end
		if k == 'GetName' then return function() return 'StubFrame' end end
		if k == 'IsShown' then return function() return true end end
		if k == 'GetFrameLevel' or k == 'GetWidth' or k == 'GetHeight' then return function() return 100 end end
		-- methods only; a field nobody set is nil, as on a real frame
		if k:match('^%u') then return noop end
	end })
end
handlers = {}
bit = { band = function(a, b) return a & b end }
UnitLevel = function() return 45 end
UnitRace = function() return RACE, RACE end
UnitClass = function() return 'Warlock', 'WARLOCK' end
UnitFactionGroup = function() return FACTION end
GetTime = function() return 0 end
IsShiftKeyDown = function() return false end
OFFSET = 0
FauxScrollFrame_Update = noop
FauxScrollFrame_GetOffset = function() return OFFSET end
FauxScrollFrame_SetOffset = noop
pfQuestOctoInstancesRightScrollBar = frame()
pfDatabase = { GetBitByRace = function() return RACEBIT end, GetBitByClass = function() return 256 end,
	GetHexDifficultyColor = function() return '' end, SearchQuestID = function() return {} end,
	GetBestMap = noop, QueryServer = noop }
pfMap = { GetMapNameByID = function(_, z) return 'zone' end, ShowMapID = noop, UpdateNodes = noop,
	-- pfQuest's name lookup inside Zul'Farrak gives the quest id, 978
	GetMapID = function() if GetMapInfo() == 'ZulFarrak' then return 978 end end, SetMapByID = noop }
WorldMapFrame, WorldMapButton, WorldMapTooltip = frame(), frame(), frame()
SetMapZoom, ToggleWorldMap = noop, noop
GetMapInfo = function() return 'TheDeadmines' end
OPENED = {}
-- the game's lists, and SetMapZoom held to them: anything else crashed the
-- client (2.2.0 passed a dungeon's map id as the continent)
GetMapContinents = function() return 'Kalimdor', 'Eastern Kingdoms' end
GetMapZones = function(c) if c == 1 then return 'Durotar', 'Tanaris' elseif c == 2 then return 'Westfall', 'Elwynn Forest' end end
SetMapToCurrentZone = noop
BADZOOM = 0
SetMapZoom = function(c, z)
	OPENED[#OPENED + 1] = c
	if c ~= nil and (c < 0 or c > 2) or z ~= nil and (z < 1 or z > 2) then
		BADZOOM = BADZOOM + 1
		if BADZOOM < 4 then print(("  FAIL SetMapZoom(%s, %s) is outside the game's lists"):format(tostring(c), tostring(z))) end
	end
end
pfQuest = { questlog = { [4264] = {} } }
pfQuest_history = { [4182] = {}, [4183] = {}, [166] = {}, [40817] = {}, [8915] = {} }
GameTooltip = setmetatable({}, { __index = function() return noop end })
SlashCmdList = { PFDB = noop }
for _, k in ipairs({ 'quests', 'units', 'objects', 'items', 'zones' }) do pfDB[k].loc = pfDB[k].enUS end
run('db/instances-turtle.lua')
-- a dungeon map with two unnamed boss icons, one where VanCleef stands
WorldMapFrame_Update = noop
GetNumMapLandmarks = function() return 2 end
local marks = { { 75.7 / 100, 28.6 / 100 }, { .02, .98 } }
GetMapLandmarkInfo = function(i) return '', '', 0, marks[i][1], marks[i][2] end
local pois = {}
getglobal = function(n) pois[n] = pois[n] or frame() return pois[n] end
TOOLTIP = {}
WorldMapTooltip = setmetatable({}, { __index = function(_, k)
	if k == 'AddLine' then return function(_, t) TOOLTIP[#TOOLTIP + 1] = t end end
	return noop
end })
run('maps.lua')
run('instances.lua')

local function each(what) local out = {} for _, h in ipairs(handlers) do if h[2] == what then out[#out + 1] = h end end return out end
local errors, rows, dupes, other, seen = 0, 0, 0, 0, {}
local function call(h)
	this = h[1]
	local ok, err = pcall(h[3])
	if not ok then errors = errors + 1 if errors < 6 then print('  ERROR ' .. tostring(err)) end end
end
local mine = FACTION == 'Horde' and 'H' or 'A'
local function wrong(id)
	local q = pfDB.quests.data[id]
	if q.race and (q.race & RACEBIT) == 0 then return 'race' end
	local s, ok, any = q.start or {}, false, false
	for _, u in pairs(s.U or {}) do any = true local r = pfDB.units.data[u] if not r or not r.fac or r.fac:find(mine) then ok = true end end
	for _, o in pairs(s.O or {}) do any = true local r = pfDB.objects.data[o] if not r or not r.fac or r.fac:find(mine) then ok = true end end
	if any and not ok then return 'giver' end
end

for _, h in ipairs(each('OnShow')) do call(h) end
local click
for _, h in ipairs(each('OnClick')) do if rawget(h[1], 'inst') ~= nil then click = h break end end
for _, inst in ipairs(pfQuestOcto_Instances) do
	OFFSET = 0
	rawset(click[1], 'inst', inst)
	call(click)
	-- open every chain, scrolling down as the list grows
	for off = 0, 600, 22 do
		OFFSET = off
		for _, h in ipairs(each('OnClick')) do
			local row = rawget(h[1], 'row')
			if row and (row.kind == 'group' or row.kind == 'section') and not row.open then call(h) end
		end
	end
	for off = 0, 600, 22 do
		OFFSET = off
		rawset(click[1], 'inst', inst)
		call(click)
		for _, h in ipairs(each('OnEnter')) do
			local row = rawget(h[1], 'row')
			if row then
				rows = rows + 1
				call(h)
				-- click a quest: pins, opens a map, flashes the marker
				if row.kind == 'step' then
					for _, c in ipairs(each('OnClick')) do
						if c[1] == h[1] then call(c) CLICKS = (CLICKS or 0) + 1 end
					end
				end
				local ids = {}
				if row.kind == 'group' then
					ids[1] = row.id
					local names = {}
					for _, s in ipairs(row.chain.steps) do
						ids[#ids + 1] = s.id
						local n = (pfDB.quests.enUS[s.id] or {}).T
						if names[n] then dupes = dupes + 1 end
						names[n] = true
					end
				elseif row.kind == 'step' then ids[1] = row.step.id end
				for _, id in ipairs(ids) do
					local w = wrong(id)
					if w and not seen[id] then
						seen[id] = true
						other = other + 1
						if other < 6 then print(('  OTHER FACTION (%s): %s %d %s'):format(w, inst.name, id, tostring((pfDB.quests.enUS[id] or {}).T))) end
					end
				end
			end
		end
	end
end
print(('  ui (%s): %d rows looked at, %d errors, %d duplicate step names in a chain, %d other-faction quests'):format(FACTION, rows, errors, dupes, other))
-- the marker's frame-by-frame update, and the boss icons' tooltips
GetTime = function() return 1 end
for _, h in ipairs(each('OnUpdate')) do call(h) end
WorldMapFrame_Update()
for _, h in ipairs(each('OnEnter')) do
	if h[1] == pois.WorldMapFramePOI1 or h[1] == pois.WorldMapFramePOI2 then call(h) end
end
if TOOLTIP[1] ~= 'Edwin VanCleef' or TOOLTIP[2] then
	print('  FAIL boss icon tooltips: ' .. table.concat(TOOLTIP, ', '))
	errors = errors + 1
end
errors = errors + BADZOOM
-- inside Zul'Farrak pfQuest's name lookup says 978; the map's own zone is 1176
GetMapInfo = function() return 'ZulFarrak' end
local id = pfMap:GetMapID(5, 1)
if id ~= 1176 then print('  FAIL inside ZulFarrak pfQuest draws on ' .. tostring(id) .. ', not 1176') errors = errors + 1 end
GetMapInfo = function() return 'TheDeadmines' end
WINDOW_ERRORS, WINDOW_DUPES, WINDOW_OTHER, WINDOW_ROWS = errors, dupes, other, rows
print(('  ui (%s): %d quest clicks, %d dungeon maps opened'):format(FACTION, CLICKS or 0, #OPENED))
-- DRIVE ]==]
