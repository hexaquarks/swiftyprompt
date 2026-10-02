local swiftyprompt = require("swiftyprompt")
local codex = require("swiftyprompt.connectors.codex")

describe("SwiftPrompt interaction UI", function()
    local original_ask
    local original_open_win
    local original_prompt_setcallback
    local original_mode
    local original_getpos
    local opened_window_configs
    local question_prompt_callbacks
    local codex_requests
    local codex_response

    before_each(function()
        opened_window_configs = {}
        question_prompt_callbacks = {}
        codex_requests = {}
        codex_response = "first line\nsecond line\nthird line"
        original_ask = codex.ask
        original_open_win = vim.api.nvim_open_win
        original_prompt_setcallback = vim.fn.prompt_setcallback
        original_mode = vim.fn.mode
        original_getpos = vim.fn.getpos

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
        codex.ask = function(_, question, selected_code, thread_id, on_complete)
            table.insert(codex_requests, {
                question = question,
                selected_code = selected_code,
                thread_id = thread_id,
            })
            on_complete(codex_response, nil, "thread-1")
        end
    end)

    after_each(function()
        codex.ask = original_ask
        vim.api.nvim_open_win = original_open_win
        vim.fn.prompt_setcallback = original_prompt_setcallback
        vim.fn.mode = original_mode
        vim.fn.getpos = original_getpos

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
            title = " Ask Codex — Enter to send ",
        }, opened_window_configs[1])

        submit_latest_prompt("Explain this")
        assert.same(table.concat({ "DEF", "ghiJKL", "mnop" }, "\n"), codex_requests[1].selected_code)
        assert.same("Explain this", codex_requests[1].question)
        assert.same(" Codex — f: follow up · q/Esc: close ", opened_window_configs[2].title)
        assert.same(" gpt-6-luna ", opened_window_configs[2].footer)
        assert.same("right", opened_window_configs[2].footer_pos)
    end)

    it("places the follow-up input directly below the visible response", function()
        open_selection({ "one", "two", "three" }, { 1, 1 }, { 3, 2 })
        submit_latest_prompt("Explain this")

        -- The response window is current after it opens, so its buffer-local
        -- mapping provides the same path a user takes by pressing f.
        vim.cmd("normal f")

        assert.same("Follow-up — Enter to send", opened_window_configs[3].title:match("Follow%-up — Enter to send"))
        assert.same(6, opened_window_configs[3].row) -- three response lines + its border gap
        assert.same(3, opened_window_configs[3].height)
    end)

    it("reuses a thread after closing and reopening the same selection", function()
        open_selection({ "one", "two", "three" }, { 1, 1 }, { 3, 2 })
        submit_latest_prompt("Explain this")
        vim.cmd("normal q")

        open_selection({ "one", "two", "three" }, { 1, 1 }, { 3, 2 })
        submit_latest_prompt("What should I change?")

        assert.same("thread-1", codex_requests[2].thread_id)
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

    it("keeps all lines from a linewise Visual selection", function()
        open_selection({ "  local one = 1", "", "  return one" }, { 1, 3 }, { 3, 0 }, "V")
        submit_latest_prompt("Explain this")

        assert.same("  local one = 1\n\n  return one", codex_requests[1].selected_code)
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
end)
