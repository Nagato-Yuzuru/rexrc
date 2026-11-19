-- tmux join-pane, both ways, chosen from a list instead of a marked pane.
--   prefix @  pick a pane in this session and move it below the focused one
--   prefix #  pick another tab and move the focused pane below its focused pane
-- With nothing to pick, both do nothing.
--
-- Rows name a pane by its terminal title, else its foreground program, so
-- full-screen programs are recognisable; Rex can't preview pane contents.

local prefix = require("lib.prefix")
local terminal = require("lib.terminal")
local view = require("lib.view")

local HOME = os.getenv("HOME")

local function short_path(path)
	if path and HOME and path:sub(1, #HOME) == HOME then
		return "~" .. path:sub(#HOME + 1)
	end
	return path
end

-- What a row calls the block: its terminal title, else its foreground program, else its label.
local function name_of(block)
	if block.creator_name ~= terminal.CREATOR then
		return block.label or block.block_id
	end
	local title = rex.block.call(terminal.CREATOR, "title", { block_id = block.block_id })
	if title and title.title and title.title ~= "" then
		return title.title
	end
	local process = rex.block.call(terminal.CREATOR, "process", { block_id = block.block_id })
	local foreground = process and process.foreground
	return (foreground and (foreground.argv0 or foreground.name)) or block.label or block.block_id
end

local function cwd_of(block)
	return block.creator_name == terminal.CREATOR and short_path(terminal.cwd(block.block_id)) or nil
end

-- The session's windows, the one holding block_id first, and each window's tab number.
local function windows_from(block_id)
	local session_view = view.check(rex.session.view({}))
	local here = view.locate(block_id)
	local ordered, index = { here }, {}
	for i, window in ipairs(session_view.windows) do
		index[window.window_id] = i
		if window.window_id ~= here.window_id then
			ordered[#ordered + 1] = window
		end
	end
	return ordered, index, here
end

-- The block_id chosen from items, or nil when there is nothing to choose or no answer.
local function pick(name, title, items)
	if #items == 0 then
		return nil
	end
	local id, why, detail = rex.ui.pick({ title = title, placeholder = "Filter", confirm = "Move", items = items })
	if id == nil and why ~= "cancelled" then
		rex.log("warn", name .. ": " .. why .. " " .. (detail or ""))
	end
	return id
end

local function move_below(block_id, anchor_id)
	view.check(rex.session.move_block({ block_id = block_id, anchor_block_id = anchor_id, direction = "vertical" }))
	view.check(rex.session.focus_block({ block_id = block_id }))
end

-- Every placed pane but focused_id, the focused pane's tab first, then in tab order.
local function panes_except(focused_id)
	local windows, index, here = windows_from(focused_id)
	local items = {}
	for _, window in ipairs(windows) do
		local tab = window.window_id == here.window_id and "this tab" or ("tab " .. index[window.window_id])
		for _, layer in ipairs(window.layers) do
			for _, block in ipairs(layer.blocks or {}) do
				if block.block_id ~= focused_id then
					items[#items + 1] = {
						id = block.block_id,
						title = name_of(block),
						subtitle = cwd_of(block),
						detail = layer.kind == "tiled" and tab or (tab .. " · floating"),
						icon = "terminal",
					}
				end
			end
		end
	end
	return items
end

local function block_in(window, block_id)
	for _, layer in ipairs(window.layers) do
		for _, block in ipairs(layer.blocks or {}) do
			if block.block_id == block_id then
				return block
			end
		end
	end
end

-- Every other tab, as the pane to move beside: its focused pane, named as the tab shows it.
local function other_tabs(focused_id)
	local windows, index, here = windows_from(focused_id)
	local items = {}
	for _, window in ipairs(windows) do
		local anchor = window.focused_block_id and block_in(window, window.focused_block_id)
		if window.window_id ~= here.window_id and anchor then
			items[#items + 1] = {
				id = anchor.block_id,
				title = name_of(anchor),
				subtitle = cwd_of(anchor),
				detail = "tab " .. index[window.window_id],
				icon = "terminal",
			}
		end
	end
	return items
end

rex.action({
	name = "pane_join",
	title = "Move a Pane Here…",
	-- block skips the picker, for scripts and tests.
	args = { block = "string?" },
	run = function(ctx, args)
		local block_id = args.block or pick("pane_join", "Move pane here", panes_except(ctx.block_id))
		if block_id then
			move_below(block_id, ctx.block_id)
		end
	end,
})

rex.action({
	name = "pane_send",
	title = "Move This Pane to Tab…",
	-- anchor skips the picker, for scripts and tests.
	args = { anchor = "string?" },
	run = function(ctx, args)
		local anchor = args.anchor or pick("pane_send", "Move this pane to tab", other_tabs(ctx.block_id))
		if anchor then
			move_below(ctx.block_id, anchor)
		end
	end,
})

prefix.bind("shift+2", "pane_join") -- @  join-pane
prefix.bind("shift+3", "pane_send") -- #  join-pane, the other way
