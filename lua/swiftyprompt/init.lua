local M = {}

local config = require("swiftyprompt.config")
local connectors = {
    codex = require("swiftyprompt.connectors.codex"),
    claude = require("swiftyprompt.connectors.claude"),
}
local connector_labels = { codex = "Codex", claude = "Claude" }

local ui = require("swiftyprompt.ui")
local markdown = require("swiftyprompt.markdown")
local thread_ids_by_conversation_key = {}
local THINKING_FRAMES = { "◜", "◠", "◝", "◞", "◡", "◟" }
local THINKING_FRAME_INTERVAL_MS = 120
local stop_thinking_animation

local function close_window_if_valid(window_id)
    if window_id and vim.api.nvim_win_is_valid(window_id) then
        vim.api.nvim_win_close(window_id, true)
    end
end

local function close_conversation_windows(conversation)
    if conversation.closed then
        return
    end
    -- Closing an Insert-mode mapping's window does not leave Insert mode by itself.
    vim.cmd("stopinsert")
    conversation.closed = true
    stop_thinking_animation(conversation)
    ui.clear_source_highlight(conversation.source_buffer, conversation.source_highlights)
    ui.detach(conversation.question_panel)
    ui.detach(conversation.response_panel)

    for _, field in ipairs({ "window_close_autocmd", "question_close_autocmd", "resize_autocmd" }) do
        if conversation[field] then
            vim.api.nvim_del_autocmd(conversation[field])
            conversation[field] = nil
        end
    end

    if conversation.is_waiting then
        conversation.is_waiting = false
        local connector = connectors[conversation.connector_name]
        if connector then
            connector.cancel(conversation.request)
        end
        conversation.request = nil
    end

    close_window_if_valid(conversation.question_window)
    close_window_if_valid(conversation.response_window)
    close_window_if_valid(conversation.question_frame_window)
    close_window_if_valid(conversation.response_frame_window)
end

function M.thinking_status_text(frame_index, connector_name)
    local frame_count = #THINKING_FRAMES
    local normalized_index = ((frame_index - 1) % frame_count) + 1
    connector_name = connector_name or config.values.connector
    local label = connector_labels[connector_name] or connector_name
    return THINKING_FRAMES[normalized_index] .. "  " .. label .. " is thinking"
end

function M.split_response_lines(response_text)
    local normalized_response = response_text:gsub("\r\n?", "\n")
    return vim.split(normalized_response, "\n", { plain = true, trimempty = false })
end

local function model_name(conversation)
    return (conversation.connector_options or {}).model or conversation.connector_name
end

local function panel_options(conversation, kind, height, row)
    return {
        kind = kind,
        body_height = height,
        row = row,
        source_window = conversation.source_window,
        anchor_line = conversation.anchor_line,
        anchor_column = conversation.anchor_column,
        context = conversation.display_context,
        model = model_name(conversation),
        question = conversation.question,
    }
end

local function response_display_height(response_lines)
    local display_rows = 0
    for _, line in ipairs(response_lines) do
        local line_width = vim.fn.strdisplaywidth(line)
        display_rows = display_rows + math.max(math.ceil(line_width / ui.body_width), 1)
    end

    return math.min(math.max(display_rows, 1), ui.max_response_body_height())
end

local function set_close_keymaps(buffer_id, conversation)
    local function close_conversation()
        close_conversation_windows(conversation)
    end

    for _, close_key in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", close_key, close_conversation, {
            buffer = buffer_id,
            desc = "Close SwiftyPrompt",
        })
    end

    vim.keymap.set("i", "<Esc>", close_conversation, {
        buffer = buffer_id,
        desc = "Close SwiftyPrompt",
    })
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

local function configure_response_display(buffer_id, window_id)
    vim.wo[window_id].winfixbuf = true
    vim.wo[window_id].wrap = true
    vim.wo[window_id].conceallevel = 2
    vim.wo[window_id].concealcursor = "nvic"
    markdown.render(buffer_id, window_id)

    -- Wrapped motions are defaults; preserve user and filetype mappings.
    vim.api.nvim_buf_call(buffer_id, function()
        for _, motion in ipairs({
            { key = "j", wrapped_key = "gj" },
            { key = "k", wrapped_key = "gk" },
            { key = "0", wrapped_key = "g0" },
            { key = "^", wrapped_key = "g^" },
            { key = "$", wrapped_key = "g$" },
        }) do
            if vim.fn.maparg(motion.key, "n") == "" then
                vim.keymap.set("n", motion.key, motion.wrapped_key, {
                    buffer = buffer_id,
                    remap = false,
                })
            end
        end
    end)
