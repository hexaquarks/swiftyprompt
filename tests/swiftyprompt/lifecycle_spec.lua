local codex = require("swiftyprompt.connectors.codex")
local interaction = require("tests.support.interaction")

describe("SwiftPrompt lifecycle behavior", function()
    local editor = interaction.setup()

    it("cancels an in-progress request when Escape closes the response window", function()
        local request = {}
        local cancelled_request
        codex.ask = function()
            return request
        end
        codex.cancel = function(request_to_cancel)
            cancelled_request = request_to_cancel
        end

        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")

        local response_window = vim.api.nvim_get_current_win()
        local escape = vim.fn.maparg("<Esc>", "n", false, true)
        escape.callback()

        assert.same(request, cancelled_request)
        assert.is_false(vim.api.nvim_win_is_valid(response_window))
    end)

    it("closes both parts of a prompt when its frame is dismissed", function()
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        local body_window = vim.api.nvim_get_current_win()
        local frame_window = vim.api.nvim_win_get_config(body_window).win
        local body_buffer = vim.api.nvim_get_current_buf()
        local frame_buffer = vim.api.nvim_win_get_buf(frame_window)
        vim.api.nvim_win_close(frame_window, true)
        assert.is_false(vim.api.nvim_win_is_valid(body_window))
        assert.is_false(vim.api.nvim_win_is_valid(frame_window))
        assert.is_false(vim.api.nvim_buf_is_valid(body_buffer))
        assert.is_false(vim.api.nvim_buf_is_valid(frame_buffer))
        assert.same({}, editor.codex_requests)
    end)

    it("dismisses an unsubmitted prompt when its source window closes", function()
        local source_window = editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
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
        assert.same({}, editor.codex_requests)
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
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")
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

    it("closes prompt and response dialogs with Escape in Normal mode", function()
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        local prompt_window = vim.api.nvim_get_current_win()
        local prompt_buffer = vim.api.nvim_win_get_buf(prompt_window)
        local escape = vim.fn.maparg("<Esc>", "n", false, true)
        assert.is_function(escape.callback)
        escape.callback()
        assert.is_false(vim.api.nvim_win_is_valid(prompt_window))
        assert.is_false(vim.api.nvim_buf_is_valid(prompt_buffer))

        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")
        local response_window = vim.api.nvim_get_current_win()
        escape = vim.fn.maparg("<Esc>", "n", false, true)
        assert.is_function(escape.callback)
        escape.callback()
        assert.is_false(vim.api.nvim_win_is_valid(response_window))
    end)

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
        local source_window = editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")
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
        editor.open_long_response()
        local response_buffer = vim.api.nvim_get_current_buf()
        vim.cmd("normal q")
        assert.is_false(vim.api.nvim_buf_is_valid(response_buffer))
        assert.same(original_watchers, window_watchers())
    end)
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
            local source_window = editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
            editor.submit_latest_prompt("Explain this")
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
end)
