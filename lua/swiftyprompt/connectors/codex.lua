local M = {}
local prompt = require("swiftyprompt.connectors.prompt")

local IDLE_TIMEOUT_MS = 5 * 60 * 1000

-- The app server is deliberately shared by all SwiftPrompt conversations.
-- Retaining the server avoids paying Codex's startup cost for every question.
local state = {
    initialized = false,
    job_id = nil,
    idle_timer = nil,
    next_request_id = 0,
    requests = {},
    queued_questions = {},
    pending_questions = {},
    active_thread_ids = {},
    turns = {},
    stdout_remainder = "",
    stderr = "",
}

local function json_encode(value)
    return vim.json.encode(value)
end

local function json_decode(value)
    return vim.json.decode(value)
end

local function reset_state()
    state.initialized = false
    state.job_id = nil
    state.idle_timer = nil
    state.requests = {}
    state.queued_questions = {}
    state.pending_questions = {}
    state.active_thread_ids = {}
    state.turns = {}
    state.stdout_remainder = ""
    state.stderr = ""
end

local function stop_idle_timer()
    if state.idle_timer then
        vim.fn.timer_stop(state.idle_timer)
        state.idle_timer = nil
    end
end

local function fail_pending(message)
    local pending_questions = state.pending_questions
    state.pending_questions = {}
    state.queued_questions = {}
    state.turns = {}

    for question in pairs(pending_questions) do
        if not question.cancelled then
            question.callbacks.on_complete(nil, message)
        end
    end
end

local function stop_server()
    stop_idle_timer()
    if state.job_id then
        vim.fn.jobstop(state.job_id)
    end
    reset_state()
end

local function schedule_shutdown_when_idle()
    stop_idle_timer()
    if not state.job_id or next(state.requests) or next(state.turns) or #state.queued_questions > 0 then
        return
    end

    state.idle_timer = vim.fn.timer_start(IDLE_TIMEOUT_MS, function()
        state.idle_timer = nil
        if state.job_id and not next(state.requests) and not next(state.turns) and #state.queued_questions == 0 then
            stop_server()
        end
    end)
end

local function next_request_id()
    state.next_request_id = state.next_request_id + 1
    return state.next_request_id
end

local function send_request(method, params, on_response)
    local request_id = next_request_id()
    state.requests[request_id] = on_response
    vim.fn.chansend(state.job_id, json_encode({
        jsonrpc = "2.0",
        id = request_id,
        method = method,
        params = params,
    }) .. "\n")
end

local function finish_turn(turn, completed_turn)
    if turn.cancelled then
        return
    end

    local response
    for _, item in ipairs(completed_turn.items or {}) do
        if item.type == "agentMessage" then
            response = item.text
        end
    end

    if completed_turn.status ~= "completed" then
        local error = completed_turn.error and completed_turn.error.message
        turn.callbacks.on_complete(nil, error or "Codex did not complete the request.", turn.thread_id)
    elseif response and response ~= "" then
        turn.callbacks.on_complete(response, nil, turn.thread_id)
    else
        turn.callbacks.on_complete(nil, "Codex finished without an answer.", turn.thread_id)
    end
end

local start_queued_questions

local function handle_message(message)
    if message.id then
        local callback = state.requests[message.id]
        state.requests[message.id] = nil
        if callback then
            if message.error then
                callback(nil, message.error.message or "Codex app server returned an error.")
            else
                callback(message.result, nil)
            end
        end
        return
    end

    if message.method == "item/agentMessage/delta" then
        local delta = message.params or {}
        local turn = state.turns[delta.turnId]
        if turn and not turn.cancelled then
            turn.response = turn.response .. delta.delta
            turn.callbacks.on_update(turn.response)
        end
        return
    end

    if message.method == "turn/completed" then
        local completed_turn = (message.params or {}).turn or {}
        local turn = state.turns[completed_turn.id]
        if turn then
            state.turns[completed_turn.id] = nil
            finish_turn(turn, completed_turn)
            schedule_shutdown_when_idle()
        end
    end
end

local function handle_stdout(_, data)
    -- jobstart can split a JSON-RPC line across callbacks. Preserve its final,
    -- incomplete fragment until the next callback.
    for index, line in ipairs(data) do
        if index == 1 then
            line = state.stdout_remainder .. line
        end

        if index == #data then
            state.stdout_remainder = line
        else
            state.stdout_remainder = ""
            local ok, message = pcall(json_decode, line)
            if ok then
                handle_message(message)
            end
        end
    end
end

local function start_turn(question)
    if question.cancelled then
        schedule_shutdown_when_idle()
        return
    end

    send_request("turn/start", {
        threadId = question.thread_id,
        input = { { type = "text", text = question.prompt } },
        effort = question.options.reasoning_effort,
    }, function(turn_result, turn_error)
        if turn_error then
            if not question.cancelled then
                question.callbacks.on_complete(nil, turn_error, question.thread_id)
            end
            schedule_shutdown_when_idle()
            return
        end

        local turn = turn_result and turn_result.turn
        if not turn or not turn.id then
            if not question.cancelled then
                question.callbacks.on_complete(nil, "Codex app server did not start a turn.", question.thread_id)
            end
            schedule_shutdown_when_idle()
            return
        end
        if question.cancelled then
            return
        end

        question.turn_id = turn.id
        state.turns[turn.id] = question
    end)
