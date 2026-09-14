local truncate = require("maki.truncate")
local ToolView = require("maki.tool_view")
local bash_scopes = require("bash_scopes")
local bash_unwrap = require("bash_unwrap")
local bash_rtk = require("bash_rtk")
local output_limits = require("maki.output_limits")
local partial = require("maki.partial")

local SEPARATOR = "──────"

local function unquote(s)
  local q = s:sub(1, 1)
  if (q == '"' or q == "'") and s:sub(-1) == q then
    return s:sub(2, -2)
  end
  return s
end

local function parse_cd_hint(input)
  if input.workdir then
    return input.command, input.workdir
  end
  local rest = input.command:match("^cd%s+(.+)$")
  if rest then
    local dir, tail = rest:match("^(.-)%s+&&%s+(.+)$")
    if dir and dir ~= "" then
      return tail, unquote(dir)
    end
  end
  return input.command, nil
end

local function normalize_sep(s)
  return s:gsub("\\", "/")
end

local function relative_path(p)
  local np = normalize_sep(p)
  local cwd = maki.uv.cwd()
  if cwd then
    cwd = normalize_sep(cwd)
    if np:sub(1, #cwd + 1) == cwd .. "/" then
      local rel = np:sub(#cwd + 2)
      return rel == "" and "." or rel
    end
    if np == cwd then
      return "."
    end
  end
  local home = maki.uv.os_homedir()
  if home then
    home = normalize_sep(home)
    if np:sub(1, #home + 1) == home .. "/" then
      local rel = np:sub(#home + 2)
      return rel == "" and "~" or "~/" .. rel
    end
  end
  return p
end

local function build_header_lines(command)
  local header = {}
  local highlighted = maki.ui.highlight(command, "bash")
  if highlighted then
    for _, line in ipairs(highlighted) do
      header[#header + 1] = line
    end
  else
    header[#header + 1] = command
  end
  header[#header + 1] = { { SEPARATOR, "dim" } }
  return header
end

local function append_line(output, line)
  if #output > 0 then
    output[#output + 1] = "\n"
  end
  output[#output + 1] = line
end

local function create_bash_view(command, ctx)
  local tol = ctx:tool_output_lines()
  local buf = maki.ui.buf()
  local view = ToolView.new(buf, {
    max_lines = (tol and tol.bash) or 5,
    keep = "tail",
    max_line_bytes = output_limits.DEFAULT_MAX_LINE_BYTES,
  })
  view:set_header(build_header_lines(command))
  buf:on("click", function()
    view:toggle()
  end)
  return buf, view
end

local cwd = maki.uv.cwd() or "."

local description = [[Execute a bash command.
Commands run in ]] .. cwd .. [[ by default.

- **DO NOT** use for file ops! Only git, builds, tests, and system commands.
- Use `workdir` param instead of `cd <dir> && <cmd>` patterns.
- Do NOT use to communicate text to the user.
- Chain dependent commands with `&&`. Use batch for independent ones.
- Provide a short `description` (3-5 words).
- Output truncated beyond 2000 lines or 50KB.
- Interactive commands (sudo, ssh prompts) fail immediately.]]

maki.api.register_prompt_hint({
  slot = "tool_usage",
  content = "- Reserve bash for system commands (git, builds, tests). Do NOT use bash for file operations, including on files outside the working dir.",
})

-- Rewrites the command before the permission gate so existing `[bash]` allow
-- rules can match what actually runs (timeout/nohup/... peel, for-loop
-- expansion). Mutate the field rather than replacing the table, so the other
-- input fields (timeout, workdir, description) survive the chain.
maki.api.set_slot("tool.bash.input", function(prev, input, ctx)
  if type(input) ~= "table" or type(input.command) ~= "string" then
    return prev(input, ctx)
  end
  local inner = bash_unwrap.transform(input.command)
  if not inner or inner == input.command then
    return prev(input, ctx)
  end
  maki.log.info(("bash-unwrap: %s -> %s"):format(input.command, inner))
  input.command = inner
  return prev(input, ctx)
end)

local opts = maki.api.register_options(output_limits.extend({
  timeout_secs = {
    default = 120,
    min = 5,
    desc = "Kill the command after this many seconds. A call's `timeout` param overrides it.",
  },
}))

maki.api.register_tool({
  name = "bash",
  kind = "execute",
  description = description,
  schema = {
    type = "object",
    properties = {
      command = { type = "string", description = "The bash command to execute", required = true },
      timeout = { type = "integer", description = "Timeout in seconds (default 120)" },
      workdir = { type = "string", description = "Working directory (default: cwd)" },
      description = { type = "string", description = "Short description (3-5 words) of what the command does" },
    },
  },
  permission = "run",
  permission_scopes = function(input)
    local command = input.command
    if not command or command:match("^%s*$") then
      return nil
    end

    return bash_scopes.scopes(command)
  end,

  header = function(input)
    local command, workdir = parse_cd_hint(input)
    local s = input.description or command
    if workdir then
      s = s .. " in " .. relative_path(workdir)
    end
    if input.timeout then
      local buf = maki.ui.buf()
      buf:line({ { s }, { " (" .. maki.ui.humantime(input.timeout) .. " timeout)", "dim" } })
      return buf
    end
    return s
  end,

  restore = function(input, output, is_error, ctx)
    local command = input.command
    local buf, view = create_bash_view(command, ctx)
    local timeout_secs = output:match("^tool bash timed out after (%d+)s$")
    if timeout_secs then
      view:append({ { "Timed out after " .. timeout_secs .. "s", "dim" } })
    elseif is_error then
      local body, code = output:match("^(.-)\nExit code: (%d+)$")
      if body then
        view:append_text(body)
        view:append({ { "Exit code: " .. code, "dim" } })
      else
        view:append_text(output)
      end
    else
      if output == "Exit code: 0" or output == "" then
        view:clear()
        view:append({ { "No output", "dim" } })
      else
        view:append_text(output)
      end
    end
    view:finish()
    return buf
  end,

  handler = function(input, ctx)
    if not input.command then
      return { llm_output = "error: command is required", is_error = true }
    end

    local command, workdir = parse_cd_hint(input)
    local timeout_secs = input.timeout or opts.timeout_secs
    local max_lines, max_bytes = output_limits.resolve(opts, ctx)

    ctx:set_deadline(timeout_secs)

    local rewritten = bash_rtk.rewrite(command, ctx)
    if rewritten then
      command = rewritten
    end

    local buf, view = create_bash_view(command, ctx)

    local output_parts = {}
    local has_output = false
    local finished = false

    local function finish(exit_code)
      if finished then
        return
      end
      finished = true
      local output = table.concat(output_parts)
      output = truncate(output, max_lines, max_bytes)

      local is_error = exit_code ~= 0
      local llm_output
      if exit_code == 0 then
        llm_output = output == "" and "Exit code: 0" or output
      else
        if output == "" then
          llm_output = "Exit code: " .. exit_code
        else
          llm_output = output .. "\nExit code: " .. exit_code
        end
      end

      if output == "" then
        view:clear()
        view:append({ { "No output", "dim" } })
      end

      if is_error then
        view:append({ { "Exit code: " .. exit_code, "dim" } })
      end
      view:finish()

      ctx:finish({ llm_output = llm_output, is_error = is_error, body = buf })
    end

    view:append({ { "Waiting for output...", "dim" } })

    maki.fn.jobstart(command, {
      cwd = workdir,
      env = { GIT_TERMINAL_PROMPT = "0" },
      on_stdout = function(_, line)
        if not has_output then
          has_output = true
          view:clear()
        end
        append_line(output_parts, line)
        view:append(line)
      end,
      on_stderr = function(_, line)
        if not has_output then
          has_output = true
          view:clear()
        end
        append_line(output_parts, line)
        view:append(line)
      end,
      on_exit = function(_, code)
        finish(code)
      end,
    })

    -- Esc or deadline: hand back the lines streamed so far, so the model
    -- keeps what the user just watched instead of a bare error.
    maki.async.on_cancel(function(reason)
      if finished then
        return
      end
      finished = true
      local out = truncate(table.concat(output_parts), max_lines, max_bytes)
      ctx:finish(partial.cut(view, out, reason, timeout_secs))
    end)

    return nil
  end,
})
