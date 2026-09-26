local M = {}

local default_options = {
    connector = "codex",
    selection_keymap = "<leader>aa",
    current_file_keymap = "<leader>af",
    current_symbol_keymap = "<leader>as",
    connectors = {
        codex = {
            command = "codex",
            model = "gpt-5-nano",
            sandbox = "read-only",
            auth = "codex_login",
            api_key_env = "OPENAI_API_KEY",
        },
    },
}

M.values = vim.deepcopy(default_options)

function M.setup(user_options)
    M.values = vim.tbl_deep_extend("force", vim.deepcopy(default_options), user_options or {})
end

return M
