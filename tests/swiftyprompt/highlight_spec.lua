local swiftyprompt = require("swiftyprompt")
local interaction = require("tests.support.interaction")
local namespace = vim.api.nvim_create_namespace("swiftyprompt.source")

local function highlights(buffer)
    return vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })
end

describe("SwiftPrompt source highlighting", function()
    local editor = interaction.setup()

    it("keeps a selection highlighted through responses and follow-ups, then clears it", function()
        local window = editor.open_selection({ "one", "two" }, { 1, 1 }, { 2, 2 }, "V")
        local buffer = vim.api.nvim_win_get_buf(window)
        assert.same(2, #highlights(buffer))
        assert.same("SwiftyPromptSource", highlights(buffer)[1][4].line_hl_group)

        editor.submit_latest_prompt("Explain this")
        assert.same(2, #highlights(buffer))
        vim.cmd("normal f")
        assert.same(2, #highlights(buffer))
        vim.cmd("normal q")
        assert.same({}, highlights(buffer))
    end)

    it("highlights only the selected rectangle and clears it on cancellation", function()
        local window = editor.open_selection({ "abcDEF", "ghiJKL" }, { 1, 3 }, { 2, 3 }, "\22")
        local buffer = vim.api.nvim_win_get_buf(window)
        local marks = highlights(buffer)
        assert.same(2, #marks)
        for _, mark in ipairs(marks) do
            assert.same(2, mark[3])
            assert.same(4, mark[4].end_col)
        end
        vim.cmd("normal q")
        assert.same({}, highlights(buffer))
    end)

    it("highlights the resolved symbol's source lines", function()
        local _, buffer = editor.set_source({ "function greet()", "end", "other()" })
        vim.lsp.buf_request_sync = function()
            return {
                {
                    result = {
                        {
                            name = "greet",
                            range = {
                                start = { line = 0, character = 0 },
                                ["end"] = { line = 1, character = 3 },
                            },
                        },
                    },
                },
            }
        end
        swiftyprompt.ask_about_current_symbol()
        local marks = highlights(buffer)
        assert.same(2, #marks)
        assert.same(0, marks[1][2])
        assert.same(1, marks[2][2])
        vim.cmd("normal q")
        assert.same({}, highlights(buffer))
    end)
end)
