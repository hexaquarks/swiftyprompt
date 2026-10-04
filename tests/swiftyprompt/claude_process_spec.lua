local claude = require("swiftyprompt.connectors.claude")

describe("Claude process transport", function()
    local command

    before_each(function()
        command = vim.fn.tempname()
        -- Exercise actual Neovim pipes without Claude installation or credentials.
        vim.fn.writefile({
            "#!/bin/sh",
            "resume=",
            'while [ "$#" -gt 0 ]; do',
            '    if [ "$1" = "--resume" ]; then',
            "        shift",
            "        resume=$1",
            "    fi",
            "    shift",
            "done",
            "prompt=$(cat)",
            'if [ -n "$resume" ]; then',
            '    [ "$resume" = "fixture-session" ] || exit 2',
            '    [ "$prompt" = "Question: Follow-up" ] || exit 3',
            "else",
            '    case "$prompt" in',
            '        *"Selected code:"*"local value = 1"*"Question: Explain this"*) ;;',
            "        *) exit 4 ;;",
            "    esac",
            "fi",
            "printf '%s\\n' '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"fixture-session\"}'",
            "printf '%s\\n' '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Fixture answer\"}}}'",
            "printf '%s' '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"Fixture answer\",\"session_id\":\"fixture-session\"}'",
        }, command)
        assert.equals(1, vim.fn.setfperm(command, "rwx------"))
    end)

    after_each(function()
        vim.fn.delete(command)
    end)

    it("streams and completes through real pipes, then resumes the returned session", function()
        local options = { command = command, model = "fixture-model", auth = "claude_login" }
        local updates = {}
        local completion
        local request = claude.ask(options, "Explain this", "local value = 1", nil, {
            on_update = function(text)
                table.insert(updates, text)
            end,
            on_complete = function(text, failure, session_id)
                completion = { text = text, failure = failure, session_id = session_id }
            end,
        })
        local finished = vim.wait(3000, function() return completion ~= nil end, 10)
        if not finished then
            claude.cancel(request)
        end
        assert.is_true(finished)
        assert.same({ "Fixture answer" }, updates)
        assert.same({ text = "Fixture answer", session_id = "fixture-session" }, completion)

        local resumed
        request = claude.ask(options, "Follow-up", "local value = 1", completion.session_id,
            function(text, failure, session_id)
                resumed = { text = text, failure = failure, session_id = session_id }
            end)
        finished = vim.wait(3000, function() return resumed ~= nil end, 10)
        if not finished then
            claude.cancel(request)
        end
        assert.is_true(finished)
        assert.same(completion, resumed)
    end)
end)
