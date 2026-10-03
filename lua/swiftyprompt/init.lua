local M = {}

local config = require("swiftyprompt.config")
local connectors = {
    codex = require("swiftyprompt.connectors.codex"),
}

local RESPONSE_WINDOW_WIDTH = 60
local MAX_RESPONSE_WINDOW_HEIGHT = 12
local QUESTION_WINDOW_HEIGHT = 3
local RESPONSE_MARKDOWN_NAMESPACE = vim.api.nvim_create_namespace("swiftyprompt-response-markdown")
local thread_ids_by_conversation_key = {}
local MARKDOWN_DELIMITERS = { "***", "___", "**", "__", "~~", "`", "*", "_" }
local THINKING_FRAMES = { "◜", "◠", "◝", "◞", "◡", "◟" }
local THINKING_FRAME_INTERVAL_MS = 120
local PROMPT_TITLE_MAX_WIDTH = RESPONSE_WINDOW_WIDTH - 4
local PROMPT_TITLE_PREFIX = "Ask "
local PROMPT_TITLE_CONNECTOR = " about "
local SYMBOL_TITLE_HIGHLIGHT = "SwiftypromptSymbol"
local FILE_TITLE_HIGHLIGHT = "SwiftypromptFile"
local CONTEXT_TITLE_HIGHLIGHTS = {
    Symbol = SYMBOL_TITLE_HIGHLIGHT,
    File = FILE_TITLE_HIGHLIGHT,
}
local stop_thinking_animation

vim.api.nvim_set_hl(0, SYMBOL_TITLE_HIGHLIGHT, { link = "Identifier" })
vim.api.nvim_set_hl(0, FILE_TITLE_HIGHLIGHT, { link = "Directory" })

local function close_window_if_valid(window_id)
    if window_id and vim.api.nvim_win_is_valid(window_id) then
        vim.api.nvim_win_close(window_id, true)
    end
end

local function close_conversation_windows(conversation)
    stop_thinking_animation(conversation)

    if conversation.is_waiting then
        local connector = connectors[conversation.connector_name]
        if connector then
            connector.cancel(conversation.request)
        end
        conversation.request = nil
        conversation.is_waiting = false
    end

    close_window_if_valid(conversation.question_window)
    close_window_if_valid(conversation.response_window)
end

function M.thinking_status_text(frame_index)
    local frame_count = #THINKING_FRAMES
    local normalized_index = ((frame_index - 1) % frame_count) + 1
    return THINKING_FRAMES[normalized_index] .. "  Codex is thinking"
end

function M.split_response_lines(response_text)
    local normalized_response = response_text:gsub("\r\n?", "\n")
    return vim.split(normalized_response, "\n", { plain = true, trimempty = false })
end

local function truncate_text(text, max_width)
    if vim.fn.strdisplaywidth(text) <= max_width then
        return text
    end

    local ellipsis = "…"
    local available_width = max_width - vim.fn.strdisplaywidth(ellipsis)
    local truncated_text = ""
    local character_index = 0

    while true do
        local character = vim.fn.strcharpart(text, character_index, 1)
        if character == "" then
            break
        end

        local next_width = vim.fn.strdisplaywidth(truncated_text .. character)
        if next_width > available_width then
            break
        end

        truncated_text = truncated_text .. character
        character_index = character_index + 1
    end

    return truncated_text .. ellipsis
end

local function prompt_title(conversation)
    local agent_name = truncate_text(conversation.agent_name, 20)
    local title_prefix = PROMPT_TITLE_PREFIX .. agent_name .. PROMPT_TITLE_CONNECTOR
    local subject_width = PROMPT_TITLE_MAX_WIDTH
        - vim.fn.strdisplaywidth(title_prefix)
    local subject = truncate_text(conversation.context_subject, math.max(subject_width, 1))

    local subject_highlight = CONTEXT_TITLE_HIGHLIGHTS[conversation.context_label]

    if subject_highlight then
        return {
            { " " .. title_prefix, "FloatTitle" },
            { subject, subject_highlight },
            { " ", "FloatTitle" },
        }
    end

    return " " .. title_prefix .. subject .. " "
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

local function block_global_keymaps(buffer_id, modes)
    for _, mode in ipairs(modes) do
        for _, keymap in ipairs(vim.api.nvim_get_keymap(mode)) do
            vim.keymap.set(mode, keymap.lhs, "<Nop>", {
                buffer = buffer_id,
                nowait = true,
                remap = false,
            })
        end
    end
end