end

local function response_is_detached(conversation)
    -- Forced buffer switches and suppressed autocmds can bypass the normal
    -- window protections. Never render into a detached or deleted response.
    local response_window = conversation.response_window
    local response_is_detached = response_window and (
        not vim.api.nvim_win_is_valid(response_window)
        or vim.api.nvim_win_get_buf(response_window) ~= conversation.response_buffer
    )
    return not vim.api.nvim_win_is_valid(conversation.source_window)
        or (conversation.response_buffer and not vim.api.nvim_buf_is_valid(conversation.response_buffer))
        or response_is_detached
        or (conversation.response_frame_window and not vim.api.nvim_win_is_valid(conversation.response_frame_window))

end

local function render_response(conversation, response_text)
    if conversation.closed then
        return
    end

    if response_is_detached(conversation) then
        close_conversation_windows(conversation)
        return
    end

    conversation.response_text = response_text
    local response_lines = M.split_response_lines(response_text)
    conversation.response_window_height = response_display_height(response_lines)

    if not conversation.response_buffer then
        conversation.response_buffer = vim.api.nvim_create_buf(false, true)
        vim.bo[conversation.response_buffer].bufhidden = "wipe"
        -- Keep Markdown highlighting, but hide document-lint warnings on AI replies.
        vim.diagnostic.enable(false, { bufnr = conversation.response_buffer })
        -- Let Neovim resolve user navigation mappings normally. The response
        -- is protected from edits by 'modifiable' and 'readonly' below.
        -- Jumping back can replace the response buffer in this floating window.
        vim.keymap.set("n", "<C-o>", "<Nop>", {
            buffer = conversation.response_buffer,
            nowait = true,
            remap = false,
            desc = "Keep jumplist navigation out of the response window",
        })
    end

    vim.bo[conversation.response_buffer].readonly = false
    vim.bo[conversation.response_buffer].modifiable = true
    vim.api.nvim_buf_set_lines(conversation.response_buffer, 0, -1, false, response_lines)
    vim.bo[conversation.response_buffer].filetype = markdown.filetype
    vim.bo[conversation.response_buffer].modified = false
    vim.bo[conversation.response_buffer].modifiable = false
    vim.bo[conversation.response_buffer].readonly = true

    if conversation.response_window and vim.api.nvim_win_is_valid(conversation.response_window) then
        ui.update(conversation.response_panel, conversation.response_window_height, conversation.question)
        configure_response_display(conversation.response_buffer, conversation.response_window)
        return
    end

    conversation.response_panel = ui.open(conversation.response_buffer,
        panel_options(conversation, "response", conversation.response_window_height, 1))
    conversation.response_window = conversation.response_panel.body_window
    conversation.response_frame_window = conversation.response_panel.frame_window
    conversation.resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
        callback = function()
            if conversation.closed then
                return
            end
            if response_is_detached(conversation) then
                close_conversation_windows(conversation)
                return
            end
            conversation.response_window_height = response_display_height(
                M.split_response_lines(conversation.response_text)
            )
            -- Resize the card without rewriting the answer or resetting its view.
            ui.update(conversation.response_panel, conversation.response_window_height, conversation.question)
        end,
        desc = "Keep SwiftyPrompt response cards within the screen height budget",
    })
    conversation.window_close_autocmd = vim.api.nvim_create_autocmd("WinClosed", {
        pattern = {
            tostring(conversation.response_window),
            tostring(conversation.response_frame_window),
            tostring(conversation.source_window),
        },
        once = true,
        callback = function(event)
            -- WinClosed runs before the window becomes invalid. Do not try
            -- to close the same window again while handling its closure.
            if tonumber(event.match) == conversation.response_window then
                conversation.response_window = nil
            elseif tonumber(event.match) == conversation.response_frame_window then
                conversation.response_frame_window = nil
            else
                conversation.source_window = nil
            end
            close_conversation_windows(conversation)
        end,
        desc = "Cancel SwiftPrompt when its response or source window closes",
    })
    configure_response_display(conversation.response_buffer, conversation.response_window)

    vim.keymap.set("n", "f", function()
        M.open_follow_up_prompt(conversation)
    end, { buffer = conversation.response_buffer, desc = "Ask a follow-up" })

    vim.keymap.set("n", "gY", function()
        vim.fn.setreg('"', conversation.response_text)
        vim.fn.setreg("+", conversation.response_text)
    end, { buffer = conversation.response_buffer, desc = "Copy SwiftyPrompt response" })

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
    render_response(conversation, M.thinking_status_text(frame_index, conversation.connector_name))

    local thinking_timer = vim.uv.new_timer()
    conversation.thinking_timer = thinking_timer
    thinking_timer:start(THINKING_FRAME_INTERVAL_MS, THINKING_FRAME_INTERVAL_MS, function()
        vim.schedule(function()
            if not conversation.is_waiting or conversation.thinking_timer ~= thinking_timer then
                return
            end

            frame_index = frame_index + 1
            render_response(conversation, M.thinking_status_text(frame_index, conversation.connector_name))
        end)
    end)
