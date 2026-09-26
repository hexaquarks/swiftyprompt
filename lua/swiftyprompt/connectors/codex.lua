local M = {}

local IDLE_TIMEOUT_MS = 5 * 60 * 1000

-- The app server is deliberately shared by all SwiftPrompt conversations. Threads
-- remain ephemeral, but retaining the server avoids paying Codex's startup cost
-- for every question.
local state = {
    initialized = false,
    job_id = nil,
    idle_timer = nil,
    next_request_id = 0,
    requests = {},
    queued_questions = {},
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
    for _, question in ipairs(state.queued_questions) do
        question.on_complete(nil, message)
    end
    state.queued_questions = {}

    for _, turn in pairs(state.turns) do
        turn.on_complete(nil, message)
    end
    state.turns = {}
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

local function build_prompt(question, selected_code, conversation_history)
    local codex_prompt = table.concat({
        "Answer this question about the selected code. Do not edit files.",
        "",
        "Selected code:",
        "```",
        selected_code,
        "```",
    }, "\n")

    for _, previous_exchange in ipairs(conversation_history) do
        codex_prompt = codex_prompt .. "\n\nPrevious question: " .. previous_exchange.question
        codex_prompt = codex_prompt .. "\nPrevious answer: " .. previous_exchange.response
    end

    return codex_prompt .. "\n\nQuestion: " .. question
end

local function finish_turn(turn, completed_turn)
    local response
    for _, item in ipairs(completed_turn.items or {}) do
        if item.type == "agentMessage" then
            response = item.text
        end
    end

    if completed_turn.status ~= "completed" then
        local error = completed_turn.error and completed_turn.error.message
        turn.on_complete(nil, error or "Codex did not complete the request.")
    elseif response and response ~= "" then
        turn.on_complete(response, nil)
    else
        turn.on_complete(nil, "Codex finished without an answer.")
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

local function ask_question(question)
    send_request("thread/start", {
        cwd = vim.fn.getcwd(),
        model = question.options.model,
        sandbox = question.options.sandbox,
        approvalPolicy = "never",
        ephemeral = true,
    }, function(thread_result, thread_error)
        if thread_error then
            question.on_complete(nil, thread_error)
            schedule_shutdown_when_idle()
            return
        end

        local thread = thread_result and thread_result.thread
        if not thread or not thread.id then
            question.on_complete(nil, "Codex app server did not create a thread.")
            schedule_shutdown_when_idle()
            return
        end

        send_request("turn/start", {
            threadId = thread.id,
            input = { { type = "text", text = question.prompt } },
            effort = question.options.reasoning_effort,
        }, function(turn_result, turn_error)
            if turn_error then
                question.on_complete(nil, turn_error)
                schedule_shutdown_when_idle()
                return
            end

            local turn = turn_result and turn_result.turn
            if not turn or not turn.id then
                question.on_complete(nil, "Codex app server did not start a turn.")
                schedule_shutdown_when_idle()
                return
            end
            state.turns[turn.id] = question
        end)
    end)
end

start_queued_questions = function()
    if not state.initialized then
        return
    end

    local queued_questions = state.queued_questions
    state.queued_questions = {}
    for _, question in ipairs(queued_questions) do
        ask_question(question)
    end
end

local function start_server(connector_options)
    state.stderr = ""
    state.job_id = vim.fn.jobstart({ connector_options.command, "app-server", "--stdio" }, {
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

    if state.job_id <= 0 then
        fail_pending("Could not start the Codex app server.")
        reset_state()
        return
    end

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

function M.ask(connector_options, question, selected_code, conversation_history, on_complete)
    if connector_options.auth == "api_key" and not vim.env[connector_options.api_key_env] then
        on_complete(nil, "Set " .. connector_options.api_key_env .. " before starting Neovim.")
        return
    end

    stop_idle_timer()
    table.insert(state.queued_questions, {
        options = connector_options,
        prompt = build_prompt(question, selected_code, conversation_history),
        on_complete = on_complete,
    })

    if not state.job_id then
        start_server(connector_options)
    else
        start_queued_questions()
    end
end

-- Useful for Neovim shutdown hooks and tests; normal use relies on the idle timer.
function M.shutdown()
    stop_server()
end

return M
