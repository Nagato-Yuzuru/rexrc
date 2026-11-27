-- Floating layers: bounds and placing an existing block into one.

local terminal = require("lib.terminal")
local view = require("lib.view")

local M = {}

-- Bounds of a centered layer taking size of the window in each direction.
function M.centered(size)
	local offset = (1 - size) / 2
	return { offset, offset, size, size }
end

-- Keeps the layer alive until the real block joins it, and closes itself if
-- place fails before it can.
local PLACEHOLDER = {
	flavor = terminal.SHELL,
	label = "float-placeholder",
	options = { shell = "none", command = { "/bin/sleep", "10" }, exit = terminal.CLOSE_ON_EXIT },
}

-- Floats block_id, detached or placed anywhere in the session, in a new layer
-- of window and focuses it. The API only floats a tiled block or creates new
-- ones, so the block joins a layer opened around a placeholder, which is then
-- closed. Tiled panes are never resized; the block may show beside the
-- placeholder, at 99% of the layer, for one frame.
function M.place(block_id, window, bounds)
	local layer = view.check(rex.session.new_layer({
		window_id = window.window_id,
		bounds = bounds,
		layout = { block = PLACEHOLDER },
		focus = false,
	}))
	local placeholder = layer.block_ids[1]
	view.check(rex.session.move_block({
		block_id = block_id,
		anchor_block_id = placeholder,
		direction = "horizontal",
		side = "after",
		ratio = 0.01,
	}))
	local session_id = view.check(rex.session.view({})).session_id -- rex.call doesn't fill it in
	view.check(rex.call("block.close", { session_id = session_id, block_id = placeholder }))
	view.check(rex.session.focus_block({ block_id = block_id }))
end

return M