end

local function submit_question(conversation, question)
    conversation.question = question
    local connector_name = conversation.connector_name
    local connector = connectors[connector_name]
    local connector_options = conversation.connector_options

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

local function close_question_panel(conversation)
    ui.detach(conversation.question_panel)
    if conversation.question_close_autocmd then
        vim.api.nvim_del_autocmd(conversation.question_close_autocmd)
        conversation.question_close_autocmd = nil
    end
    close_window_if_valid(conversation.question_window)
    close_window_if_valid(conversation.question_frame_window)
    conversation.question_window = nil
    conversation.question_frame_window = nil
end

local function open_question_prompt(conversation, row_offset)
    close_question_panel(conversation)

    local question_buffer = vim.api.nvim_create_buf(false, true)
    -- A scratch buffer lets users edit every line of a multiline question.
    vim.bo[question_buffer].buftype = "nofile"
    -- Prompt text must never survive after its floating window closes. Otherwise
    -- Neovim keeps a modified unnamed buffer and asks to save it on exit.
    vim.bo[question_buffer].bufhidden = "wipe"
    -- Blink enables completion in scratch buffers unless explicitly disabled.
    vim.b[question_buffer].completion = false

    local previous_cursor
    local input_cursor
    vim.api.nvim_create_autocmd({ "BufEnter", "InsertEnter" }, {
        buffer = question_buffer,
        callback = function()
            if previous_cursor == nil then
                previous_cursor = vim.o.guicursor
            end
            input_cursor = previous_cursor .. (previous_cursor == "" and "" or ",") .. "a:ver25"
            vim.o.guicursor = input_cursor
        end,
        desc = "Show an insertion caret in the question editor",
    })
    vim.api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
        buffer = question_buffer,
        callback = function()
            -- Cursor shape is global, so restore it when focus leaves the input.
            if previous_cursor and vim.o.guicursor == input_cursor then
                vim.o.guicursor = previous_cursor
            end
            previous_cursor = nil
        end,
        desc = "Restore the editor cursor after leaving the question",
    })

    block_global_keymaps(question_buffer, { "n", "i" })
    -- Native completion still works without Blink unless its shortcuts are blocked.
    for _, completion_key in ipairs({ "<C-n>", "<C-p>", "<C-x>" }) do
        vim.keymap.set("i", completion_key, "<Nop>", {
            buffer = question_buffer,
            nowait = true,
        })
    end
    for _, mode in ipairs({ "n", "i" }) do
        vim.keymap.set(mode, "<C-o>", "<Nop>", {
            buffer = question_buffer,
            nowait = true,
            remap = false,
        })
    end
    for _, input_key in ipairs({ "<BS>", "<C-h>", "<Del>" }) do
        vim.keymap.set("i", input_key, input_key, {
            buffer = question_buffer,
            nowait = true,
            remap = false,
        })
    end

    local function insert_newline()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local row, column = cursor[1] - 1, cursor[2]
        -- Split at the cursor without applying the source buffer's indentation rules.
        vim.api.nvim_buf_set_text(question_buffer, row, column, row, column, { "", "" })
        vim.api.nvim_win_set_cursor(0, { cursor[1] + 1, 0 })
    end

    vim.keymap.set("i", "<C-j>", insert_newline, {
        buffer = question_buffer,
        nowait = true,
        desc = "Insert a newline in the question",
    })

    conversation.question_panel = ui.open(question_buffer,
        panel_options(conversation, "input", ui.input_height, row_offset))
    conversation.question_window = conversation.question_panel.body_window
    conversation.question_frame_window = conversation.question_panel.frame_window
    conversation.question_close_autocmd = vim.api.nvim_create_autocmd("WinClosed", {
        pattern = {
            tostring(conversation.question_window),
            tostring(conversation.question_frame_window),
            tostring(conversation.source_window),
        },
        once = true,
        callback = function(event)
            if tonumber(event.match) == conversation.question_window then
                conversation.question_window = nil
            elseif tonumber(event.match) == conversation.question_frame_window then
                conversation.question_frame_window = nil
            else
                conversation.source_window = nil
            end
            close_conversation_windows(conversation)
        end,
        desc = "Dismiss SwiftyPrompt when its input or source window closes",
    })

    vim.keymap.set("i", "<CR>", function()
        local lines = vim.api.nvim_buf_get_lines(question_buffer, 0, -1, false)
        local question = table.concat(lines, "\n")
        vim.cmd("stopinsert")
        close_question_panel(conversation)

        if question ~= "" then
            submit_question(conversation, question)
        else
            close_conversation_windows(conversation)
        end
    end, {
        buffer = question_buffer,
        nowait = true,
        desc = "Send the question",
    })

    set_close_keymaps(question_buffer, conversation)
    vim.cmd("startinsert")
