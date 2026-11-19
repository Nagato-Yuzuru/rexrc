-- The tmux-style prefix key. Keys are written unshifted: "shift+-" is "_".

local M = {}

M.key = "alt+'"

function M.bind(key, action, args) rex.bind(M.key .. ">" .. key, action, args) end

return M
