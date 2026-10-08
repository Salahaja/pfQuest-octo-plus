-- Dumps a pfQuest database as JSON, the way the client ends up with it: the
-- base database, then an extension's tables, then its overwrites.lua, then
-- the patchtable merge (entries replace, "_" deletes).
--
--   lua dump.lua <pfQuest dir> [<extension dir>] > out.json
--
-- Output: { "<kind>": { "data": {id: record}, "loc": {id: name} }, ... }
-- for quests, units, objects and items; enUS names only.

local base, ext = arg[1], arg[2]

pfDB = setmetatable({}, {
	__index = function(t, k)
		local v = {}
		rawset(t, k, v)
		return v
	end
})

local function run(path, optional)
	local f = io.open(path, 'rb')
	if not f then
		if optional then return false end
		error('missing ' .. path)
	end
	local src = f:read('a'):gsub('^\239\187\191', '')
	f:close()
	assert(load(src, '@' .. path))()
	return true
end

local kinds = { 'quests', 'units', 'objects', 'items' }
for _, k in ipairs(kinds) do
	run(base .. '/db/' .. k .. '.lua')
	run(base .. '/db/enUS/' .. k .. '.lua')
end

-- not dumped, but overwrites.lua writes to it
run(base .. '/db/areatrigger.lua')

if ext and ext ~= '' then
	for _, k in ipairs(kinds) do
		run(ext .. '/db/' .. k .. '-turtle.lua')
		run(ext .. '/db/enUS/' .. k .. '-turtle.lua')
	end
	run(ext .. '/db/areatrigger-turtle.lua', true)
	-- overwrites edit the extension's tables before the merge, as in game;
	-- one that fails is reported, not fatal, since it then fails in game too
	local ok, err = pcall(run, ext .. '/overwrites.lua', true)
	if not ok then io.stderr:write('overwrites.lua: ', tostring(err), '\n') end
	for _, k in ipairs(kinds) do
		for _, pair in ipairs({ { 'data', 'data-turtle' }, { 'enUS', 'enUS-turtle' } }) do
			local dst, diff = pfDB[k][pair[1]], pfDB[k][pair[2]]
			for id, v in pairs(diff) do
				if v == '_' then dst[id] = nil else dst[id] = v end
			end
		end
	end
end

local function esc(s)
	return '"' .. tostring(s):gsub('[%c"\\]', function(c)
		return string.format('\\u%04x', c:byte())
	end) .. '"'
end

local out = {}
local function w(s) out[#out + 1] = s end

local function json(v)
	local t = type(v)
	if t == 'number' then
		w(v == math.floor(v) and string.format('%d', v) or string.format('%.10g', v))
	elseif t == 'string' then
		w(esc(v))
	elseif t == 'boolean' then
		w(tostring(v))
	elseif t == 'table' then
		local n, count = #v, 0
		for _ in pairs(v) do count = count + 1 end
		if count > 0 and n == count then
			w('[')
			for i = 1, n do
				if i > 1 then w(',') end
				json(v[i])
			end
			w(']')
		else
			w('{')
			local first = true
			for k, val in pairs(v) do
				if not first then w(',') end
				first = false
				w(esc(k)); w(':'); json(val)
			end
			w('}')
		end
	else
		w('null')
	end
end

io.write('{')
for i, k in ipairs(kinds) do
	out = {}
	w(i > 1 and ',' or ''); w(esc(k)); w(':{"data":'); json(pfDB[k]['data'])
	w(',"loc":'); json(pfDB[k]['enUS']); w('}')
	io.write(table.concat(out))
end
io.write('}')
