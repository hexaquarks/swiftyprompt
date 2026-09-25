describe("SwiftPrompt plugin entry point", function()
    it("registers a command that does not call a removed function", function()
        vim.g.loaded_swiftyprompt = nil
        vim.cmd("runtime plugin/swiftyprompt.lua")

        assert.is_not_nil(vim.api.nvim_get_commands({}).SwiftPromptPop)
        assert.has_no.errors(function()
            vim.cmd("SwiftPromptPop")
        end)
    end)
end)
