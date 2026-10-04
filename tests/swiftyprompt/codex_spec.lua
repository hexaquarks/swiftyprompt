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

    local function emit(message)
        callbacks.on_stdout(nil, { vim.json.encode(message), "" })
    end

    local function sent_request(index)
        return vim.json.decode(sent_messages[index])
    end

    local function respond(request_index, result)
        emit({
            jsonrpc = "2.0",
            id = sent_request(request_index).id,
            result = result,
        })
    end

    local function reject(request_index, message)
        emit({ id = sent_request(request_index).id, error = { message = message } })
    end

    local function complete_turn(turn_id, status, error_message)
        emit({
            method = "turn/completed",
            params = {
                turn = {
                    id = turn_id,
                    status = status,
                    error = error_message and { message = error_message },
                    items = { { type = "agentMessage", text = "Answer" } },
                },
            },
        })
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

        codex.ask(options, "What does this do?", "local value = 1", nil, function(result, failure)
            answer = result
            error_message = failure
        end)

        assert.same("initialize", sent_request(1).method)
        respond(1, {})
        assert.same("initialized", sent_request(2).method)
        assert.same("thread/start", sent_request(3).method)
        assert.same("test-model", sent_request(3).params.model)
        assert.same("read-only", sent_request(3).params.sandbox)
        assert.is_false(sent_request(3).params.ephemeral)

        respond(3, { thread = { id = "thread-1" } })
        assert.same("turn/start", sent_request(4).method)
        assert.same("thread-1", sent_request(4).params.threadId)
        assert.same("none", sent_request(4).params.effort)
        assert.matches("local value = 1", sent_request(4).params.input[1].text)
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

    it("sends a follow-up to the existing thread without repeating its context", function()
        codex.ask(options, "First?", "local value = 1", nil, function() end)
        respond(1, {})
        respond(3, { thread = { id = "thread-1" } })
        respond(4, { turn = { id = "turn-1" } })
        callbacks.on_stdout(nil, { vim.json.encode({
            jsonrpc = "2.0",
            method = "turn/completed",
            params = { turn = { id = "turn-1", status = "completed", items = {} } },
        }), "" })

        codex.ask(options, "And now?", "local value = 1", "thread-1", function() end)

        assert.same("turn/start", sent_request(5).method)
        assert.same("thread-1", sent_request(5).params.threadId)
        assert.matches("Question: And now%?", sent_request(5).params.input[1].text)
        assert.is_nil(sent_request(5).params.input[1].text:match("Selected code:"))
    end)

    it("streams agent-message deltas before the turn completes", function()
        local streamed_responses = {}
        local request = codex.ask(options, "Explain this", "code", nil, {
            on_complete = function() end,
            on_update = function(response)
                table.insert(streamed_responses, response)
            end,
        })
        respond(1, {})
        respond(3, { thread = { id = "thread-1" } })
        respond(4, { turn = { id = "turn-1" } })

        callbacks.on_stdout(nil, { vim.json.encode({
            jsonrpc = "2.0",
            method = "item/agentMessage/delta",
            params = {
                delta = "First ",
                itemId = "item-1",
                threadId = "thread-1",
                turnId = "turn-1",
            },
        }), "" })
        callbacks.on_stdout(nil, { vim.json.encode({
            jsonrpc = "2.0",
            method = "item/agentMessage/delta",
            params = {
                delta = "answer.",
                itemId = "item-1",
                threadId = "thread-1",
                turnId = "turn-1",
            },
        }), "" })

        assert.same({ "First ", "First answer." }, streamed_responses)
        assert.same("turn-1", request.turn_id)
    end)

    it("interrupts an active turn and suppresses its late completion", function()
        local completed = false
        local request = codex.ask(options, "Explain this", "code", nil, {
            on_complete = function()
                completed = true
            end,
        })
        respond(1, {})
        respond(3, { thread = { id = "thread-1" } })
        respond(4, { turn = { id = "turn-1" } })

        codex.cancel(request)
        assert.same("turn/interrupt", sent_request(5).method)
        assert.same({ threadId = "thread-1", turnId = "turn-1" }, sent_request(5).params)
        respond(5, {})

        callbacks.on_stdout(nil, { vim.json.encode({
            jsonrpc = "2.0",
            method = "turn/completed",
            params = { turn = { id = "turn-1", status = "interrupted", items = {} } },
        }), "" })

        assert.is_false(completed)
    end)

    it("does not start a request cancelled before Codex initializes", function()
        local request = codex.ask(options, "Explain this", "code", nil, function() end)
        codex.cancel(request)
        respond(1, {})

        assert.same("initialized", sent_request(2).method)
        assert.same(2, #sent_messages)
    end)

    it("does not start a turn when a thread request is cancelled", function()
        local request = codex.ask(options, "Explain this", "code", nil, function() end)
        respond(1, {})

        codex.cancel(request)
        respond(3, { thread = { id = "thread-1" } })

        assert.same(3, #sent_messages)
    end)

    it("resumes a saved thread after the idle server shuts down", function()
        codex.ask(options, "First?", "code", nil, function() end)
        respond(1, {})
        respond(3, { thread = { id = "thread-1" } })
        respond(4, { turn = { id = "turn-1" } })
        callbacks.on_stdout(nil, { vim.json.encode({
            jsonrpc = "2.0",
            method = "turn/completed",
            params = { turn = { id = "turn-1", status = "completed", items = {} } },
        }), "" })
        callbacks.idle_timer()

        codex.ask(options, "And now?", "code", "thread-1", function() end)
        respond(5, {})

        assert.same("thread/resume", sent_request(7).method)
        assert.same("thread-1", sent_request(7).params.threadId)
        respond(7, { thread = { id = "thread-1" } })
        assert.same("turn/start", sent_request(8).method)
        assert.same("thread-1", sent_request(8).params.threadId)
    end)

    it("reuses the server before its idle timer fires, then stops it", function()
        codex.ask(options, "First?", "code", nil, function() end)
        respond(1, {})
        respond(3, { thread = { id = "thread-1" } })
        respond(4, { turn = { id = "turn-1" } })
        callbacks.on_stdout(nil, { vim.json.encode({
            jsonrpc = "2.0",
            method = "turn/completed",
            params = { turn = { id = "turn-1", status = "completed", items = {} } },
        }), "" })

        codex.ask(options, "Second?", "code", nil, function() end)
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
        codex.ask(options, "Why?", "code", nil, function(result, failure)
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
        }, "Why?", "code", nil, function(result, failure)
            answer = result
            error_message = failure
        end)

        assert.is_nil(callbacks.on_stdout)
        assert.is_nil(answer)
        assert.same("Set SWIFTPROMPT_TEST_API_KEY before starting Neovim.", error_message)
    end)

    it("reports startup failure and can start a replacement server", function()
        vim.fn.jobstart = function()
            return -1
        end
        local failure
        codex.ask(options, "Why?", "code", nil, function(_, message)
            failure = message
        end)
        assert.same("Could not start the Codex app server.", failure)
        assert.same({}, sent_messages)

        vim.fn.jobstart = function(_, job_callbacks)
            callbacks = job_callbacks
            return 43
        end
        codex.ask(options, "Retry", "code", nil, function() end)
        assert.same("initialize", sent_request(1).method)
    end)

    for _, stage in ipairs({ "thread", "resume", "turn" }) do
        for _, cancelled in ipairs({ false, true }) do
            it("handles " .. stage .. " errors" .. (cancelled and " after cancellation" or ""), function()
                local failures = {}
                local request = codex.ask(options, "Why?", "code",
                    stage == "resume" and "saved-thread" or nil, function(_, failure)
                        table.insert(failures, failure)
                    end)
                respond(1, {})
                local request_index = 3
                if stage == "turn" then
                    respond(3, { thread = { id = "thread-1" } })
                    request_index = 4
                end
                if cancelled then
                    codex.cancel(request)
                end
                reject(request_index, stage .. " unavailable")
                assert.same(cancelled and {} or { stage .. " unavailable" }, failures)
                assert.is_not_nil(callbacks.idle_timer)
                assert.same(request_index, #sent_messages)
            end)
        end
    end

    for _, stage in ipairs({ "thread", "turn" }) do
        it("reports a " .. stage .. " response without an ID", function()
            local failure
            codex.ask(options, "Why?", "code", nil, function(_, message)
                failure = message
            end)
            respond(1, {})
            local index = 3
            if stage == "turn" then
                respond(3, { thread = { id = "thread-1" } })
                index = 4
            end
            respond(index, { [stage] = {} })
            local expected = stage == "thread" and "Codex app server did not create a thread."
                or "Codex app server did not start a turn."
            assert.same(expected, failure)
            assert.same(index, #sent_messages)
            assert.is_not_nil(callbacks.idle_timer)
        end)
    end

    it("reports failed turns and falls back when the server supplies no error", function()
        local failures = {}
        local function on_complete(_, failure)
            table.insert(failures, failure)
        end
        codex.ask(options, "First", "code", nil, on_complete)
        respond(1, {})
        respond(3, { thread = { id = "thread-1" } })
        respond(4, { turn = { id = "turn-1" } })
        complete_turn("turn-1", "failed", "Model unavailable")
        codex.ask(options, "Retry", "code", "thread-1", on_complete)
        respond(5, { turn = { id = "turn-2" } })
        complete_turn("turn-2", "failed")
        assert.same({ "Model unavailable", "Codex did not complete the request." }, failures)
    end)

    for _, stage in ipairs({ "initialization", "thread", "resume", "turn", "active turn" }) do
        it("fails pending questions when the server crashes during " .. stage, function()
            local failures = {}
            codex.ask(options, "Why?", "code", stage == "resume" and "saved-thread" or nil, function(_, failure)
                table.insert(failures, failure)
            end)
            if stage ~= "initialization" then
                respond(1, {})
            end
            if stage == "turn" or stage == "active turn" then
                respond(3, { thread = { id = "thread-1" } })
            end
            if stage == "active turn" then
                respond(4, { turn = { id = "turn-1" } })
            end
            callbacks.on_stderr(42, { "Server crashed", "" })
            callbacks.on_exit(42, 1)
            assert.same({ "Server crashed\n" }, failures)
            callbacks.on_exit(42, 1)
            assert.same(1, #failures)
        end)
    end

    it("uses a fallback error for a crash without stderr", function()
        local failure
        codex.ask(options, "Why?", "code", nil, function(_, message)
            failure = message
        end)
        callbacks.on_exit(42, 1)
        assert.same("Codex app server stopped unexpectedly.", failure)
    end)

    it("ignores the exit of an old server after a replacement starts", function()
        codex.ask(options, "First", "code", nil, function() end)
        local old_callbacks = callbacks
        codex.shutdown()
        vim.fn.jobstart = function(_, job_callbacks)
            callbacks = job_callbacks
            return 43
        end
        local answer
        codex.ask(options, "Retry", "code", nil, function(response)
            answer = response
        end)
        old_callbacks.on_exit(42, 1)
        respond(2, {})
        respond(4, { thread = { id = "thread-2" } })
        respond(5, { turn = { id = "turn-2" } })
        complete_turn("turn-2", "completed")
        assert.same("Answer", answer)
    end)

    it("queues concurrent questions until initialization and stays alive while one is active", function()
        local answers = {}
        local function on_complete(response)
            table.insert(answers, response)
        end
        codex.ask(options, "First", "code", nil, on_complete)
        codex.ask(options, "Second", "code", nil, on_complete)
        assert.same(1, #sent_messages)
        respond(1, {})
        respond(3, { thread = { id = "thread-1" } })
        respond(4, { thread = { id = "thread-2" } })
        respond(5, { turn = { id = "turn-1" } })
        respond(6, { turn = { id = "turn-2" } })
        complete_turn("turn-1", "completed")
        assert.is_nil(callbacks.idle_timer)
        complete_turn("turn-2", "completed")
        assert.same({ "Answer", "Answer" }, answers)
        assert.is_not_nil(callbacks.idle_timer)
    end)

    it("cancels resumed questions before a turn starts", function()
        local completed = false
        local request = codex.ask(options, "Follow-up", "code", "saved-thread", function()
            completed = true
        end)
        respond(1, {})
        codex.cancel(request)
        codex.cancel(request)
        codex.cancel(nil)
        respond(3, {})
        assert.same(3, #sent_messages)
        assert.is_false(completed)
    end)

    it("fails each concurrent question once on a crash and skips cancelled questions", function()
        local failures = {}
        local function ask(label)
            return codex.ask(options, label, "code", nil, function(_, failure)
                table.insert(failures, { question = label, error = failure })
            end)
        end
        ask("active")
        respond(1, {})
        respond(3, { thread = { id = "thread-1" } })
        respond(4, { turn = { id = "turn-1" } })
        ask("pending")
        local cancelled = ask("cancelled")
        codex.cancel(cancelled)

        callbacks.on_exit(42, 1)
        table.sort(failures, function(first, second)
            return first.question < second.question
        end)
        assert.same({
            { question = "active", error = "Codex app server stopped unexpectedly." },
            { question = "pending", error = "Codex app server stopped unexpectedly." },
        }, failures)
    end)
end)
