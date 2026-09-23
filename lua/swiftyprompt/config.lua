local M = {}

local defaults = {
  connector = "codex",
  keymap = "<leader>aa",
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
