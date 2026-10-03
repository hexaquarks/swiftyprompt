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
        original_normal_control_o = vim.fn.maparg("<C-o>", "n", false, true)
        original_insert_control_o = vim.fn.maparg("<C-o>", "i", false, true)
        original_normal_f9 = vim.fn.maparg("<F9>", "n", false, true)
        notifications = {}

        vim.api.nvim_open_win = function(buffer_id, enter_window, window_config)
            table.insert(opened_window_configs, vim.deepcopy(window_config))
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
        pcall(vim.keymap.del, "n", "<C-o>")
        pcall(vim.keymap.del, "i", "<C-o>")
        pcall(vim.keymap.del, "n", "<F9>")
        if next(original_normal_control_o) then
            vim.fn.mapset("n", false, original_normal_control_o)
        end
        if next(original_insert_control_o) then
            vim.fn.mapset("i", false, original_insert_control_o)
        end
        if next(original_normal_f9) then
            vim.fn.mapset("n", false, original_normal_f9)
        end

        for _, window in ipairs(vim.api.nvim_list_wins()) do
            local config = vim.api.nvim_win_get_config(window)
            if config.relative ~= "" and vim.api.nvim_win_is_valid(window) then
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
        local prompt_buffer, submit_callback = next(question_prompt_callbacks)
        assert.is_not_nil(prompt_buffer)
        submit_callback(question)
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
            height = 3,
            row = 1,
            col = 0,
            style = "minimal",
            border = "rounded",
            title = " Ask Codex about selected code ",
            footer = " Enter to send ",
            footer_pos = "right",
        }, opened_window_configs[1])

        submit_latest_prompt("Explain this")
        assert.same(table.concat({ "DEF", "ghiJKL", "mnop" }, "\n"), codex_requests[1].selected_code)
        assert.same("Explain this", codex_requests[1].question)
        assert.same(" Codex — f: follow up · q/Esc: close or stop ", opened_window_configs[2].title)
        assert.same(" gpt-6-luna ", opened_window_configs[2].footer)
        assert.same("right", opened_window_configs[2].footer_pos)
    end)

    it("places the follow-up input directly below the visible response", function()
        open_selection({ "one", "two", "three" }, { 1, 1 }, { 3, 2 })
        submit_latest_prompt("Explain this")

        -- The response window is current after it opens, so its buffer-local
        -- mapping provides the same path a user takes by pressing f.
        vim.cmd("normal f")

        assert.same(" Ask Codex about selected code ", opened_window_configs[3].title)
        assert.same(6, opened_window_configs[3].row) -- three response lines + its border gap
        assert.same(3, opened_window_configs[3].height)
    end)

    it("labels file prompts and responses with their context", function()
        local source_window = vim.api.nvim_get_current_win()
        local source_buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(source_window, source_buffer)
        vim.api.nvim_buf_set_name(source_buffer, "/tmp/settings.lua")
        vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { "local value = 1" })

        swiftyprompt.ask_about_current_file()
        assert.same({
            { " Ask Codex about ", "FloatTitle" },
            { "settings.lua", "SwiftypromptFile" },
            { " ", "FloatTitle" },
        }, opened_window_configs[1].title)

        submit_latest_prompt("Explain this")
        assert.same(" Codex — f: follow up · q/Esc: close or stop ", opened_window_configs[2].title)
    end)

    it("labels unnamed file prompts as the current buffer", function()
        local source_window = vim.api.nvim_get_current_win()
        local source_buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(source_window, source_buffer)
        vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { "local value = 1" })

        swiftyprompt.ask_about_current_file()

        assert.same({
            { " Ask Codex about ", "FloatTitle" },
            { "this buffer", "SwiftypromptFile" },
            { " ", "FloatTitle" },
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
            { " Ask Codex about ", "FloatTitle" },
            { "greet", "SwiftypromptSymbol" },
            { " ", "FloatTitle" },
        }, opened_window_configs[1].title)

        submit_latest_prompt("Explain this")
        assert.same(" Codex — f: follow up · q/Esc: close or stop ", opened_window_configs[2].title)
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
        local title_text = title[1][1] .. title[2][1] .. title[3][1]
        assert.matches("Ask Codex about very_long_symbol_name", title_text)
        assert.matches("…", title[2][1])
        assert.same("SwiftypromptSymbol", title[2][2])
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
            { " Ask Codex about ", "FloatTitle" },
            { "M.setup", "SwiftypromptSymbol" },
            { " ", "FloatTitle" },
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
            { " Ask Codex about ", "FloatTitle" },
            { "this symbol", "SwiftypromptSymbol" },
            { " ", "FloatTitle" },
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
        assert.same(60, response_config.width)
        assert.same(2, response_config.height)
        assert.is_true(vim.wo[response_window].wrap)
    end)

    it("renders responses in a read-only Markdown buffer", function()
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")

        local response_window = vim.api.nvim_get_current_win()
        local response_buffer = vim.api.nvim_win_get_buf(response_window)
        assert.equals("markdown", vim.bo[response_buffer].filetype)
        assert.is_false(vim.bo[response_buffer].modifiable)
        assert.is_true(vim.bo[response_buffer].readonly)
        assert.is_false(vim.bo[response_buffer].modified)
        assert.same(3, vim.wo[response_window].conceallevel)
        assert.same("nvic", vim.wo[response_window].concealcursor)
    end)

    it("conceals Markdown delimiters and navigates by wrapped rows", function()
        codex_response = "`Model` has **bold** and *italic* text."
        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")

        local response_window = vim.api.nvim_get_current_win()
        local response_buffer = vim.api.nvim_win_get_buf(response_window)
        local namespace = vim.api.nvim_create_namespace("swiftyprompt-response-markdown")
        local delimiter_marks = vim.api.nvim_buf_get_extmarks(response_buffer, namespace, 0, -1, { details = true })

        local delimiter_columns = {}
        for _, delimiter_mark in ipairs(delimiter_marks) do
            assert.same("", delimiter_mark[4].conceal)
            table.insert(delimiter_columns, delimiter_mark[3])
        end
        assert.same({ 0, 6, 12, 18, 25, 32 }, delimiter_columns)

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

    it("blocks global Control-O mappings inside the response dialog", function()
        local global_mapping_count = 0
        vim.keymap.set("n", "<C-o>", function()
            global_mapping_count = global_mapping_count + 1
        end)

        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")

        local control_o_mapping = vim.fn.maparg("<C-o>", "n", false, true)
        assert.same(1, control_o_mapping.buffer)
        assert.same("<Nop>", control_o_mapping.rhs)

        vim.api.nvim_feedkeys(vim.keycode("<C-o>"), "mtx", false)
        assert.same(0, global_mapping_count)
    end)

    it("blocks unrelated global mappings inside the response dialog", function()
        local global_mapping_count = 0
        vim.keymap.set("n", "<F9>", function()
            global_mapping_count = global_mapping_count + 1
        end)

        open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        submit_latest_prompt("Explain this")

        local f9_mapping = vim.fn.maparg("<F9>", "n", false, true)
        assert.same(1, f9_mapping.buffer)
        assert.same("<Nop>", f9_mapping.rhs)

        vim.api.nvim_feedkeys(vim.keycode("<F9>"), "mtx", false)
        assert.same(0, global_mapping_count)
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
