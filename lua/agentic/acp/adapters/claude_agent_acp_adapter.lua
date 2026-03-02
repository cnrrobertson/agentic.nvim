local ACPClient = require("agentic.acp.acp_client")
local ClaudeACPAdapter = require("agentic.acp.adapters.claude_acp_adapter")
local FileSystem = require("agentic.utils.file_system")

--- Adapter for claude-agent-acp, which is the renamed @zed-industries/claude-code-acp
--- package but backed by the Claude Agent SDK.
---
--- Protocol difference vs claude-code-acp:
---   claude-code-acp sends two consecutive tool_call events per tool use:
---     1. tool_call  rawInput={}       (skipped by ClaudeACPAdapter guard)
---     2. tool_call  rawInput={…data}  (rendered by ClaudeACPAdapter)
---
---   claude-agent-acp sends one tool_call then one tool_call_update per tool use:
---     1. tool_call        rawInput={}       status="pending"  (streaming not done)
---     2. tool_call_update rawInput={…data}  status=nil        (streaming complete)
---     3. tool_call_update                   status="completed"|"failed"
---
---   The ClaudeACPAdapter guard (`if rawInput empty → return`) drops step 1, and
---   the base handler guard (`if not status → return`) drops step 2, so nothing
---   ever reaches the buffer. This adapter fixes both.
---
--- @class agentic.acp.ClaudeAgentACPAdapter : agentic.acp.ClaudeACPAdapter
local ClaudeAgentACPAdapter = setmetatable({}, { __index = ClaudeACPAdapter })
ClaudeAgentACPAdapter.__index = ClaudeAgentACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.ClaudeAgentACPAdapter
function ClaudeAgentACPAdapter:new(config, on_ready)
    self = ClaudeACPAdapter.new(ClaudeACPAdapter, config, on_ready)
    self = setmetatable(self, ClaudeAgentACPAdapter) --[[@as agentic.acp.ClaudeAgentACPAdapter]]
    return self
end

--- @protected
--- @param session_id string
--- @param update agentic.acp.ClaudeToolCallMessage
function ClaudeAgentACPAdapter:__handle_tool_call(session_id, update)
    -- Step 1: claude-agent-acp sends the initial tool_call during streaming before
    -- the tool input has arrived, so rawInput is empty. Render a placeholder
    -- immediately using kind and title (always set from the tool name). The
    -- subsequent no-status tool_call_update will fill in the real content.
    if not update.rawInput or vim.tbl_isempty(update.rawInput) then
        --- @type agentic.ui.MessageWriter.ToolCallBlock
        local message = {
            tool_call_id = update.toolCallId,
            kind = update.kind or "other",
            status = update.status,
            argument = update.title or "",
        }
        self:__with_subscriber(session_id, function(subscriber)
            subscriber.on_tool_call(message)
        end)
        return
    end

    -- rawInput is already populated (arrives via the permission request path).
    -- Delegate to parent for full content extraction.
    ClaudeACPAdapter.__handle_tool_call(self, session_id, update)
end

--- @protected
--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function ClaudeAgentACPAdapter:__handle_tool_call_update(session_id, update)
    -- Cast early so LuaLS knows about Claude-specific rawInput on this message type.
    local claude_update = update --[[@as agentic.acp.ClaudeToolCallMessage]]

    -- Standard path: has status, or no rawInput data — delegate to base.
    if claude_update.status or not claude_update.rawInput or vim.tbl_isempty(claude_update.rawInput) then
        ACPClient.__handle_tool_call_update(self, session_id, update)
        return
    end

    -- Step 2: no-status refinement update — rawInput is now fully populated after
    -- streaming completed. Update the placeholder block with the real content.
    -- Status is intentionally absent so MessageWriter preserves the existing
    -- "pending" status via tbl_deep_extend.
    local raw = claude_update.rawInput --[[@as agentic.acp.ClaudeRawInput]]

    local kind = claude_update.kind
    if kind == "think" and raw.subagent_type then
        kind = "SubAgent"
    end

    local message = {
        tool_call_id = claude_update.toolCallId,
        kind = kind,
        argument = claude_update.title or "",
    }

    if kind == "read" or kind == "edit" then
        message.argument = FileSystem.to_smart_path(raw.file_path)

        if kind == "edit" then
            local new_string = raw.content or raw.new_string
            local old_string = raw.old_string

            message.diff = {
                new = self:safe_split(new_string),
                old = self:safe_split(old_string),
                all = raw.replace_all or false,
            }
        end
    elseif kind == "fetch" then
        if raw.query then
            message.kind = "WebSearch"
            message.argument = raw.query
        elseif raw.url then
            message.argument = raw.url

            if raw.prompt then
                message.argument =
                    string.format("%s %s", message.argument, raw.prompt)
            end
        else
            message.argument = "unknown fetch"
        end
    elseif kind == "SubAgent" then
        message.argument = string.format(
            "%s, %s: %s",
            raw.model or "default",
            raw.subagent_type or "",
            raw.description or ""
        )

        if raw.prompt then
            message.body = self:safe_split(raw.prompt)
        end
    elseif kind == "other" then
        if claude_update.title == "SlashCommand" then
            message.kind = "SlashCommand"
        elseif claude_update.title == "Skill" then
            message.kind = "Skill"
            message.argument = raw.skill or "unknown skill"

            if raw.args then
                message.body = self:safe_split(raw.args)
            end
        end
    else
        local command = raw.command
        if type(command) == "table" then
            command = table.concat(command, " ")
        end
        message.argument = command or claude_update.title or ""
        message.body = self:extract_content_body(claude_update)
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(
            message --[[@as agentic.ui.MessageWriter.ToolCallBase]]
        )
    end)
end

return ClaudeAgentACPAdapter
