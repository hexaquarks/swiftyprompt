if vim.g.loaded_swiftyprompt == 1 then
  return
end

vim.g.loaded_swiftyprompt = 1

vim.api.nvim_create_user_command("SwiftPromptPop", function()
  require("swiftyprompt").notify_selection_required()
end, {})
