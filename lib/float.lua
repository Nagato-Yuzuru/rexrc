-- Floating layers: bounds and placing an existing block into one.

local view = require("lib.view")

local M = {}

-- Bounds of a centered layer taking size of the window in each direction.
function M.centered(size)
	local offset = (1 - size) / 2
	return { offset, offset, size, size }
end

local function tiled_anchor(window)
	for _, layer in ipairs(window.layers) do
		if layer.kind == "tiled" then
			local ids = view.collect(layer.layout)
			if ids[1] then
				return ids[1]
			end
		end
	end
	error("window has no tiled pane to place a floating layer by", 0)
end

-- Floats a detached block in window and focuses it. The API can only float a
-- tiled block, so it is split in first and may show as a split for one frame.
function M.place(block_id, window, bounds)
	view.check(rex.session.move_block({
		block_id = block_id,
		anchor_block_id = tiled_anchor(window),
		direction = "vertical",
	}))
	view.check(rex.session.float_block({ block_id = block_id, bounds = bounds }))
	view.check(rex.session.focus_block({ block_id = block_id }))
end

return M
