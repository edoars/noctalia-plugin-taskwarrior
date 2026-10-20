--!nonstrict
-- Snapshot of the last Taskwarrior export, kept on disk.
--
-- The plugin runs no background command: the bar widget and the panel read
-- this file instead of shelling out to `task` on a timer, and the panel
-- writes it after every load.
--
-- A snapshot belongs to one Taskwarrior instance. `instance` names the
-- binary, the rc file, and the data directory the rows came from, so a
-- settings change cannot show another instance's tasks.

local taskwarrior = require("./taskwarrior.luau")

local cache = {}

local FILE_NAME = "tasks.json"
local VERSION = 1

local function filePath()
	local dir, err = noctalia.pluginDataDir()
	if dir == nil then
		return nil, err
	end
	return dir .. "/" .. FILE_NAME
end

-- Read the snapshot. Returns nil when there is nothing to restore: no file
-- yet, another Taskwarrior instance, or a file this version cannot read.
function cache.load()
	local file, pathErr = filePath()
	if file == nil then
		noctalia.log("no plugin data dir for the task snapshot: " .. tostring(pathErr))
		return nil
	end
	local contents = noctalia.readFile(file)
	if contents == nil then
		return nil -- no snapshot yet
	end
	local decoded, decodeErr = noctalia.json.decode(contents)
	if type(decoded) ~= "table" then
		noctalia.log("task snapshot is not valid JSON: " .. tostring(decodeErr))
		return nil
	end
	if decoded.version ~= VERSION then
		return nil -- written by another version of the plugin
	end
	if decoded.instance ~= taskwarrior.instanceKey() then
		return nil -- another Taskwarrior instance
	end
	local rows = {}
	if type(decoded.rows) == "table" then
		for _, row in ipairs(decoded.rows) do
			local task = taskwarrior.normalizeTask(row)
			if task ~= nil then
				table.insert(rows, task)
			end
		end
	end
	return {
		rows = rows,
		filter = type(decoded.filter) == "string" and decoded.filter or "",
		total = type(decoded.total) == "number" and decoded.total or nil,
		savedAt = type(decoded.savedAt) == "number" and decoded.savedAt or nil,
	}
end

-- Write the snapshot. `total` is the pending count of the last unfiltered
-- load, kept beside the rows so the bar can show it without running a
-- command of its own. Returns ok, err.
function cache.save(rows, filter, total)
	local file, pathErr = filePath()
	if file == nil then
		return false, pathErr
	end
	local encoded, encodeErr = noctalia.json.encode({
		version = VERSION,
		instance = taskwarrior.instanceKey(),
		savedAt = math.floor(noctalia.nowMs() / 1000),
		filter = filter or "",
		total = total,
		rows = rows or {},
	})
	if encoded == nil then
		return false, encodeErr
	end
	return noctalia.writeFile(file, encoded)
end

return cache
