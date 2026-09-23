local M = {}
local config = require("swiftyprompt.config")
local connectors = {
  codex = require("swiftyprompt.connectors.codex"),
}

local function show_text(buffer, window, text)
    local lines = vim.split(text, "\n")
    local width = math.min(70, vim.o.columns - 4)
    local height = 0

    for _, line in ipairs(lines) do
        height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
    end

    vim.bo[buffer].buftype = "nofile"
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].filetype = "markdown"

    vim.api.nvim_win_set_config(window, {
        width = width,
        height = math.min(height, vim.o.lines - 4),
    })
end

local function open_prompt(line, col, selected_text)
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.bo[buffer].buftype = "prompt"
    vim.fn.prompt_setprompt(buffer, "Ask Codex: ")

    local window = vim.api.nvim_open_win(buffer, true, {
        relative = "win",
        win = 0,
        bufpos = { line, col },
        anchor = "NW",
        width = 40,
        height = 1,
        row = 1,
        col = 0,
        style = "minimal",
        border = "rounded",
    })

    vim.fn.prompt_setcallback(buffer, function(question)
        if question == "" then
            return
        end

        vim.cmd("stopinsert")
        show_text(buffer, window, "Codex is thinking...")
    local connector_name = config.values.connector
    local connector = connectors[connector_name]
    local connector_options = config.values.connectors[connector_name]

    if not connector or not connector_options then
      show_text(buffer, window, "Unknown connector: " .. config.values.connector)
      return
    end

    connector.ask(connector_options, question, selected_text, function(answer, error_message)
            if error_message then
                show_text(buffer, window, error_message)
                return
            end

            show_text(buffer, window, answer)
        end)
    end)

    vim.cmd("startinsert")
end

local function selected_text(start, finish)
    local start_line = start[2] - 1
    local start_col = start[3] - 1
    local end_line = finish[1] - 1
    local end_col = finish[2]

    if start_line > end_line or (start_line == end_line and start_col > end_col) then
        start_line, end_line = end_line, start_line
        start_col, end_col = end_col, start_col
    end

    local lines = vim.api.nvim_buf_get_text(0, start_line, start_col, end_line, end_col + 1, {})
    return table.concat(lines, "\n")
end

function M.open_at_cursor()
    local cursor = vim.api.nvim_win_get_cursor(0)
    open_prompt(cursor[1] - 1, cursor[2], "")
end

function M.open_at_visual_selection()
    local start = vim.fn.getpos("v")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local first_line = math.min(start[2] - 1, cursor[1] - 1)
    local last_line = math.max(start[2] - 1, cursor[1] - 1)
    local lines = vim.api.nvim_buf_get_lines(0, first_line, last_line + 1, false)
    local non_empty_lines = {}

    for index, line in ipairs(lines) do
        if line:match("%S") then
            table.insert(non_empty_lines, first_line + index - 1)
        end
    end

    local middle_line = math.floor((first_line + last_line) / 2)
    if #non_empty_lines > 0 then
        middle_line = non_empty_lines[math.ceil(#non_empty_lines / 2)]
    end

    local middle_col = math.floor(((start[3] - 1) + cursor[2]) / 2)
  open_prompt(middle_line, middle_col, selected_text(start, cursor))
end

function M.setup(options)
  config.setup(options)

  if config.values.keymap then
    vim.keymap.set("n", config.values.keymap, M.open_at_cursor, { desc = "Ask SwiftPrompt" })
    vim.keymap.set("x", config.values.keymap, M.open_at_visual_selection, { desc = "Ask SwiftPrompt about selection" })
  end
end

return M
