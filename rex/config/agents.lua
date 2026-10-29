-- Agent workflow for Rex: worktree tasks, agent history, token usage, and
-- jumping to the agent that needs you. Loaded from init.lua with
-- require("agents"). The commands it runs are installed in ~/.local/bin.

local shell = "com.superlogical.terminal.shell"
local terminal = "com.superlogical.terminal"
local bin = os.getenv("HOME") .. "/.local/bin/"

-- Opens COMMAND in a floating layer over the current window. The layer
-- closes when the command exits.
local function overlay(command, bounds)
  local _, err = rex.session.new_layer{
    bounds = bounds or { 0.1, 0.08, 0.8, 0.84 },
    focus = true,
    layout = rex.layout.block{ flavor = shell, options = { command = command } },
  }
  if err ~= nil then error(err, 0) end
end

-- The directory of the focused terminal, if its shell reports one.
local function focused_dir(ctx)
  if ctx.block_id == nil then return nil end
  local r = rex.block.call(terminal, "pwd", { block_id = ctx.block_id })
  local url = r and r.pwd
  if url == nil or url == "" then return nil end
  return (url:gsub("^file://[^/]*", ""):gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

rex.action{
  name = "task_new",
  title = "New Agent Task…",
  description = "Create a git worktree and start Claude in its own session",
  category = "Agents",
  keywords = "worktree claude branch",
  run = function(ctx)
    local command = { bin .. "rex-task", "new", "--interactive" }
    local dir = focused_dir(ctx)
    if dir ~= nil then
      table.insert(command, "--repo")
      table.insert(command, dir)
    end
    overlay(command, { 0.2, 0.2, 0.6, 0.5 })
  end,
}

rex.action{
  name = "agent_history",
  title = "Search Agent History…",
  description = "Search and resume Claude Code and Codex sessions",
  category = "Agents",
  run = function()
    overlay({ "sh", "-c",
      'if command -v agent-history-rex >/dev/null; then exec agent-history-rex; ' ..
      'else exec agent-history browse; fi' })
  end,
}

rex.action{
  name = "tokens_dashboard",
  title = "Agent Token Usage",
  description = "Token usage dashboard, opened on the focused agent",
  category = "Agents",
  args = { pane = "string?" },
  run = function(ctx, args)
    overlay({ "env", "AGENT_TOKENS_PANE=" .. (args.pane or ctx.block_id or ""),
      bin .. "agent-tokens" })
  end,
}

-- Agents that need you first: blocked on a question or permission, then
-- finished work you haven't looked at.
local attention = { blocked = 1, error = 2, done = 3 }

rex.action{
  name = "agent_attention",
  title = "Go to Agent Needing Attention",
  description = "Jump to the next agent that is blocked or has finished",
  category = "Agents",
  run = function(ctx)
    local r, err = rex.exec({ bin .. "rex-agent", "list", "--json" }, { timeout = 15 })
    if r == nil then error(err, 0) end
    if not r.ok then error(r.stderr, 0) end
    local best
    for _, agent in ipairs(rex.json.decode(r.stdout).agents) do
      local rank = attention[agent.state]
      if rank ~= nil and agent.block_id ~= ctx.block_id
          and (best == nil or rank < attention[best.state]) then
        best = agent
      end
    end
    if best == nil then return { found = false } end
    rex.call("session.focus_block", { session_id = best.session_id, block_id = best.block_id })
    rex.client.queue("session.select", { session_id = best.session_id })
    return { found = true, block_id = best.block_id }
  end,
}

-- Shortcuts set in the app with Change Shortcut… take precedence over these.
rex.bind("shift+cmd+n", "task_new")
rex.bind("shift+cmd+a", "agent_attention")
rex.bind("shift+cmd+h", "agent_history")
rex.bind("shift+cmd+u", "tokens_dashboard")
