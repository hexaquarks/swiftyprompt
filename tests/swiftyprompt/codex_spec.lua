local codex = require("swiftyprompt.connectors.codex")

local options = {
    command = "codex",
    model = "test-model",
    reasoning_effort = "none",
    sandbox = "read-only",
    auth = "codex_login",
    api_key_env = "OPENAI_API_KEY",
}

describe("Codex connector", function()
    local original_jobstart
    local original_chansend
    local original_jobstop
    local original_timer_start
    local original_timer_stop
    local original_api_key
    local callbacks
    local sent_messages
    local stopped_jobs
    local stopped_timers

    local function sent_request(index)
        return vim.json.decode(sent_messages[index])
    end

    local function respond(request_index, result)
        callbacks.on_stdout(nil, { vim.json.encode({
            jsonrpc = "2.0",
            id = sent_request(request_index).id,
            result = result,
        }), "" })
    end

    before_each(function()
        codex.shutdown()
        original_jobstart = vim.fn.jobstart
        original_chansend = vim.fn.chansend
        original_jobstop = vim.fn.jobstop
        original_timer_start = vim.fn.timer_start
        original_timer_stop = vim.fn.timer_stop
        original_api_key = vim.env.SWIFTPROMPT_TEST_API_KEY
        vim.env.SWIFTPROMPT_TEST_API_KEY = nil
        callbacks = {}
        sent_messages = {}
        stopped_jobs = {}
        stopped_timers = {}

        vim.fn.jobstart = function(_, job_callbacks)
            callbacks = job_callbacks
            return 42
        end
        vim.fn.chansend = function(_, message)
            table.insert(sent_messages, message)
        end
        vim.fn.jobstop = function(job_id)
            table.insert(stopped_jobs, job_id)
        end
        vim.fn.timer_start = function(_, callback)
            callbacks.idle_timer = callback
            return 7
        end
        vim.fn.timer_stop = function(timer_id)
            table.insert(stopped_timers, timer_id)
        end
    end)

    after_each(function()
        codex.shutdown()
        vim.fn.jobstart = original_jobstart
        vim.fn.chansend = original_chansend
        vim.fn.jobstop = original_jobstop
        vim.fn.timer_start = original_timer_start
        vim.fn.timer_stop = original_timer_stop
        vim.env.SWIFTPROMPT_TEST_API_KEY = original_api_key
    end)

    it("lazily starts one app server and returns the completed turn", function()
        local answer
        local error_message

        codex.ask(options, "What does this do?", "local value = 1", {
            { question = "What is value?", response = "It is a number." },
        }, function(result, failure)
            answer = result
            error_message = failure
        end)

        assert.same("initialize", sent_request(1).method)
        respond(1, {})
        assert.same("initialized", sent_request(2).method)
        assert.same("thread/start", sent_request(3).method)
        assert.same("test-model", sent_request(3).params.model)
        assert.same("read-only", sent_request(3).params.sandbox)

        respond(3, { thread = { id = "thread-1" } })
        assert.same("turn/start", sent_request(4).method)
        assert.same("thread-1", sent_request(4).params.threadId)
        assert.same("none", sent_request(4).params.effort)
        assert.matches("local value = 1", sent_request(4).params.input[1].text)
        assert.matches("Previous question: What is value%?", sent_request(4).params.input[1].text)
        assert.matches("Question: What does this do%?", sent_request(4).params.input[1].text)

        respond(4, { turn = { id = "turn-1" } })
        callbacks.on_stdout(nil, { vim.json.encode({
            jsonrpc = "2.0",
            method = "turn/completed",
            params = {
                turn = {
                    id = "turn-1",
                    status = "completed",
                    items = { { type = "agentMessage", text = "The answer" } },
                },
            },
        }), "" })

        assert.same("The answer", answer)
        assert.is_nil(error_message)
        assert.is_not_nil(callbacks.idle_timer)
    end)

    it("reuses the server before its idle timer fires, then stops it", function()
        codex.ask(options, "First?", "code", {}, function() end)
        respond(1, {})
        respond(3, { thread = { id = "thread-1" } })
        respond(4, { turn = { id = "turn-1" } })
        callbacks.on_stdout(nil, { vim.json.encode({
            jsonrpc = "2.0",
            method = "turn/completed",
            params = { turn = { id = "turn-1", status = "completed", items = {} } },
        }), "" })

        codex.ask(options, "Second?", "code", {}, function() end)
        assert.same("thread/start", sent_request(5).method)
        assert.same({ 7 }, stopped_timers)

        respond(5, { thread = { id = "thread-2" } })
        respond(6, { turn = { id = "turn-2" } })
        callbacks.on_stdout(nil, { vim.json.encode({
            jsonrpc = "2.0",
            method = "turn/completed",
            params = { turn = { id = "turn-2", status = "completed", items = {} } },
        }), "" })
        callbacks.idle_timer()
        assert.same({ 42 }, stopped_jobs)
    end)

    it("returns app-server errors", function()
        local answer
        local error_message
        codex.ask(options, "Why?", "code", {}, function(result, failure)
            answer = result
            error_message = failure
        end)

        callbacks.on_stdout(nil, { vim.json.encode({
            jsonrpc = "2.0",
            id = sent_request(1).id,
            error = { message = "Codex is unavailable" },
        }), "" })

        assert.is_nil(answer)
        assert.same("Codex is unavailable", error_message)
    end)

    it("does not start Codex when an API key is required but missing", function()
        local answer
        local error_message

        codex.ask({
            command = "codex",
            model = "test-model",
            sandbox = "read-only",
            auth = "api_key",
            api_key_env = "SWIFTPROMPT_TEST_API_KEY",
        }, "Why?", "code", {}, function(result, failure)
            answer = result
            error_message = failure
        end)

        assert.is_nil(callbacks.on_stdout)
        assert.is_nil(answer)
        assert.same("Set SWIFTPROMPT_TEST_API_KEY before starting Neovim.", error_message)
    end)
end)
