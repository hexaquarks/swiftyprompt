if vim.g.loaded_swiftyprompt == 1 then
  return
end

vim.g.loaded_swiftyprompt = 1

vim.api.nvim_create_user_command("SwiftPromptPop", function()
  require("swiftyprompt").open_at_cursor()
end, {})

vim.keymap.set("n", "<leader>aa", function()
  require("swiftyprompt").open_at_cursor()
end, { desc = "Open SwiftPrompt" })

vim.keymap.set("x", "<leader>aa", function()
  require("swiftyprompt").open_at_visual_selection()
end, { desc = "Open SwiftPrompt for selection" })
