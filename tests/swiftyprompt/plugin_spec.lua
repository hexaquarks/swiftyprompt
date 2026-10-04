describe("SwiftPrompt plugin entry point", function()
    it("registers a command that does not call a removed function", function()
        vim.g.loaded_swiftyprompt = nil
        vim.cmd("runtime plugin/swiftyprompt.lua")

        assert.is_not_nil(vim.api.nvim_get_commands({}).SwiftPromptPop)
        assert.has_no.errors(function()
            vim.cmd("SwiftPromptPop")
        end)
    end)

    it("does not register its command twice when sourced again", function()
        vim.g.loaded_swiftyprompt = nil
        vim.cmd("runtime plugin/swiftyprompt.lua")
        local command = vim.api.nvim_get_commands({}).SwiftPromptPop
        assert.has_no.errors(function()
            vim.cmd("runtime plugin/swiftyprompt.lua")
        end)
        assert.same(command, vim.api.nvim_get_commands({}).SwiftPromptPop)
    end)
end)
