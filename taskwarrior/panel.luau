--!nonstrict
-- Taskwarrior — capture box and pending-task list, backed by the `task` CLI.
--
-- The panel is a capture surface first: the input at the top holds focus from
-- the moment the panel opens, and Enter files the task and clears the field
-- without losing focus, so several tasks are several keystrokes. The list
-- below is a read-and-tick view; project, tags and due dates are shown but
-- never edited here.
--
-- Opening the panel is what runs `task`. The widget on the bar only toggles
-- the panel, so the plugin starts no command of its own while the panel
-- stays closed.
--
-- The panel owns a FIFO of task processes: the next command is launched only
-- after the previous callback fires, so Taskwarrior is never written by two
-- processes at once. Reads share the queue, so a refresh can never interleave
-- with a write. After writes drain, one coalesced export refreshes the model.
--
-- The last load is kept on disk, so a reopened panel paints the tasks it
-- had last time at once and then refreshes them. The bar widget reads the
-- same snapshot for the pending count it shows in its tooltip.
--
-- UI interactions are optimistic (the row updates immediately) and the queued
-- write confirms; a failed write raises an error notification and the
-- coalesced refresh restores the real state.

local taskwarrior = require("./taskwarrior.luau")
local snapshot = require("./snapshot.luau")

local PANEL_WIDTH = 560 -- keep in sync with the [[panel]] width in plugin.toml
local TEXT_WIDTH = PANEL_WIDTH - 212 -- description room left beside padding and row buttons
local UNDO_SECONDS = 8

local items = {} -- tasks in display order
local loaded = false
local loadError = nil
local lastNotifiedError = nil
local panelOpen = false
local pendingCount = nil -- pending tasks in Taskwarrior, whatever filter is active
local composeSeq = 0 -- bumping the input's key gives a fresh, empty, focused field
local composeText = ""
local filter = "" -- active taskwarrior filter, "" for everything pending
local filterOpen = false
local filterSeq = 0
local editingId = nil
local editingText = ""
local hoveredId = nil
local armedDelete = nil -- uuid whose delete button is one click from firing
local hoverDirty = false -- hover events happened; render once on the next frame tick
local undoTicks = 0 -- seconds the undo affordance stays on screen

-- Serial launch queue. A job is { argv, rev?, count? }: rev marks reads and
-- counts, and a job whose revision is stale (a write was queued after it) is
-- discarded.
local queue = {}
local running = false
local refreshWanted = false
local revision = 0

local render

local function tr(key, args)
	return noctalia.tr(key, args)
end

local function notifyFailure(message)
	if lastNotifiedError ~= message then
		lastNotifiedError = message
		noctalia.notifyError(tr("title"), message)
	end
end

local function findItem(uuid)
	for _, item in ipairs(items) do
		if item.uuid == uuid then
			return item
		end
	end
	return nil
end

local function removeItem(uuid)
	for index, item in ipairs(items) do
		if item.uuid == uuid then
			table.remove(items, index)
			return true
		end
	end
	return false
end

-- ── Settings ────────────────────────────────────────────────────────────────

local function splitList(value, separator)
	local parts = {}
	if type(value) ~= "string" then
		return parts
	end
	for piece in value:gmatch("[^" .. separator .. "]+") do
		local clean = noctalia.string.trim(piece)
		if clean ~= "" then
			table.insert(parts, clean)
		end
	end
	return parts
end

local function defaultTags()
	local tags = {}
	for _, tag in ipairs(splitList(noctalia.getConfig("default_tags"), ",%s")) do
		table.insert(tags, (tag:gsub("^%+", "")))
	end
	return tags
end

local function savedFilters()
	return splitList(noctalia.getConfig("saved_filters"), ",")
end

local function sortOrder()
	local value = noctalia.getConfig("sort_order")
	if value == "newest" or value == "oldest" or value == "alpha" then
		return value
	end
	return "urgency"
end