end

local function resume_thread(question)
    send_request("thread/resume", {
        threadId = question.thread_id,
    }, function(_, resume_error)
        if resume_error then
            if not question.cancelled then
                question.callbacks.on_complete(nil, resume_error, question.thread_id)
            end
            schedule_shutdown_when_idle()
            return
        end

        if question.cancelled then
            schedule_shutdown_when_idle()
            return
        end

        state.active_thread_ids[question.thread_id] = true
        start_turn(question)
    end)
end

local function ask_question(question)
    if question.thread_id then
        if state.active_thread_ids[question.thread_id] then
            start_turn(question)
        else
            resume_thread(question)
        end
        return
    end

    send_request("thread/start", {
        cwd = vim.fn.getcwd(),
        model = question.options.model,
        sandbox = question.options.sandbox,
        approvalPolicy = "never",
        ephemeral = false,
    }, function(thread_result, thread_error)
        if thread_error then
            if not question.cancelled then
                question.callbacks.on_complete(nil, thread_error)
            end
            schedule_shutdown_when_idle()
            return
        end

        local thread = thread_result and thread_result.thread
        if not thread or not thread.id then
            if not question.cancelled then
                question.callbacks.on_complete(nil, "Codex app server did not create a thread.")
            end
            schedule_shutdown_when_idle()
            return
        end

        if question.cancelled then
            schedule_shutdown_when_idle()
            return
        end

        question.thread_id = thread.id
        state.active_thread_ids[thread.id] = true
        start_turn(question)
    end)
end

start_queued_questions = function()
    if not state.initialized then
        return
    end

    local queued_questions = state.queued_questions
    state.queued_questions = {}
    for _, question in ipairs(queued_questions) do
        if not question.cancelled then
            ask_question(question)
        end
    end
end

local function start_server(connector_options)
    state.stderr = ""
    -- jobstart can throw for a missing executable instead of returning a failure code.
    local ok, job_id = pcall(vim.fn.jobstart, { connector_options.command, "app-server", "--stdio" }, {
        on_stdout = handle_stdout,
        on_stderr = function(_, data)
            state.stderr = state.stderr .. table.concat(data, "\n")
        end,
        on_exit = function(job_id)
            -- A terminated server can report its exit after a replacement has
            -- already been created. It must not tear down that newer server.
            if state.job_id ~= job_id then
                return
            end
            local failure = state.stderr ~= "" and state.stderr or "Codex app server stopped unexpectedly."
            fail_pending(failure)
            reset_state()
        end,
    })

    if not ok or job_id <= 0 then
        fail_pending("Could not start the Codex app server.")
        reset_state()
        return
    end
    state.job_id = job_id

    send_request("initialize", {
        clientInfo = { name = "swiftyprompt", version = "0.1.0" },
    }, function(_, initialize_error)
        if initialize_error then
            fail_pending(initialize_error)
            stop_server()
            return
        end
        state.initialized = true
        vim.fn.chansend(state.job_id, json_encode({ jsonrpc = "2.0", method = "initialized", params = {} }) .. "\n")
        start_queued_questions()
    end)
end

function M.ask(connector_options, question, selected_code, thread_id, callbacks)
    if type(callbacks) == "function" then
        callbacks = { on_complete = callbacks }
    end
    callbacks.on_update = callbacks.on_update or function() end

    if connector_options.auth == "api_key" and not vim.env[connector_options.api_key_env] then
        callbacks.on_complete(nil, "Set " .. connector_options.api_key_env .. " before starting Neovim.")
        return nil
    end

    local request = {
        options = connector_options,
        prompt = prompt.build(question, selected_code, thread_id == nil),
        response = "",
        thread_id = thread_id,
    }
    -- Track the question across thread/turn RPCs as well as active turns, so a
    -- server crash always completes it instead of leaving the UI waiting.
    request.callbacks = {
        on_update = callbacks.on_update,
        on_complete = function(...)
            state.pending_questions[request] = nil
            callbacks.on_complete(...)
        end,
    }
    state.pending_questions[request] = true

    stop_idle_timer()
    table.insert(state.queued_questions, request)

    if not state.job_id then
        start_server(connector_options)
    else
        start_queued_questions()
    end

    return request
end

function M.cancel(request)
    if not request or request.cancelled then
        return
    end

    request.cancelled = true
    state.pending_questions[request] = nil
    if not request.turn_id or not request.thread_id or not state.job_id then
        return
    end

    send_request("turn/interrupt", {
        threadId = request.thread_id,
        turnId = request.turn_id,
    }, function() end)
end

-- Useful for Neovim shutdown hooks and tests; normal use relies on the idle timer.
function M.shutdown()
    stop_server()
end

return M
