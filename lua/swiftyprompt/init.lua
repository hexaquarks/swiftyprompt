local M = {}
local config = require("swiftyprompt.config")
local connectors = {
    codex = require("swiftyprompt.connectors.codex"),
}

local RESPONSE_WIDTH = 60
local MAX_RESPONSE_HEIGHT = 12

local function close_window(window)
    if window and vim.api.nvim_win_is_valid(window) then
        vim.api.nvim_win_close(window, true)
    end
end

local function close_thread(state)
    close_window(state.input_window)
    close_window(state.response_window)
end

local function response_lines(text)
    return vim.split(text, "\n")
end

local function show_response(state, text)
    local lines = response_lines(text)
    state.response_height = math.min(math.max(#lines, 1), MAX_RESPONSE_HEIGHT)

    if not state.response_buffer then
        state.response_buffer = vim.api.nvim_create_buf(false, true)
        -- Keep Markdown highlighting, but hide document-lint warnings on AI replies.
        vim.diagnostic.enable(false, { bufnr = state.response_buffer })
    end

    vim.api.nvim_buf_set_lines(state.response_buffer, 0, -1, false, lines)
    vim.bo[state.response_buffer].filetype = "markdown"

    local window_config = {
        relative = "win",
        win = state.source_window,
        bufpos = { state.anchor_line, state.anchor_col },
        anchor = "NW",
        width = RESPONSE_WIDTH,
        height = state.response_height,
        row = 1,
        col = 0,
        style = "minimal",
        border = "rounded",
        title = " Codex — f: follow up · y: copy · q: close ",
    }

    if state.response_window and vim.api.nvim_win_is_valid(state.response_window) then
        vim.api.nvim_win_set_config(state.response_window, window_config)
    else
        state.response_window = vim.api.nvim_open_win(state.response_buffer, true, window_config)

        vim.keymap.set("n", "f", function()
            M.follow_up(state)
        end, { buffer = state.response_buffer, desc = "Ask a follow-up" })

        vim.keymap.set("n", "y", function()
            vim.fn.setreg('"', state.current_answer)
            vim.notify("Copied SwiftPrompt answer")
        end, { buffer = state.response_buffer, desc = "Copy answer" })

        vim.keymap.set("n", "q", function()
            close_thread(state)
        end, { buffer = state.response_buffer, desc = "Close SwiftPrompt" })
    end
end

local function send_question(state, question)
    local connector_name = config.values.connector
    local connector = connectors[connector_name]
    local connector_options = config.values.connectors[connector_name]

    if not connector or not connector_options then
        show_response(state, "Unknown connector: " .. connector_name)
        return
    end

    show_response(state, "Codex is thinking...")
    connector.ask(connector_options, question, state.selected_text, state.turns, function(answer, error_message)
        if error_message then
            show_response(state, error_message)
            return
        end

        -- The UI shows only the current answer; Codex receives every prior turn.
        table.insert(state.turns, {
            question = question,
            answer = answer,
        })
        state.current_answer = answer
        show_response(state, answer)
    end)
end

local function open_question_input(state, row, title)
    close_window(state.input_window)

    local buffer = vim.api.nvim_create_buf(false, true)
    vim.bo[buffer].buftype = "prompt"
    vim.fn.prompt_setprompt(buffer, "Ask: ")

    state.input_window = vim.api.nvim_open_win(buffer, true, {
        relative = "win",
        win = state.source_window,
        bufpos = { state.anchor_line, state.anchor_col },
        anchor = "NW",
        width = RESPONSE_WIDTH,
        height = 1,
        row = row,
        col = 0,
        style = "minimal",
        border = "rounded",
        title = " " .. title .. " ",
    })

    vim.fn.prompt_setcallback(buffer, function(question)
        close_window(state.input_window)
        state.input_window = nil

        if question ~= "" then
            send_question(state, question)
        end
    end)

    vim.keymap.set("n", "q", function()
        close_thread(state)
    end, { buffer = buffer, desc = "Close SwiftPrompt" })

    vim.cmd("startinsert")
end

function M.follow_up(state)
    if not state.response_window or not vim.api.nvim_win_is_valid(state.response_window) then
        return
    end

    -- Put the one-line follow-up editor directly below the visible answer card.
    open_question_input(state, state.response_height + 3, "Follow-up — Enter to send")
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

local function open_thread(source_window, anchor_line, anchor_col, text)
    local state = {
        source_window = source_window,
        anchor_line = anchor_line,
        anchor_col = anchor_col,
        selected_text = text,
        turns = {},
        current_answer = "",
    }

    open_question_input(state, 1, "Ask Codex — Enter to send")
end

function M.require_selection()
    vim.notify("SwiftPrompt: select code first, then press " .. config.values.keymap, vim.log.levels.INFO)
end

function M.open_current_file()
    local source_window = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(source_window)
    local buffer = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
    open_thread(source_window, cursor[1] - 1, cursor[2], table.concat(lines, "\n"))
end

function M.open_at_visual_selection()
    local source_window = vim.api.nvim_get_current_win()
    local start = vim.fn.getpos("v")
    local cursor = vim.api.nvim_win_get_cursor(source_window)
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
    open_thread(source_window, middle_line, middle_col, selected_text(start, cursor))
end

local function symbol_at_cursor(symbols, cursor_line)
    for _, symbol in ipairs(symbols) do
        local range = symbol.range or (symbol.location and symbol.location.range)

        if range and cursor_line >= range.start.line and cursor_line <= range["end"].line then
            local child = symbol.children and symbol_at_cursor(symbol.children, cursor_line)
            return child or symbol
        end
    end
end

function M.open_current_symbol()
    local source_window = vim.api.nvim_get_current_win()
    local buffer = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(source_window)
    local request = {
        textDocument = vim.lsp.util.make_text_document_params(),
    }
    local responses = vim.lsp.buf_request_sync(buffer, "textDocument/documentSymbol", request, 1000)

    for _, response in pairs(responses or {}) do
        local symbol = response.result and symbol_at_cursor(response.result, cursor[1] - 1)
        if symbol then
            local range = symbol.range or symbol.location.range
            local lines = vim.api.nvim_buf_get_lines(buffer, range.start.line, range["end"].line + 1, false)
            open_thread(source_window, cursor[1] - 1, cursor[2], table.concat(lines, "\n"))
            return
        end
    end

    vim.notify("SwiftPrompt: no LSP symbol found at the cursor", vim.log.levels.WARN)
end

function M.setup(options)
    config.setup(options)

    if config.values.keymap then
        vim.keymap.set("n", config.values.keymap, M.require_selection, { desc = "SwiftPrompt needs a selection" })
        vim.keymap.set(
            "x",
            config.values.keymap,
            M.open_at_visual_selection,
            { desc = "Ask SwiftPrompt about selection" }
        )
    end

    vim.keymap.set("n", config.values.file_keymap, M.open_current_file, { desc = "Ask SwiftPrompt about file" })
    vim.keymap.set("n", config.values.symbol_keymap, M.open_current_symbol, { desc = "Ask SwiftPrompt about symbol" })
end

return M
