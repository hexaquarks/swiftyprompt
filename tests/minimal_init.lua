-- Load this plugin, but none of the user's Neovim configuration.
local test_file = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(test_file, ":p:h:h")

vim.opt.rtp:append(project_root)