local function conceal_markdown_delimiters(buffer_id)
    vim.api.nvim_buf_clear_namespace(buffer_id, RESPONSE_MARKDOWN_NAMESPACE, 0, -1)

    for line_index, line_text in ipairs(vim.api.nvim_buf_get_lines(buffer_id, 0, -1, false)) do
        local claimed_columns = {}

        for _, delimiter in ipairs(MARKDOWN_DELIMITERS) do
            local delimiter_length = #delimiter
            local search_start = 1

            local function delimiter_is_available(delimiter_column)
                local start_column = delimiter_column - 1
                for column = start_column, start_column + delimiter_length - 1 do
                    if claimed_columns[column] then
                        return false
                    end
                end

                return true
            end

            while true do
                local opening_column = line_text:find(delimiter, search_start, true)
                if not opening_column then
                    break
                end

                local closing_column = line_text:find(delimiter, opening_column + delimiter_length, true)
                local opening_content = line_text:sub(opening_column + delimiter_length, opening_column + delimiter_length)
                local closing_content = closing_column and line_text:sub(closing_column - 1, closing_column - 1)
                local has_content = closing_content and opening_content:match("%S") and closing_content:match("%S")
                local delimiters_are_available = closing_column
                    and delimiter_is_available(opening_column)
                    and delimiter_is_available(closing_column)

                if has_content and delimiters_are_available then
                    for _, delimiter_column in ipairs({ opening_column, closing_column }) do
                        local start_column = delimiter_column - 1
                        vim.api.nvim_buf_set_extmark(buffer_id, RESPONSE_MARKDOWN_NAMESPACE, line_index - 1, start_column, {
                            end_col = start_column + delimiter_length,
                            conceal = "",
                        })

                        for column = start_column, start_column + delimiter_length - 1 do
                            claimed_columns[column] = true
                        end
                    end
                end

                search_start = (closing_column or opening_column) + delimiter_length
            end
        end
    end
end

local function configure_response_display(buffer_id, window_id)
    vim.wo[window_id].wrap = true
    vim.wo[window_id].conceallevel = 3
    vim.wo[window_id].concealcursor = "nvic"
    conceal_markdown_delimiters(buffer_id)

    for _, motion in ipairs({
        { key = "j", wrapped_key = "gj" },
        { key = "k", wrapped_key = "gk" },
        { key = "0", wrapped_key = "g0" },
        { key = "^", wrapped_key = "g^" },
        { key = "$", wrapped_key = "g$" },
    }) do
        vim.keymap.set("n", motion.key, motion.wrapped_key, {
            buffer = buffer_id,
            remap = false,
        })
    end
end

local function response_window_config(conversation)
    local connector_options = config.values.connectors[config.values.connector] or {}
    local model_name = connector_options.model or config.values.connector

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
        title = " Codex — f: follow up · q/Esc: close or stop ",
        footer = " " .. model_name .. " ",
        footer_pos = "right",
    }
end

local function render_response(conversation, response_text)
    local response_lines = M.split_response_lines(response_text)
    conversation.response_window_height = response_display_height(response_lines)

    if not conversation.response_buffer then
        conversation.response_buffer = vim.api.nvim_create_buf(false, true)
        -- Keep Markdown highlighting, but hide document-lint warnings on AI replies.
        vim.diagnostic.enable(false, { bufnr = conversation.response_buffer })
        block_global_keymaps(conversation.response_buffer, { "n" })
        vim.keymap.set("n", "<C-o>", "<Nop>", {
            buffer = conversation.response_buffer,
            nowait = true,
            remap = false,
        })
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
        configure_response_display(conversation.response_buffer, conversation.response_window)
        return
    end

    conversation.response_window = vim.api.nvim_open_win(conversation.response_buffer, true, window_config)
    configure_response_display(conversation.response_buffer, conversation.response_window)

    vim.keymap.set("n", "f", function()
        M.open_follow_up_prompt(conversation)
    end, { buffer = conversation.response_buffer, desc = "Ask a follow-up" })

    set_close_keymaps(conversation.response_buffer, conversation)
end

stop_thinking_animation = function(conversation)
    if not conversation.thinking_timer then
        return
    end

    conversation.thinking_timer:stop()
    conversation.thinking_timer:close()
    conversation.thinking_timer = nil
end

local function start_thinking_animation(conversation)
    stop_thinking_animation(conversation)

    local frame_index = 1
    render_response(conversation, M.thinking_status_text(frame_index))

    local thinking_timer = vim.uv.new_timer()
    conversation.thinking_timer = thinking_timer
    thinking_timer:start(THINKING_FRAME_INTERVAL_MS, THINKING_FRAME_INTERVAL_MS, function()
        vim.schedule(function()
            if not conversation.is_waiting or conversation.thinking_timer ~= thinking_timer then
                return
            end

            frame_index = frame_index + 1
            render_response(conversation, M.thinking_status_text(frame_index))
        end)
    end)
end

local function submit_question(conversation, question)
    local connector_name = config.values.connector
    local connector = connectors[connector_name]
    local connector_options = config.values.connectors[connector_name]

    if not connector or not connector_options then
        render_response(conversation, "Unknown connector: " .. connector_name)
        return
    end

    conversation.connector_name = connector_name
    conversation.is_waiting = true
    start_thinking_animation(conversation)
    local request = connector.ask(
        connector_options,
        question,
        conversation.selected_code,
        conversation.thread_id,
        {
            on_update = function(response)
                if conversation.is_waiting then
                    stop_thinking_animation(conversation)
                    render_response(conversation, response)
                end
            end,
            on_complete = function(response, error_message, thread_id)
                if not conversation.is_waiting then
                    return
                end

                conversation.is_waiting = false
                conversation.request = nil
                stop_thinking_animation(conversation)
                if error_message then
                    render_response(conversation, error_message)
                    return
                end

                conversation.thread_id = thread_id
                thread_ids_by_conversation_key[conversation.key] = thread_id
                render_response(conversation, response)
            end,
        }
    )

    if conversation.is_waiting then
        conversation.request = request
    end
