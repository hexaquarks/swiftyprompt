local claude = require("swiftyprompt.connectors.claude")

describe("Claude connector", function()
    local originals
    local options
    local jobs
    local sent
    local closed
    local stopped
    local updates
    local completions
    local original_api_key

    local function ask(thread_id)
        return claude.ask(options, "Explain this", "local value = 1", thread_id, {
            on_update = function(response)
                table.insert(updates, response)
            end,
            on_complete = function(response, failure, session_id)
                table.insert(completions, { response = response, failure = failure, session_id = session_id })
            end,
        })
    end

    local function emit(message, job_index)
        jobs[job_index or 1].callbacks.on_stdout(nil, { vim.json.encode(message), "" })
    end

    local function result(text, job_index)
        emit({ type = "result", subtype = "success", result = text, session_id = "claude-session" }, job_index)
    end

    before_each(function()
        originals = {}
        for _, name in ipairs({ "jobstart", "chansend", "chanclose", "jobstop" }) do
            originals[name] = vim.fn[name]
        end
        options = {
            command = "my-claude",
            model = "sonnet",
            auth = "claude_login",
            api_key_env = "SWIFTPROMPT_TEST_CLAUDE_KEY",
        }
        original_api_key = vim.env.SWIFTPROMPT_TEST_CLAUDE_KEY
        vim.env.SWIFTPROMPT_TEST_CLAUDE_KEY = nil
        jobs, sent, closed, stopped, updates, completions = {}, {}, {}, {}, {}, {}
        vim.fn.jobstart = function(command, callbacks)
            table.insert(jobs, { command = command, callbacks = callbacks })
            return 40 + #jobs
        end
        vim.fn.chansend = function(job_id, text)
            table.insert(sent, { job_id, text })
        end
        vim.fn.chanclose = function(job_id, stream)
            table.insert(closed, { job_id, stream })
        end
        vim.fn.jobstop = function(job_id)
            table.insert(stopped, job_id)
        end
    end)

    after_each(function()
        for name, fn in pairs(originals) do
            vim.fn[name] = fn
        end
        vim.env.SWIFTPROMPT_TEST_CLAUDE_KEY = original_api_key
    end)

    it("uses streaming print mode, disables tools, and passes code through stdin", function()
        ask()
        assert.same({
            "my-claude", "--print", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--tools", "", "--strict-mcp-config",
            "--mcp-config", '{"mcpServers":{}}', "--model", "sonnet",
        }, jobs[1].command)
        assert.matches("Selected code:\n```\nlocal value = 1\n```", sent[1][2])
        assert.matches("Question: Explain this", sent[1][2])
        assert.same({ { 41, "stdin" } }, closed)
        result("The answer")
        assert.same({}, completions)
        jobs[1].callbacks.on_exit(41, 0)
        assert.same({ { response = "The answer", session_id = "claude-session" } }, completions)
    end)

    it("resumes the explicit session without repeating selected code", function()
        ask("saved-session")
        assert.same({ "--resume", "saved-session" }, { unpack(jobs[1].command, #jobs[1].command - 1) })
        assert.same("Question: Explain this", sent[1][2])
    end)

    it("streams text deltas and ignores thinking and assistant snapshots", function()
        ask()
        for _, delta in ipairs({
            { type = "text_delta", text = "First " },
            { type = "thinking_delta", thinking = "Internal thought" },
            { type = "text_delta", text = "answer" },
        }) do
            emit({ type = "stream_event", event = { type = "content_block_delta", delta = delta } })
        end
        emit({ type = "assistant", message = { content = { { type = "text", text = "First answer" } } } })
        assert.same({ "First ", "First answer" }, updates)
        result("First answer")
        jobs[1].callbacks.on_exit(41, 0)
        assert.same("First answer", completions[1].response)
    end)

    it("handles split JSON lines and a final result without a newline", function()
        ask()
        local line = vim.json.encode({
            type = "stream_event", event = {
                type = "content_block_delta", delta = { type = "text_delta", text = "Hello" },
            },
        })
        jobs[1].callbacks.on_stdout(41, { line:sub(1, 15) })
        jobs[1].callbacks.on_stdout(41, { line:sub(16), vim.json.encode({
            type = "result", subtype = "success", result = "Hello", session_id = "session",
        }) })
        jobs[1].callbacks.on_exit(41, 0)
        assert.same({ "Hello" }, updates)
        assert.same({ { response = "Hello", session_id = "session" } }, completions)
    end)

    it("keeps simultaneous requests independent", function()
        ask()
        ask()
        result("Second answer", 2)
        jobs[2].callbacks.on_exit(42, 0)
        result("First answer", 1)
        jobs[1].callbacks.on_exit(41, 0)
        assert.same("Second answer", completions[1].response)
        assert.same("First answer", completions[2].response)
    end)

    it("stops cancelled jobs once and suppresses all late callbacks", function()
        local request = ask()
        claude.cancel(request)
        claude.cancel(request)
        emit({ type = "stream_event", event = {
            type = "content_block_delta", delta = { type = "text_delta", text = "Late" },
        } })
        result("Late answer")
        jobs[1].callbacks.on_exit(41, 143)
        assert.same({ 41 }, stopped)
        assert.same({}, updates)
        assert.same({}, completions)
    end)

    it("does not stop completed jobs or complete twice", function()
        local request = ask()
        result("Done")
        jobs[1].callbacks.on_exit(41, 0)
        jobs[1].callbacks.on_exit(41, 0)
        emit({ type = "stream_event", event = {
            type = "content_block_delta", delta = { type = "text_delta", text = "Late" },
        } })
        claude.cancel(request)
        claude.cancel(nil)
        assert.same(1, #completions)
        assert.same({}, stopped)
        assert.same({}, updates)
    end)

    it("reports structured failures even when the process exits successfully", function()
        ask()
        emit({ type = "result", is_error = true, result = "Not logged in" })
        jobs[1].callbacks.on_exit(41, 0)
        assert.same("Not logged in", completions[1].failure)
        assert.is_nil(completions[1].response)
    end)

    it("reports result error arrays for failed turns", function()
        ask()
        emit({ type = "result", subtype = "error_max_turns", errors = { "Turn limit reached" } })
        jobs[1].callbacks.on_exit(41, 1)
        assert.same("Turn limit reached", completions[1].failure)
    end)

    it("reports stderr on a nonzero exit instead of returning partial output", function()
        ask()
        result("Partial answer")
        jobs[1].callbacks.on_stderr(41, { "Invalid model", "" })
        jobs[1].callbacks.on_exit(41, 1)
        assert.same("Invalid model", completions[1].failure)
        assert.is_nil(completions[1].response)
    end)

    it("reports exit codes when stderr is empty", function()
        ask()
        jobs[1].callbacks.on_exit(41, 2)
        assert.same("Claude exited with code 2.", completions[1].failure)
    end)

    for _, output in ipairs({
        { name = "empty output", lines = { "" } },
        { name = "malformed JSON", lines = { "not JSON", "" } },
        { name = "a non-object JSON value", lines = { "null", "" } },
        { name = "an empty result", lines = {
            vim.json.encode({ type = "result", subtype = "success", result = "" }), "",
        } },
        { name = "a stream without a final result", lines = {
            vim.json.encode({ type = "stream_event", event = {
                type = "content_block_delta", delta = { type = "text_delta", text = "Partial" },
            } }), "",
        } },
    }) do
        it("rejects " .. output.name, function()
            ask()
            jobs[1].callbacks.on_stdout(41, output.lines)
            jobs[1].callbacks.on_exit(41, 0)
            assert.same({ { failure = "Claude finished without an answer." } }, completions)
        end)
    end

    for _, startup_failure in ipairs({ "return", "throw" }) do
        it("reports startup failures when jobstart will " .. startup_failure, function()
            vim.fn.jobstart = function()
                if startup_failure == "throw" then
                    error("Command not found")
                end
                return -1
            end
            assert.is_nil(ask())
            assert.matches("Could not start Claude Code", completions[1].failure)
            assert.same({}, sent)
        end)
    end

    it("stops the job and reports stdin failures once", function()
        vim.fn.chansend = function()
            error("Channel closed")
        end
        ask()
        jobs[1].callbacks.on_exit(41, 1)
        assert.same({ 41 }, stopped)
        assert.same(1, #completions)
        assert.matches("Could not send the question to Claude", completions[1].failure)
    end)

    it("requires a nonempty API key before starting a job", function()
        options.auth = "api_key"
        assert.is_nil(ask())
        vim.env.SWIFTPROMPT_TEST_CLAUDE_KEY = ""
        assert.is_nil(ask())
        assert.same({}, jobs)
        assert.same("Set SWIFTPROMPT_TEST_CLAUDE_KEY before starting Neovim.", completions[1].failure)
    end)

    it("maps a custom key environment variable to the Claude CLI variable", function()
        options.auth = "api_key"
        vim.env.SWIFTPROMPT_TEST_CLAUDE_KEY = "test-key"
        ask()
        assert.same({ ANTHROPIC_API_KEY = "test-key" }, jobs[1].callbacks.env)
    end)

    it("accepts a completion function without an update callback", function()
        local answer
        claude.ask(options, "Why?", "code", nil, function(response)
            answer = response
        end)
        result("Because")
        jobs[1].callbacks.on_exit(41, 0)
        assert.same("Because", answer)
    end)
end)
