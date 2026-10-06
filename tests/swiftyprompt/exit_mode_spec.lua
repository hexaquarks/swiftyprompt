-- A separate editor exercises real Insert-mode input without the interaction helper's mode stub.
describe("SwiftPrompt exit mode", function()
    local channel
    local source_window
    local prompt_window

    local function request(method, ...)
        return vim.rpcrequest(channel, method, ...)
    end

    local function mode()
        return request("nvim_get_mode").mode
    end

    before_each(function()
        channel = vim.fn.jobstart({
            vim.v.progpath, "--embed", "--headless", "--noplugin", "-u", "tests/minimal_init.lua",
        }, { rpc = true })
        assert.is_true(channel > 0)
        source_window = request("nvim_get_current_win")
        request("nvim_exec_lua", [[
            vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 1" })
            require("swiftyprompt.connectors.codex").ask = function(_, _, _, _, callbacks)
                callbacks.on_complete("A short answer", nil, "test-thread")
                return {}
            end
            require("swiftyprompt").ask_about_current_file()
        ]], {})
        prompt_window = request("nvim_get_current_win")
        assert.is_true(vim.wait(1000, function() return mode() == "i" end, 10))
    end)

    after_each(function()
        if channel and channel > 0 then
            vim.fn.jobstop(channel)
        end
    end)

    it("returns to Normal mode after Escape cancels a prompt being edited", function()
        request("nvim_input", "Explain this<Esc>")
        assert.is_true(vim.wait(1000, function()
            return request("nvim_get_current_win") == source_window
        end, 10))
        assert.same("n", mode())
        assert.is_false(request("nvim_win_is_valid", prompt_window))
        assert.same({ "local value = 1" }, request("nvim_buf_get_lines", 0, 0, -1, false))
    end)
    it("returns to Normal mode after Escape closes a follow-up being edited", function()
        request("nvim_input", "Explain this<CR>")
        assert.is_true(vim.wait(1000, function()
            return mode() == "n" and not request("nvim_win_is_valid", prompt_window)
        end, 10))
        request("nvim_input", "f")
        assert.is_true(vim.wait(1000, function() return mode() == "i" end, 10))
        request("nvim_input", "More details<Esc>")
        assert.is_true(vim.wait(1000, function()
            return request("nvim_get_current_win") == source_window and mode() == "n"
        end, 10))
    end)

    it("leaves Insert mode when the input window is closed externally", function()
        request("nvim_win_close", prompt_window, true)
        assert.is_true(vim.wait(1000, function()
            return request("nvim_get_current_win") == source_window and mode() == "n"
        end, 10))
    end)
end)
