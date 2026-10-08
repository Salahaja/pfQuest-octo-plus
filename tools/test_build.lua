-- Loads pfQuest and this addon the way the client does -- base database, the
-- files the .toc names in order, then the real patchtable.lua against
-- stand-ins for the WoW API -- and checks what comes out.
--
--   lua tools/test_build.lua <pfQuest dir> <build-cache dir>     (from the repo root)

local base, cache = arg[1], arg[2]
local failures = 0
local function fail(msg, ...)
	failures = failures + 1
	print('  FAIL ' .. string.format(msg, ...))
end

local function readfile(path)
	local f = assert(io.open(path, 'rb'), 'missing ' .. path)
	local s = f:read('a'):gsub('^\239\187\191', '')
	f:close()
	return s
end
local function run(path)
	assert(load(readfile(path), '@' .. path))()
end

-- Lua 5.0 built-ins the client has and 5.4 does not
table.getn = function(t) return #t end
string.gfind = string.gmatch

-- ---------------------------------------------------------------- base
pfDB = setmetatable({}, { __index = function(t, k) local v = {} rawset(t, k, v) return v end })
pfDB.locales = { enUS = 'English' }
for _, f in ipairs({ 'items', 'units', 'objects', 'quests', 'zones', 'minimap', 'meta',
                     'refloot', 'areatrigger', 'quests-itemreq' }) do
	run(base .. '/db/' .. f .. '.lua')
end
for _, f in ipairs({ 'items', 'units', 'objects', 'quests', 'zones', 'professions' }) do
	run(base .. '/db/enUS/' .. f .. '.lua')
end

-- ---------------------------------------------------------------- addon
local toc = readfile('pfQuest-octo-plus.toc')
local loaded = 0
for line in toc:gmatch('[^\r\n]+') do
	if line:match('^init\\') then
		local xml = readfile(line:gsub('\\', '/'))
		for inc in xml:gmatch('file="([^"]+)"') do
			run(('init/' .. inc):gsub('\\', '/'))
			loaded = loaded + 1
		end
	end
end
print(string.format('  loaded %d database file(s) from the .toc', loaded))

-- stand-ins for what patchtable.lua touches at load
local handlers, calls = {}, {}
local function noop() end
local function frame()
	local f = {}
	return setmetatable(f, { __index = function(_, k)
		if k == 'SetScript' then
			return function(self, what, fn) handlers[#handlers + 1] = { self, what, fn } end
		end
		return noop
	end })
end
GetLocale = function() return 'enUS' end
GetMapZones = function() return end
CreateFrame = function() return frame() end
GetMouseFocus = function() return nil end
SendChatMessage = noop
DEFAULT_CHAT_FRAME = { AddMessage = noop }
GameTooltip = { SetText = noop, Show = noop, AddLine = noop }
pfMap = {}
pfQuest = { Debug = noop }
pfQuest_history, pfQuest_questcache = {}, {}
pfDatabase = setmetatable({}, { __index = function(_, k)
	return function() calls[k] = (calls[k] or 0) + 1 end
end })
SlashCmdList = {}

run('patchtable.lua')
for _, h in ipairs(handlers) do
	if h[2] == 'OnEvent' then
		this, event = h[1], 'PLAYER_ENTERING_WORLD'
		local ok, err = pcall(h[3])
		if not ok then fail('an OnEvent handler errors: %s', err) end
	end
end

-- ---------------------------------------------------------------- checks
local Q, QL = pfDB.quests.data, pfDB.quests.enUS

local function lines(path)
	local out = {}
	for l in readfile(path):gmatch('%d+') do out[#out + 1] = tonumber(l) end
	return out
end

local expected = lines(cache .. '/expected-quests.txt')
local missing, untitled = 0, 0
for _, id in ipairs(expected) do
	if type(Q[id]) ~= 'table' then missing = missing + 1 end
	if not (type(QL[id]) == 'table' and QL[id].T) then untitled = untitled + 1 end
end
if missing > 0 then fail('%d server quest(s) missing after the merge', missing) end
if untitled > 0 then fail('%d server quest(s) without a title', untitled) end

local left = 0
for _, id in ipairs(lines(cache .. '/removed-quests.txt')) do
	if Q[id] ~= nil then left = left + 1 end
end
if left > 0 then fail('%d quest(s) the server lacks survived the merge', left) end

local total = 0
for _ in pairs(Q) do total = total + 1 end
if total ~= #expected then
	fail('%d quests after the merge, the server has %d', total, #expected)
end

-- every coordinate four numbers, nothing left on the made-up Moonwhisper id
for _, kind in ipairs({ 'units', 'objects' }) do
	local bad, alias = 0, 0
	for id, rec in pairs(pfDB[kind].data) do
		for _, c in pairs(type(rec) == 'table' and rec.coords or {}) do
			if type(c[1]) ~= 'number' or type(c[2]) ~= 'number' or type(c[3]) ~= 'number'
				or type(c[4]) ~= 'number' then
				bad = bad + 1
			end
			if c[3] == 5700 then alias = alias + 1 end
		end
	end
	if bad > 0 then fail('%d %s coordinate(s) are not four numbers', bad, kind) end
	if alias > 0 then fail('%d %s coordinate(s) on zone 5700', alias, kind) end
end

-- what a quest points at has a record to point with
local nostart, noend = 0, 0
for id, q in pairs(Q) do
	for _, which in ipairs({ 'start', 'end' }) do
		local s = q[which]
		if s then
			local known = false
			for _, u in pairs(s.U or {}) do if pfDB.units.data[u] then known = true end end
			for _, o in pairs(s.O or {}) do if pfDB.objects.data[o] then known = true end end
			for _, i in pairs(s.I or {}) do if pfDB.items.data[i] then known = true end end
			if not known then
				if which == 'start' then nostart = nostart + 1 else noend = noend + 1 end
			end
		end
	end
end
print(string.format('  quests whose start / end names nothing in the database: %d / %d', nostart, noend))

-- Moonwhisper Coast
if pfDB.zones.enUS[5642] ~= 'Moonwhisper Coast' then fail('zone 5642 is %s', tostring(pfDB.zones.enUS[5642])) end
local mm = pfDB.minimap[5642]
if not (mm and mm[1] > mm[2]) then fail('Moonwhisper minimap size is not {width, height}') end
for _, z in ipairs({ 5600, 5098, 5550, 5132, 5140 }) do
	if pfDB.zones.enUS[z] then fail('phantom zone %d still named', z) end
end

if pfQuest.dburl ~= 'https://octowow.st/db/?quest=' then fail('dburl is %s', tostring(pfQuest.dburl)) end
if not calls.BuildNameIndex then fail('the name index is not rebuilt after the merge') end
if not calls.Reload then fail('pfDatabase:Reload() was not called') end

print(string.format('  %d quests, %d units, %d objects, %d items after the merge', total,
	(function() local n = 0 for _ in pairs(pfDB.units.data) do n = n + 1 end return n end)(),
	(function() local n = 0 for _ in pairs(pfDB.objects.data) do n = n + 1 end return n end)(),
	(function() local n = 0 for _ in pairs(pfDB.items.data) do n = n + 1 end return n end)()))

if failures > 0 then
	print(string.format('%d check(s) failed', failures))
	os.exit(1)
end
print('test_build: all checks passed')
