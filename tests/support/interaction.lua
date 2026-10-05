local swiftyprompt = require("swiftyprompt")
local codex = require("swiftyprompt.connectors.codex")
local claude = require("swiftyprompt.connectors.claude")
local config = require("swiftyprompt.config")

local M = {}

-- Keep real Neovim windows and input; replace only provider calls and selection/LSP input.
function M.setup()
    local editor = {}
    local originals
    local mappings
    local initial_windows
    local initial_buffers
    local initial_window
    local initial_buffer

    before_each(function()
        initial_window = vim.api.nvim_get_current_win()
        initial_buffer = vim.api.nvim_get_current_buf()
        initial_windows = vim.api.nvim_list_wins()
        initial_buffers = vim.api.nvim_list_bufs()
        originals = {
            codex_ask = codex.ask,
            codex_cancel = codex.cancel,
            claude_ask = claude.ask,
            claude_cancel = claude.cancel,
            open_win = vim.api.nvim_open_win,
            prompt_setcallback = vim.fn.prompt_setcallback,
            buf_request_sync = vim.lsp.buf_request_sync,
            mode = vim.fn.mode,
            getpos = vim.fn.getpos,
            getcwd = vim.fn.getcwd,
            notify = vim.notify,
            setreg = vim.fn.setreg,
            selection = vim.o.selection,
            lines = vim.o.lines,
        }
        mappings = {}
        for mode, keys in pairs({
            n = {
                "<C-o>", "<C-d>", "<C-u>", "<F8>", "<F9>", "j", "<Plug>(SwiftPromptTestDown)",
                "<leader>aa", "<leader>af", "<leader>as",
            },
            i = { "<C-o>", "<CR>", "<S-CR>", "<BS>", "<Esc>" },
            x = { "<leader>aa" },
        }) do
            mappings[mode] = {}
            for _, key in ipairs(keys) do
                mappings[mode][key] = vim.fn.maparg(key, mode, false, true)
                pcall(vim.keymap.del, mode, key)
            end
        end
        editor.opened_window_configs = {}
        editor.question_prompt_callbacks = {}
        editor.codex_requests = {}
        editor.notifications = {}
        editor.codex_response = "first line\nsecond line\nthird line"
        editor.original_prompt_setcallback = originals.prompt_setcallback

        config.setup({})
        vim.api.nvim_open_win = function(buffer, enter, options)
            if options.border ~= "none" and options.relative and options.relative ~= "" then
                table.insert(editor.opened_window_configs, vim.deepcopy(options))
            end
            return originals.open_win(buffer, enter, options)
        end
        vim.fn.prompt_setcallback = function(buffer, callback)
            editor.question_prompt_callbacks[buffer] = callback
        end
        vim.fn.mode = function()
            return "v"
        end
        vim.notify = function(message, level)
            table.insert(editor.notifications, { message = message, level = level })
        end
        codex.ask = function(_, question, selected_code, thread_id, callbacks)
            table.insert(editor.codex_requests, {
                question = question,
                selected_code = selected_code,
                thread_id = thread_id,
            })
            callbacks.on_complete(editor.codex_response, nil, "thread-1")
            return {}
        end
    end)

    after_each(function()
        -- Dismiss cards while provider mocks are still installed, then release test sources.
        local restore_window = initial_window
        if not vim.api.nvim_win_is_valid(restore_window) then
            for _, window in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_config(window).relative == "" then
                    restore_window = window
                    break
                end
            end
        end
        for _, window in ipairs(vim.api.nvim_list_wins()) do
            if window ~= restore_window and not vim.tbl_contains(initial_windows, window)
                and vim.api.nvim_win_is_valid(window)
            then
                vim.api.nvim_win_close(window, true)
            end
        end
        if vim.api.nvim_win_is_valid(restore_window) then
            vim.api.nvim_set_current_win(restore_window)
            vim.api.nvim_win_set_buf(restore_window, initial_buffer)
        end
        for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
            if not vim.tbl_contains(initial_buffers, buffer) and vim.api.nvim_buf_is_valid(buffer) then
                vim.api.nvim_buf_delete(buffer, { force = true })
            end
        end

        codex.ask = originals.codex_ask
        codex.cancel = originals.codex_cancel
        claude.ask = originals.claude_ask
        claude.cancel = originals.claude_cancel
        vim.api.nvim_open_win = originals.open_win
        vim.fn.prompt_setcallback = originals.prompt_setcallback
        vim.lsp.buf_request_sync = originals.buf_request_sync
        vim.fn.mode = originals.mode
        vim.fn.getpos = originals.getpos
        vim.fn.getcwd = originals.getcwd
        vim.notify = originals.notify
        vim.fn.setreg = originals.setreg
        vim.o.selection = originals.selection
        vim.o.lines = originals.lines
        config.setup({})
        for mode, keys in pairs(mappings) do
            for key, mapping in pairs(keys) do
                pcall(vim.keymap.del, mode, key)
                if next(mapping) then
                    vim.fn.mapset(mode, false, mapping)
                end
            end
        end
    end)

    function editor.set_source(lines, filename)
        local source_window = vim.api.nvim_get_current_win()
        local source_buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(source_window, source_buffer)
        vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, lines)
        if filename then
            vim.api.nvim_buf_set_name(source_buffer, filename)
        end
        return source_window, source_buffer
    end

    function editor.open_selection(lines, start_position, cursor_position, mode, filename)
        local source_window = editor.set_source(lines, filename)
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

    function editor.submit_latest_prompt(question)
        local prompt_buffer = vim.api.nvim_get_current_buf()
        local callback = editor.question_prompt_callbacks[prompt_buffer]
        assert.is_function(callback, "The current buffer is not a question prompt")
        callback(question)
    end

    function editor.open_long_response()
        local lines = {}
        for line = 1, 80 do
            lines[line] = "Response line " .. line
        end
        editor.codex_response = table.concat(lines, "\n")
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")
        vim.wo.scroll = 4
        vim.api.nvim_win_set_cursor(0, { 30, 0 })
        vim.cmd("normal! zz")
    end

    return editor
end

return M
