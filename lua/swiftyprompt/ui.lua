local M = {}

M.width = 60
M.body_width = M.width - 2
M.input_height = 3
M.response_offset = 2

function M.max_response_body_height()
    -- Budget the entire card: question, spacer, footer, divider, and borders.
    local card_height = math.min(22, math.floor((vim.o.lines - vim.o.cmdheight) * 0.6))
    return math.max(card_height - M.response_offset - 4, 1)
end

local namespace = vim.api.nvim_create_namespace("swiftyprompt.ui")
local colors = {
    background = "#101619",
    foreground = "#e6edf3",
    accent = "#48e9f1",
    context = "#82baff",
    muted = "#8b9aaa",
    border = "#88a7bd",
    separator = "#2b3942",
    code = "#141e24",
}

local function define_highlights()
    for name, options in pairs({
        Normal = { fg = colors.foreground, bg = colors.background },
        Border = { fg = colors.border, bg = colors.background },
        Accent = { fg = colors.accent, bg = colors.background },
        Context = { fg = colors.context, bg = colors.background },
        Muted = { fg = colors.muted, bg = colors.background },
        Separator = { fg = colors.separator, bg = colors.background },
        Code = { bg = colors.code },
        CodeBorder = { fg = colors.separator, bg = colors.code },
        String = { fg = "#83ed9b" },
        Keyword = { fg = "#ed8bd2" },
        Function = { fg = colors.context },
        Property = { fg = "#ed8bd2" },
    }) do
        vim.api.nvim_set_hl(0, "SwiftyPrompt" .. name, options)
    end
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("SwiftyPromptTheme", { clear = true }),
    callback = define_highlights,
    desc = "Restore SwiftyPrompt panel colors after a colorscheme change",
})

-- Work in display cells so CJK text and multibyte names fit the actual panel.
function M.truncate(text, width, force_ellipsis)
    if not force_ellipsis and vim.fn.strdisplaywidth(text) <= width then
        return text
    end

    local suffix = string.rep(".", math.min(width, 3))
    local result = ""
    for index = 0, vim.fn.strchars(text) - 1 do
        local character = vim.fn.strcharpart(text, index, 1)
        if vim.fn.strdisplaywidth(result .. character) > width - #suffix then
            break
        end
        result = result .. character
    end
    return result .. suffix
end

function M.title(context)
    return {
        { " SwiftyPrompt ", "SwiftyPromptAccent" },
        { "· ", "SwiftyPromptMuted" },
        { M.truncate(context, M.width - 18), "SwiftyPromptContext" },
        { " ", "SwiftyPromptNormal" },
    }
end

local function panel_options(window)
    vim.wo[window].winfixbuf = true
    vim.wo[window].winblend = 0
    vim.wo[window].winhighlight = table.concat({
        "Normal:SwiftyPromptNormal",
        "NormalNC:SwiftyPromptNormal",
        "EndOfBuffer:SwiftyPromptNormal",
        "FloatBorder:SwiftyPromptBorder",
        "FloatTitle:SwiftyPromptAccent",
        "CursorLine:SwiftyPromptNormal",
        "RenderMarkdownCode:SwiftyPromptCode",
        "RenderMarkdownCodeBorder:SwiftyPromptCodeBorder",
        "@string:SwiftyPromptString",
        "@string.lua:SwiftyPromptString",
        "@keyword:SwiftyPromptKeyword",
        "@keyword.lua:SwiftyPromptKeyword",
        "@function:SwiftyPromptFunction",
        "@function.call.lua:SwiftyPromptFunction",
        "@property.lua:SwiftyPromptProperty",
    }, ",")
end

local function footer_chunks(kind, model)
    local controls
    if kind == "input" then
        controls = {
            { "Enter", "SwiftyPromptAccent" }, { " send · ", "SwiftyPromptMuted" },
            { "Esc", "SwiftyPromptAccent" }, { " cancel", "SwiftyPromptMuted" },
        }
    else
        controls = {
            { "f", "SwiftyPromptAccent" }, { " follow-up · ", "SwiftyPromptMuted" },
            { "gY", "SwiftyPromptAccent" }, { " copy · ", "SwiftyPromptMuted" },
            { "q", "SwiftyPromptAccent" }, { " close", "SwiftyPromptMuted" },
        }
    end

    local controls_width = 0
    for _, chunk in ipairs(controls) do
        controls_width = controls_width + vim.fn.strdisplaywidth(chunk[1])
    end
    model = M.truncate(model, M.body_width - controls_width - 1)
    table.insert(controls, { string.rep(" ", M.body_width - controls_width - vim.fn.strdisplaywidth(model)),
        "SwiftyPromptNormal" })
    table.insert(controls, { model, "SwiftyPromptAccent" })
    return controls
end

