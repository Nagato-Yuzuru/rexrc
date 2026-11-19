-- tmux layout presets as pure layout trees: no rex calls, so tests run on plain Lua 5.1.
--
-- A tree is { leaf = id } or
-- { dir = "horizontal" | "vertical", ratio = share of before, before = tree, after = tree }.

local M = {}

M.MAIN_SHARE = 0.6 -- of the window, for the main pane in main-*

local function leaves(ids, from, to)
	local out = {}
	for i = from or 1, to or #ids do
		out[#out + 1] = { leaf = ids[i] }
	end
	return out
end

-- nodes side by side (horizontal) or stacked (vertical), equal shares. Needs at least one node.
local function chain(dir, nodes, i)
	i = i or 1
	if i == #nodes then
		return nodes[i]
	end
	return { dir = dir, ratio = 1 / (#nodes - i + 1), before = nodes[i], after = chain(dir, nodes, i + 1) }
end

local function main(dir, rest_dir)
	return function(ids)
		if #ids < 2 then
			return { leaf = ids[1] }
		end
		return { dir = dir, ratio = M.MAIN_SHARE, before = { leaf = ids[1] }, after = chain(rest_dir, leaves(ids, 2)) }
	end
end

-- tmux's grid: grow rows, then columns, until every pane fits; fill row by row.
local function tiled(ids)
	local rows, cols = 1, 1
	while rows * cols < #ids do
		rows = rows + 1
		if rows * cols < #ids then
			cols = cols + 1
		end
	end
	local row_nodes = {}
	for first = 1, #ids, cols do
		row_nodes[#row_nodes + 1] = chain("horizontal", leaves(ids, first, math.min(first + cols - 1, #ids)))
	end
	return chain("vertical", row_nodes)
end

-- In tmux's next-layout order. build(ids) takes at least one id.
M.presets = {
	{ name = "even-horizontal", build = function(ids) return chain("horizontal", leaves(ids)) end },
	{ name = "even-vertical", build = function(ids) return chain("vertical", leaves(ids)) end },
	{ name = "main-horizontal", build = main("vertical", "horizontal") },
	{ name = "main-vertical", build = main("horizontal", "vertical") },
	{ name = "tiled", build = tiled },
}

function M.index_of(name)
	for i, preset in ipairs(M.presets) do
		if preset.name == name then
			return i
		end
	end
	error("unknown layout " .. tostring(name), 0)
end

-- 1..n, to preview a preset with pane numbers instead of block ids.
function M.numbers(n)
	local out = {}
	for i = 1, n do
		out[i] = i
	end
	return out
end

local function first_leaf(node)
	while not node.leaf do
		node = node.before
	end
	return node.leaf
end

-- The session.move_block arguments that rebuild tree once every leaf but the
-- first is detached, in order: each places the first pane of a subtree beside
-- the first pane of its sibling, so a whole slot is filled before it is split.
function M.moves(tree, out)
	out = out or {}
	if tree.leaf then
		return out
	end
	out[#out + 1] = {
		block_id = first_leaf(tree.after),
		anchor_block_id = first_leaf(tree.before),
		direction = tree.dir,
		side = "after",
		ratio = tree.ratio,
	}
	M.moves(tree.before, out)
	M.moves(tree.after, out)
	return out
end

-- One line: " │ " joins panes side by side, " ─ " stacks them, [ ] nests a split,
-- and an uneven two-way split (main-*) shows the first side's share.
function M.sketch(tree, nested)
	if tree.leaf then
		return tostring(tree.leaf)
	end
	local parts = {}
	local function flatten(n)
		if n.dir == tree.dir then
			flatten(n.before)
			flatten(n.after)
		else
			parts[#parts + 1] = M.sketch(n, true)
		end
	end
	flatten(tree)
	if #parts == 2 and math.abs(tree.ratio - 0.5) > 0.01 then
		parts[1] = parts[1] .. " (" .. math.floor(tree.ratio * 100 + 0.5) .. "%)"
	end
	local s = table.concat(parts, tree.dir == "horizontal" and " │ " or " ─ ")
	return nested and "[" .. s .. "]" or s
end

-- "pane:x0:y0:x1:y1" rects in 0..1 (bin/layout-picker.py's input). Siblings
-- share the exact same float for their common edge, so thumbnail borders meet.
function M.rects(tree, x0, y0, x1, y1, out)
	x0, y0, x1, y1, out = x0 or 0, y0 or 0, x1 or 1, y1 or 1, out or {}
	if tree.leaf then
		out[#out + 1] = string.format("%d:%.4f:%.4f:%.4f:%.4f", tree.leaf, x0, y0, x1, y1)
	elseif tree.dir == "horizontal" then
		local mid = x0 + (x1 - x0) * tree.ratio
		M.rects(tree.before, x0, y0, mid, y1, out)
		M.rects(tree.after, mid, y0, x1, y1, out)
	else
		local mid = y0 + (y1 - y0) * tree.ratio
		M.rects(tree.before, x0, y0, x1, mid, out)
		M.rects(tree.after, x0, mid, x1, y1, out)
	end
	return out
end

return M
