local M = {}

local config = require("swiftyprompt.config")
local connectors = {
    codex = require("swiftyprompt.connectors.codex"),
}

local RESPONSE_WINDOW_WIDTH = 60
local MAX_RESPONSE_WINDOW_HEIGHT = 12
local QUESTION_WINDOW_HEIGHT = 3

local function close_window_if_valid(window_id)
    if window_id and vim.api.nvim_win_is_valid(window_id) then
        vim.api.nvim_win_close(window_id, true)
    end
end

local function close_conversation_windows(conversation)
    close_window_if_valid(conversation.question_window)
    close_window_if_valid(conversation.response_window)
end

function M.split_response_lines(response_text)
    local normalized_response = response_text:gsub("\r\n?", "\n")
    return vim.split(normalized_response, "\n", { plain = true, trimempty = false })
end

local function response_display_height(response_lines)
    local display_rows = 0
    for _, line in ipairs(response_lines) do
        local line_width = vim.fn.strdisplaywidth(line)
        display_rows = display_rows + math.max(math.ceil(line_width / RESPONSE_WINDOW_WIDTH), 1)
    end

    return math.min(math.max(display_rows, 1), MAX_RESPONSE_WINDOW_HEIGHT)
end

local function set_close_keymaps(buffer_id, conversation)
    local function close_conversation()
        close_conversation_windows(conversation)
    end

    for _, close_key in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", close_key, close_conversation, {
            buffer = buffer_id,
            desc = "Close SwiftPrompt",
        })
    end
end

local function response_window_config(conversation)
    return {
        relative = "win",
        win = conversation.source_window,
        bufpos = { conversation.anchor_line, conversation.anchor_column },
        anchor = "NW",
        width = RESPONSE_WINDOW_WIDTH,
        height = conversation.response_window_height,
        row = 1,
        col = 0,
        style = "minimal",
        border = "rounded",
        title = " Codex — f: follow up · y: copy · q/Esc: close ",
    }
end

local function render_response(conversation, response_text)
    local response_lines = M.split_response_lines(response_text)
    conversation.response_window_height = response_display_height(response_lines)

    if not conversation.response_buffer then
        conversation.response_buffer = vim.api.nvim_create_buf(false, true)
        -- Keep Markdown highlighting, but hide document-lint warnings on AI replies.
        vim.diagnostic.enable(false, { bufnr = conversation.response_buffer })
    end

    vim.bo[conversation.response_buffer].readonly = false
    vim.bo[conversation.response_buffer].modifiable = true
    vim.api.nvim_buf_set_lines(conversation.response_buffer, 0, -1, false, response_lines)
    vim.bo[conversation.response_buffer].filetype = "markdown"
    vim.bo[conversation.response_buffer].modified = false
    vim.bo[conversation.response_buffer].modifiable = false
    vim.bo[conversation.response_buffer].readonly = true

    local window_config = response_window_config(conversation)
    if conversation.response_window and vim.api.nvim_win_is_valid(conversation.response_window) then
        vim.api.nvim_win_set_config(conversation.response_window, window_config)
        return
    end

    conversation.response_window = vim.api.nvim_open_win(conversation.response_buffer, true, window_config)
    vim.wo[conversation.response_window].wrap = true
    vim.wo[conversation.response_window].conceallevel = 2
    vim.wo[conversation.response_window].concealcursor = "nvic"

    vim.keymap.set("n", "f", function()
        M.open_follow_up_prompt(conversation)
    end, { buffer = conversation.response_buffer, desc = "Ask a follow-up" })

    vim.keymap.set("n", "y", function()
        vim.fn.setreg('"', conversation.latest_response)
        vim.notify("Copied SwiftPrompt answer")
    end, { buffer = conversation.response_buffer, desc = "Copy answer" })

    set_close_keymaps(conversation.response_buffer, conversation)
end

