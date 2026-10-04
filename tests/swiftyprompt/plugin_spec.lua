describe("SwiftPrompt plugin entry point", function()
    local original_create_user_command

    before_each(function()
        original_create_user_command = vim.api.nvim_create_user_command
    end)

    after_each(function()
        vim.api.nvim_create_user_command = original_create_user_command
    end)

    it("registers a command that does not call a removed function", function()
        vim.g.loaded_swiftyprompt = nil
        vim.cmd("runtime plugin/swiftyprompt.lua")

        assert.is_not_nil(vim.api.nvim_get_commands({}).SwiftPromptPop)
        assert.has_no.errors(function()
            vim.cmd("SwiftPromptPop")
        end)
    end)

    it("does not register its command twice when sourced again", function()
        local registrations = 0
        vim.api.nvim_create_user_command = function(...)
            registrations = registrations + 1
            return original_create_user_command(...)
        end
        vim.g.loaded_swiftyprompt = nil
        vim.cmd("runtime plugin/swiftyprompt.lua")
        assert.same(1, registrations)
        assert.has_no.errors(function()
            vim.cmd("runtime plugin/swiftyprompt.lua")
        end)
        assert.same(1, registrations)
        assert.is_not_nil(vim.api.nvim_get_commands({}).SwiftPromptPop)
    end)
end)
