local interaction = require("tests.support.interaction")

describe("SwiftPrompt response behavior", function()
    local editor = interaction.setup()

    it("wraps question text within the three-line prompt input", function()
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })

        local prompt_window = vim.api.nvim_get_current_win()
        local prompt_config = vim.api.nvim_win_get_config(prompt_window)
        assert.same(3, prompt_config.height)
        assert.is_true(vim.wo[prompt_window].wrap)
    end)

    it("grows the response window for wrapped lines", function()
        editor.codex_response = string.rep("x", 61)
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")

        local response_window = vim.api.nvim_get_current_win()
        local response_config = vim.api.nvim_win_get_config(response_window)
        assert.same(58, response_config.width)
        assert.same(2, response_config.height)
        assert.is_true(vim.wo[response_window].wrap)
    end)

    for _, screen_height in ipairs({ 24, 40, 80 }) do
        it("limits the entire response card on a " .. screen_height .. "-row screen", function()
            vim.o.lines = screen_height
            editor.codex_response = string.rep("Response line\n", 100)
            editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
            editor.submit_latest_prompt("Explain this")
            local frame_window = vim.api.nvim_win_get_config(0).win
            local card_height = vim.api.nvim_win_get_height(frame_window) + 2
            assert.is_true(card_height <= 22)
            assert.is_true(card_height <= math.floor((screen_height - vim.o.cmdheight) * 0.6))
            vim.api.nvim_feedkeys("G", "mtx", false)
            assert.same(101, vim.api.nvim_win_get_cursor(0)[1])
        end)
    end

    it("shrinks an open response card when the terminal gets smaller", function()
        vim.o.lines = 80
        editor.codex_response = string.rep("Response line\n", 100)
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")
        local response_window = vim.api.nvim_get_current_win()
        local frame_window = vim.api.nvim_win_get_config(response_window).win
        local previous_height = vim.api.nvim_win_get_height(frame_window)
        vim.api.nvim_win_set_cursor(response_window, { 70, 0 })
        local changedtick = vim.api.nvim_buf_get_changedtick(0)
        vim.o.lines = 24
        vim.api.nvim_exec_autocmds("VimResized", {})
        assert.is_true(vim.api.nvim_win_get_height(frame_window) < previous_height)
        assert.is_true(vim.api.nvim_win_get_height(frame_window) + 2 <= 13)
        assert.same(response_window, vim.api.nvim_get_current_win())
        assert.same(101, vim.api.nvim_buf_line_count(0))
        assert.same({ 70, 0 }, vim.api.nvim_win_get_cursor(response_window))
        assert.same(changedtick, vim.api.nvim_buf_get_changedtick(0))
    end)

    it("renders responses in a read-only Markdown buffer", function()
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")

        local response_window = vim.api.nvim_get_current_win()
        local response_buffer = vim.api.nvim_win_get_buf(response_window)
        assert.equals("swiftyprompt_markdown", vim.bo[response_buffer].filetype)
        assert.is_false(vim.bo[response_buffer].modifiable)
        assert.is_true(vim.bo[response_buffer].readonly)
        assert.is_false(vim.bo[response_buffer].modified)
        assert.same(2, vim.wo[response_window].conceallevel)
        assert.same("nvic", vim.wo[response_window].concealcursor)
    end)

    it("keeps the question and controls fixed while scrolling a response", function()
        local lines = {}
        for row = 1, 80 do
            lines[row] = "Answer line " .. row
        end
        editor.codex_response = table.concat(lines, "\n")
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("What does setup() override?")
        local response_window = vim.api.nvim_get_current_win()
        local frame_window = vim.api.nvim_win_get_config(response_window).win
        local frame_buffer = vim.api.nvim_win_get_buf(frame_window)
        local namespace = vim.api.nvim_create_namespace("swiftyprompt.ui")
        local chrome = vim.api.nvim_buf_get_extmarks(frame_buffer, namespace, 0, -1, { details = true })
        vim.api.nvim_feedkeys("G", "mtx", false)
        vim.cmd("redraw")
        assert.same(80, vim.api.nvim_win_get_cursor(response_window)[1])
        assert.is_true(vim.fn.winsaveview().topline > 1)
        assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(frame_window))
        assert.same(chrome, vim.api.nvim_buf_get_extmarks(frame_buffer, namespace, 0, -1, { details = true }))
        assert.same("You", chrome[1][4].virt_text[1][1])
        assert.same(" · What does setup() override?", chrome[1][4].virt_text[2][1])
        assert.same({ lines[1], lines[2] }, vim.api.nvim_buf_get_lines(0, 0, 2, false))
    end)

    it("copies the complete response with gY, including offscreen Markdown", function()
        editor.codex_response = "# Heading\n" .. string.rep("- **Detail**\n", 40)
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")
        local copied = {}
        vim.fn.setreg = function(register, text)
            copied[register] = text
        end
        vim.api.nvim_feedkeys("GgY", "mtx", false)
        assert.same(editor.codex_response, copied['"'])
        assert.same(editor.codex_response, copied["+"])
        assert.is_false(vim.bo.modifiable)
    end)

    it("updates the fixed question when a follow-up is submitted", function()
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("First question")
        vim.api.nvim_feedkeys("f", "mtx", false)
        editor.submit_latest_prompt("Follow-up question")
        local frame_window = vim.api.nvim_win_get_config(0).win
        local frame_buffer = vim.api.nvim_win_get_buf(frame_window)
        local marks = vim.api.nvim_buf_get_extmarks(frame_buffer,
            vim.api.nvim_create_namespace("swiftyprompt.ui"), { 0, 0 }, { 0, -1 }, { details = true })
        assert.same(" · Follow-up question", marks[1][4].virt_text[2][1])
        assert.same("Follow-up question", editor.codex_requests[2].question)
    end)

    it("conceals Markdown delimiters and configures wrapped motions", function()
        editor.codex_response = "`Model` has **bold** and *italic* text."
        editor.open_selection({ "one" }, { 1, 1 }, { 1, 0 })
        editor.submit_latest_prompt("Explain this")

        local response_window = vim.api.nvim_get_current_win()
        local response_buffer = vim.api.nvim_win_get_buf(response_window)
        local parser = vim.treesitter.get_parser(response_buffer, "markdown")
        parser:parse(true)
        local captures = vim.treesitter.get_captures_at_pos(response_buffer, 0, 0)
        assert.is_true(vim.iter(captures):any(function(capture)
            return capture.capture == "conceal"
        end))

        for key, wrapped_key in pairs({ j = "gj", k = "gk", ["0"] = "g0", ["^"] = "g^", ["$"] = "g$" }) do
            assert.same(wrapped_key, vim.fn.maparg(key, "n", false, true).rhs)
        end

        assert.same(response_buffer, vim.api.nvim_win_get_buf(response_window))
    end)
end)
