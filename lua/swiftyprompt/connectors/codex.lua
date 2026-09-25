local M = {}

function M.ask(connector_options, question, selected_code, conversation_history, on_complete)
    if connector_options.auth == "api_key" and not vim.env[connector_options.api_key_env] then
        on_complete(nil, "Set " .. connector_options.api_key_env .. " before starting Neovim.")
        return
    end

    -- Codex can print progress messages to stdout. We ask it to write only its
    -- final answer to a temporary file, then read and delete that file below.
    local output_file = vim.fn.tempname()
    local codex_prompt = table.concat({
        "Answer this question about the selected code. Do not edit files.",
        "",
        "Selected code:",
        "```",
        selected_code,
        "```",
    }, "\n")

    -- Include completed turns so a follow-up can refer to earlier answers.
    for _, previous_exchange in ipairs(conversation_history) do
        codex_prompt = codex_prompt .. "\n\nPrevious question: " .. previous_exchange.question
        codex_prompt = codex_prompt .. "\nPrevious answer: " .. previous_exchange.response
    end

    codex_prompt = codex_prompt .. "\n\nQuestion: " .. question

    vim.system({
        connector_options.command,
        "exec",
        "--sandbox",
        connector_options.sandbox,
        "--ephemeral",
        "--output-last-message",
        output_file,
        codex_prompt,
    }, { text = true, cwd = vim.fn.getcwd() }, function(process_result)
        vim.schedule(function()
            if process_result.code ~= 0 then
                vim.fn.delete(output_file)
                on_complete(nil, process_result.stderr)
                return
            end

            if vim.fn.filereadable(output_file) == 0 then
                vim.fn.delete(output_file)
                on_complete(nil, "Codex finished without an answer.")
                return
            end

            local response = table.concat(vim.fn.readfile(output_file), "\n")
            vim.fn.delete(output_file)
            on_complete(response, nil)
        end)
    end)
end

return M
