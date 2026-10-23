local swiftyprompt = require("swiftyprompt")
local codex = require("swiftyprompt.connectors.codex")
local interaction = require("tests.support.interaction")

describe("Reopening a response", function()
    local editor = interaction.setup()

    local function complete_response()
        editor.open_selection({ "original code" }, { 1, 1 }, { 1, 12 })
        editor.submit_latest_prompt("Explain this")
    end

    local function close_response()
        vim.fn.maparg("q", "n", false, true).callback()
    end

    it("explains when no completed answer is available", function()
        swiftyprompt.reopen_last_response()

        assert.same("SwiftPrompt: no completed response to reopen", editor.notifications[1].message)
        assert.same(0, #editor.opened_window_configs)
    end)

    it("reopens repeatedly with the default mapping without making another request", function()
        swiftyprompt.setup()
        complete_response()
        local original_buffer = vim.api.nvim_get_current_buf()

        for _ = 1, 2 do
            close_response()
            vim.fn.maparg("<leader>ar", "n", false, true).callback()

            assert.same({ "first line", "second line", "third line" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
            assert.is_true(vim.bo.readonly)
            assert.same(1, #editor.codex_requests)
        end

        assert.is_false(vim.api.nvim_buf_is_valid(original_buffer))
    end)

    it("focuses the existing response without opening duplicate windows", function()
        complete_response()
        local response_window = vim.api.nvim_get_current_win()
        local window_count = #vim.api.nvim_list_wins()

        swiftyprompt.reopen_last_response()

        assert.same(response_window, vim.api.nvim_get_current_win())
        assert.same(window_count, #vim.api.nvim_list_wins())
        assert.same(1, #editor.codex_requests)
    end)

    it("preserves the original context and session for follow-ups", function()
        complete_response()
        close_response()
        editor.set_source({ "unrelated code" })
        swiftyprompt.reopen_last_response()

        vim.fn.maparg("f", "n", false, true).callback()
        editor.codex_response = "Follow-up answer"
        editor.submit_latest_prompt("Tell me more")

        assert.same("original code", editor.codex_requests[2].selected_code)
        assert.same("thread-1", editor.codex_requests[2].thread_id)
        assert.same("Tell me more", editor.codex_requests[2].question)

        close_response()
        swiftyprompt.reopen_last_response()
        assert.same({ "Follow-up answer" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    end)

    it("reopens even after the original source buffer is deleted", function()
        complete_response()
        close_response()
        local source_buffer = vim.api.nvim_get_current_buf()
        editor.set_source({ "another file" })
        vim.api.nvim_buf_delete(source_buffer, { force = true })

        swiftyprompt.reopen_last_response()

        assert.same("first line", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
        assert.same(1, #editor.codex_requests)
    end)

    it("keeps the completed answer when a later request is cancelled", function()
        complete_response()
        close_response()
        local callbacks
        codex.ask = function(_, _, _, _, request_callbacks)
            callbacks = request_callbacks
            return {}
        end
        codex.cancel = function() end

        editor.open_selection({ "new code" }, { 1, 1 }, { 1, 7 })
        editor.submit_latest_prompt("Another question")
        callbacks.on_update("Partial answer")
        close_response()
        callbacks.on_complete("Late answer", nil, "late-thread")
        swiftyprompt.reopen_last_response()

        assert.same("first line", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    end)

    it("keeps the completed answer when a later request fails", function()
        complete_response()
        vim.fn.maparg("f", "n", false, true).callback()
        codex.ask = function(_, _, _, _, callbacks)
            callbacks.on_complete(nil, "Request failed", nil)
            return {}
        end
        editor.submit_latest_prompt("Another question")
        close_response()

        swiftyprompt.reopen_last_response()

        assert.same("first line", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    end)
end)