local function submit_question(conversation, question)
    local connector_name = config.values.connector
    local connector = connectors[connector_name]
    local connector_options = config.values.connectors[connector_name]

    if not connector or not connector_options then
        render_response(conversation, "Unknown connector: " .. connector_name)
        return
    end

    render_response(conversation, "Codex is thinking...")
    connector.ask(connector_options, question, conversation.selected_code, conversation.history, function(response, error_message)
        if error_message then
            render_response(conversation, error_message)
            return
        end

        -- The UI shows only the current response; Codex receives the full history.
        table.insert(conversation.history, {
            question = question,
            response = response,
        })
        conversation.latest_response = response
        render_response(conversation, response)
    end)
end

local function open_question_prompt(conversation, row_offset, title)
    close_window_if_valid(conversation.question_window)

    local question_buffer = vim.api.nvim_create_buf(false, true)
    vim.bo[question_buffer].buftype = "prompt"
    -- Prompt text must never survive after its floating window closes. Otherwise
    -- Neovim keeps a modified unnamed buffer and asks to save it on exit.
    vim.bo[question_buffer].bufhidden = "wipe"
    vim.fn.prompt_setprompt(question_buffer, "Ask: ")

    conversation.question_window = vim.api.nvim_open_win(question_buffer, true, {
        relative = "win",
        win = conversation.source_window,
        bufpos = { conversation.anchor_line, conversation.anchor_column },
        anchor = "NW",
        width = RESPONSE_WINDOW_WIDTH,
        height = QUESTION_WINDOW_HEIGHT,
        row = row_offset,
        col = 0,
        style = "minimal",
        border = "rounded",
        title = " " .. title .. " ",
    })

    vim.fn.prompt_setcallback(question_buffer, function(question)
        close_window_if_valid(conversation.question_window)
        conversation.question_window = nil

        if question ~= "" then
            submit_question(conversation, question)
        end
    end)

    set_close_keymaps(question_buffer, conversation)
    vim.cmd("startinsert")
end

function M.open_follow_up_prompt(conversation)
    if not conversation.response_window or not vim.api.nvim_win_is_valid(conversation.response_window) then
        return
    end

    -- Keep the editor directly below the visible response card.
    open_question_prompt(conversation, conversation.response_window_height + 3, "Follow-up — Enter to send")
end

local function extract_visual_selection(visual_start, cursor_position, visual_mode)
    local start_line = visual_start[2] - 1
    local start_column = visual_start[3] - 1
    local end_line = cursor_position[1] - 1
    local end_column = cursor_position[2]

    if start_line > end_line or (start_line == end_line and start_column > end_column) then
        start_line, end_line = end_line, start_line
        start_column, end_column = end_column, start_column
    end

    -- Linewise selections include whole lines. Blockwise selections form a rectangle.
    if visual_mode == "V" then
        return table.concat(vim.api.nvim_buf_get_lines(0, start_line, end_line + 1, false), "\n")
    end

    if visual_mode == "\22" then
        local selected_lines = {}
        local first_column = math.min(start_column, end_column)
        local last_column = math.max(start_column, end_column)
        for line_index = start_line, end_line do
            local line_text = vim.api.nvim_buf_get_text(0, line_index, first_column, line_index, last_column + 1, {})
            table.insert(selected_lines, line_text[1] or "")
        end
        return table.concat(selected_lines, "\n")
    end

    local selected_lines = vim.api.nvim_buf_get_text(0, start_line, start_column, end_line, end_column + 1, {})
    return table.concat(selected_lines, "\n")
end

local function start_conversation(source_window, anchor_line, anchor_column, selected_code)
    local conversation = {
        source_window = source_window,
        anchor_line = anchor_line,
        anchor_column = anchor_column,
        selected_code = selected_code,
        history = {},
        latest_response = "",
    }

    open_question_prompt(conversation, 1, "Ask Codex — Enter to send")
end

function M.notify_selection_required()
    vim.notify(
        "SwiftPrompt: select code first, then press " .. config.values.selection_keymap,
        vim.log.levels.INFO
    )
end

