-- Load this plugin, but none of the user's Neovim configuration.
local test_file = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(test_file, ":p:h:h")

vim.opt.rtp:append(project_root)

-- Integration tests load the real renderer and its installed parser runtime.
for _, runtime_path in ipairs({ vim.env.RENDER_MARKDOWN_DIR, vim.env.MARKDOWN_PARSER_DIR }) do
    if runtime_path then
        vim.opt.rtp:append(runtime_path)
    end
end