local function sortItems()
	local order = sortOrder()
	table.sort(items, function(a, b)
		if order == "alpha" then
			local da, db = a.description:lower(), b.description:lower()
			if da ~= db then
				return da < db
			end
		elseif order == "newest" or order == "oldest" then
			if a.entry ~= b.entry then
				if order == "newest" then
					return a.entry > b.entry
				end
				return a.entry < b.entry
			end
		elseif a.urgency ~= b.urgency then
			return a.urgency > b.urgency
		end
		return a.uuid < b.uuid -- uuid is unique: deterministic final tie-break
	end)
end

-- The rows on screen, in display order. Every path that fills the list goes
-- through here, so a fresh load and a restored snapshot are ordered the same
-- way and the sort order setting applies to both.
local function setItems(rows)
	items = rows
	sortItems()
end
-- ── Serial task queue ───────────────────────────────────────────────────────
-- Forward declaration: pump() runs the refresh a write scheduled, and
-- refresh() calls pump() to start the jobs.
local refresh

-- A read job loads the rows the filter selects.
local function makeReadJob()
	return { argv = taskwarrior.exportArgs(filter), rev = revision }
end

-- The count job asks for the number of every pending task. The export
-- already counts the rows when no filter is active, so the count job only
-- runs for a filtered view, where the rows are a subset.
--
-- Like a read job it carries the revision, so a count that was already
-- waiting in the queue when a write arrived is dropped instead of
-- publishing a number that belongs to the older state.
local function makeCountJob()
	return { argv = taskwarrior.countArgs(), count = true, rev = revision }
end

-- Publish the count for the bar widget's tooltip.
local function publishCount(count)
	if count == nil then
		return
	end
	pendingCount = count
	noctalia.state.set(taskwarrior.PENDING_COUNT_KEY, count)
end

-- Keep the snapshot on disk so the next open of the panel paints at once.
-- The rows in it belong to the filter they were loaded with, so they are
-- only restored when that filter is the one in force.
local function saveSnapshot()
	local ok, err = snapshot.write(items, filter, pendingCount)
	if not ok then
		noctalia.log("could not save the task snapshot: " .. tostring(err))
	end
end