function M.ask_about_current_file()
    local source_window = vim.api.nvim_get_current_win()
    local cursor_position = vim.api.nvim_win_get_cursor(source_window)
    local source_buffer = vim.api.nvim_get_current_buf()
    local file_lines = vim.api.nvim_buf_get_lines(source_buffer, 0, -1, false)
    start_conversation(source_window, cursor_position[1] - 1, cursor_position[2], table.concat(file_lines, "\n"))
end

function M.ask_about_visual_selection()
    local source_window = vim.api.nvim_get_current_win()
    local visual_start = vim.fn.getpos("v")
    local cursor_position = vim.api.nvim_win_get_cursor(source_window)
    local visual_mode = vim.fn.mode(1)
    local first_selected_line = math.min(visual_start[2] - 1, cursor_position[1] - 1)
    local last_selected_line = math.max(visual_start[2] - 1, cursor_position[1] - 1)
    local selected_lines = vim.api.nvim_buf_get_lines(0, first_selected_line, last_selected_line + 1, false)
    local non_empty_line_indices = {}

    for offset, line_text in ipairs(selected_lines) do
        if line_text:match("%S") then
            table.insert(non_empty_line_indices, first_selected_line + offset - 1)
        end
    end

    local anchor_line = math.floor((first_selected_line + last_selected_line) / 2)
    if #non_empty_line_indices > 0 then
        anchor_line = non_empty_line_indices[math.ceil(#non_empty_line_indices / 2)]
    end

    local anchor_column = math.floor(((visual_start[3] - 1) + cursor_position[2]) / 2)
    local selected_code = extract_visual_selection(visual_start, cursor_position, visual_mode)
    start_conversation(source_window, anchor_line, anchor_column, selected_code)
end

local function find_innermost_symbol_at_line(document_symbols, cursor_line)
    for _, document_symbol in ipairs(document_symbols) do
        local symbol_range = document_symbol.range or (document_symbol.location and document_symbol.location.range)

        if symbol_range and cursor_line >= symbol_range.start.line and cursor_line <= symbol_range["end"].line then
            local nested_symbol = document_symbol.children
                and find_innermost_symbol_at_line(document_symbol.children, cursor_line)
            return nested_symbol or document_symbol
        end
    end
end

function M.ask_about_current_symbol()
    local source_window = vim.api.nvim_get_current_win()
    local source_buffer = vim.api.nvim_get_current_buf()
    local cursor_position = vim.api.nvim_win_get_cursor(source_window)
    local document_symbol_request = {
        textDocument = vim.lsp.util.make_text_document_params(),
    }
    local lsp_responses = vim.lsp.buf_request_sync(
        source_buffer,
        "textDocument/documentSymbol",
        document_symbol_request,
        1000
    )

    for _, lsp_response in pairs(lsp_responses or {}) do
        local selected_symbol = lsp_response.result
            and find_innermost_symbol_at_line(lsp_response.result, cursor_position[1] - 1)
        if selected_symbol then
            local symbol_range = selected_symbol.range or selected_symbol.location.range
            local symbol_lines = vim.api.nvim_buf_get_lines(
                source_buffer,
                symbol_range.start.line,
                symbol_range["end"].line + 1,
                false
            )
            start_conversation(
                source_window,
                cursor_position[1] - 1,
                cursor_position[2],
                table.concat(symbol_lines, "\n")
            )
            return
        end
    end

    vim.notify("SwiftPrompt: no LSP symbol found at the cursor", vim.log.levels.WARN)
end

function M.setup(user_options)
    config.setup(user_options)

    if config.values.selection_keymap then
        vim.keymap.set("n", config.values.selection_keymap, M.notify_selection_required, {
            desc = "SwiftPrompt needs a selection",
        })
        vim.keymap.set("x", config.values.selection_keymap, M.ask_about_visual_selection, {
            desc = "Ask SwiftPrompt about selection",
        })
    end

    vim.keymap.set("n", config.values.current_file_keymap, M.ask_about_current_file, {
        desc = "Ask SwiftPrompt about file",
    })
    vim.keymap.set("n", config.values.current_symbol_keymap, M.ask_about_current_symbol, {
        desc = "Ask SwiftPrompt about symbol",
    })
end

return M
