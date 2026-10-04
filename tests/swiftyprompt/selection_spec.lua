local interaction = require("tests.support.interaction")

describe("SwiftPrompt selection behavior", function()
    local editor = interaction.setup()

    it("keeps all lines from a linewise Visual selection", function()
        editor.open_selection({ "  local one = 1", "", "  return one" }, { 1, 3 }, { 3, 0 }, "V")
        editor.submit_latest_prompt("Explain this")

        assert.same("  local one = 1\n\n  return one", editor.codex_requests[1].selected_code)
    end)

    it("rejects an empty Visual selection", function()
        editor.open_selection({ "" }, { 1, 1 }, { 1, 0 })

        assert.same({}, editor.opened_window_configs)
        assert.same({}, editor.codex_requests)
        assert.same({
            {
                message = "SwiftPrompt: select non-empty code first, then press <leader>aa",
                level = vim.log.levels.INFO,
            },
        }, editor.notifications)
    end)

    it("rejects a whitespace-only Visual selection", function()
        editor.open_selection({ "   ", "\t" }, { 1, 1 }, { 2, 0 }, "V")

        assert.same({}, editor.opened_window_configs)
        assert.same({}, editor.codex_requests)
        assert.same(1, #editor.notifications)
    end)

    it("honors exclusive characterwise selections in either direction", function()
        vim.o.selection = "exclusive"

        editor.open_selection({ "abcd" }, { 1, 1 }, { 1, 2 })
        editor.submit_latest_prompt("Explain this")
        assert.same("ab", editor.codex_requests[1].selected_code)
        vim.cmd("normal q")

        editor.open_selection({ "abcd" }, { 1, 3 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")
        assert.same("ab", editor.codex_requests[2].selected_code)
    end)

    it("extracts a rectangle for a blockwise Visual selection", function()
        editor.open_selection({ "abcDEF", "ghiJKL", "mnopqr" }, { 1, 3 }, { 3, 3 }, "\22")
        editor.submit_latest_prompt("Explain this")

        assert.same("cD\niJ\nop", editor.codex_requests[1].selected_code)
    end)

    it("keeps blockwise columns ordered when the selection is dragged left", function()
        editor.open_selection({ "abcDEF", "ghiJKL", "mnopqr" }, { 1, 5 }, { 3, 1 }, "\22")
        editor.submit_latest_prompt("Explain this")

        assert.same("bcDE\nhiJK\nnopq", editor.codex_requests[1].selected_code)
    end)

    it("uses displayed columns for blockwise selections with short, tab, and wide-character lines", function()
        editor.open_selection({ "a界cd", "a\tcd", "x", "abcdef" }, { 1, 2 }, { 4, 4 }, "\22")
        editor.submit_latest_prompt("Explain this")

        assert.same("界cd\n    \n\nbcde", editor.codex_requests[1].selected_code)
    end)
end)
