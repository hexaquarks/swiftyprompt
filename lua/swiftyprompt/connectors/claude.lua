local M = {}
local prompt = require("swiftyprompt.connectors.prompt")

local function complete(request, response, error_message)
    if request.cancelled or request.completed then
        return
    end

    request.completed = true
    request.callbacks.on_complete(response, error_message, request.thread_id)
end

local function handle_message(request, line)
    local ok, message = pcall(vim.json.decode, line)
    if not ok or type(message) ~= "table" then
        return
    end

    if type(message.session_id) == "string" then
        request.thread_id = message.session_id
    end

    if message.type == "result" then
        request.result = message
    elseif message.type == "stream_event" then
        local event = message.event or {}
        local delta = event.delta or {}
        if event.type == "content_block_delta" and delta.type == "text_delta"
            and type(delta.text) == "string"
        then
            request.response = request.response .. delta.text
            request.callbacks.on_update(request.response)
        end
    end
end

function M.ask(connector_options, question, selected_code, thread_id, callbacks)
    if type(callbacks) == "function" then
        callbacks = { on_complete = callbacks }
    end
    callbacks.on_update = callbacks.on_update or function() end

    local request = {
        callbacks = callbacks,
        thread_id = thread_id,
        response = "",
        stdout_remainder = "",
        stderr = "",
    }
    local environment
    if connector_options.auth == "api_key" then
        local api_key_env = connector_options.api_key_env or "ANTHROPIC_API_KEY"
        local api_key = vim.env[api_key_env]
        if not api_key or api_key == "" then
            complete(request, nil, "Set " .. api_key_env .. " before starting Neovim.")
            return nil
        end
        environment = { ANTHROPIC_API_KEY = api_key }
    end

    local command = {
        connector_options.command,
        "--print",
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
        -- The selected text is the context; no file edits or tool calls are needed.
        "--tools", "",
        "--strict-mcp-config",
        "--mcp-config", '{"mcpServers":{}}',
    }
    if connector_options.model then
        vim.list_extend(command, { "--model", connector_options.model })
    end
    if thread_id then
        vim.list_extend(command, { "--resume", thread_id })
    end

    local ok, job_id = pcall(vim.fn.jobstart, command, {
        env = environment,
        on_stdout = function(_, data)
            if request.cancelled or request.completed then
                return
            end
            -- Neovim can split one JSON line across several stdout callbacks.
            for index, fragment in ipairs(data) do
                local line = index == 1 and request.stdout_remainder .. fragment or fragment
                if index == #data then
                    request.stdout_remainder = line
                else
                    request.stdout_remainder = ""
                    handle_message(request, line)
                end
            end
        end,
        stderr_buffered = true,
        on_stderr = function(_, data)
            request.stderr = request.stderr .. table.concat(data, "\n")
        end,
        on_exit = function(_, exit_code)
            if request.cancelled or request.completed then
                return
            end
            if request.stdout_remainder ~= "" then
                handle_message(request, request.stdout_remainder)
                request.stdout_remainder = ""
            end

            local result = request.result
            if result and (result.is_error or (result.subtype and result.subtype ~= "success")) then
                local errors = type(result.errors) == "table" and table.concat(result.errors, "\n") or ""
                local message = type(result.result) == "string" and result.result ~= "" and result.result
                    or (errors ~= "" and errors) or "Claude did not complete the request."
                complete(request, nil, message)
            elseif exit_code ~= 0 then
                local message = vim.trim(request.stderr)
                complete(request, nil, message ~= "" and message
                    or "Claude exited with code " .. exit_code .. ".")
            elseif result and type(result.result) == "string" and result.result ~= "" then
                complete(request, result.result, nil)
            else
                complete(request, nil, "Claude finished without an answer.")
            end
        end,
    })

    if not ok or job_id <= 0 then
        complete(request, nil, "Could not start Claude Code. Check the configured command and installation.")
        return nil
    end
    request.job_id = job_id

    -- Use stdin instead of argv so large selections don't hit command-length limits.
    local sent, send_error = pcall(function()
        vim.fn.chansend(job_id, prompt.build(question, selected_code, thread_id == nil))
        vim.fn.chanclose(job_id, "stdin")
    end)
    if not sent then
        complete(request, nil, "Could not send the question to Claude: " .. tostring(send_error))
        vim.fn.jobstop(job_id)
    end
    return request
end

function M.cancel(request)
    if not request or request.cancelled or request.completed then
        return
    end
    request.cancelled = true
    if request.job_id then
        vim.fn.jobstop(request.job_id)
    end
end

return M
