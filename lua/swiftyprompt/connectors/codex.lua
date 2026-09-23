local M = {}

function M.ask(options, question, selected_text, input_context, done)
    if options.auth == "api_key" and not vim.env[options.api_key_env] then
        done(nil, "Set " .. options.api_key_env .. " before starting Neovim.")
        return
    end

    -- Codex can print progress messages to stdout. We ask it to write only its
    -- final answer to a temporary file, then read and delete that file below.
    local output_file = vim.fn.tempname()
    local prompt = table.concat({
        "Answer this question about the selected code. Do not edit files.",
        "",
        "Selected code:",
        "```",
        selected_text,
        "```",
    }, "\n")

    -- Include completed turns so a follow-up can refer to earlier answers.
    for _, turn in ipairs(input_context) do
        prompt = prompt .. "\n\nPrevious question: " .. turn.question
        prompt = prompt .. "\nPrevious answer: " .. turn.answer
    end

    prompt = prompt .. "\n\nQuestion: " .. question

    vim.system({
        options.command,
        "exec",
        "--sandbox",
        options.sandbox,
        "--ephemeral",
        "--output-last-message",
        output_file,
        prompt,
    }, { text = true, cwd = vim.fn.getcwd() }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                vim.fn.delete(output_file)
                done(nil, result.stderr)
                return
            end

            if vim.fn.filereadable(output_file) == 0 then
                done(nil, "Codex finished without an answer.")
                return
            end

            local answer = table.concat(vim.fn.readfile(output_file), "\n")
            vim.fn.delete(output_file)
            done(answer, nil)
        end)
    end)
end

return M
