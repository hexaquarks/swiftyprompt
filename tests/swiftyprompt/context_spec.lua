local swiftyprompt = require("swiftyprompt")
local interaction = require("tests.support.interaction")

describe("SwiftPrompt context behavior", function()
    local editor = interaction.setup()

    it("anchors the question dialog at the middle of a multi-line selection", function()
        local source_window = editor.open_selection(
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
        }, editor.opened_window_configs[1])

        editor.submit_latest_prompt("Explain this")
        assert.same(table.concat({ "DEF", "ghiJKL", "mnop" }, "\n"), editor.codex_requests[1].selected_code)
        assert.same("Explain this", editor.codex_requests[1].question)
        assert.same(editor.opened_window_configs[1].title, editor.opened_window_configs[2].title)
    end)

    it("keeps selection context in named files through responses and follow-ups", function()
        editor.open_selection({ "one", "two" }, { 1, 1 }, { 2, 2 }, "V", "/tmp/selection-context.lua")
        assert.same("selected code", editor.opened_window_configs[1].title[3][1])
        editor.submit_latest_prompt("Explain this")
        assert.same("selected code", editor.opened_window_configs[2].title[3][1])
        vim.cmd("normal f")
        assert.same("selected code", editor.opened_window_configs[3].title[3][1])
        editor.submit_latest_prompt("Explain further")
        local response_frame = vim.api.nvim_win_get_config(0).win
        assert.same("selected code", vim.api.nvim_win_get_config(response_frame).title[3][1])
    end)

    it("places the follow-up input directly below the visible response", function()
        editor.open_selection({ "one", "two", "three" }, { 1, 1 }, { 3, 2 })
        editor.submit_latest_prompt("Explain this")

        -- The response window is current after it opens, so its buffer-local
        -- mapping provides the same path a user takes by pressing f.
        vim.cmd("normal f")

        assert.same(editor.opened_window_configs[2].title, editor.opened_window_configs[3].title)
        assert.same(10, editor.opened_window_configs[3].row) -- reply + pinned header + footer and borders
        assert.same(5, editor.opened_window_configs[3].height)
    end)

    it("labels file prompts and responses with their context", function()
        editor.set_source({ "local value = 1" }, "/tmp/settings.lua")

        swiftyprompt.ask_about_current_file()
        assert.same({
            { " SwiftyPrompt ", "SwiftyPromptAccent" },
            { "· ", "SwiftyPromptMuted" },
            { "settings.lua", "SwiftyPromptContext" },
            { " ", "SwiftyPromptNormal" },
        }, editor.opened_window_configs[1].title)

        editor.submit_latest_prompt("Explain this")
        assert.same(editor.opened_window_configs[1].title, editor.opened_window_configs[2].title)
        assert.same("local value = 1", editor.codex_requests[1].selected_code)
    end)

    it("labels unnamed file prompts as the current buffer", function()
        editor.set_source({ "local value = 1" })

        swiftyprompt.ask_about_current_file()

        assert.same({
            { " SwiftyPrompt ", "SwiftyPromptAccent" },
            { "· ", "SwiftyPromptMuted" },
            { "this buffer", "SwiftyPromptContext" },
            { " ", "SwiftyPromptNormal" },
        }, editor.opened_window_configs[1].title)
    end)

    it("labels symbol prompts and responses with their context", function()
        local source_window = editor.set_source({
            "local function greet()",
            "  return 'hello'",
            "end",
        }, "/tmp/symbol-context.lua")
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
        }, editor.opened_window_configs[1].title)

        editor.submit_latest_prompt("Explain this")
        assert.same(editor.opened_window_configs[1].title, editor.opened_window_configs[2].title)
    end)

    it("truncates long symbol names in prompt titles", function()
        editor.set_source({ "local value = 1" })
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

        local title = editor.opened_window_configs[1].title
        local title_text = title[1][1] .. title[2][1] .. title[3][1] .. title[4][1]
        assert.matches("SwiftyPrompt · very_long_symbol_name", title_text)
        assert.matches("%.%.%.", title[3][1])
        assert.same("SwiftyPromptContext", title[3][2])
        assert.is_true(vim.fn.strdisplaywidth(title_text) <= 60)
    end)

    it("uses a non-empty symbol detail when the LSP omits its name", function()
        editor.set_source({ "local value = 1" })
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
        }, editor.opened_window_configs[1].title)
    end)

    it("uses a generic label when the LSP returns no symbol text", function()
        editor.set_source({ "local value = 1" })
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
        }, editor.opened_window_configs[1].title)
    end)

    it("selects the innermost LSP symbol and sends only its code", function()
        local source_window = editor.set_source({
            "local module = {}",
            "local function inner()",
            "  return 1",
            "end",
            "return module",
        })
        vim.api.nvim_win_set_cursor(source_window, { 3, 0 })
        vim.lsp.buf_request_sync = function()
            return { { result = {
                { name = "elsewhere", range = {
                    start = { line = 10, character = 0 }, ["end"] = { line = 11, character = 0 },
                } },
                { name = "module", range = {
                    start = { line = 0, character = 0 }, ["end"] = { line = 4, character = 13 },
                }, children = {
                    { name = "inner", range = {
                        start = { line = 1, character = 0 }, ["end"] = { line = 3, character = 3 },
                    } },
                } },
            } } }
        end

        swiftyprompt.ask_about_current_symbol()
        assert.same("inner", editor.opened_window_configs[1].title[3][1])
        editor.submit_latest_prompt("Explain this")
        assert.same("local function inner()\n  return 1\nend", editor.codex_requests[1].selected_code)
    end)

    for _, case in ipairs({
        { name = "no clients respond", response = {} },
        { name = "the symbol list is empty", response = { { result = {} } } },
        { name = "the client returns an error", response = { { error = { message = "LSP unavailable" } } } },
    }) do
        it("warns without opening a symbol prompt when " .. case.name, function()
            vim.lsp.buf_request_sync = function()
                return case.response
            end
            local window_count = #vim.api.nvim_list_wins()
            swiftyprompt.ask_about_current_symbol()
            assert.same(window_count, #vim.api.nvim_list_wins())
            assert.same({ { message = "SwiftPrompt: no LSP symbol found at the cursor",
                level = vim.log.levels.WARN } }, editor.notifications)
            assert.same({}, editor.codex_requests)
        end)
    end
end)
