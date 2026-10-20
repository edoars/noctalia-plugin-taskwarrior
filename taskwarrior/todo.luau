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
local cache = require("./cache.luau")

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
		barWidget.setTooltip(noctalia.tr("tooltip_uncached"))
	end
end

-- The count of the last load, from the snapshot on disk. The panel
-- publishes the fresh count once it has run.
local function readSnapshot()
	local snapshot = cache.load()
	if snapshot == nil or snapshot.total == nil then
		return
	end
	pending = snapshot.total
	known = true
end

noctalia.state.watch("todo_open", function(value)
	open = value == true
	render()
end)

noctalia.state.watch("todo_count", function(value)
	if type(value) == "number" then
		pending = value
		known = true
		render()
	end
end)

function onClick()
	noctalia.togglePanel(PANEL_ID)
end

missing = not taskwarrior.available()

-- A panel that ran before this widget was placed has already published a
-- count; the watch above only fires on a change.
local published = noctalia.state.get("todo_count")
if type(published) == "number" then
	pending = published
	known = true
else
	readSnapshot()
end

render()
