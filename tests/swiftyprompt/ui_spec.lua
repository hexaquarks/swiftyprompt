local ui = require("swiftyprompt.ui")

describe("SwiftyPrompt panel chrome", function()
    local panel

    after_each(function()
        if panel then
            ui.detach(panel)
            for _, window in ipairs({ panel.body_window, panel.frame_window }) do
                if vim.api.nvim_win_is_valid(window) then
                    vim.api.nvim_win_close(window, true)
                end
            end
            panel = nil
        end
    end)

    local function open_panel(kind, question, model)
        panel = ui.open(vim.api.nvim_create_buf(false, true), {
            kind = kind,
            body_height = 3,
            row = 1,
            source_window = vim.api.nvim_get_current_win(),
            anchor_line = 0,
            anchor_column = 0,
            context = "config.lua",
            question = question,
            model = model or "gpt-6-luna",
        })
        return panel
    end

    local function chrome_at(row)
        local marks = vim.api.nvim_buf_get_extmarks(panel.frame_buffer,
            vim.api.nvim_create_namespace("swiftyprompt.ui"), { row, 0 }, { row, -1 }, { details = true })
        local text = ""
        for _, mark in ipairs(marks) do
            for _, chunk in ipairs(mark[4].virt_text or {}) do
                text = text .. chunk[1]
            end
        end
        return text
    end

    it("truncates overflow and keeps exact-width text intact", function()
        assert.same("12345678", ui.truncate("12345678", 8))
        assert.same("12345...", ui.truncate("123456789", 8))
        assert.same("short...", ui.truncate("short", 20, true))
        assert.same("..", ui.truncate("long", 2))
    end)

    it("fits Unicode by display width without splitting characters", function()
        local text = ui.truncate("你好世界你好世界", 10)
        assert.same("你好世...", text)
        assert.is_true(vim.fn.strdisplaywidth(text) <= 10)
        assert.same("café", ui.truncate("café", 4))
    end)

    it("shows the question in fixed chrome above the answer body", function()
        open_panel("response", "What does setup() override?")
        assert.same("You · What does setup() override?", chrome_at(0))
        local body_config = vim.api.nvim_win_get_config(panel.body_window)
        assert.same(panel.frame_window, body_config.win)
        assert.same(2, body_config.row)
        assert.is_false(vim.api.nvim_win_get_config(panel.frame_window).focusable)
        assert.same("", vim.api.nvim_buf_get_lines(panel.frame_buffer, 0, 1, false)[1])
    end)

    it("truncates long and multiline questions with three dots", function()
        open_panel("response", string.rep("a", 100))
        assert.matches("%.%.%.$", chrome_at(0))
        assert.is_true(vim.fn.strdisplaywidth(chrome_at(0)) <= 58)
        ui.update(panel, 3, "First line\nSecond line")
        assert.same("You · First line...", chrome_at(0))
        ui.update(panel, 3, "100% %{danger()}\tworks")
        assert.same("You · 100% %{danger()} works", chrome_at(0))
    end)

    it("lays out input controls and the model on one footer row", function()
        open_panel("input")
        local footer = chrome_at(4)
        assert.matches("^Enter send · Esc cancel", footer)
        assert.matches("gpt%-6%-luna$", footer)
        assert.same(58, vim.fn.strdisplaywidth(footer))
        assert.same(0, vim.api.nvim_win_get_config(panel.body_window).row)
    end)

    it("keeps response controls visible and right-aligns long model labels", function()
        open_panel("response", "Question", string.rep("long-model-", 8))
        local footer = chrome_at(6)
        assert.matches("^f follow%-up · gY copy · q close", footer)
        assert.matches("%.%.%.$", footer)
        assert.same(58, vim.fn.strdisplaywidth(footer))
        ui.update(panel, 10, "Updated question")
        assert.same("You · Updated question", chrome_at(0))
        assert.same(footer, chrome_at(13))
    end)

    it("uses its own dark palette without changing editor colors", function()
        local editor_normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
        open_panel("input")
        assert.matches("Normal:SwiftyPromptNormal", vim.wo[panel.body_window].winhighlight)
        assert.same(0x101619, vim.api.nvim_get_hl(0, { name = "SwiftyPromptNormal" }).bg)
        assert.same(0x48e9f1, vim.api.nvim_get_hl(0, { name = "SwiftyPromptAccent" }).fg)
        assert.same(editor_normal, vim.api.nvim_get_hl(0, { name = "Normal", link = false }))
    end)

    it("restores the panel palette after a colorscheme change", function()
        vim.api.nvim_set_hl(0, "SwiftyPromptAccent", { fg = "#ffffff" })
        vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "test" })
        assert.same(0x48e9f1, vim.api.nvim_get_hl(0, { name = "SwiftyPromptAccent" }).fg)
    end)

    it("restores card dimensions after a cursor handler enlarges its windows", function()
        open_panel("response", "Question")
        vim.api.nvim_create_autocmd("CursorMoved", {
            buffer = vim.api.nvim_win_get_buf(panel.body_window),
            once = true,
            callback = function()
                vim.api.nvim_win_set_height(panel.frame_window, 40)
                vim.api.nvim_win_set_height(panel.body_window, 40)
            end,
        })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(panel.body_window) })
        assert.is_true(vim.wait(200, function()
            return vim.api.nvim_win_get_height(panel.frame_window) == 7
                and vim.api.nvim_win_get_height(panel.body_window) == 3
        end))
        assert.same(60, vim.api.nvim_win_get_width(panel.frame_window))
        assert.same(58, vim.api.nvim_win_get_width(panel.body_window))
    end)

    it("keeps resizing guards from touching a dismissed card", function()
        open_panel("response", "Question")
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(panel.body_window) })
        ui.detach(panel)
        vim.api.nvim_win_close(panel.body_window, true)
        vim.api.nvim_win_close(panel.frame_window, true)
        assert.has_no.errors(function()
            vim.wait(20)
        end)
        assert.same({}, vim.api.nvim_get_autocmds({ id = panel.layout_autocmd }))
    end)
end)
