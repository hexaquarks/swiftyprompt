local M = {}

function M.open_window()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "Hello from SwiftPrompt" })

    local window = vim.api.nvim_open_win(buffer, true, {
        relative = "editor",
        width = 30,
        height = 1,
        row = 50,
        col = 5,
        style = "minimal",
        border = "rounded",
    })

    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(window, true)
    end, { buffer = buffer })
end

return M
