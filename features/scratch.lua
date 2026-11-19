-- prefix ` — a persistent scratch shell in a floating layer, one per session,
-- found by its label.
--   none                                   new shell in the focused pane's directory
--   in this window, shown and focused      minimize (the shell keeps running)
--   in this window, minimized or unfocused restore, raise, and focus
--   in another window, or detached         move here, keeping its last bounds
-- Exiting the shell closes it for good; the next press makes a new one.

local float = require("lib.float")
local prefix = require("lib.prefix")
local terminal = require("lib.terminal")
local view = require("lib.view")

local LABEL = "scratch"
local SIZE = 0.8

-- The session's scratch as { block_id, window?, layer? } (window and layer only
-- when floating), and whether focused_id is in its layer.
local function find(session_view, focused_id)
	for _, window in ipairs(session_view.windows) do
		for _, layer in ipairs(window.layers) do
			if layer.kind ~= "tiled" then
				local found, inside = nil, false
				for _, block in ipairs(layer.blocks or {}) do
					if block.label == LABEL then
						found = block.block_id
					end
					inside = inside or block.block_id == focused_id
				end
				if found then
					return { block_id = found, window = window, layer = layer }, inside
				end
			end
		end
	end
	local listed = view.check(rex.session.list_blocks({}))
	for _, block in ipairs(listed.blocks or {}) do
		if block.label == LABEL and block.placement == "detached" then
			return { block_id = block.block_id }, false
		end
	end
	return nil, false
end

rex.action({
	name = "scratch_toggle",
	title = "Toggle Scratch Popup",
	run = function(ctx)
		local window = view.locate(ctx.block_id)
		local scratch, inside = find(view.check(rex.session.view({})), ctx.block_id)

		if scratch == nil then
			view.check(rex.session.new_layer({
				window_id = window.window_id,
				bounds = float.centered(SIZE),
				layout = {
					block = { flavor = terminal.SHELL, label = LABEL, options = { cwd = terminal.cwd(ctx.block_id) } },
				},
				focus = true,
			}))
		elseif scratch.window == nil or scratch.window.window_id ~= window.window_id then
			if scratch.window then
				view.check(rex.session.detach_block({ block_id = scratch.block_id }))
			end
			float.place(scratch.block_id, window, scratch.layer and scratch.layer.bounds or float.centered(SIZE))
		elseif scratch.layer.state ~= "minimized" and inside then
			view.check(rex.session.set_layer_state({ layer_id = scratch.layer.layer_id, state = "minimized" }))
		else
			view.check(
				rex.session.set_layer_state({ layer_id = scratch.layer.layer_id, state = "normal", focus = true })
			)
		end
	end,
})

prefix.bind("`", "scratch_toggle")
