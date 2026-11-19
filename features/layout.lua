-- tmux select-layout presets for the focused window's tiled panes.
--   prefix M-1..M-5  select a preset
--   prefix M-Space   next preset
--   prefix Space     picker with a thumbnail of each preset (bin/layout-picker.py)
--   "Pick Layout…"   the same choice as a text list in the command palette
--
-- Rex has no layout presets, so a layout is rebuilt: every pane but the first
-- is detached, then lib/layout_tree's moves place each back. Pane order is kept.

local bin = require("lib.bin")
local prefix = require("lib.prefix")
local terminal = require("lib.terminal")
local tree = require("lib.layout_tree")
local view = require("lib.view")
local check = view.check

local PICKER_BOUNDS = { 0.1, 0.3, 0.8, 0.4 }

-- Preset index last applied per window, for next and the pickers' "current".
local applied = {}

local function apply(block_id, index)
	local window, layer, order = view.locate(block_id)
	if layer.kind ~= "tiled" then
		error("layouts apply to tiled panes, not floating ones", 0)
	end
	applied[window.window_id] = index
	if #order < 2 then
		return
	end
	for i = 2, #order do
		check(rex.session.detach_block({ block_id = order[i] }))
	end
	for _, move in ipairs(tree.moves(tree.presets[index].build(order))) do
		check(rex.session.move_block(move))
	end
	check(rex.session.focus_block({ block_id = block_id }))
end

rex.action({
	name = "layout_select",
	title = "Select Layout",
	args = { name = "string" },
	run = function(ctx, args) apply(ctx.block_id, tree.index_of(args.name)) end,
})

rex.action({
	name = "layout_next",
	title = "Next Layout",
	run = function(ctx)
		local window = view.locate(ctx.block_id)
		apply(ctx.block_id, (applied[window.window_id] or 0) % #tree.presets + 1)
	end,
})

rex.action({
	name = "layout_pick",
	title = "Pick Layout…",
	run = function(ctx)
		local window, _, order = view.locate(ctx.block_id)
		local numbers = tree.numbers(#order)
		local items = {}
		for i, preset in ipairs(tree.presets) do
			items[#items + 1] = {
				id = preset.name,
				title = preset.name,
				subtitle = tree.sketch(preset.build(numbers)),
				detail = "M-" .. i .. (applied[window.window_id] == i and " · current" or ""),
			}
		end
		local name, why, detail =
			rex.ui.pick({ title = "Select layout", placeholder = "Filter layouts", items = items })
		if name == nil then
			if why ~= "cancelled" then
				rex.log("warn", "layout_pick: " .. why .. " " .. (detail or ""))
			end
			return
		end
		apply(ctx.block_id, tree.index_of(name))
	end,
})

rex.action({
	name = "layout_popup",
	title = "Layout Picker",
	run = function(ctx)
		local window, layer, order = view.locate(ctx.block_id)
		if layer.kind ~= "tiled" then
			error("layouts apply to tiled panes, not floating ones", 0)
		end
		local numbers = tree.numbers(#order)
		local command = bin.uv_script("layout-picker.py", ctx.block_id, tostring(applied[window.window_id] or 0))
		for _, preset in ipairs(tree.presets) do
			command[#command + 1] = preset.name .. "|" .. table.concat(tree.rects(preset.build(numbers)), ",")
		end
		check(rex.session.new_layer({
			window_id = window.window_id,
			bounds = PICKER_BOUNDS,
			layout = {
				block = {
					flavor = terminal.SHELL,
					label = "layout",
					options = { shell = "none", command = command, exit = terminal.CLOSE_ON_EXIT },
				},
			},
			focus = true,
		}))
	end,
})

-- Called by the picker, which runs in its own floating pane: applies to the
-- pane the picker was opened from.
rex.action({
	name = "layout_apply",
	title = "Apply Layout",
	args = { name = "string", block = "string" },
	run = function(_, args) apply(args.block, tree.index_of(args.name)) end,
})

for i, preset in ipairs(tree.presets) do
	prefix.bind("alt+" .. i, "layout_select", { name = preset.name })
end
prefix.bind("alt+space", "layout_next")
prefix.bind("space", "layout_popup")
