local markdown = require("swiftyprompt.markdown")

describe("SwiftPrompt Markdown rendering", function()
    local buffer_id
    local window_id
    local original_start
    local original_language_add
    local original_notify
    local original_require

    before_each(function()
        original_start = vim.treesitter.start
        original_language_add = vim.treesitter.language.add
        original_notify = vim.notify
        original_require = require
        buffer_id = vim.api.nvim_create_buf(false, true)
        vim.bo[buffer_id].filetype = markdown.filetype
        window_id = vim.api.nvim_open_win(buffer_id, true, {
            relative = "editor",
            row = 1,
            col = 1,
            width = 60,
            height = 12,
            style = "minimal",
            border = "rounded",
        })
    end)

    after_each(function()
        vim.treesitter.start = original_start
        vim.treesitter.language.add = original_language_add
        vim.notify = original_notify
        _G.require = original_require
        if vim.api.nvim_win_is_valid(window_id) then
            vim.api.nvim_win_close(window_id, true)
        end
        if vim.api.nvim_buf_is_valid(buffer_id) then
            vim.api.nvim_buf_delete(buffer_id, { force = true })
        end
    end)

    local function render_marks(predicate)
        markdown.render(buffer_id, window_id)
        local namespace = vim.api.nvim_create_namespace("render-markdown.nvim")
        assert.is_true(vim.wait(1000, function()
            local marks = vim.api.nvim_buf_get_extmarks(buffer_id, namespace, 0, -1, { details = true })
            return #marks > 0 and (not predicate or predicate(marks))
        end))
        return vim.api.nvim_buf_get_extmarks(buffer_id, namespace, 0, -1, { details = true })
    end

    local function has_bullet(marks)
        for _, mark in ipairs(marks) do
            for _, chunk in ipairs(mark[4].virt_text or {}) do
                if chunk[1]:find("•", 1, true) then
                    return true
                end
            end
        end
        return false
    end

    it("renders bullets and keeps them rendered on the cursor line", function()
        vim.api.nvim_buf_set_lines(buffer_id, 0, -1, false, { "Introduction", "- `code` and **bold**" })
        assert.is_true(has_bullet(render_marks(has_bullet)))

        vim.api.nvim_win_set_cursor(window_id, { 2, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buffer_id })
        assert.is_true(has_bullet(render_marks(has_bullet)))
        assert.same("nvic", vim.wo[window_id].concealcursor)

        local renderer_config = require("render-markdown.state").get(buffer_id)
        assert.is_false(renderer_config.anti_conceal.enabled)
    end)

    it("renders headings, fenced code, and tables without changing response text", function()
        local response_lines = {
            "# Heading",
            "",
            "```lua",
            "local value = 1",
            "```",
            "",
            "| Name | Value |",
            "| ---- | ----- |",
            "| test | 1 |",
        }
        vim.api.nvim_buf_set_lines(buffer_id, 0, -1, false, response_lines)
        local decorated_rows = {}
        for _, mark in ipairs(render_marks()) do
            decorated_rows[mark[2]] = true
        end
        assert.is_true(decorated_rows[0]) -- heading
        assert.is_true(decorated_rows[3]) -- code content
        assert.is_true(decorated_rows[6]) -- table header
        assert.same(response_lines, vim.api.nvim_buf_get_lines(buffer_id, 0, -1, false))
    end)

    it("updates rendering when a streamed response replaces the buffer text", function()
        vim.api.nvim_buf_set_lines(buffer_id, 0, -1, false, { "# Starting" })
        render_marks()

        vim.api.nvim_buf_set_lines(buffer_id, 0, -1, false, { "- Complete response" })
        assert.is_true(has_bullet(render_marks(has_bullet)))
    end)

    it("renders newly visible Markdown through the cursor event", function()
        local response_lines = { "# Introduction" }
        for line_number = 2, 40 do
            response_lines[line_number] = "Plain response text"
        end
        response_lines[40] = "- Newly visible bullet"
        vim.api.nvim_buf_set_lines(buffer_id, 0, -1, false, response_lines)
        assert.is_false(has_bullet(render_marks()))

        vim.api.nvim_win_set_cursor(window_id, { 40, 0 })
        vim.cmd("normal! zb")
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buffer_id })

        local namespace = vim.api.nvim_create_namespace("render-markdown.nvim")
        assert.is_true(vim.wait(1000, function()
            local marks = vim.api.nvim_buf_get_extmarks(buffer_id, namespace, 0, -1, { details = true })
            return has_bullet(marks)
        end))
    end)

    it("keeps responses readable when starting the parser throws", function()
        vim.api.nvim_buf_set_lines(buffer_id, 0, -1, false, { "Readable response" })
        vim.treesitter.start = function()
            error("parser unavailable")
        end
        local warning
        vim.notify = function(message)
            warning = message
        end

        assert.has_no.errors(function()
            markdown.render(buffer_id, window_id)
        end)
        assert.matches("install the markdown and markdown_inline", warning)
        assert.same({ "Readable response" }, vim.api.nvim_buf_get_lines(buffer_id, 0, -1, false))
    end)

    it("preserves literal Markdown markers inside inline code", function()
        vim.api.nvim_buf_set_lines(buffer_id, 0, -1, false, { "- `snake_case_value`" })
        render_marks(has_bullet)

        local function is_concealed(column)
            return vim.iter(vim.treesitter.get_captures_at_pos(buffer_id, 0, column)):any(function(capture)
                return capture.capture == "conceal"
            end)
        end

        assert.is_true(is_concealed(2)) -- opening backtick
        assert.is_false(is_concealed(8)) -- literal underscore inside code
        assert.is_false(is_concealed(13)) -- another literal underscore
        assert.is_true(is_concealed(19)) -- closing backtick
    end)

    for _, missing_language in ipairs({ "markdown", "markdown_inline" }) do
        it("preserves plain text when " .. missing_language .. " cannot be loaded", function()
            vim.api.nvim_buf_set_lines(buffer_id, 0, -1, false, { "Readable response" })
            vim.treesitter.language.add = function(language)
                return language ~= missing_language
            end
            local parser_started = false
            vim.treesitter.start = function()
                parser_started = true
            end
            local warnings = {}
            vim.notify = function(message)
                table.insert(warnings, message)
            end

            markdown.render(buffer_id, window_id)
            markdown.render(buffer_id, window_id)

            assert.is_false(parser_started)
            assert.same({ "SwiftPrompt: install the markdown and markdown_inline Tree-sitter parsers" }, warnings)
            assert.same({ "Readable response" }, vim.api.nvim_buf_get_lines(buffer_id, 0, -1, false))
        end)
    end

    it("warns once and preserves the response when the renderer is unavailable", function()
        vim.api.nvim_buf_set_lines(buffer_id, 0, -1, false, { "Readable response" })
        _G.require = function(module_name)
            if module_name == "render-markdown" then
                error("renderer unavailable")
            end
            return original_require(module_name)
        end
        local warnings = {}
        vim.notify = function(message)
            table.insert(warnings, message)
        end

        markdown.render(buffer_id, window_id)
        markdown.render(buffer_id, window_id)

        assert.same({ "SwiftPrompt: install render-markdown.nvim to format responses" }, warnings)
        assert.same({ "Readable response" }, vim.api.nvim_buf_get_lines(buffer_id, 0, -1, false))
    end)
end)
