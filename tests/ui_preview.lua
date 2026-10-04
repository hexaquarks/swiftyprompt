-- Open an isolated, interactive preview with a local sample reply:
-- nvim -u tests/minimal_init.lua -c 'luafile tests/ui_preview.lua'
-- Set RENDER_MARKDOWN_DIR to your render-markdown.nvim installation if needed.
local script = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(script, ":p:h:h"))

vim.opt.termguicolors = true
vim.opt.laststatus = 0
vim.opt.showmode = false
vim.api.nvim_set_hl(0, "Normal", { fg = "#d5dee8", bg = "#080d10" })
vim.api.nvim_set_hl(0, "EndOfBuffer", { fg = "#080d10" })

local response = table.concat({
    "setup() merges your options into the defaults.",
    "Keys you provide replace their default values;",
    "nested tables are merged recursively.",
    "",
    "```lua",
    'require("swiftyprompt").setup({',
    "  connectors = {",
    '    codex = { model = "gpt-6-luna" },',
    "  },",
    "})",
    "```",
    "",
    "Everything else keeps its default.",
}, "\n")

-- This preview runs without calling Codex or sending any code to a service.
local codex = require("swiftyprompt.connectors.codex")
codex.ask = function(_, _, _, _, callbacks)
    callbacks.on_complete(response, nil, "preview-thread")
    return {}
end
codex.cancel = function() end

local source = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_name(source, "/tmp/swiftyprompt-preview/config.lua")
vim.api.nvim_buf_set_lines(source, 0, -1, false, {
    "local M = {}",
    "",
    "local default_options = {",
    '    connector = "codex",',
    '    selection_keymap = "<leader>aa",',
    '    current_file_keymap = "<leader>af",',
    '    current_symbol_keymap = "<leader>as",',
    "    connectors = {",
    "        codex = {",
    '            command = "codex",',
    '            model = "gpt-6-luna",',
    "        },",
    "    },",
    "}",
    "",
    "M.values = vim.deepcopy(default_options)",
    "",
    "function M.setup(user_options)",
    '    M.values = vim.tbl_deep_extend("force", vim.deepcopy(default_options), user_options or {})',
    "end",
    "",
    "return M",
})
vim.bo[source].filetype = "lua"
pcall(vim.treesitter.start, source, "lua")
vim.wo.number = true
vim.wo.relativenumber = true
vim.api.nvim_win_set_cursor(0, { 11, 20 })

require("swiftyprompt").ask_about_current_file()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "What does setup() override?" })
vim.api.nvim_win_set_cursor(0, { 1, 26 })