end

local function open_question_prompt(conversation, row_offset, title)
    close_window_if_valid(conversation.question_window)

    local question_buffer = vim.api.nvim_create_buf(false, true)
    vim.bo[question_buffer].buftype = "prompt"
    -- Prompt text must never survive after its floating window closes. Otherwise
    -- Neovim keeps a modified unnamed buffer and asks to save it on exit.
    vim.bo[question_buffer].bufhidden = "wipe"
    vim.fn.prompt_setprompt(question_buffer, "Ask: ")
    block_global_keymaps(question_buffer, { "n", "i" })
    for _, mode in ipairs({ "n", "i" }) do
        vim.keymap.set(mode, "<C-o>", "<Nop>", {
            buffer = question_buffer,
            nowait = true,
            remap = false,
        })
    end
    vim.keymap.set("i", "<CR>", "<CR>", {
        buffer = question_buffer,
        nowait = true,
        remap = false,
    })

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
        title = title,
        footer = " Enter to send ",
        footer_pos = "right",
    })
    vim.wo[conversation.question_window].wrap = true

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
    open_question_prompt(
        conversation,
        conversation.response_window_height + 3,
        prompt_title(conversation)
    )
end

local function extract_visual_selection(visual_start, cursor_position, visual_mode)
    local cursor_position_for_region = { 0, cursor_position[1], cursor_position[2] + 1, 0 }
    local selected_lines = vim.fn.getregion(visual_start, cursor_position_for_region, {
        type = visual_mode,
    })
    return table.concat(selected_lines, "\n")
end

local function conversation_key(source_buffer, scope, selected_code)
    return table.concat({ source_buffer, scope, selected_code }, "\0")
end

local function start_conversation(source_window, anchor_line, anchor_column, selected_code, scope, context_label, context_subject)
    local source_buffer = vim.api.nvim_win_get_buf(source_window)
    local key = conversation_key(source_buffer, scope, selected_code)
    local conversation = {
        source_window = source_window,
        anchor_line = anchor_line,
        anchor_column = anchor_column,
        selected_code = selected_code,
        key = key,
        thread_id = thread_ids_by_conversation_key[key],
        context_label = context_label,
        context_subject = context_subject,
        agent_name = "Codex",
    }

    open_question_prompt(conversation, 1, prompt_title(conversation))
end

function M.notify_selection_required()
    vim.notify(
        "SwiftPrompt: select code first, then press " .. config.values.selection_keymap,
        vim.log.levels.INFO
    )
end

local function current_file_display_name(buffer_id)
    local buffer_name = vim.api.nvim_buf_get_name(buffer_id)
    if buffer_name == "" then
        return "this buffer"
    end

    return vim.fn.fnamemodify(buffer_name, ":t")
end

function M.ask_about_current_file()
    local source_window = vim.api.nvim_get_current_win()
    local cursor_position = vim.api.nvim_win_get_cursor(source_window)
    local source_buffer = vim.api.nvim_get_current_buf()
    local file_lines = vim.api.nvim_buf_get_lines(source_buffer, 0, -1, false)
    start_conversation(
        source_window,
        cursor_position[1] - 1,
        cursor_position[2],
        table.concat(file_lines, "\n"),
        "file",
        "File",
        current_file_display_name(source_buffer)
    )
end

function M.ask_about_visual_selection()
    local source_window = vim.api.nvim_get_current_win()
    local visual_start = vim.fn.getpos("v")
    local cursor_position = vim.api.nvim_win_get_cursor(source_window)
    local visual_mode = vim.fn.mode(1)
    local selected_code = extract_visual_selection(visual_start, cursor_position, visual_mode)

    if not selected_code:match("%S") then
        vim.notify(
            "SwiftPrompt: select non-empty code first, then press " .. config.values.selection_keymap,
            vim.log.levels.INFO
        )
        return
    end

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
    local selection_scope = table.concat({
        visual_mode,
        visual_start[2],
        visual_start[3],
        cursor_position[1],
        cursor_position[2],
    }, ":")
    start_conversation(source_window, anchor_line, anchor_column, selected_code, selection_scope, "Selection", "selected code")
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

local function symbol_display_name(symbol)
    local candidate_names = { symbol.name or false, symbol.detail or false }

    for _, candidate_name in ipairs(candidate_names) do
        if type(candidate_name) == "string" and vim.trim(candidate_name) ~= "" then
            return vim.trim(candidate_name)
        end
    end

    return "this symbol"
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
                table.concat(symbol_lines, "\n"),
                table.concat({
                    "symbol",
                    symbol_range.start.line,
                    symbol_range.start.character,
                    symbol_range["end"].line,
                    symbol_range["end"].character,
                }, ":"),
                "Symbol",
                symbol_display_name(selected_symbol)
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
