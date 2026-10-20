--!nonstrict
-- Taskwarrior — bar widget that toggles the task panel.
--
-- The widget runs no command. The panel loads the tasks when the glyph is
-- clicked and publishes the pending count through the plugin's state
-- channel; at startup the widget reads the count from the snapshot the
-- panel wrote last, so the tooltip has a number before the panel has ever
-- run.
--
-- The glyph is configurable (widget setting). It lights up while the panel is
-- open (shared "todo_open" state, published by panel.luau).

local taskwarrior = require("./taskwarrior.luau")
local snapshot = require("./snapshot.luau")

local PANEL_ID = "lpzchr/taskwarrior:panel"
local open = false
local pending = 0
local known = false -- a count is known, rather than "never loaded"
local missing = false

local function render()
	barWidget.setGlyph(noctalia.getConfig("glyph"))
	barWidget.setGlyphColor(open and "primary" or "on_surface")
	if missing then
		barWidget.setTooltip(noctalia.tr("tooltip_missing"))
	elseif known then
		barWidget.setTooltip(noctalia.tr("tooltip", { count = pending }))
	else
		barWidget.setTooltip(noctalia.tr("tooltip_no_snapshot"))
	end
end

-- The count the tooltip shows. One place, so the state channel and the
-- snapshot on disk cannot disagree about what is known.
local function setCount(count)
	if type(count) ~= "number" then
		return
	end
	pending = count
	known = true
end

-- The count of the last load, from the snapshot on disk. The panel
-- publishes the fresh count once it has run.
local function readSnapshot()
	local snap = snapshot.read()
	if snap == nil then
		-- No snapshot, or one from another Taskwarrior instance. Either way
		-- the count on screen belongs to an instance that is no longer in use.
		pending = 0
		known = false
		return
	end
	setCount(snap.pendingCount)
end

noctalia.state.watch("todo_open", function(value)
	open = value == true
	render()
end)

noctalia.state.watch(taskwarrior.PENDING_COUNT_KEY, function(value)
	setCount(value)
	render()
end)

function onClick()
	noctalia.togglePanel(PANEL_ID)
end

missing = not taskwarrior.available()

-- A panel that ran before this widget was placed has already published a
-- count; the watch above only fires on a change.
local published = noctalia.state.get(taskwarrior.PENDING_COUNT_KEY)
if type(published) == "number" then
	setCount(published)
else
	readSnapshot()
end

-- A setting change can point the plugin at another Taskwarrior, or at a
-- binary that is no longer there. The count on the bar belongs to the
-- instance in use, so it is read again through the snapshot, which checks
-- the instance.
function onConfigChanged()
	missing = not taskwarrior.available()
	known = false
	pending = 0
	readSnapshot()
	render()
end

render()
