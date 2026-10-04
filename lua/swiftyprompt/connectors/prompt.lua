local M = {}

function M.build(question, selected_code, is_new_conversation)
    if not is_new_conversation then
        return "Question: " .. question
    end

    return table.concat({
        "Answer this question about the selected code. Do not edit files.",
        "",
        "Selected code:",
        "```",
        selected_code,
        "```",
        "",
        "Question: " .. question,
    }, "\n")
end

return M
