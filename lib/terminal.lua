-- Terminal blocks: creating them and reading their state.

local M = {}

M.CREATOR = "com.superlogical.terminal"
M.SHELL = "com.superlogical.terminal.shell"

-- Close as soon as the program exits, bypassing Rex's keep-open-on-quick-failure
-- heuristic; scripts that care about failures report them themselves.
M.CLOSE_ON_EXIT = { on_completion = true, quick_exit_threshold_ms = 0 }

-- The terminal's last reported working directory, or nil. Rex reports it as a
-- file://HOST/PATH URL with PATH percent-encoded.
function M.cwd(block_id)
	local result = rex.block.call(M.CREATOR, "pwd", { block_id = block_id })
	local path = result and result.pwd and result.pwd:match("^file://[^/]*(/.*)$")
	if path == nil then
		return nil
	end
	return (path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

-- The last n non-blank lines on the terminal's screen, trailing spaces removed.
function M.tail(block_id, n)
	local result = rex.block.call(M.CREATOR, "format", { block_id = block_id, format = "text", trim = true })
	local lines = {}
	for line in ((result and result.content) or ""):gmatch("[^\n]+") do
		line = line:gsub("%s+$", "")
		if line ~= "" then
			lines[#lines + 1] = line
		end
	end
	return table.concat(lines, "\n", math.max(1, #lines - n + 1))
end

return M