local function frame_config(panel)
    return {
        relative = "win",
        win = panel.source_window,
        bufpos = { panel.anchor_line, panel.anchor_column },
        anchor = "NW",
        width = M.width,
        height = panel.body_height + panel.body_offset + 2,
        row = panel.row,
        col = 0,
        style = "minimal",
        border = "rounded",
        title = M.title(panel.context),
        focusable = false,
        zindex = 50,
    }
end

local function body_config(panel)
    return {
        relative = "win",
        win = panel.frame_window,
        anchor = "NW",
        width = M.body_width,
        height = panel.body_height,
        row = panel.body_offset,
        col = 1,
        style = "minimal",
        border = "none",
        zindex = 51,
    }
end

local function restore_dimensions(panel)
    local frame_height = panel.body_height + panel.body_offset + 2
    if vim.api.nvim_win_get_height(panel.frame_window) ~= frame_height
        or vim.api.nvim_win_get_width(panel.frame_window) ~= M.width
    then
        vim.api.nvim_win_set_config(panel.frame_window, frame_config(panel))
    end
    if vim.api.nvim_win_get_height(panel.body_window) ~= panel.body_height
        or vim.api.nvim_win_get_width(panel.body_window) ~= M.body_width
    then
        vim.api.nvim_win_set_config(panel.body_window, body_config(panel))
    end
end

local function write_chrome(panel)
    local height = panel.body_height + panel.body_offset + 2
    local lines = {}
    for row = 1, height do
        lines[row] = ""
    end
    lines[height - 1] = string.rep("─", M.width)

    vim.bo[panel.frame_buffer].modifiable = true
    vim.api.nvim_buf_set_lines(panel.frame_buffer, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(panel.frame_buffer, namespace, 0, -1)
    vim.api.nvim_buf_set_extmark(panel.frame_buffer, namespace, height - 2, 0, {
        line_hl_group = "SwiftyPromptSeparator",
    })
    vim.api.nvim_buf_set_extmark(panel.frame_buffer, namespace, height - 1, 0, {
        virt_text = footer_chunks(panel.kind, panel.model),
        virt_text_win_col = 1,
    })

    if panel.kind == "response" then
        local question = panel.question or ""
        local first_line = question:match("^[^\r\n]*"):gsub("\t", " ")
        local summary = M.truncate(first_line, M.body_width - 6, question:find("[\r\n]") ~= nil)
        vim.api.nvim_buf_set_extmark(panel.frame_buffer, namespace, 0, 0, {
            virt_text = {
                { "You", "SwiftyPromptNormal" },
                { " · " .. summary, "SwiftyPromptMuted" },
            },
            virt_text_win_col = 1,
        })
    end
    vim.bo[panel.frame_buffer].modifiable = false
    vim.bo[panel.frame_buffer].modified = false
end

function M.open(buffer, options)
    local panel = vim.tbl_extend("force", options, {
        body_offset = options.kind == "response" and M.response_offset or 0,
    })
    panel.frame_buffer = vim.api.nvim_create_buf(false, true)
    vim.bo[panel.frame_buffer].bufhidden = "wipe"
    write_chrome(panel)
    panel.frame_window = vim.api.nvim_open_win(panel.frame_buffer, false, frame_config(panel))
    panel_options(panel.frame_window)
    panel.body_window = vim.api.nvim_open_win(buffer, true, body_config(panel))
    panel_options(panel.body_window)
    vim.wo[panel.body_window].wrap = true
    panel.layout_autocmd = vim.api.nvim_create_autocmd({ "CursorMoved", "WinResized" }, {
        callback = function(event)
            if event.event == "CursorMoved" and vim.api.nvim_get_current_win() ~= panel.body_window then
                return
            end
            if panel.layout_pending then
                return
            end
            panel.layout_pending = true
            -- Run after other cursor/renderer handlers: only content changes
            -- and terminal resizing should change a card's intended dimensions.
            vim.schedule(function()
                panel.layout_pending = false
                if panel.closed or not vim.api.nvim_win_is_valid(panel.frame_window)
                    or not vim.api.nvim_win_is_valid(panel.body_window)
                then
                    return
                end
                restore_dimensions(panel)
            end)
        end,
        desc = "Keep SwiftyPrompt card dimensions stable during navigation",
    })
    return panel
end

function M.detach(panel)
    if not panel or panel.closed then
        return
    end
    panel.closed = true
    vim.api.nvim_del_autocmd(panel.layout_autocmd)
end

function M.update(panel, body_height, question)
    panel.body_height = body_height
    panel.question = question
    vim.api.nvim_win_set_config(panel.frame_window, frame_config(panel))
    vim.api.nvim_win_set_config(panel.body_window, body_config(panel))
    write_chrome(panel)
end

return M