end

function M.open_follow_up_prompt(conversation)
    if conversation.is_waiting or not conversation.response_window
        or not vim.api.nvim_win_is_valid(conversation.response_window)
    then
        return
    end

    -- Keep the editor directly below the visible response card.
    open_question_prompt(
        conversation,
        conversation.response_window_height + ui.response_offset + 5
    )
end

local function extract_visual_selection(visual_start, cursor_position, visual_mode)
    local cursor_position_for_region = { 0, cursor_position[1], cursor_position[2] + 1, 0 }
    local selected_lines = vim.fn.getregion(visual_start, cursor_position_for_region, {
        type = visual_mode,
    })
    return table.concat(selected_lines, "\n")
end

local function conversation_key(source_buffer, scope, selected_code, connector_name, connector_options)
    connector_options = connector_options or {}
    -- Session IDs are private to a provider, executable, model, and project.
    return table.concat({
        connector_name,
        connector_options.command or "",
        connector_options.model or "",
        vim.fn.getcwd(),
        source_buffer,
        scope,
        selected_code,
    }, "\0")
end

local function start_conversation(
    source_window, anchor_line, anchor_column, selected_code, scope, context_label, context_subject, highlight_ranges
)
    local source_buffer = vim.api.nvim_win_get_buf(source_window)
    local connector_name = config.values.connector
    local connector_options = vim.deepcopy(config.values.connectors[connector_name])
    local key = conversation_key(source_buffer, scope, selected_code, connector_name, connector_options)
    local conversation = {
        source_window = source_window,
        source_buffer = source_buffer,
        source_highlights = ui.highlight_source(source_buffer, highlight_ranges or {}),
        anchor_line = anchor_line,
        anchor_column = anchor_column,
        selected_code = selected_code,
        key = key,
        connector_name = connector_name,
        connector_options = connector_options,
        thread_id = thread_ids_by_conversation_key[key],
        context_label = context_label,
        context_subject = context_subject,
        display_context = context_subject,
    }

    open_question_prompt(conversation, 1)
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
    local highlight_ranges = {}
    local cursor_region_position = { 0, cursor_position[1], cursor_position[2] + 1, 0 }
    -- Use the same native region rules as extraction for reversed and block selections.
    for _, segment in ipairs(vim.fn.getregionpos(visual_start, cursor_region_position, { type = visual_mode })) do
        local first, last = segment[1], segment[2]
        local line = vim.api.nvim_buf_get_lines(0, first[2] - 1, first[2], false)[1]
        if visual_mode == "V" then
            table.insert(highlight_ranges, { row = first[2] - 1, linewise = true })
        elseif first[3] > 0 then
            local last_character = vim.fn.strcharpart(line:sub(last[3]), 0, 1)
            table.insert(highlight_ranges, {
                row = first[2] - 1,
                column = first[3] - 1,
                end_column = last[3] - 1 + #last_character,
            })
        end
    end
    start_conversation(source_window, anchor_line, anchor_column, selected_code, selection_scope,
        "Selection", "selected code", highlight_ranges)
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
            local highlight_ranges = {}
            -- Symbol context includes complete source lines, so highlight those same lines.
            for row = symbol_range.start.line, symbol_range["end"].line do
                table.insert(highlight_ranges, { row = row, linewise = true })
            end
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
                symbol_display_name(selected_symbol),
                highlight_ranges
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
