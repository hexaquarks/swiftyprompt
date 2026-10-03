local M = {}

-- A separate filetype prevents the user's Markdown editing configuration from
-- attaching first and enabling cursor-line anti-conceal in this read-only view.
M.filetype = "swiftyprompt_markdown"
vim.treesitter.language.register("markdown", M.filetype)

local response_render_options = {
    enabled = true,
    render_modes = true,
    debounce = 0,
    anti_conceal = { enabled = false },
    sign = { enabled = false },
    heading = { icons = {}, width = "block" },
    code = { language_icon = false, width = "block" },
    bullet = { icons = { "•", "◦", "▪" } },
    win_options = {
        conceallevel = { default = 2, rendered = 2 },
        concealcursor = { default = "nvic", rendered = "nvic" },
    },
}

local function warn_once(buffer_id, message)
    if vim.b[buffer_id].swiftyprompt_render_warning then
        return
    end

    vim.b[buffer_id].swiftyprompt_render_warning = true
    vim.notify(message, vim.log.levels.WARN)
end

local function start_markdown_parser(buffer_id)
    for _, language in ipairs({ "markdown", "markdown_inline" }) do
        if not vim.treesitter.language.add(language) then
            return false
        end
    end

    vim.treesitter.start(buffer_id, "markdown")
    return true
end

local function attach_response_events(buffer_id)
    if vim.b[buffer_id].swiftyprompt_render_attached then
        return
    end

    vim.b[buffer_id].swiftyprompt_render_attached = true
    vim.api.nvim_create_autocmd({ "CursorMoved", "BufWinEnter" }, {
        buffer = buffer_id,
        callback = function()
            for _, window_id in ipairs(vim.fn.win_findbuf(buffer_id)) do
                M.render(buffer_id, window_id)
            end
        end,
        desc = "Render Markdown as the response viewport changes",
    })
end

function M.render(buffer_id, window_id)
    local available, renderer = pcall(require, "render-markdown")
    if not available then
        warn_once(buffer_id, "SwiftPrompt: install render-markdown.nvim to format responses")
        return
    end

    renderer.setup()
    local parser_started, parser_available = pcall(start_markdown_parser, buffer_id)
    if not parser_started or not parser_available then
        warn_once(buffer_id, "SwiftPrompt: install the markdown and markdown_inline Tree-sitter parsers")
        return
    end
    attach_response_events(buffer_id)
    renderer.render({
        buf = buffer_id,
        win = window_id,
        config = response_render_options,
    })
end

return M
