-- tmux copy mode: prefix [ enters it, prefix ] pastes, prefix / enters it
-- already searching backward from the bottom, like
-- `copy-mode \; command-prompt "send -X search-backward '%%'"`.
-- Keys inside copy mode are Rex's vim defaults.

local prefix = require("lib.prefix")

rex.action({
	name = "copy_mode_search",
	title = "Search Scrollback in Copy Mode",
	run = function()
		rex.client.queue("pane.copy_mode.enter")
		rex.client.queue("pane.copy_mode.search", { direction = "backward" })
	end,
})

prefix.bind("[", "pane.copy_mode.enter")
prefix.bind("]", "pane.paste")
prefix.bind("/", "copy_mode_search")
