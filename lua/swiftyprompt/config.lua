local M = {}

local defaults = {
  connector = "codex",
  keymap = "<leader>aa",
  file_keymap = "<leader>af",
  symbol_keymap = "<leader>as",
  connectors = {
    codex = {
      command = "codex",
      sandbox = "read-only",
      auth = "codex_login",
      api_key_env = "OPENAI_API_KEY",
    },
  },
}

M.values = vim.deepcopy(defaults)

function M.setup(options)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
end

return M
