-- prefix ; — tmux's command-prompt + display-popup: type a command, run it in a
-- floating window that closes when the command exits.
--   empty Enter      a shell in the popup
--   Esc / Ctrl-C     cancel
--   quick failure    no popup; the bar shows the error with the command kept for editing
--
-- The bar is a short floating terminal (bin/popup-bar.zsh), not rex.ui.input,
-- so that a quick failure can be shown in place with the command still editable.
-- Enter runs the command in a detached block (bin/popup-run.zsh). Once it has
-- run for SHOW_DELAY, popup_show floats it; if it fails before that, the bar
-- shows the error. A failure after showing goes through popup_failed, which
-- reopens the bar.

local bin = require("lib.bin")
local float = require("lib.float")
local prefix = require("lib.prefix")
local terminal = require("lib.terminal")
local view = require("lib.view")

local SIZE = 0.8 -- of the window in each direction, like tmux's -w 80% -h 80%
local BAR = { 0.15, 0.84, 0.7, 0.06 } -- bottom center, about 3 rows
local BAR_WITH_ERROR = { 0.15, 0.78, 0.7, 0.12 }
local SHOW_DELAY = "0.3" -- seconds

-- Opens the bar in the window holding block_id, which need not be the active one.
local function open_bar(block_id, cwd, command, err)
	local window = view.locate(block_id)
	view.check(rex.session.new_layer({
		window_id = window.window_id,
		bounds = err and BAR_WITH_ERROR or BAR,
		layout = {
			block = {
				flavor = terminal.SHELL,
				label = "popup>",
				options = {
					shell = "none",
					command = { "/bin/zsh", "-f", bin.path("popup-bar.zsh"), command or "", err or "" },
					cwd = cwd,
					exit = terminal.CLOSE_ON_EXIT,
				},
			},
		},
		focus = true,
	}))
end

rex.action({
	name = "popup",
	title = "Popup Command…",
	run = function(ctx) open_bar(ctx.block_id, terminal.cwd(ctx.block_id)) end,
})

-- Called by the bar. The block is sized from the bar's cell size so showing it
-- doesn't reflow the program.
rex.action({
	name = "popup_run",
	title = "Popup Run",
	args = { command = "string?", cwd = "string?", bar = "string", fifo = "string" },
	run = function(_, args)
		local _, bar_layer = view.locate(args.bar)
		local bar_size = rex.block.call(terminal.CREATOR, "size", { block_id = args.bar })
		local size = nil
		if bar_size and bar_size.columns then
			size = {
				columns = math.floor(bar_size.columns / bar_layer.bounds[3] * SIZE),
				rows = math.max(10, math.floor(bar_size.rows / bar_layer.bounds[4] * SIZE)),
			}
		end
		view.check(rex.session.new_block({
			flavor = terminal.SHELL,
			label = "popup",
			options = {
				shell = "none",
				command = {
					"/bin/zsh",
					"-li",
					bin.path("popup-run.zsh"),
					args.command or "",
					SHOW_DELAY,
					args.bar,
					args.fifo,
				},
				cwd = args.cwd,
				size = size,
				exit = terminal.CLOSE_ON_EXIT,
			},
		}))
	end,
})

-- Called by the command once it has run for SHOW_DELAY.
rex.action({
	name = "popup_show",
	title = "Popup Show",
	args = { block = "string", bar = "string" },
	run = function(_, args)
		local window = view.locate(args.bar)
		float.place(args.block, window, float.centered(SIZE))
	end,
})

-- Called by the command on a quick failure: makes room in the bar for the error.
rex.action({
	name = "popup_bar_error",
	title = "Popup Bar Error",
	args = { bar = "string" },
	run = function(_, args)
		local _, layer = view.locate(args.bar)
		view.check(rex.session.resize_layer({ layer_id = layer.layer_id, bounds = BAR_WITH_ERROR }))
	end,
})

-- Called by a shown command that failed: reopens the bar with its error and command.
rex.action({
	name = "popup_failed",
	title = "Popup Failed",
	args = { command = "string", cwd = "string?", rc = "integer", block = "string" },
	run = function(_, args)
		local err = terminal.tail(args.block, 3)
		open_bar(args.block, args.cwd, args.command, err ~= "" and err or ("[exit " .. args.rc .. "]"))
	end,
})

prefix.bind(";", "popup")