local function pump()
	if running then
		return
	end
	if #queue == 0 and refreshWanted then
		-- A write drained: run the one refresh it scheduled. The jobs go
		-- through refresh() so a write-triggered load looks exactly like
		-- the one a filter change schedules.
		refreshWanted = false
		refresh()
		return
	end
	if #queue == 0 then
		return
	end
	local job = table.remove(queue, 1)
	running = true
	taskwarrior.run(job.argv, function(result)
		running = false
		if job.count then
			if job.rev == revision then
				local count, countErr = taskwarrior.parseCount(result)
				if count == nil then
					-- The count is a nicety for the tooltip. The read
					-- below still loads the rows, so a failure here is
					-- not worth an error notification.
					noctalia.log("task count failed: " .. tostring(countErr))
				else
					publishCount(count)
				end
			end
		elseif job.rev ~= nil then
			if job.rev == revision then
				local tasks, err = taskwarrior.parseExport(result)
				if err ~= nil then
					loadError = tr("load_failed")
					notifyFailure(err)
				else
					setItems(tasks)
					loadError = nil
					lastNotifiedError = nil
					if editingId ~= nil and findItem(editingId) == nil then
						editingId = nil
						editingText = ""
					end
					if filter == "" then
						-- Every pending task is on screen, so the rows
						-- are the count.
						publishCount(#tasks)
					end
					saveSnapshot()
				end
				loaded = true
				render()
			end
		else
			local message = taskwarrior.failureMessage(result)
			if message ~= nil then
				notifyFailure(message)
			end
		end
		pump()
	end)
end
-- A load is the rows for the active filter, plus the pending count when a
-- filter hides some of the tasks. Every load goes through here, so the two
-- kinds of load always look the same.
refresh = function()
	revision += 1
	if filter ~= "" then
		table.insert(queue, makeCountJob())
	end
	table.insert(queue, makeReadJob())
	pump()
end

-- Every write invalidates in-flight reads (revision) and schedules exactly
-- one refresh once the queue drains (refreshWanted).
local function queueWrite(argv)
	revision += 1
	refreshWanted = true
	table.insert(queue, { argv = argv })
	pump()
end

-- ── Model operations (optimistic) ───────────────────────────────────────────

local function markUndoable()
	undoTicks = UNDO_SECONDS
	panel.setWantsSecondTicks(true)
end

local function commitCompose(value)
	local parsed = taskwarrior.parseCompose(value)
	composeText = ""
	composeSeq += 1 -- new key: the host builds an empty field and focuses it
	if parsed.description ~= "" then
		queueWrite(taskwarrior.addArgs(parsed, defaultTags()))
	end
	render()
end

local function enterEdit(uuid)
	local item = findItem(uuid)
	if item == nil then
		return
	end
	editingId = uuid
	editingText = item.description
	armedDelete = nil
	render()
end

local function commitEdit(uuid, value)
	local text = noctalia.string.trim(value or "")
	local item = findItem(uuid)
	editingId = nil
	editingText = ""
	if item ~= nil and text ~= "" and text ~= item.description then
		item.description = text
		sortItems()
		queueWrite(taskwarrior.modifyDescriptionArgs(uuid, text))
	end
	render()
end

local function completeTask(uuid)
	if findItem(uuid) == nil then
		return
	end
	if editingId == uuid then
		editingId = nil
		editingText = ""
	end
	removeItem(uuid)
	armedDelete = nil
	markUndoable()
	queueWrite(taskwarrior.doneArgs(uuid))
	render()
end

-- First click arms, second click deletes: there is no confirmation dialog in
-- the host and delete is permanent.
local function deleteTask(uuid)
	if findItem(uuid) == nil then
		return
	end
	if armedDelete ~= uuid then
		armedDelete = uuid
		render()
		return
	end
	if editingId == uuid then
		editingId = nil
		editingText = ""
	end
	removeItem(uuid)
	armedDelete = nil
	markUndoable()
	queueWrite(taskwarrior.deleteArgs(uuid))
	render()
end

local function undoLast()
	undoTicks = 0
	queueWrite(taskwarrior.undoArgs())
	render()
end

local function applyFilter(value)
	filter = noctalia.string.trim(value or "")
	armedDelete = nil
	refresh()
	render()
end

-- ── UI pieces ───────────────────────────────────────────────────────────────

local function chip(key, text, color, fill)
	return ui.row({
		key = key,
		fill = fill,
		radius = 4,
		paddingH = 6,
		paddingV = 1,
		align = "center",
	}, {
		ui.label({ text = text, fontSize = 11, color = color }),
	})
end

local DUE_COLORS = { overdue = "error", today = "primary", tomorrow = "primary", days = "on_surface_variant", date = "on_surface_variant" }

local function dueChip(item)
	local kind, detail = taskwarrior.dueKind(item.due)
	if kind == "none" then
		return nil
	end
	local text
	if kind == "days" then
		text = tr("due_days", { count = detail })
	elseif kind == "date" then
		text = detail
	else
		text = tr("due_" .. kind)
	end
	local color = DUE_COLORS[kind] or "on_surface_variant"
	return chip("due-" .. item.uuid, text, color, color .. "/0.14")
end

-- Muted second line: project, tags, due, annotation count. Nothing here is
-- interactive; editing metadata belongs in the CLI.
local function metaRow(item)
	local parts = {}
	if item.project ~= "" then
		table.insert(parts, chip("proj-" .. item.uuid, item.project, "on_surface_variant", "surface_variant/0.7"))
	end
	for index, tag in ipairs(item.tags) do
		if index > 3 then
			break
		end
		table.insert(parts, chip("tag-" .. item.uuid .. "-" .. tag, "+" .. tag, "primary", "primary/0.12"))
	end
	local due = dueChip(item)
	if due ~= nil then
		table.insert(parts, due)
	end
	if item.notes > 0 then
		table.insert(parts, ui.row({ key = "notes-" .. item.uuid, gap = 3, align = "center" }, {
			ui.glyph({ name = "note", size = 12, color = "on_surface_variant" }),
			ui.label({ text = tostring(item.notes), fontSize = 11, color = "on_surface_variant" }),
		}))
	end
	if #parts == 0 then
		return nil
	end
	return ui.row({ key = "meta-" .. item.uuid, gap = 6, align = "center" }, parts)
end

-- Every interactive child of a row steals hover from the row container (only
-- the innermost target reports), which made the row highlight flicker as the
-- pointer crossed the checkbox or text. Each child gets a key encoding the
-- row's uuid and the shared named handler, so the row reads as one target and
-- teardown leaves are still delivered after a re-render (closures from a
-- superseded render are dropped by the host, which is how highlights got
-- stuck on).

local function glyphButton(key, glyph, tooltip, variant, opacity, onClick, onHover)
	local spec = {
		key = key,
		glyph = glyph,
		glyphSize = 16,
		variant = variant,
		controlSize = "sm",
		width = 30,
		height = 30,
		opacity = opacity,
		tooltip = tooltip,
		onClick = onClick,
		onHover = onHover,
	}
	return ui.button(spec)
end
local function taskRow(item)
	local uuid = item.uuid
	local hovered = hoveredId == uuid
	local armed = armedDelete == uuid
	local children = {
		glyphButton("done-" .. uuid, "square", tr("tip_done"), "ghost", 1, function()
			completeTask(uuid)
		end, "onRowHover"),
	}

	if editingId == uuid then
		table.insert(
			children,
			ui.input({
				key = "edit-" .. uuid,
				value = editingText,
				focus = true,
				fontSize = 14,
				controlSize = "sm",
				flexGrow = 1,
				onChange = function(value)
					editingText = value
				end,
				onSubmit = function(value)
					commitEdit(uuid, value)
				end,
			})
		)
		table.insert(
			children,
			glyphButton("save-" .. uuid, "check", tr("tip_commit"), "primary", 1, function()
				commitEdit(uuid, editingText)
			end)
		)
		table.insert(
			children,
			glyphButton("cancel-" .. uuid, "close", tr("tip_cancel"), "ghost", 1, function()
				editingId = nil
				editingText = ""
				render()
			end)
		)
	else
		local lines = {
			ui.label({
				key = "text-" .. uuid,
				text = item.description,
				fontSize = 14,
				color = "on_surface",
				maxWidth = TEXT_WIDTH,
				maxLines = 2,
			}),
		}
		local meta = metaRow(item)
		if meta ~= nil then
			table.insert(lines, meta)
		end
		table.insert(
			children,
			ui.column({
				key = "body-" .. uuid,
				gap = 3,
				flexGrow = 1,
				align = "start",
				justify = "center",
				onClick = function()
					enterEdit(uuid)
				end,
				onHover = "onRowHover",
			}, lines)
		)
		-- Kept in the tree at zero opacity so the row never shifts on hover.
		table.insert(
			children,
			glyphButton("edit-" .. uuid, "pencil", tr("tip_edit"), "ghost", hovered and 1 or 0, function()
				enterEdit(uuid)
			end, "onRowHover")
		)
		table.insert(
			children,
			glyphButton(
				"del-" .. uuid,
				armed and "trash-x" or "trash",
				armed and tr("tip_delete_confirm") or tr("tip_delete"),
				armed and "destructive" or "ghost",
				(hovered or armed) and 1 or 0,
				function()
					deleteTask(uuid)
				end,
				"onRowHover"
			)
		)
	end

	return ui.row({
		key = "row-" .. uuid,
		gap = 6,
		align = "center",
		paddingH = 4,
		paddingV = 4,
		radius = 8,
		-- Never nil: the host's tree diff does not revert a prop that goes from a
		-- value back to nil, so an unhovered row must repaint with an explicit
		-- transparent fill or the last highlight sticks on screen.
		fill = hovered and "surface_variant/0.5" or "surface_variant/0",
		onHover = "onRowHover",
	}, children)
end

local function filterChips()
	local chips = {
		ui.button({
			key = "filter-all",
			text = tr("filter_all"),
			variant = filter == "" and "primary" or "ghost",
			controlSize = "sm",
			fontSize = 12,
			onClick = function()
				applyFilter("")
			end,
		}),
	}
	for index, saved in ipairs(savedFilters()) do
		table.insert(
			chips,
			ui.button({
				key = "filter-" .. tostring(index),
				text = saved,
				variant = filter == saved and "primary" or "ghost",
				controlSize = "sm",
				fontSize = 12,
				onClick = function()
					applyFilter(saved)
				end,
			})
		)
	end
	table.insert(chips, ui.spacer({ flexGrow = 1 }))
	table.insert(
		chips,
		glyphButton("filter-toggle", "search", tr("tip_filter"), filterOpen and "primary" or "ghost", 1, function()
			filterOpen = not filterOpen
			filterSeq += 1
			render()
		end)
	)
	return ui.row({ key = "filters", gap = 4, align = "center" }, chips)
end
-- One string per parse result, so any change to the parsed tags or attributes
-- (not just their count) invalidates the chips.
local function signatureOf(parsed)
	local parts = {}
	for _, token in ipairs(parsed.tags) do
		table.insert(parts, token)
	end
	for _, token in ipairs(parsed.attributes) do
		table.insert(parts, token)
	end
	return table.concat(parts, "\1")
end

local function composeBlock()
	local rows = {
		ui.input({
			key = "compose-" .. tostring(composeSeq),
			value = "",
			placeholder = tr("placeholder"),
			focus = true,
			fontSize = 15,
			controlSize = "lg",
			onChange = function(value)
				local before = signatureOf(taskwarrior.parseCompose(composeText))
				composeText = value
				if signatureOf(taskwarrior.parseCompose(value)) ~= before then
					render()
				end
			end,
			onSubmit = commitCompose,
		}),
	}
	local parsed = taskwarrior.parseCompose(composeText)
	local preview = {}
	for _, tag in ipairs(parsed.tags) do
		table.insert(preview, chip("pre-tag-" .. tag, tag, "primary", "primary/0.12"))
	end
	for _, attribute in ipairs(parsed.attributes) do
		table.insert(preview, chip("pre-attr-" .. attribute, attribute, "secondary", "secondary/0.14"))
	end
	if #preview > 0 then
		table.insert(preview, 1, ui.label({ text = tr("parsed"), fontSize = 11, color = "on_surface_variant" }))
		table.insert(rows, ui.row({ key = "preview", gap = 6, align = "center" }, preview))
	end
	return ui.column({ key = "compose", gap = 6, align = "stretch" }, rows)
end

local function header()
	local children = {
		ui.label({ text = tr("title"), fontSize = 19, fontWeight = "bold", color = "on_surface" }),
		ui.label({ text = tostring(#items), fontSize = 13, color = "on_surface_variant" }),
		ui.spacer({ flexGrow = 1 }),
	}
	if undoTicks > 0 then
		table.insert(
			children,
			ui.button({
				key = "undo",
				text = tr("undo"),
				glyph = "arrow-back-up",
				glyphSize = 14,
				fontSize = 12,
				variant = "ghost",
				controlSize = "sm",
				tooltip = tr("tip_undo"),
				onClick = undoLast,
			})
		)
	end
	-- The list loads only on open, after a write, or from this button, which
	-- asks Taskwarrior for the tasks again. It is also how changes made in a
	-- terminal show up.
	table.insert(children, glyphButton("header-refresh", "refresh", tr("tip_refresh"), "ghost", 1, function()
		refresh()
	end))
	table.insert(children, glyphButton("header-settings", "settings", tr("tip_settings"), "ghost", 1, "onOpenSettings"))
	table.insert(children, glyphButton("header-close", "close", tr("tip_close"), "ghost", 1, "onClosePanel"))
	return ui.row({ key = "header", gap = 8, align = "center" }, children)
end

render = function()
	if not panelOpen then
		return
	end

	local body
	if not loaded then
		body = ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
			ui.label({ text = tr("loading"), color = "on_surface_variant" }),
		})
	elseif loadError ~= nil then
		body = ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
			ui.label({ text = loadError, color = "error", maxWidth = 440, maxLines = 4, textAlign = "center" }),
		})
	elseif #items == 0 then
		body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 4 }, {
			ui.glyph({ name = "checklist", size = 28, color = "on_surface_variant/0.6" }),
			ui.label({ text = filter == "" and tr("empty") or tr("empty_filtered"), color = "on_surface_variant" }),
		})
	else
		local rows = {}
		for _, item in ipairs(items) do
			table.insert(rows, taskRow(item))
		end
		body = ui.scroll({ key = "list", flexGrow = 1, gap = 2 }, rows)
	end

	local sections = { header(), composeBlock(), filterChips() }
	if filterOpen then
		table.insert(
			sections,
			ui.input({
				key = "filter-input-" .. tostring(filterSeq),
				value = filter,
				placeholder = tr("filter_placeholder"),
				focus = true,
				fontSize = 13,
				controlSize = "sm",
				onSubmit = applyFilter,
			})
		)
	end
	table.insert(sections, body)

	panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, sections))
