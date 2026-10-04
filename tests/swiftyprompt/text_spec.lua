local swiftyprompt = require("swiftyprompt")

describe("SwiftPrompt text behavior", function()
    it("splits empty, single-line, and multi-line responses", function()
        assert.same({ "" }, swiftyprompt.split_response_lines(""))
        assert.same({ "one line" }, swiftyprompt.split_response_lines("one line"))
        assert.same({ "one", "two", "three" }, swiftyprompt.split_response_lines("one\ntwo\nthree"))
    end)

    it("normalizes Windows and classic Mac newlines", function()
        assert.same({ "one", "two", "three" }, swiftyprompt.split_response_lines("one\r\ntwo\r\nthree"))
        assert.same({ "one", "two", "three" }, swiftyprompt.split_response_lines("one\rtwo\rthree"))
    end)

    it("preserves blank lines and trailing newlines in responses", function()
        assert.same({ "one", "", "two", "", "" }, swiftyprompt.split_response_lines("one\n\ntwo\n\n"))
    end)

    it("cycles thinking-status frames without changing its message", function()
        assert.same("◜  Codex is thinking", swiftyprompt.thinking_status_text(1))
        assert.same("◠  Codex is thinking", swiftyprompt.thinking_status_text(2))
        assert.same("◜  Codex is thinking", swiftyprompt.thinking_status_text(7))
    end)
end)
