local swiftyprompt = require("swiftyprompt")
local codex = require("swiftyprompt.connectors.codex")
local claude = require("swiftyprompt.connectors.claude")
local config = require("swiftyprompt.config")
local interaction = require("tests.support.interaction")

describe("SwiftPrompt conversation behavior", function()
    local editor = interaction.setup()

    it("reuses a thread after closing and reopening the same selection", function()
        local source_window = editor.open_selection({ "one", "two", "three" }, { 1, 1 }, { 3, 2 })
        editor.submit_latest_prompt("Explain this")
        vim.cmd("normal q")

        vim.api.nvim_win_set_cursor(source_window, { 3, 2 })
        swiftyprompt.ask_about_visual_selection()
        editor.submit_latest_prompt("What should I change?")

        assert.same("thread-1", editor.codex_requests[2].thread_id)
    end)

    it("streams response text into the response window", function()
        local callbacks
        codex.ask = function(_, _, _, _, request_callbacks)
            callbacks = request_callbacks
            return {}
        end

        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")
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

        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")

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

    for _, provider in ipairs({ "codex", "claude" }) do
        it("displays " .. provider .. " errors and allows retrying", function()
            config.setup({ connector = provider })
            local connector = provider == "codex" and codex or claude
            local attempts = 0
            local pending_callbacks
            connector.ask = function(_, _, _, _, callbacks)
                attempts = attempts + 1
                if attempts == 1 then
                    pending_callbacks = callbacks
                else
                    callbacks.on_complete("Recovered answer", nil, "recovered-session")
                end
                return {}
            end
            editor.open_selection({ "one" }, { 1, 1 }, { 1, 2 })
            editor.submit_latest_prompt("Explain this")
            local response_buffer = vim.api.nvim_get_current_buf()
            local first_status = vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false)[1]
            assert.is_true(vim.wait(300, function()
                return vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false)[1] ~= first_status
            end, 20))
            pending_callbacks.on_complete(nil, "Provider unavailable")
            assert.same({ "Provider unavailable" }, vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false))
            vim.wait(150)
            assert.same({ "Provider unavailable" }, vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false))
            vim.api.nvim_feedkeys("f", "mtx", false)
            editor.submit_latest_prompt("Retry")
            assert.same({ "Recovered answer" }, vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false))
            assert.same(2, attempts)
        end)
    end

    it("shows an unknown connector error without making a request", function()
        config.setup({ connector = "unsupported" })
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 2 })
        editor.submit_latest_prompt("Explain this")
        assert.same({ "Unknown connector: unsupported" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
        assert.same({}, editor.codex_requests)
    end)

    it("keeps follow-up input closed while a request is pending", function()
        local callbacks
        codex.ask = function(_, _, _, _, request_callbacks)
            callbacks = request_callbacks
            return {}
        end
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 2 })
        editor.submit_latest_prompt("Explain this")
        local response_window = vim.api.nvim_get_current_win()
        local window_count = #vim.api.nvim_list_wins()
        vim.api.nvim_feedkeys("f", "mtx", false)
        assert.same(response_window, vim.api.nvim_get_current_win())
        assert.same(window_count, #vim.api.nvim_list_wins())
        callbacks.on_complete("Done", nil, "thread-1")
    end)

    it("uses Claude status, model labels, streaming, and cancellation", function()
        swiftyprompt.setup({ connector = "claude", connectors = { claude = { model = "haiku" } } })
        local callbacks
        local request = {}
        local cancelled
        claude.ask = function(options, question, selected_code, thread_id, request_callbacks)
            assert.same("haiku", options.model)
            assert.same("Explain this", question)
            assert.same("one", selected_code)
            assert.is_nil(thread_id)
            callbacks = request_callbacks
            return request
        end
        claude.cancel = function(value)
            cancelled = value
        end
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 2 })
        editor.submit_latest_prompt("Explain this")
        local response_buffer = vim.api.nvim_get_current_buf()
        assert.same({ "◜  Claude is thinking" }, vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false))
        local frame_buffer = vim.api.nvim_win_get_buf(vim.api.nvim_win_get_config(0).win)
        local marks = vim.api.nvim_buf_get_extmarks(frame_buffer,
            vim.api.nvim_create_namespace("swiftyprompt.ui"), 0, -1, { details = true })
        local footer = marks[#marks][4].virt_text
        assert.same("haiku", footer[#footer][1])
        callbacks.on_update("Claude answer")
        assert.same({ "Claude answer" }, vim.api.nvim_buf_get_lines(response_buffer, 0, -1, false))
        vim.fn.maparg("<Esc>", "n", false, true).callback()
        assert.same(request, cancelled)
        assert.is_true(pcall(callbacks.on_complete, "Late answer", nil, "claude-session"))
        assert.same({}, editor.codex_requests)
    end)

    it("keeps follow-ups on the provider and model that started the conversation", function()
        swiftyprompt.setup({ connector = "claude", connectors = { claude = { model = "haiku" } } })
        local sessions = {}
        claude.ask = function(options, _, _, thread_id, callbacks)
            assert.same("haiku", options.model)
            table.insert(sessions, thread_id or "new")
            callbacks.on_complete("Answer", nil, "claude-session")
            return {}
        end
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 2 })
        editor.submit_latest_prompt("First")
        swiftyprompt.setup({ connector = "codex" })
        vim.api.nvim_feedkeys("f", "mtx", false)
        editor.submit_latest_prompt("Follow-up")
        assert.same({ "new", "claude-session" }, sessions)
        assert.same({}, editor.codex_requests)
    end)

    for _, setting in ipairs({ "executable", "project" }) do
        it("isolates reopened sessions by " .. setting, function()
            local original_getcwd = vim.fn.getcwd
            local source_window = editor.open_selection({ "one" }, { 1, 1 }, { 1, 2 })
            editor.submit_latest_prompt("First")
            vim.cmd("normal q")

            if setting == "executable" then
                config.setup({ connectors = { codex = { command = "another-codex" } } })
            else
                vim.fn.getcwd = function()
                    return "/another-project"
                end
            end

            local function reopen()
                vim.api.nvim_set_current_win(source_window)
                vim.api.nvim_win_set_cursor(source_window, { 1, 2 })
                swiftyprompt.ask_about_visual_selection()
                editor.submit_latest_prompt("Another question")
                vim.cmd("normal q")
            end
            reopen()
            config.setup({})
            vim.fn.getcwd = original_getcwd
            reopen()

            assert.is_nil(editor.codex_requests[1].thread_id)
            assert.is_nil(editor.codex_requests[2].thread_id)
            assert.same("thread-1", editor.codex_requests[3].thread_id)
        end)
    end

    it("isolates reopened sessions by provider and model", function()
        local sessions = {}
        claude.ask = function(options, _, _, thread_id, callbacks)
            table.insert(sessions, { model = options.model, session = thread_id or "new" })
            callbacks.on_complete("Answer", nil, "claude-" .. options.model)
            return {}
        end
        local source_window = editor.open_selection({ "one" }, { 1, 1 }, { 1, 2 })
        editor.submit_latest_prompt("Codex question")
        vim.cmd("normal q")

        local function reopen(connector, model)
            swiftyprompt.setup({ connector = connector, connectors = { claude = { model = model } } })
            vim.api.nvim_set_current_win(source_window)
            vim.api.nvim_win_set_cursor(source_window, { 1, 2 })
            swiftyprompt.ask_about_visual_selection()
            editor.submit_latest_prompt("Another question")
            vim.cmd("normal q")
        end
        reopen("claude", "haiku")
        reopen("claude", "sonnet")
        reopen("claude", "haiku")
        reopen("codex", "haiku")
        assert.same({
            { model = "haiku", session = "new" },
            { model = "sonnet", session = "new" },
            { model = "haiku", session = "claude-haiku" },
        }, sessions)
        assert.same("thread-1", editor.codex_requests[2].thread_id)
    end)
end)
