-- The helper programs in bin/, next to this config, and how to start them.

local M = {}

-- Rex reports a required file's source as its absolute path, without Lua's "@".
local root = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/lib/[^/]+$")
assert(root, "lib/bin.lua: cannot locate the config directory")

function M.path(name) return root .. "/bin/" .. name end

local uv_path

-- uv as the login shell finds it: Rex's own PATH lacks the user's bin directories,
-- so a script's `env uv` shebang fails there. Looked up once, on first use.
local function uv()
	if uv_path == nil then
		local result = rex.exec({ "/bin/zsh", "-lic", "command -v uv" })
		for line in ((result and result.stdout) or ""):gmatch("[^\n]+") do
			if line:match("^/") then
				uv_path = line -- last absolute path; .zshrc may print a banner first
			end
		end
		if uv_path == nil then
			error("uv not found by the login shell, needed for bin/ PEP 723 scripts", 0)
		end
	end
	return uv_path
end

-- argv that runs a bin/ PEP 723 script with uv.
function M.uv_script(name, ...) return { uv(), "run", M.path(name), ... } end

return M
