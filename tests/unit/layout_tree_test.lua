-- lua tests/unit/layout_tree_test.lua (from the repo root, plain Lua 5.1, no Rex)

package.path = "./?.lua;" .. package.path
local tree = require("lib.layout_tree")

local failures, count = 0, 0
local function test(name, fn)
	count = count + 1
	local ok, err = pcall(fn)
	if ok then
		print("ok    " .. name)
	else
		failures = failures + 1
		print("FAIL  " .. name .. ": " .. tostring(err))
	end
end

local function eq(got, want, what)
	if got ~= want then
		error(string.format("%s: got %s, want %s", what, tostring(got), tostring(want)), 2)
	end
end

local function leaves(node, out)
	out = out or {}
	if node.leaf then
		out[#out + 1] = node.leaf
	else
		leaves(node.before, out)
		leaves(node.after, out)
	end
	return out
end

-- Rex's move_block as the rebuild relies on it: the anchor's slot splits in two,
-- anchor before, moved block after.
local function apply_move(node, move)
	if node.leaf then
		if node.leaf == move.anchor_block_id then
			return { dir = move.direction, ratio = move.ratio, before = node, after = { leaf = move.block_id } }
		end
		return node
	end
	return {
		dir = node.dir,
		ratio = node.ratio,
		before = apply_move(node.before, move),
		after = apply_move(node.after, move),
	}
end

local function same(a, b)
	if a.leaf or b.leaf then
		return a.leaf == b.leaf
	end
	return a.dir == b.dir and math.abs(a.ratio - b.ratio) < 1e-9 and same(a.before, b.before) and same(a.after, b.after)
end

for _, preset in ipairs(tree.presets) do
	test(preset.name .. ": keeps every pane in order, 1 to 9 panes", function()
		for n = 1, 9 do
			eq(
				table.concat(leaves(preset.build(tree.numbers(n))), ","),
				table.concat(tree.numbers(n), ","),
				n .. " panes"
			)
		end
	end)

	test(preset.name .. ": moves rebuild the tree from the first pane alone", function()
		for n = 1, 9 do
			local want = preset.build(tree.numbers(n))
			local got = { leaf = 1 }
			for _, move in ipairs(tree.moves(want)) do
				got = apply_move(got, move)
			end
			eq(same(got, want), true, n .. " panes")
		end
	end)
end

test("sketches for 4 panes", function()
	local want = {
		["even-horizontal"] = "1 │ 2 │ 3 │ 4",
		["even-vertical"] = "1 ─ 2 ─ 3 ─ 4",
		["main-horizontal"] = "1 (60%) ─ [2 │ 3 │ 4]",
		["main-vertical"] = "1 (60%) │ [2 ─ 3 ─ 4]",
		["tiled"] = "[1 │ 2] ─ [3 │ 4]",
	}
	for _, preset in ipairs(tree.presets) do
		eq(tree.sketch(preset.build(tree.numbers(4))), want[preset.name], preset.name)
	end
end)

test("tiled grows rows before columns", function()
	eq(tree.sketch(tree.presets[tree.index_of("tiled")].build(tree.numbers(3))), "[1 │ 2] ─ 3", "3 panes")
	eq(
		tree.sketch(tree.presets[tree.index_of("tiled")].build(tree.numbers(5))),
		"[1 │ 2] ─ [3 │ 4] ─ 5",
		"5 panes"
	)
end)

test("rects tile the unit square without gaps", function()
	for _, preset in ipairs(tree.presets) do
		local area = 0
		for _, r in ipairs(tree.rects(preset.build(tree.numbers(5)))) do
			local _, x0, y0, x1, y1 = r:match("^(%d+):([%d.]+):([%d.]+):([%d.]+):([%d.]+)$")
			area = area + (tonumber(x1) - tonumber(x0)) * (tonumber(y1) - tonumber(y0))
		end
		eq(math.abs(area - 1) < 1e-3, true, preset.name .. " area " .. area)
	end
end)

test("index_of rejects an unknown name", function() eq(pcall(tree.index_of, "nope"), false, "pcall") end)

print(string.format("%d tests, %d failed", count, failures))
os.exit(failures == 0 and 0 or 1)
