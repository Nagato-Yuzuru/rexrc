-- tmux-yank: prefix y copies the command line being edited, prefix Y the
-- shell's directory. zsh does the copying: two widgets in .zshrc print the
-- text as OSC 52, which Rex delivers to the clipboard of the device you're
-- using, through ssh too. Rex only types the widget's key, and only when a
-- shell, or ssh to one, is in front; in a full-screen program the key would
-- land in that program.

local prefix = require("lib.prefix")
local terminal = require("lib.terminal")

-- The keys the .zshrc widgets are bound to.
local KEYS = {
	line = "\24\25", -- ^X^Y
	pwd = "\24\16", -- ^X^P
}

local AT_PROMPT = { zsh = true, bash = true, fish = true, ssh = true, mosh = true, ["mosh-client"] = true }

rex.action({
	name = "yank",
	title = "Copy Command Line or Directory",
	args = { what = "string" },
	run = function(ctx, args)
		local key = KEYS[args.what]
		if key == nil then
			error("what must be line or pwd", 0)
		end
		local front = terminal.foreground(ctx.block_id)
		if not AT_PROMPT[front] or terminal.alt_screen(ctx.block_id) then
			error("not at a shell prompt (" .. tostring(front) .. " is in front)", 0)
		end
		rex.block.call(terminal.CREATOR, "write", { block_id = ctx.block_id, data = key })
	end,
})

prefix.bind("y", "yank", { what = "line" })
prefix.bind("shift+y", "yank", { what = "pwd" })
