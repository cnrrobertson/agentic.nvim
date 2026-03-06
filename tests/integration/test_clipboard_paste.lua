local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Clipboard paste in widget input", function()
    local child = Child:new()

    before_each(function()
        child.setup()
        child.cmd([[ edit tests/init.lua ]])
        child.lua([[ require("agentic").toggle() ]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    it("pasting plain text inserts text into the input buffer", function()
        -- Set system clipboard register to plain text
        child.lua([[ vim.fn.setreg("+", "hello world") ]])

        -- Focus input window and enter insert mode
        child.lua([[
            local session = require("agentic.session_registry").get_session_for_tab_page()
            vim.api.nvim_set_current_win(session.widget.win_nrs.input)
        ]])
        child.cmd("startinsert")

        -- Trigger the paste_image keymap (<C-v> in insert mode) which should
        -- fall back to text paste since there is no image in clipboard
        child.lua([[
            -- Directly invoke the same fallback path: no image -> paste text from register
            local lines = vim.split(vim.fn.getreg("+"), "\n", { plain = true })
            vim.paste(lines, -1)
        ]])
        child.flush()

        local input_lines = child.lua([[
            local session = require("agentic.session_registry").get_session_for_tab_page()
            return vim.api.nvim_buf_get_lines(session.widget.buf_nrs.input, 0, -1, false)
        ]])

        assert.is_true(vim.tbl_contains(input_lines, "hello world"))
    end)

    it(
        "pasting a valid file path adds it to the file list instead of inserting text",
        function()
            local abs_path = vim.fn.fnamemodify("tests/init.lua", ":p")

            -- Set system clipboard to an absolute file path
            child.lua(
                string.format([[ vim.fn.setreg("+", "%s") ]], abs_path)
            )

            child.lua([[
                local session = require("agentic.session_registry").get_session_for_tab_page()
                vim.api.nvim_set_current_win(session.widget.win_nrs.input)
            ]])

            -- Simulate what vim.paste override does when receiving a file path
            child.lua(
                string.format(
                    [[ vim.paste({ "%s" }, -1) ]],
                    abs_path
                )
            )
            child.flush()

            local files_list = child.lua([[
                local session = require("agentic.session_registry").get_session_for_tab_page()
                return session.file_list:get_files()
            ]])

            assert.is_true(vim.tbl_contains(files_list, abs_path))

            -- Input buffer should NOT contain the file path as text
            local input_lines = child.lua([[
                local session = require("agentic.session_registry").get_session_for_tab_page()
                return vim.api.nvim_buf_get_lines(session.widget.buf_nrs.input, 0, -1, false)
            ]])
            local joined = table.concat(input_lines, "\n")
            assert.is_false(joined:find(abs_path, 1, true) ~= nil)
        end
    )

    it(
        "pasting a non-existent path falls back to inserting as text",
        function()
            local fake_path = "/this/path/does/not/exist.lua"

            child.lua([[
                local session = require("agentic.session_registry").get_session_for_tab_page()
                vim.api.nvim_set_current_win(session.widget.win_nrs.input)
            ]])
            child.cmd("startinsert")

            child.lua(
                string.format([[ vim.paste({ "%s" }, -1) ]], fake_path)
            )
            child.flush()

            local input_lines = child.lua([[
                local session = require("agentic.session_registry").get_session_for_tab_page()
                return vim.api.nvim_buf_get_lines(session.widget.buf_nrs.input, 0, -1, false)
            ]])

            assert.is_true(
                vim.tbl_contains(input_lines, fake_path)
            )
        end
    )

    it(
        "pasting multiline text inserts all lines into input buffer",
        function()
            child.lua([[
                local session = require("agentic.session_registry").get_session_for_tab_page()
                vim.api.nvim_set_current_win(session.widget.win_nrs.input)
            ]])
            child.cmd("startinsert")

            child.lua([[ vim.paste({ "line one", "line two", "line three" }, -1) ]])
            child.flush()

            local input_lines = child.lua([[
                local session = require("agentic.session_registry").get_session_for_tab_page()
                return vim.api.nvim_buf_get_lines(session.widget.buf_nrs.input, 0, -1, false)
            ]])

            assert.is_true(vim.tbl_contains(input_lines, "line one"))
            assert.is_true(vim.tbl_contains(input_lines, "line two"))
            assert.is_true(vim.tbl_contains(input_lines, "line three"))
        end
    )
end)
