if vim.g.loaded_swiftyprompt == 1 then
  return
end

vim.g.loaded_swiftyprompt = 1

vim.api.nvim_create_user_command("SwiftPromptPop", function()
  require("swiftyprompt").open_window()
end, {})

vim.keymap.set("n", "<leader>aa", function()
  require("swiftyprompt").open_window()
end, { desc = "Open SwiftPrompt" })