end

-- ── Lifecycle ───────────────────────────────────────────────────────────────

-- Paint the last snapshot at once, so a reopened panel shows its tasks
-- without waiting for the command that refreshes them. The snapshot is only
-- a starting point: the refresh below replaces it.
--
-- The rows in the snapshot were loaded through the filter they were saved
-- with, so they are only restored when that filter is the one in force.
local function restoreSnapshot()
	local snap = snapshot.read()
	if snap == nil then
		-- Nothing to restore: no snapshot, another Taskwarrior instance, or a
		-- file this version cannot read. The rows on screen would then belong
		-- to another instance, so they go.
		setItems({})
		pendingCount = nil
		loaded = false
		return
	end
	publishCount(snap.pendingCount)
	if snap.filter ~= filter then
		-- The rows were loaded through another filter, so they are not the
		-- rows this filter selects. The count still stands: it counts every
		-- pending task.
		setItems({})
		loaded = false
		return
	end
	setItems(snap.rows)
	loaded = true
	loadError = nil
end

local function startLoad()
	editingId = nil
	editingText = ""
	armedDelete = nil
	hoveredId = nil
	if not taskwarrior.available() then
		loaded = true
		loadError = tr("task_missing")
		notifyFailure(loadError)
		return
	end
	loadError = nil
	restoreSnapshot()
	refresh()
