local M = {}

local function open_popup(line, col)
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "Hello from SwiftPrompt" })

    local window_config = {
        relative = "win",
        win = 0,
        bufpos = { line, col },
        anchor = "NW",
        width = 30,
        height = 1,
        row = 1,
        col = 0,
        style = "minimal",
        border = "rounded",
    }
    local window = vim.api.nvim_open_win(buffer, true, window_config)

    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(window, true)
    end, { buffer = buffer })
end

function M.open_at_cursor()
    local cursor = vim.api.nvim_win_get_cursor(0)
    -- The API line is 1-based; bufpos lines are 0-based.
    open_popup(cursor[1] - 1, cursor[2])
end

function M.open_at_visual_selection()
    -- getpos("v") gives the start of the visual selection.
    local start = vim.fn.getpos("v")
    local cursor = vim.api.nvim_win_get_cursor(0)

    -- Find the middle of the selection, ignoring blank lines in between.
    -- start[2] is 1-based, so we change it to a 0-based buffer line first.
    local first_line = math.min(start[2] - 1, cursor[1] - 1)
    local last_line = math.max(start[2] - 1, cursor[1] - 1)

    -- get_lines stops before its last number, hence `last_line + 1`.
    local lines = vim.api.nvim_buf_get_lines(0, first_line, last_line + 1, false)
    local non_empty_lines = {}

    for index, line in ipairs(lines) do
        if line:match("%S") then
            -- ipairs starts at 1; buffer lines start at 0.
            table.insert(non_empty_lines, first_line + index - 1)
        end
    end

    local middle_line = math.floor((first_line + last_line) / 2)
    if #non_empty_lines > 0 then
        middle_line = non_empty_lines[math.ceil(#non_empty_lines / 2)]
    end

    -- getpos columns start at 1, while cursor columns already start at 0.
    local middle_col = math.floor(((start[3] - 1) + cursor[2]) / 2)

    open_popup(middle_line, middle_col)
end

return M
