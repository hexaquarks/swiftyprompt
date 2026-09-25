local codex = require("swiftyprompt.connectors.codex")

local options = {
    command = "codex",
    sandbox = "read-only",
    auth = "codex_login",
    api_key_env = "OPENAI_API_KEY",
}

describe("Codex connector", function()
    local original_system
    local original_schedule
    local original_tempname
    local original_filereadable
    local original_readfile
    local original_delete
    local original_api_key

    before_each(function()
        original_system = vim.system
        original_schedule = vim.schedule
        original_tempname = vim.fn.tempname
        original_filereadable = vim.fn.filereadable
        original_readfile = vim.fn.readfile
        original_delete = vim.fn.delete
        original_api_key = vim.env.SWIFTPROMPT_TEST_API_KEY
        vim.env.SWIFTPROMPT_TEST_API_KEY = nil

        -- Run scheduled callbacks immediately so each test stays synchronous.
        vim.schedule = function(callback)
            callback()
        end
        vim.fn.tempname = function()
            return "/tmp/swiftyprompt-test-answer"
        end
    end)

    after_each(function()
        vim.system = original_system
        vim.schedule = original_schedule
        vim.fn.tempname = original_tempname
        vim.fn.filereadable = original_filereadable
        vim.fn.readfile = original_readfile
        vim.fn.delete = original_delete
        vim.env.SWIFTPROMPT_TEST_API_KEY = original_api_key
    end)

    it("sends selection, prior turns, and the new question to Codex", function()
        local command
        local deleted_file
        local answer
        local error_message

        vim.fn.filereadable = function()
            return 1
        end
        vim.fn.readfile = function()
            return { "The answer", "has two lines." }
        end
        vim.fn.delete = function(path)
            deleted_file = path
        end
        vim.system = function(args, _, callback)
            command = args
            callback({ code = 0, stderr = "" })
        end

        codex.ask(options, "What does this do?", "local value = 1", {
            { question = "What is value?", response = "It is a number." },
        }, function(result, failure)
            answer = result
            error_message = failure
        end)

        assert.same("codex", command[1])
        assert.same("exec", command[2])
        assert.same("--skip-git-repo-check", command[3])
        assert.same("--output-last-message", command[7])
        assert.matches("local value = 1", command[9])
        assert.matches("Previous question: What is value%?", command[9])
        assert.matches("Question: What does this do%?", command[9])
        assert.same("The answer\nhas two lines.", answer)
        assert.is_nil(error_message)
        assert.same("/tmp/swiftyprompt-test-answer", deleted_file)
    end)

    it("returns Codex errors and removes the temporary answer file", function()
        local answer
        local error_message
        local deleted_file

        vim.fn.delete = function(path)
            deleted_file = path
        end
        vim.system = function(_, _, callback)
            callback({ code = 1, stderr = "Codex is unavailable" })
        end

        codex.ask(options, "Why?", "code", {}, function(result, failure)
            answer = result
            error_message = failure
        end)

        assert.is_nil(answer)
        assert.same("Codex is unavailable", error_message)
        assert.same("/tmp/swiftyprompt-test-answer", deleted_file)
    end)

    it("explains when Codex does not write an answer", function()
        local answer
        local error_message
        local deleted_file

        vim.fn.filereadable = function()
            return 0
        end
        vim.fn.delete = function(path)
            deleted_file = path
        end
        vim.system = function(_, _, callback)
            callback({ code = 0, stderr = "" })
        end

        codex.ask(options, "Why?", "code", {}, function(result, failure)
            answer = result
            error_message = failure
        end)

        assert.is_nil(answer)
        assert.same("Codex finished without an answer.", error_message)
        assert.same("/tmp/swiftyprompt-test-answer", deleted_file)
    end)

    it("does not start Codex when an API key is required but missing", function()
        local system_was_called = false
        local answer
        local error_message

        vim.system = function()
            system_was_called = true
        end

        codex.ask({
            command = "codex",
            sandbox = "read-only",
            auth = "api_key",
            api_key_env = "SWIFTPROMPT_TEST_API_KEY",
        }, "Why?", "code", {}, function(result, failure)
            answer = result
            error_message = failure
        end)

        assert.is_false(system_was_called)
        assert.is_nil(answer)
        assert.same("Set SWIFTPROMPT_TEST_API_KEY before starting Neovim.", error_message)
    end)
end)
