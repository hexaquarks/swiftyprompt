local codex = require("swiftyprompt.connectors.codex")
local interaction = require("tests.support.interaction")

describe("SwiftPrompt navigation behavior", function()
    local editor = interaction.setup()

    it("blocks global Control-O mappings inside the question prompt", function()
        local global_mapping_count = 0
        vim.keymap.set("i", "<C-o>", function()
            global_mapping_count = global_mapping_count + 1
        end)
        vim.fn.prompt_setcallback = editor.original_prompt_setcallback

        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })

        local prompt_buffer = vim.api.nvim_get_current_buf()
        for _, mode in ipairs({ "n", "i" }) do
            local control_o_mapping = vim.fn.maparg("<C-o>", mode, false, true)
            assert.same(1, control_o_mapping.buffer)
            assert.same("<Nop>", control_o_mapping.rhs)
        end

        vim.api.nvim_feedkeys(vim.keycode("<C-o>"), "mtx", false)
        assert.same(0, global_mapping_count)
        assert.same(prompt_buffer, vim.api.nvim_get_current_buf())
        vim.api.nvim_feedkeys(vim.keycode("i<C-o>Explain this<CR>"), "mtx", false)
        assert.same(0, global_mapping_count)
        assert.same("Explain this", editor.codex_requests[1].question)
    end)

    it("preserves Enter to submit from the question prompt", function()
        local global_mapping_count = 0
        vim.keymap.set("i", "<CR>", function()
            global_mapping_count = global_mapping_count + 1
        end)
        vim.fn.prompt_setcallback = editor.original_prompt_setcallback

        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })

        local enter_mapping = vim.fn.maparg("<CR>", "i", false, true)
        assert.same(1, enter_mapping.buffer)
        assert.same("<CR>", enter_mapping.rhs)

        vim.api.nvim_feedkeys(vim.keycode("iExplain this<CR>"), "mtx", false)
        assert.same(0, global_mapping_count)
        assert.same("Explain this", editor.codex_requests[1].question)
    end)

    it("preserves Backspace while editing a question prompt", function()
        local global_mapping_count = 0
        vim.keymap.set("i", "<BS>", function()
            global_mapping_count = global_mapping_count + 1
        end)
        vim.fn.prompt_setcallback = editor.original_prompt_setcallback

        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })

        local backspace_mapping = vim.fn.maparg("<BS>", "i", false, true)
        assert.same(1, backspace_mapping.buffer)
        assert.same("<BS>", backspace_mapping.rhs)

        vim.api.nvim_feedkeys(vim.keycode("iHellx<BS>o<CR>"), "mtx", false)
        assert.same(0, global_mapping_count)
        assert.same("Hello", editor.codex_requests[1].question)
    end)

    it("closes a question prompt with Escape from Insert mode", function()
        local global_mapping_count = 0
        vim.keymap.set("i", "<Esc>", function()
            global_mapping_count = global_mapping_count + 1
        end)

        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        local prompt_window = vim.api.nvim_get_current_win()

        vim.api.nvim_feedkeys(vim.keycode("i<Esc>"), "mtx", false)
        assert.same(0, global_mapping_count)
        assert.is_false(vim.api.nvim_win_is_valid(prompt_window))
    end)

    it("scrolls responses with native Control-D and Control-U", function()
        editor.open_long_response()
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
        editor.open_long_response()
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
        editor.open_long_response()
        vim.api.nvim_feedkeys(vim.keycode("<F8>"), "mtx", false)
        assert.same(34, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("executes Lua navigation callbacks in the response buffer", function()
        vim.keymap.set("n", "<F9>", function()
            local cursor = vim.api.nvim_win_get_cursor(0)
            vim.api.nvim_win_set_cursor(0, { cursor[1] + 5, cursor[2] })
        end)
        editor.open_long_response()
        vim.api.nvim_feedkeys(vim.keycode("<F9>"), "mtx", false)
        assert.same(35, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("honors expression navigation mappings", function()
        vim.keymap.set("n", "<F8>", function()
            return "5j"
        end, { expr = true })
        editor.open_long_response()
        vim.api.nvim_feedkeys(vim.keycode("<F8>"), "mtx", false)
        assert.same(35, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("uses navigation mappings added or changed after opening a response", function()
        vim.keymap.set("n", "<F8>", "2j")
        editor.open_long_response()
        vim.keymap.set("n", "<F8>", "5j")
        vim.keymap.set("n", "<F9>", "3k")
        vim.api.nvim_feedkeys(vim.keycode("<F8><F9>"), "mtx", false)
        assert.same(32, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("preserves user motions instead of replacing them with wrapped defaults", function()
        vim.keymap.set("n", "j", "2j")
        editor.open_long_response()
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
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")
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
        editor.codex_response = string.rep("x", 121)
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")
        vim.api.nvim_feedkeys("j", "mtx", false)
        local cursor = vim.api.nvim_win_get_cursor(0)
        assert.same(1, cursor[1])
        assert.is_true(cursor[2] >= vim.api.nvim_win_get_width(0))
        vim.api.nvim_feedkeys("k", "mtx", false)
        assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
        assert.is_false(pcall(vim.cmd, "normal! x"))
        assert.same({ editor.codex_response }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
        assert.is_false(vim.bo.modifiable)
        assert.is_true(vim.bo.readonly)
    end)

    it("blocks native Control-O jumps out of the response", function()
        pcall(vim.keymap.del, "n", "<C-o>")
        editor.open_long_response()
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
        editor.open_long_response()
        local response_buffer = vim.api.nvim_get_current_buf()
        vim.api.nvim_feedkeys(vim.keycode("<C-o>"), "mtx", false)
        assert.is_false(mapping_called)
        assert.same(response_buffer, vim.api.nvim_get_current_buf())
        assert.same({ 30, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    for _, command in ipairs({ "buffer", "alternate buffer", "global mark" }) do
        it("protects the response window from " .. command .. " switches", function()
            local source_window = editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
            local source_buffer = vim.api.nvim_win_get_buf(source_window)
            editor.submit_latest_prompt("Explain this")
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

end)
