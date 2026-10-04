local swiftyprompt = require("swiftyprompt")
local codex = require("swiftyprompt.connectors.codex")

describe("SwiftPrompt interaction UI", function()
    local original_ask
    local original_cancel
    local original_open_win
    local original_prompt_setcallback
    local original_buf_request_sync
    local original_mode
    local original_getpos
    local original_notify
    local original_selection
    local original_normal_control_o
    local original_insert_control_o
    local original_normal_f9
    local original_insert_enter
    local original_insert_backspace
    local original_insert_escape
    local original_navigation_mappings
    local original_setreg
    local original_lines
    local opened_window_configs
    local question_prompt_callbacks
    local codex_requests
    local notifications
    local codex_response

    before_each(function()
        opened_window_configs = {}
        question_prompt_callbacks = {}
        codex_requests = {}
        codex_response = "first line\nsecond line\nthird line"
        original_ask = codex.ask
        original_cancel = codex.cancel
        original_open_win = vim.api.nvim_open_win
        original_prompt_setcallback = vim.fn.prompt_setcallback
        original_buf_request_sync = vim.lsp.buf_request_sync
        original_mode = vim.fn.mode
        original_getpos = vim.fn.getpos
        original_notify = vim.notify
        original_selection = vim.o.selection
        original_setreg = vim.fn.setreg
        original_lines = vim.o.lines
        original_normal_control_o = vim.fn.maparg("<C-o>", "n", false, true)
        original_insert_control_o = vim.fn.maparg("<C-o>", "i", false, true)
        original_normal_f9 = vim.fn.maparg("<F9>", "n", false, true)
        original_insert_enter = vim.fn.maparg("<CR>", "i", false, true)
        original_insert_backspace = vim.fn.maparg("<BS>", "i", false, true)
        original_insert_escape = vim.fn.maparg("<Esc>", "i", false, true)
        original_navigation_mappings = {}
        for _, key in ipairs({ "<C-d>", "<C-u>", "<F8>", "j", "<Plug>(SwiftPromptTestDown)" }) do
            original_navigation_mappings[key] = vim.fn.maparg(key, "n", false, true)
            pcall(vim.keymap.del, "n", key)
        end
        notifications = {}

        vim.api.nvim_open_win = function(buffer_id, enter_window, window_config)
            if window_config.border ~= "none" then
                table.insert(opened_window_configs, vim.deepcopy(window_config))
            end
            return original_open_win(buffer_id, enter_window, window_config)
        end
        vim.fn.prompt_setcallback = function(prompt_buffer, submit_callback)
            question_prompt_callbacks[prompt_buffer] = submit_callback
        end
        vim.fn.mode = function()
            return "v"
        end
        vim.notify = function(message, level)
            table.insert(notifications, { message = message, level = level })
        end
        codex.ask = function(_, question, selected_code, thread_id, callbacks)
            table.insert(codex_requests, {
                question = question,
                selected_code = selected_code,
                thread_id = thread_id,
            })
            callbacks.on_complete(codex_response, nil, "thread-1")
            return {}
        end
    end)

    after_each(function()
        codex.ask = original_ask
        codex.cancel = original_cancel
        vim.api.nvim_open_win = original_open_win
        vim.fn.prompt_setcallback = original_prompt_setcallback
        vim.lsp.buf_request_sync = original_buf_request_sync
        vim.fn.mode = original_mode
        vim.fn.getpos = original_getpos
        vim.notify = original_notify
        vim.o.selection = original_selection
        vim.fn.setreg = original_setreg
        vim.o.lines = original_lines
        for key, mapping in pairs(original_navigation_mappings) do
            pcall(vim.keymap.del, "n", key)
            if next(mapping) then
                vim.fn.mapset("n", false, mapping)
            end
        end
        pcall(vim.keymap.del, "n", "<C-o>")
        pcall(vim.keymap.del, "i", "<C-o>")
        pcall(vim.keymap.del, "n", "<F9>")
        pcall(vim.keymap.del, "i", "<CR>")
        pcall(vim.keymap.del, "i", "<BS>")
        pcall(vim.keymap.del, "i", "<Esc>")
        if next(original_normal_control_o) then
            vim.fn.mapset("n", false, original_normal_control_o)
        end
        if next(original_insert_control_o) then
            vim.fn.mapset("i", false, original_insert_control_o)
        end
        if next(original_normal_f9) then
            vim.fn.mapset("n", false, original_normal_f9)
        end
        if next(original_insert_enter) then
            vim.fn.mapset("i", false, original_insert_enter)
        end
        if next(original_insert_backspace) then
            vim.fn.mapset("i", false, original_insert_backspace)
        end
        if next(original_insert_escape) then
            vim.fn.mapset("i", false, original_insert_escape)
        end

        for _, window in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_is_valid(window) and vim.api.nvim_win_get_config(window).relative ~= "" then
                vim.api.nvim_win_close(window, true)
            end
        end
    end)

    local function open_selection(lines, start_position, cursor_position, mode)
        local source_window = vim.api.nvim_get_current_win()
        local source_buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(source_window, source_buffer)
        vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, lines)
        vim.fn.getpos = function(mark)
            assert.same("v", mark)
            return { 0, start_position[1], start_position[2], 0 }
        end
        vim.api.nvim_win_set_cursor(source_window, cursor_position)
        vim.fn.mode = function()
            return mode or "v"
        end

        swiftyprompt.ask_about_visual_selection()
        return source_window
    end

    local function submit_latest_prompt(question)
        for prompt_buffer, submit_callback in pairs(question_prompt_callbacks) do
            if vim.api.nvim_buf_is_valid(prompt_buffer) then
                submit_callback(question)
                return
            end
        end
        error("No open question prompt")
    end

    it("splits empty, single-line, and multi-line responses", function()
        assert.same({ "" }, swiftyprompt.split_response_lines(""))
        assert.same({ "one line" }, swiftyprompt.split_response_lines("one line"))
        assert.same({ "one", "two", "three" }, swiftyprompt.split_response_lines("one\ntwo\nthree"))
    end)

    it("normalizes Unix, Windows, and classic Mac newlines", function()
        assert.same({ "one", "two", "three" }, swiftyprompt.split_response_lines("one\ntwo\nthree"))
        assert.same({ "one", "two", "three" }, swiftyprompt.split_response_lines("one\r\ntwo\r\nthree"))
        assert.same({ "one", "two", "three" }, swiftyprompt.split_response_lines("one\rtwo\rthree"))
    end)

    it("preserves blank lines and trailing newlines in responses", function()
        assert.same({ "one", "", "two", "", "" }, swiftyprompt.split_response_lines("one\n\ntwo\n\n"))
    end)

    it("anchors the question dialog at the middle of a multi-line selection", function()
        local source_window = open_selection(
            { "abcDEF", "ghiJKL", "mnopqr" },
            { 1, 4 },
            { 3, 3 }
        )

        assert.same({
            relative = "win",
            win = source_window,
            bufpos = { 1, 3 },
            anchor = "NW",
            width = 60,
            height = 5,
            row = 1,
            col = 0,
            style = "minimal",
            border = "rounded",
            title = {
                { " SwiftyPrompt ", "SwiftyPromptAccent" },
                { "· ", "SwiftyPromptMuted" },
                { "selected code", "SwiftyPromptContext" },
                { " ", "SwiftyPromptNormal" },
            },
            focusable = false,
            zindex = 50,
        }, opened_window_configs[1])

        submit_latest_prompt("Explain this")
        assert.same(table.concat({ "DEF", "ghiJKL", "mnop" }, "\n"), codex_requests[1].selected_code)
        assert.same("Explain this", codex_requests[1].question)
        assert.same(opened_window_configs[1].title, opened_window_configs[2].title)
    end)

    it("places the follow-up input directly below the visible response", function()
        open_selection({ "one", "two", "three" }, { 1, 1 }, { 3, 2 })
        submit_latest_prompt("Explain this")

        -- The response window is current after it opens, so its buffer-local
        -- mapping provides the same path a user takes by pressing f.
        vim.cmd("normal f")

        assert.same(opened_window_configs[2].title, opened_window_configs[3].title)
        assert.same(10, opened_window_configs[3].row) -- reply + pinned header + footer and borders
        assert.same(5, opened_window_configs[3].height)
    end)

    it("labels file prompts and responses with their context", function()
        local source_window = vim.api.nvim_get_current_win()
        local source_buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(source_window, source_buffer)
        vim.api.nvim_buf_set_name(source_buffer, "/tmp/settings.lua")
        vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { "local value = 1" })

        swiftyprompt.ask_about_current_file()
        assert.same({
            { " SwiftyPrompt ", "SwiftyPromptAccent" },
            { "· ", "SwiftyPromptMuted" },
            { "settings.lua", "SwiftyPromptContext" },
            { " ", "SwiftyPromptNormal" },
        }, opened_window_configs[1].title)

        submit_latest_prompt("Explain this")
        assert.same(opened_window_configs[1].title, opened_window_configs[2].title)
    end)

    it("labels unnamed file prompts as the current buffer", function()
        local source_window = vim.api.nvim_get_current_win()
        local source_buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(source_window, source_buffer)
        vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { "local value = 1" })

        swiftyprompt.ask_about_current_file()

        assert.same({
            { " SwiftyPrompt ", "SwiftyPromptAccent" },
            { "· ", "SwiftyPromptMuted" },
            { "this buffer", "SwiftyPromptContext" },
            { " ", "SwiftyPromptNormal" },
        }, opened_window_configs[1].title)
    end)

    it("labels symbol prompts and responses with their context", function()
        local source_window = vim.api.nvim_get_current_win()
        local source_buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(source_window, source_buffer)
        vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, {
            "local function greet()",
            "  return 'hello'",
            "end",
        })
        vim.api.nvim_win_set_cursor(source_window, { 1, 0 })
        vim.lsp.buf_request_sync = function()
            return {
                [1] = {
                    result = {
                        {
                            name = "greet",
                            range = {
                                start = { line = 0, character = 0 },
                                ["end"] = { line = 2, character = 3 },
                            },
                        },
                    },
                },
            }
        end

        swiftyprompt.ask_about_current_symbol()
        assert.same({
            { " SwiftyPrompt ", "SwiftyPromptAccent" },
            { "· ", "SwiftyPromptMuted" },
            { "greet", "SwiftyPromptContext" },
            { " ", "SwiftyPromptNormal" },
        }, opened_window_configs[1].title)

        submit_latest_prompt("Explain this")
        assert.same(opened_window_configs[1].title, opened_window_configs[2].title)
    end)

    it("truncates long symbol names in prompt titles", function()
        local source_window = vim.api.nvim_get_current_win()
        local source_buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(source_window, source_buffer)
        vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { "local value = 1" })
        local long_symbol_name = string.rep("very_long_symbol_name_", 4)
        vim.lsp.buf_request_sync = function()
            return {
                [1] = {
                    result = {
                        {
                            name = long_symbol_name,
                            range = {
                                start = { line = 0, character = 0 },
                                ["end"] = { line = 0, character = 15 },
                            },
                        },
                    },
                },
            }
        end

        swiftyprompt.ask_about_current_symbol()

        local title = opened_window_configs[1].title
        local title_text = title[1][1] .. title[2][1] .. title[3][1] .. title[4][1]
        assert.matches("SwiftyPrompt · very_long_symbol_name", title_text)
        assert.matches("%.%.%.", title[3][1])
        assert.same("SwiftyPromptContext", title[3][2])
        assert.is_true(vim.fn.strdisplaywidth(title_text) <= 60)
    end)

    it("uses a non-empty symbol detail when the LSP omits its name", function()
        local source_window = vim.api.nvim_get_current_win()
        local source_buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(source_window, source_buffer)
        vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { "local value = 1" })
        vim.lsp.buf_request_sync = function()
            return {
                [1] = {
                    result = {
                        {
                            name = "",
                            detail = "M.setup",
                            range = {
                                start = { line = 0, character = 0 },
                                ["end"] = { line = 0, character = 15 },
                            },
                        },
                    },
                },
            }
        end

        swiftyprompt.ask_about_current_symbol()

        assert.same({
            { " SwiftyPrompt ", "SwiftyPromptAccent" },
            { "· ", "SwiftyPromptMuted" },
            { "M.setup", "SwiftyPromptContext" },
            { " ", "SwiftyPromptNormal" },
        }, opened_window_configs[1].title)
    end)

    it("uses a generic label when the LSP returns no symbol text", function()
        local source_window = vim.api.nvim_get_current_win()
        local source_buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(source_window, source_buffer)
        vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { "local value = 1" })
        vim.lsp.buf_request_sync = function()
            return {
                [1] = {
                    result = {
                        {
                            name = "",
                            detail = " ",
                            range = {
                                start = { line = 0, character = 0 },
                                ["end"] = { line = 0, character = 15 },
                            },
                        },
                    },
                },
            }
        end

        swiftyprompt.ask_about_current_symbol()

        assert.same({
            { " SwiftyPrompt ", "SwiftyPromptAccent" },
            { "· ", "SwiftyPromptMuted" },
            { "this symbol", "SwiftyPromptContext" },
            { " ", "SwiftyPromptNormal" },
        }, opened_window_configs[1].title)
    end)

    it("reuses a thread after closing and reopening the same selection", function()
        local source_window = open_selection({ "one", "two", "three" }, { 1, 1 }, { 3, 2 })
        submit_latest_prompt("Explain this")
        vim.cmd("normal q")

        vim.api.nvim_win_set_cursor(source_window, { 3, 2 })
        swiftyprompt.ask_about_visual_selection()
        submit_latest_prompt("What should I change?")

        assert.same("thread-1", codex_requests[2].thread_id)
    end)

    it("streams response text into the response window", function()
        local callbacks
        codex.ask = function(_, _, _, _, request_callbacks)
            callbacks = request_callbacks
            return {}
        end

        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")
        callbacks.on_update("First streamed sentence.")

        local response_buffer = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
        assert.same({ "First streamed sentence." }, vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false))

        callbacks.on_complete("Complete response.", nil, "thread-1")
        assert.same({ "Complete response." }, vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false))
    end)

    it("animates the thinking status until streamed text arrives", function()
        local callbacks
        codex.ask = function(_, _, _, _, request_callbacks)
            callbacks = request_callbacks
            return {}
        end

        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")

        local response_buffer = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
        local first_status = vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false)[1]
        assert.same(swiftyprompt.thinking_status_text(1), first_status)

        assert.is_true(vim.wait(300, function()
            local current_status = vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false)[1]
            return current_status ~= first_status
        end, 20))

        callbacks.on_update("The answer is arriving.")
        assert.same({ "The answer is arriving." }, vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false))
        vim.wait(150)
        assert.same({ "The answer is arriving." }, vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false))
        callbacks.on_complete("The complete answer.", nil, "thread-1")
    end)

    it("cycles thinking-status frames without changing its message", function()
        assert.same("◜  Codex is thinking", swiftyprompt.thinking_status_text(1))
        assert.same("◠  Codex is thinking", swiftyprompt.thinking_status_text(2))
        assert.same("◜  Codex is thinking", swiftyprompt.thinking_status_text(7))
    end)

    it("cancels an in-progress request when Escape closes the response window", function()
        local request = {}
        local cancelled_request
        codex.ask = function()
            return request
        end
        codex.cancel = function(request_to_cancel)
            cancelled_request = request_to_cancel
        end

        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")

        local response_window = vim.api.nvim_get_current_win()
        local escape = vim.fn.maparg("<Esc>", "n", false, true)
        escape.callback()

        assert.same(request, cancelled_request)
        assert.is_false(vim.api.nvim_win_is_valid(response_window))
    end)

    it("wraps question text within the three-line prompt input", function()
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })

        local prompt_window = vim.api.nvim_get_current_win()
        local prompt_config = vim.api.nvim_win_get_config(prompt_window)
        assert.same(3, prompt_config.height)
        assert.is_true(vim.wo[prompt_window].wrap)
    end)

    it("grows the response window for wrapped lines", function()
        codex_response = string.rep("x", 61)
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")

        local response_window = vim.api.nvim_get_current_win()
        local response_config = vim.api.nvim_win_get_config(response_window)
        assert.same(58, response_config.width)
        assert.same(2, response_config.height)
        assert.is_true(vim.wo[response_window].wrap)
    end)

    for _, screen_height in ipairs({ 24, 40, 80 }) do
        it("limits the entire response card on a " .. screen_height .. "-row screen", function()
            vim.o.lines = screen_height
            codex_response = string.rep("Response line\n", 100)
            open_selection({ "one" }, { 1, 1 }, { 1, 0 })
            submit_latest_prompt("Explain this")
            local frame_window = vim.api.nvim_win_get_config(0).win
            local card_height = vim.api.nvim_win_get_height(frame_window) + 2
            assert.is_true(card_height <= 22)
            assert.is_true(card_height <= math.floor((screen_height - vim.o.cmdheight) * 0.6))
            vim.api.nvim_feedkeys("G", "mtx", false)
            assert.same(101, vim.api.nvim_win_get_cursor(0)[1])
        end)
    end

    it("shrinks an open response card when the terminal gets smaller", function()
        vim.o.lines = 80
        codex_response = string.rep("Response line\n", 100)
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")
        local response_window = vim.api.nvim_get_current_win()
        local frame_window = vim.api.nvim_win_get_config(response_window).win
        local previous_height = vim.api.nvim_win_get_height(frame_window)
        vim.api.nvim_win_set_cursor(response_window, { 70, 0 })
        local changedtick = vim.api.nvim_buf_get_changedtick(0)
        vim.o.lines = 24
        vim.api.nvim_exec_autocmds("VimResized", {})
        assert.is_true(vim.api.nvim_win_get_height(frame_window) < previous_height)
        assert.is_true(vim.api.nvim_win_get_height(frame_window) + 2 <= 13)
        assert.same(response_window, vim.api.nvim_get_current_win())
        assert.same(101, vim.api.nvim_buf_line_count(0))
        assert.same({ 70, 0 }, vim.api.nvim_win_get_cursor(response_window))
        assert.same(changedtick, vim.api.nvim_buf_get_changedtick(0))
    end)

    it("renders responses in a read-only Markdown buffer", function()
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")

        local response_window = vim.api.nvim_get_current_win()
        local response_buffer = vim.api.nvim_win_get_buf(response_window)
        assert.equals("swiftyprompt_markdown", vim.bo[response_buffer].filetype)
        assert.is_false(vim.bo[response_buffer].modifiable)
        assert.is_true(vim.bo[response_buffer].readonly)
        assert.is_false(vim.bo[response_buffer].modified)
        assert.same(2, vim.wo[response_window].conceallevel)
        assert.same("nvic", vim.wo[response_window].concealcursor)
    end)

    it("keeps the question and controls fixed while scrolling a response", function()
        local lines = {}
        for row = 1, 80 do
            lines[row] = "Answer line " .. row
        end
        codex_response = table.concat(lines, "\n")
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("What does setup() override?")
        local response_window = vim.api.nvim_get_current_win()
        local frame_window = vim.api.nvim_win_get_config(response_window).win
        local frame_buffer = vim.api.nvim_win_get_buf(frame_window)
        local namespace = vim.api.nvim_create_namespace("swiftyprompt.ui")
        local chrome = vim.api.nvim_buf_get_extmarks(frame_buffer, namespace, 0, -1, { details = true })
        vim.api.nvim_feedkeys("G", "mtx", false)
        vim.cmd("redraw")
        assert.same(80, vim.api.nvim_win_get_cursor(response_window)[1])
        assert.is_true(vim.fn.winsaveview().topline > 1)
        assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(frame_window))
        assert.same(chrome, vim.api.nvim_buf_get_extmarks(frame_buffer, namespace, 0, -1, { details = true }))
        assert.same("You", chrome[1][4].virt_text[1][1])
        assert.same(" · What does setup() override?", chrome[1][4].virt_text[2][1])
        assert.same({ lines[1], lines[2] }, vim.api.nvim_buf_get_lines(0, 0, 2, false))
    end)

    it("copies the complete response with gY, including offscreen Markdown", function()
        codex_response = "# Heading\n" .. string.rep("- **Detail**\n", 40)
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")
        local copied = {}
        vim.fn.setreg = function(register, text)
            copied[register] = text
        end
        vim.api.nvim_feedkeys("GgY", "mtx", false)
        assert.same(codex_response, copied['"'])
        assert.same(codex_response, copied["+"])
        assert.is_false(vim.bo.modifiable)
    end)

    it("updates the fixed question when a follow-up is submitted", function()
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("First question")
        vim.api.nvim_feedkeys("f", "mtx", false)
        submit_latest_prompt("Follow-up question")
        local frame_window = vim.api.nvim_win_get_config(0).win
        local frame_buffer = vim.api.nvim_win_get_buf(frame_window)
        local marks = vim.api.nvim_buf_get_extmarks(frame_buffer,
            vim.api.nvim_create_namespace("swiftyprompt.ui"), { 0, 0 }, { 0, -1 }, { details = true })
        assert.same(" · Follow-up question", marks[1][4].virt_text[2][1])
        assert.same("Follow-up question", codex_requests[2].question)
    end)

    it("closes both parts of a prompt when its frame is dismissed", function()
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        local body_window = vim.api.nvim_get_current_win()
        local frame_window = vim.api.nvim_win_get_config(body_window).win
        local body_buffer = vim.api.nvim_get_current_buf()
        local frame_buffer = vim.api.nvim_win_get_buf(frame_window)
        vim.api.nvim_win_close(frame_window, true)
        assert.is_false(vim.api.nvim_win_is_valid(body_window))
        assert.is_false(vim.api.nvim_win_is_valid(frame_window))
        assert.is_false(vim.api.nvim_buf_is_valid(body_buffer))
        assert.is_false(vim.api.nvim_buf_is_valid(frame_buffer))
        assert.same({}, codex_requests)
    end)

    it("dismisses an unsubmitted prompt when its source window closes", function()
        local source_window = open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        local body_window = vim.api.nvim_get_current_win()
        local frame_window = vim.api.nvim_win_get_config(body_window).win
        local body_buffer = vim.api.nvim_get_current_buf()
        local frame_buffer = vim.api.nvim_win_get_buf(frame_window)
        vim.api.nvim_open_win(vim.api.nvim_win_get_buf(source_window), false, {
            split = "right", win = source_window,
        })
        vim.api.nvim_win_close(source_window, true)
        assert.is_false(vim.api.nvim_win_is_valid(body_window))
        assert.is_false(vim.api.nvim_win_is_valid(frame_window))
        assert.is_false(vim.api.nvim_buf_is_valid(body_buffer))
        assert.is_false(vim.api.nvim_buf_is_valid(frame_buffer))
        assert.same({}, codex_requests)
    end)

    it("cancels a pending request when its response frame closes", function()
        local callbacks
        local request = {}
        local cancellations = 0
        codex.ask = function(_, _, _, _, request_callbacks)
            callbacks = request_callbacks
            return request
        end
        codex.cancel = function(cancelled)
            assert.same(request, cancelled)
            cancellations = cancellations + 1
        end
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")
        local body_window = vim.api.nvim_get_current_win()
        local frame_window = vim.api.nvim_win_get_config(body_window).win
        local body_buffer = vim.api.nvim_get_current_buf()
        local frame_buffer = vim.api.nvim_win_get_buf(frame_window)
        vim.api.nvim_win_close(frame_window, true)
        assert.has_no.errors(function()
            callbacks.on_update("Late update")
            callbacks.on_complete("Late answer", nil, "thread-1")
        end)
        assert.same(1, cancellations)
        assert.is_false(vim.api.nvim_win_is_valid(body_window))
        assert.is_false(vim.api.nvim_win_is_valid(frame_window))
        assert.is_false(vim.api.nvim_buf_is_valid(body_buffer))
        assert.is_false(vim.api.nvim_buf_is_valid(frame_buffer))
    end)

    it("conceals Markdown delimiters and navigates by wrapped rows", function()
        codex_response = "`Model` has **bold** and *italic* text."
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")

        local response_window = vim.api.nvim_get_current_win()
        local response_buffer = vim.api.nvim_win_get_buf(response_window)
        local parser = vim.treesitter.get_parser(response_buffer, "markdown")
        parser:parse(true)
        local captures = vim.treesitter.get_captures_at_pos(response_buffer, 0, 0)
        assert.is_true(vim.iter(captures):any(function(capture)
            return capture.capture == "conceal"
        end))

        for key, wrapped_key in pairs({ j = "gj", k = "gk", ["0"] = "g0", ["^"] = "g^", ["$"] = "g$" }) do
            assert.same(wrapped_key, vim.fn.maparg(key, "n", false, true).rhs)
        end

        assert.same(response_buffer, vim.api.nvim_win_get_buf(response_window))
    end)

    it("closes prompt and response dialogs with Escape in Normal mode", function()
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        local prompt_window = vim.api.nvim_get_current_win()
        local prompt_buffer = vim.api.nvim_win_get_buf(prompt_window)
        local escape = vim.fn.maparg("<Esc>", "n", false, true)
        assert.is_function(escape.callback)
        escape.callback()
        assert.is_false(vim.api.nvim_win_is_valid(prompt_window))
        assert.is_false(vim.api.nvim_buf_is_valid(prompt_buffer))

        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")
        local response_window = vim.api.nvim_get_current_win()
        escape = vim.fn.maparg("<Esc>", "n", false, true)
        assert.is_function(escape.callback)
        escape.callback()
        assert.is_false(vim.api.nvim_win_is_valid(response_window))
    end)

    it("blocks global Control-O mappings inside the question prompt", function()
        local global_mapping_count = 0
        vim.keymap.set("i", "<C-o>", function()
            global_mapping_count = global_mapping_count + 1
        end)

        open_selection({ "one" }, { 1, 1 }, { 1, 0 })

        local prompt_buffer = vim.api.nvim_get_current_buf()
        for _, mode in ipairs({ "n", "i" }) do
            local control_o_mapping = vim.fn.maparg("<C-o>", mode, false, true)
            assert.same(1, control_o_mapping.buffer)
            assert.same("<Nop>", control_o_mapping.rhs)
        end

        vim.api.nvim_feedkeys(vim.keycode("<C-o>"), "mtx", false)
        assert.same(0, global_mapping_count)
        assert.same(prompt_buffer, vim.api.nvim_get_current_buf())
    end)

    it("preserves Enter to submit from the question prompt", function()
        local global_mapping_count = 0
        vim.keymap.set("i", "<CR>", function()
            global_mapping_count = global_mapping_count + 1
        end)
        vim.fn.prompt_setcallback = original_prompt_setcallback

        open_selection({ "one" }, { 1, 1 }, { 1, 0 })

        local enter_mapping = vim.fn.maparg("<CR>", "i", false, true)
        assert.same(1, enter_mapping.buffer)
        assert.same("<CR>", enter_mapping.rhs)

        vim.api.nvim_feedkeys(vim.keycode("iExplain this<CR>"), "mtx", false)
        assert.same(0, global_mapping_count)
        assert.same("Explain this", codex_requests[1].question)
    end)

    it("preserves Backspace while editing a question prompt", function()
        local global_mapping_count = 0
        vim.keymap.set("i", "<BS>", function()
            global_mapping_count = global_mapping_count + 1
        end)
        vim.fn.prompt_setcallback = original_prompt_setcallback

        open_selection({ "one" }, { 1, 1 }, { 1, 0 })

        local backspace_mapping = vim.fn.maparg("<BS>", "i", false, true)
        assert.same(1, backspace_mapping.buffer)
        assert.same("<BS>", backspace_mapping.rhs)

        vim.api.nvim_feedkeys(vim.keycode("iHellx<BS>o<CR>"), "mtx", false)
        assert.same(0, global_mapping_count)
        assert.same("Hello", codex_requests[1].question)
    end)

    it("closes a question prompt with Escape from Insert mode", function()
        local global_mapping_count = 0
        vim.keymap.set("i", "<Esc>", function()
            global_mapping_count = global_mapping_count + 1
        end)

        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        local prompt_window = vim.api.nvim_get_current_win()

        vim.api.nvim_feedkeys(vim.keycode("i<Esc>"), "mtx", false)
        assert.same(0, global_mapping_count)
        assert.is_false(vim.api.nvim_win_is_valid(prompt_window))
    end)

    local function open_long_response()
        local lines = {}
        for line = 1, 80 do
            lines[line] = "Response line " .. line
        end
        codex_response = table.concat(lines, "\n")
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")
        vim.wo.scroll = 4
        vim.api.nvim_win_set_cursor(0, { 30, 0 })
        vim.cmd("normal! zz")
    end

    it("scrolls responses with native Control-D and Control-U", function()
        open_long_response()
        local original_topline = vim.fn.winsaveview().topline
        vim.api.nvim_feedkeys(vim.keycode("<C-d>"), "mtx", false)
        assert.same(34, vim.api.nvim_win_get_cursor(0)[1])
        assert.is_true(vim.fn.winsaveview().topline > original_topline)
        vim.api.nvim_feedkeys(vim.keycode("<C-u>"), "mtx", false)
        assert.same(30, vim.api.nvim_win_get_cursor(0)[1])
        assert.same(original_topline, vim.fn.winsaveview().topline)
    end)

    it("honors user Control-D and Control-U mappings in responses", function()
        vim.keymap.set("n", "<C-d>", "<C-d>zz")
        vim.keymap.set("n", "<C-u>", "<C-u>zz")
        open_long_response()
        local response_window = vim.api.nvim_get_current_win()
        vim.api.nvim_feedkeys(vim.keycode("<C-d>"), "mtx", false)
        assert.same(34, vim.api.nvim_win_get_cursor(0)[1])
        vim.api.nvim_feedkeys(vim.keycode("<C-u>"), "mtx", false)
        assert.same(30, vim.api.nvim_win_get_cursor(0)[1])
        assert.same(response_window, vim.api.nvim_get_current_win())
        assert.same(0, vim.fn.maparg("<C-d>", "n", false, true).buffer)
    end)

    it("resolves navigation through custom keys and Plug mappings", function()
        vim.keymap.set("n", "<Plug>(SwiftPromptTestDown)", "<C-d>zz")
        vim.keymap.set("n", "<F8>", "<Plug>(SwiftPromptTestDown)", { remap = true })
        open_long_response()
        vim.api.nvim_feedkeys(vim.keycode("<F8>"), "mtx", false)
        assert.same(34, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("executes Lua navigation callbacks in the response buffer", function()
        vim.keymap.set("n", "<F9>", function()
            local cursor = vim.api.nvim_win_get_cursor(0)
            vim.api.nvim_win_set_cursor(0, { cursor[1] + 5, cursor[2] })
        end)
        open_long_response()
        vim.api.nvim_feedkeys(vim.keycode("<F9>"), "mtx", false)
        assert.same(35, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("honors expression navigation mappings", function()
        vim.keymap.set("n", "<F8>", function()
            return "5j"
        end, { expr = true })
        open_long_response()
        vim.api.nvim_feedkeys(vim.keycode("<F8>"), "mtx", false)
        assert.same(35, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("uses navigation mappings added or changed after opening a response", function()
        vim.keymap.set("n", "<F8>", "2j")
        open_long_response()
        vim.keymap.set("n", "<F8>", "5j")
        vim.keymap.set("n", "<F9>", "3k")
        vim.api.nvim_feedkeys(vim.keycode("<F8><F9>"), "mtx", false)
        assert.same(32, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("preserves user motions instead of replacing them with wrapped defaults", function()
        vim.keymap.set("n", "j", "2j")
        open_long_response()
        vim.api.nvim_feedkeys("j", "mtx", false)
        assert.same(32, vim.api.nvim_win_get_cursor(0)[1])
        assert.same(0, vim.fn.maparg("j", "n", false, true).buffer)
    end)

    it("preserves navigation mappings across streamed updates and completion", function()
        local callbacks
        codex.ask = function(_, _, _, _, request_callbacks)
            callbacks = request_callbacks
            return {}
        end
        vim.keymap.set("n", "<F8>", "5j")
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")
        local response_buffer = vim.api.nvim_get_current_buf()
        vim.keymap.set("n", "j", "2j", { buffer = response_buffer })
        local lines = {}
        for line = 1, 40 do
            lines[line] = "Response line " .. line
        end
        local text = table.concat(lines, "\n")

        callbacks.on_update(text)
        vim.api.nvim_win_set_cursor(0, { 10, 0 })
        vim.api.nvim_feedkeys(vim.keycode("<F8>j"), "mtx", false)
        assert.same(17, vim.api.nvim_win_get_cursor(0)[1])

        callbacks.on_complete(text, nil, "thread-1")
        vim.api.nvim_win_set_cursor(0, { 10, 0 })
        vim.api.nvim_feedkeys(vim.keycode("<F8>j"), "mtx", false)
        assert.same(17, vim.api.nvim_win_get_cursor(0)[1])
        assert.same(response_buffer, vim.api.nvim_get_current_buf())
        assert.is_false(vim.bo.modifiable)
        assert.is_true(vim.bo.readonly)
    end)

    it("navigates wrapped rows by default without changing response text", function()
        codex_response = string.rep("x", 121)
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")
        vim.api.nvim_feedkeys("j", "mtx", false)
        local cursor = vim.api.nvim_win_get_cursor(0)
        assert.same(1, cursor[1])
        assert.is_true(cursor[2] >= vim.api.nvim_win_get_width(0))
        vim.api.nvim_feedkeys("k", "mtx", false)
        assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
        assert.is_false(pcall(vim.cmd, "normal! x"))
        assert.same({ codex_response }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
        assert.is_false(vim.bo.modifiable)
        assert.is_true(vim.bo.readonly)
    end)

    it("blocks native Control-O jumps out of the response", function()
        pcall(vim.keymap.del, "n", "<C-o>")
        open_long_response()
        local response_window = vim.api.nvim_get_current_win()
        local response_buffer = vim.api.nvim_get_current_buf()
        vim.cmd("normal! gg")
        local jumplist = vim.fn.getjumplist()
        vim.api.nvim_feedkeys(vim.keycode("3<C-o>"), "mtx", false)
        assert.same(response_window, vim.api.nvim_get_current_win())
        assert.same(response_buffer, vim.api.nvim_get_current_buf())
        assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
        assert.same(jumplist, vim.fn.getjumplist())
    end)

    it("blocks global Control-O mappings inside the response", function()
        local mapping_called = false
        vim.keymap.set("n", "<C-o>", function()
            mapping_called = true
        end)
        open_long_response()
        local response_buffer = vim.api.nvim_get_current_buf()
        vim.api.nvim_feedkeys(vim.keycode("<C-o>"), "mtx", false)
        assert.is_false(mapping_called)
        assert.same(response_buffer, vim.api.nvim_get_current_buf())
        assert.same({ 30, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    for _, command in ipairs({ "buffer", "alternate buffer", "global mark" }) do
        it("protects the response window from " .. command .. " switches", function()
            local source_window = open_selection({ "one" }, { 1, 1 }, { 1, 0 })
            local source_buffer = vim.api.nvim_win_get_buf(source_window)
            submit_latest_prompt("Explain this")
            local response_window = vim.api.nvim_get_current_win()
            local response_buffer = vim.api.nvim_get_current_buf()
            local previous_mark = vim.api.nvim_get_mark("A", {})
            if command == "buffer" then
                pcall(vim.cmd, "buffer " .. source_buffer)
            elseif command == "alternate buffer" then
                -- Ensure the source is the alternate buffer for this window.
                vim.api.nvim_buf_set_name(source_buffer, "/tmp/swiftyprompt-test-source-" .. source_buffer)
                vim.cmd("balt " .. vim.fn.fnameescape(vim.api.nvim_buf_get_name(source_buffer)))
                pcall(vim.cmd, "normal! " .. vim.keycode("<C-^>"))
                vim.api.nvim_buf_set_name(source_buffer, "")
            else
                vim.api.nvim_buf_set_mark(source_buffer, "A", 1, 0, {})
                pcall(vim.cmd, "normal! 'A")
                vim.api.nvim_del_mark("A")
                if previous_mark[1] > 0 and vim.api.nvim_buf_is_valid(previous_mark[3]) then
                    vim.api.nvim_buf_set_mark(previous_mark[3], "A", previous_mark[1], previous_mark[2], {})
                end
            end
            assert.same(response_window, vim.api.nvim_get_current_win())
            assert.same(response_buffer, vim.api.nvim_win_get_buf(response_window))
            assert.same({ "first line", "second line", "third line" },
                vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false))
        end)
    end

    for _, command in ipairs({ "close", "bdelete!", "bwipeout!", "noautocmd close", "forced buffer switch" }) do
        it("cancels a response closed with :" .. command .. " and ignores late replies", function()
            local callbacks
            local request = {}
            local cancelled_request
            codex.ask = function(_, _, _, _, request_callbacks)
                callbacks = request_callbacks
                return request
            end
            codex.cancel = function(cancelled)
                cancelled_request = cancelled
            end
            local source_window = open_selection({ "one" }, { 1, 1 }, { 1, 0 })
            submit_latest_prompt("Explain this")
            local response_window = vim.api.nvim_get_current_win()
            if command == "forced buffer switch" then
                vim.cmd("noautocmd buffer! " .. vim.api.nvim_win_get_buf(source_window))
            else
                vim.cmd(command)
            end
            local update_ok = pcall(callbacks.on_update, "Late update")
            local complete_ok = pcall(callbacks.on_complete, "Late answer", nil, "thread-1")
            local remaining_floats = vim.tbl_filter(function(window)
                return vim.api.nvim_win_get_config(window).relative ~= ""
            end, vim.api.nvim_list_wins())
            assert.same(request, cancelled_request)
            assert.is_true(update_ok)
            assert.is_true(complete_ok)
            assert.is_false(vim.api.nvim_win_is_valid(response_window))
            assert.same({}, remaining_floats)
        end)
    end

    it("cancels a pending response when its source window closes", function()
        local callbacks
        local request = {}
        local cancelled_request
        codex.ask = function(_, _, _, _, request_callbacks)
            callbacks = request_callbacks
            return request
        end
        codex.cancel = function(cancelled)
            cancelled_request = cancelled
        end
        local source_window = open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")
        local response_window = vim.api.nvim_get_current_win()
        local source_buffer = vim.api.nvim_win_get_buf(source_window)
        vim.api.nvim_open_win(source_buffer, false, { split = "right", win = source_window })
        vim.api.nvim_win_close(source_window, true)
        local update_ok = pcall(callbacks.on_update, "Late update")
        local complete_ok = pcall(callbacks.on_complete, "Late answer", nil, "thread-1")
        assert.same(request, cancelled_request)
        assert.is_true(update_ok)
        assert.is_true(complete_ok)
        assert.is_false(vim.api.nvim_win_is_valid(response_window))
    end)

    it("releases response buffers and window watchers when dismissed", function()
        local function window_watchers()
            return vim.tbl_filter(function(autocmd)
                return autocmd.desc == "Cancel SwiftPrompt when its response or source window closes"
            end, vim.api.nvim_get_autocmds({ event = "WinClosed" }))
        end
        local original_watchers = window_watchers()
        open_long_response()
        local response_buffer = vim.api.nvim_get_current_buf()
        vim.cmd("normal q")
        assert.is_false(vim.api.nvim_buf_is_valid(response_buffer))
        assert.same(original_watchers, window_watchers())
    end)

    it("keeps all lines from a linewise Visual selection", function()
        open_selection({ "  local one = 1", "", "  return one" }, { 1, 3 }, { 3, 0 }, "V")
        submit_latest_prompt("Explain this")

        assert.same("  local one = 1\n\n  return one", codex_requests[1].selected_code)
    end)

    it("rejects an empty Visual selection", function()
        open_selection({ "" }, { 1, 1 }, { 1, 0 })

        assert.same({}, opened_window_configs)
        assert.same({}, codex_requests)
        assert.same({
            {
                message = "SwiftPrompt: select non-empty code first, then press <leader>aa",
                level = vim.log.levels.INFO,
            },
        }, notifications)
    end)

    it("rejects a whitespace-only Visual selection", function()
        open_selection({ "   ", "\t" }, { 1, 1 }, { 2, 0 }, "V")

        assert.same({}, opened_window_configs)
        assert.same({}, codex_requests)
        assert.same(1, #notifications)
    end)

    it("honors exclusive characterwise selections in either direction", function()
        vim.o.selection = "exclusive"

        open_selection({ "abcd" }, { 1, 1 }, { 1, 2 })
        submit_latest_prompt("Explain this")
        assert.same("ab", codex_requests[1].selected_code)
        vim.cmd("normal q")

        open_selection({ "abcd" }, { 1, 3 }, { 1, 0 })
        submit_latest_prompt("Explain this")
        assert.same("ab", codex_requests[2].selected_code)
    end)

    it("extracts a rectangle for a blockwise Visual selection", function()
        open_selection({ "abcDEF", "ghiJKL", "mnopqr" }, { 1, 3 }, { 3, 3 }, "\22")
        submit_latest_prompt("Explain this")

        assert.same("cD\niJ\nop", codex_requests[1].selected_code)
    end)

    it("keeps blockwise columns ordered when the selection is dragged left", function()
        open_selection({ "abcDEF", "ghiJKL", "mnopqr" }, { 1, 5 }, { 3, 1 }, "\22")
        submit_latest_prompt("Explain this")

        assert.same("bcDE\nhiJK\nnopq", codex_requests[1].selected_code)
    end)

    it("uses displayed columns for blockwise selections with short, tab, and wide-character lines", function()
        open_selection({ "a界cd", "a\tcd", "x", "abcdef" }, { 1, 2 }, { 4, 4 }, "\22")
        submit_latest_prompt("Explain this")

        assert.same("界cd\n    \n\nbcde", codex_requests[1].selected_code)
    end)
end)