end

function onOpen(_context)
	panelOpen = true
	composeSeq += 1
	composeText = ""
	undoTicks = 0
	noctalia.state.set("todo_open", true)
	panel.setNeedsFrameTick(true) -- hover coalescing; disabled in onClose
	startLoad()
	render()
end

function onClose()
	-- No draft state: an uncommitted edit is discarded.
	panelOpen = false
	editingId = nil
	editingText = ""
	composeText = ""
	filterOpen = false
	armedDelete = nil
	undoTicks = 0
	panel.setWantsSecondTicks(false)
	panel.setNeedsFrameTick(false)
	hoverDirty = false
	noctalia.state.set("todo_open", false)
end

function onConfigChanged()
	-- A setting change only loads while the panel is open. The plugin runs no
	-- command of its own while the panel is closed.
	if panelOpen then
		startLoad()
		render()
	end
end

-- Second ticks only run while the undo affordance is on screen.
function update()
	if undoTicks <= 0 then
		return
	end
	undoTicks -= 1
	if undoTicks <= 0 then
		panel.setWantsSecondTicks(false)
	end
	render()
end

function onRowHover(state, key)
	-- Every child of a row is keyed "<part>-<uuid>", so stripping the part
	-- prefix recovers the row this hover belongs to.
	local uuid = tostring(key):gsub("^%a+%-", "")
	if state == "true" then
		if hoveredId == uuid then
			return
		end
		hoveredId = uuid
	else
		if hoveredId ~= uuid then
			return
		end
		hoveredId = nil
	end
	-- Crossing a row fires several enter/leave events per frame (container,
	-- body, buttons). Rendering per event strands a stale tree when the host
	-- drops rapid posts, so only mark dirty here; onFrameTick renders once.
	hoverDirty = true
	panel.setNeedsFrameTick(true)
end

-- One render per frame at most: the frame callback sees the settled hover
-- state, never the intermediate flips a pointer crossing produces.
function onFrameTick(_deltaMs)
	if not hoverDirty then
		return -- ticks stay on while the panel is open; this is the idle path
	end
	hoverDirty = false
	if armedDelete ~= nil and armedDelete ~= hoveredId then
		armedDelete = nil -- leaving the row disarms the delete
	end
	render()
end

-- Opens the settings window on this plugin's own page (the host supplies the
-- plugin id, so a plugin can only ever open its own).
function onOpenSettings()
	noctalia.openSettings()
end

function onClosePanel()
	panel.close()
end
