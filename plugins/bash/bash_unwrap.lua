-- bash-unwrap: rewrite bash commands before maki's permission gate so the
-- project's existing `[bash]` allow rules can match what actually runs.
--
-- Two transforms, both rewrite-only (the command handed back is exactly the
-- command that executes, so the gate always judges what runs):
--
-- 1. Wrapper peel: drop benign prefix wrappers (timeout, nice, stdbuf,
--    nohup, command) from the front of any top-level command.
--    `timeout 8 npm run dev 2>&1 | head -40` -> `npm run dev 2>&1 | head -40`.
--    Every command in a pipeline/chain gets its own independent chance;
--    commands that do not peel are left byte-identical.
-- 2. For-loop expansion: `for x in a b; do CMD $x; done` becomes
--    `CMD a; CMD b` when the loop is simple enough that the expansion is
--    exactly equivalent (literal word list, whitelist body).
--
-- Env assignments (FOO=x cmd) are deliberately NOT peeled: dropping them
-- would change the environment the command sees (NODE_ENV=production npm
-- test would silently run without it).
--
-- Wrapper semantics are dropped with the wrapper text: `timeout 5 cmd` runs
-- without the 5s kill (the bash tool's own deadline still applies), nice/
-- stdbuf priorities are lost. Fine for agent commands.
--
-- Parsing is tree-sitter (the same grammar bash_scopes uses), and every
-- rewrite is a byte-span edit on the original text: untouched text is
-- preserved verbatim, quoting included. Anything the grammar cannot parse
-- cleanly passes through untouched.

local common = require("bash_common")

local MAX_DEPTH = 4
local MAX_LOOP_VALUES = 64

local function text(node, source)
  return common.text(node, source)
end

local function start_byte(node)
  local _, _, s = node:start()
  return s
end

local function end_byte(node)
  local _, _, e = node:end_()
  return e
end

-- timeout durations: 5, 0.5, 5s, 5m, 1h, 300ms
local function is_duration(t)
  return t:match("^%d+%.?%d*ms$") ~= nil or t:match("^%d+%.?%d*[smhd]$") ~= nil or t:match("^%d+%.?%d*$") ~= nil
end

-- Each parser takes the argument list AFTER its wrapper word (nodes with
-- .t = text, .s = start byte) and returns how many leading arguments are
-- wrapper-owned, or nil when not confidently peelable.

local function peel_timeout(args)
  local i = 1
  while true do
    local a = args[i]
    if not a then
      return nil
    end
    local t = a.t
    if t == "-k" or t == "--kill-after" then
      local v = args[i + 1]
      if not v or not is_duration(v.t) then
        return nil
      end
      i = i + 2
    elseif t == "-s" or t == "--signal" then
      local v = args[i + 1]
      if not v or v.t:sub(1, 1) == "-" then
        return nil
      end
      i = i + 2
    elseif t == "--preserve-status" or t == "--foreground" then
      i = i + 1
    elseif t:match("^%-%-kill%-after=") or t:match("^%-%-signal=") then
      i = i + 1
    elseif t:sub(1, 1) == "-" then
      return nil -- unknown flag: do not guess
    else
      if not is_duration(t) then
        return nil
      end
      local nxt = args[i + 1]
      if not nxt then
        return nil -- duration with no command after it
      end
      if nxt.t:sub(1, 1) == "-" then
        -- GNU getopt permutes trailing options, so a flag after the duration
        -- may still belong to timeout. Not confidently peelable.
        return nil
      end
      return i
    end
  end
end

local function peel_nice(args)
  local a = args[1]
  if not a then
    return nil
  end
  local t = a.t
  if t == "-n" then
    local v = args[2]
    if not v or not v.t:match("^%-?%d+$") then
      return nil
    end
    if not args[3] then
      return nil
    end
    return 2
  elseif t:match("^%-?%d+$") then
    if not args[2] then
      return nil
    end
    return 1
  elseif t:match("^%-%-adjustment=%-?%d+$") then
    if not args[2] then
      return nil
    end
    return 1
  elseif t:sub(1, 1) == "-" then
    return nil
  end
  return 0 -- no adjustment given
end

-- Attached short forms (-o0, -eL) and long forms (--output=0) only; the
-- separate "-o 0" form bails.
local function peel_stdbuf(args)
  local i = 1
  while true do
    local a = args[i]
    if not a then
      return nil
    end
    local t = a.t
    if
      t:match("^%-[ioe][0-9L]+$")
      or t:match("^%-%-output=[0-9L]+$")
      or t:match("^%-%-input=[0-9L]+$")
      or t:match("^%-%-error=[0-9L]+$")
    then
      i = i + 1
    elseif t:sub(1, 1) == "-" then
      return nil
    else
      return i - 1
    end
  end
end

local function peel_bare(args)
  local a = args[1]
  if not a or a.t:sub(1, 1) == "-" then
    return nil -- `command -v x` and friends: keep today's behavior
  end
  return 0
end

local WRAPPERS = {
  timeout = peel_timeout,
  nice = peel_nice,
  stdbuf = peel_stdbuf,
  nohup = peel_bare,
  command = peel_bare,
}

-- Try to peel wrappers off one command node. On success appends a deletion
-- span { s, e, val = "" } covering the wrapper text (from the command word
-- up to the first argument of the inner command).
local function peel_command(node, source, edits)
  local names = node:field("name")
  if #names ~= 1 then
    return
  end
  local wrapper = text(names[1], source)
  if not WRAPPERS[wrapper] then
    return
  end

  -- An env-assignment prefix means the wrapper runs in a modified
  -- environment; we do not peel those at all.
  for _, kid in ipairs(node:named_children()) do
    if kid:type() == "variable_assignment" then
      return
    end
  end

  local args = {}
  for _, a in ipairs(node:field("argument")) do
    args[#args + 1] = { t = text(a, source), s = start_byte(a) }
  end
  table.sort(args, function(x, y)
    return x.s < y.s
  end)

  local consumed = WRAPPERS[wrapper](args)
  if not consumed then
    return
  end
  local depth = 1
  while true do
    if consumed >= #args then
      return -- wrapper tokens with no inner command left
    end
    local fn = WRAPPERS[args[consumed + 1].t]
    if not fn then
      break
    end
    local tail = {}
    for k = consumed + 2, #args do
      tail[#tail + 1] = args[k]
    end
    local c = fn(tail)
    if not c then
      return
    end
    consumed = consumed + 1 + c
    depth = depth + 1
    if depth > MAX_DEPTH then
      return
    end
  end

  local inner = args[consumed + 1]
  -- A redirect sitting between the wrapper and the inner command would be
  -- swallowed by the deletion (`timeout 5 >out cmd`), changing semantics.
  for _, r in ipairs(node:field("redirect")) do
    if start_byte(r) < inner.s then
      return
    end
  end

  edits[#edits + 1] = { s = start_byte(node), e = inner.s, val = "" }
end

local function collect_commands(node, out)
  if common.WALK_THROUGH_TYPES[node:type()] then
    for _, kid in ipairs(node:named_children()) do
      if kid:type() ~= "comment" then
        collect_commands(kid, out)
      end
    end
  elseif node:type() == "command" then
    out[#out + 1] = node
  end
end

-- Apply span edits to source in one ascending pass. Spans are 0-based
-- half-open byte offsets and must not overlap.
local function apply_edits(source, edits)
  table.sort(edits, function(a, b)
    return a.s < b.s
  end)
  local parts, pos = {}, 1
  for _, ed in ipairs(edits) do
    parts[#parts + 1] = source:sub(pos, ed.s)
    parts[#parts + 1] = ed.val
    pos = ed.e + 1
  end
  parts[#parts + 1] = source:sub(pos)
  return table.concat(parts)
end

-- Strips wrapper prefixes from every command the tree reaches at statement
-- level (through pipelines/lists/redirects). Returns the rewritten text, or
-- nil when no command peels.
local function peel(root, source)
  local cmds = {}
  collect_commands(root, cmds)
  local edits = {}
  for _, c in ipairs(cmds) do
    peel_command(c, source, edits)
  end
  return #edits > 0 and apply_edits(source, edits) or nil
end

------------------------------------------------------------------- for loops --

local BODY_STMT_TYPES = {
  command = true,
  pipeline = true,
  list = true,
  redirected_statement = true,
  variable_assignment = true,
}

local BAIL_BODY_TYPES = {
  command_substitution = true,
  process_substitution = true,
  arithmetic_expansion = true,
  heredoc_redirect = true,
  herestring_redirect = true,
  brace_expression = true,
}

local function has_reserved_command(node, source)
  if node:type() == "command_name" and common.RESERVED_WORDS[text(node, source)] then
    return true
  end
  for _, kid in ipairs(node:named_children()) do
    if has_reserved_command(kid, source) then
      return true
    end
  end
  return false
end

-- Expand one for_statement into "BODY(v1); BODY(v2)". Returns the
-- replacement text, or nil when the loop is not exactly equivalent to its
-- expansion.
local function expand_for(for_node, source)
  local vars = for_node:field("variable")
  if #vars ~= 1 then
    return nil
  end
  local var = text(vars[1], source)
  if not var:match("^[A-Za-z_][A-Za-z0-9_]*$") then
    return nil
  end

  -- Values must be literal words: no expansions, globs, quotes, escapes.
  local value_nodes = for_node:field("value")
  if #value_nodes == 0 or #value_nodes > MAX_LOOP_VALUES then
    return nil
  end
  local values = {}
  for _, v in ipairs(value_nodes) do
    local t = v:type()
    if t ~= "word" and t ~= "number" then
      return nil
    end
    local tv = text(v, source)
    if tv:find("[%$*?%[%]{}\\`'\"~#]") then
      return nil
    end
    values[#values + 1] = tv
  end

  local bodies = for_node:field("body")
  if #bodies ~= 1 or bodies[1]:type() ~= "do_group" then
    return nil
  end
  local dg = bodies[1]
  local kids = dg:children()
  if #kids < 3 or kids[1]:type() ~= "do" or kids[#kids]:type() ~= "done" then
    return nil
  end
  local do_end = end_byte(kids[1])
  local done_start = start_byte(kids[#kids])
  if done_start <= do_end then
    return nil
  end
  local body_raw = source:sub(do_end + 1, done_start)
  local lead = body_raw:match("^%s*")
  local body = body_raw:match("^%s*(.-)%s*$")
  if body == "" then
    return nil
  end
  -- Start offset of the trimmed body in source (0-based). body_raw begins
  -- at 0-based do_end, so after stripping #lead characters the body starts
  -- at do_end + #lead; substitution spans are stored relative to this.
  local b0 = do_end + #lead

  -- Strip trailing ";" runs (bash allows `do cmd; done`), then reject
  -- bodies whose edges would make the "; "-joined expansion invalid or
  -- change semantics: a leading separator, or a trailing `&` (each
  -- repetition would background into the next).
  body = body:match("^(.-)[%s;]*$")
  if body == "" then
    return nil
  end
  if body:sub(1, 1):match("[;&|]") or body:sub(-1) == "&" then
    return nil
  end

  -- Walk the body: check that every statement repeats faithfully, and
  -- collect $var/${var} spans to substitute, bail on
  -- anything the per-value repetition cannot replicate.
  local spans = {}
  local function contains_var(node)
    if node:type() == "variable_name" then
      return text(node, source) == var
    end
    for _, kid in ipairs(node:named_children()) do
      if contains_var(kid) then
        return true
      end
    end
    return false
  end

  local function scan(node)
    local t = node:type()
    if BAIL_BODY_TYPES[t] then
      return nil
    end
    if t == "expansion" then
      -- ${...}: only the exact `${var}` form is substitutable. The variable
      -- name may be a named node or a hidden token, so check both.
      local tv = text(node, source)
      local ekids = node:named_children()
      local exact = tv == "${" .. var .. "}"
        or (#ekids == 1 and ekids[1]:type() == "variable_name" and text(ekids[1], source) == var)
      if exact then
        spans[#spans + 1] = { s = start_byte(node) - b0, e = end_byte(node) - b0 }
        return true
      end
      if contains_var(node) then
        return nil -- ${x:-d} and friends: not exactly substitutable
      end
      return true -- ${y} etc: keep verbatim
    end
    if t == "simple_expansion" then
      -- $var: the variable name is a hidden token, so match the text.
      if text(node, source) == "$" .. var then
        spans[#spans + 1] = { s = start_byte(node) - b0, e = end_byte(node) - b0 }
      end
      return true -- other variables ($y, $?, $@): keep verbatim
    end
    for _, kid in ipairs(node:named_children()) do
      if not scan(kid) then
        return nil
      end
    end
    return true
  end

  for _, kid in ipairs(dg:named_children()) do
    if not BODY_STMT_TYPES[kid:type()] then
      return nil
    end
    if has_reserved_command(kid, source) then
      return nil
    end
    if not scan(kid) then
      return nil
    end
  end

  local parts = {}
  for _, val in ipairs(values) do
    local edits = {}
    for _, sp in ipairs(spans) do
      edits[#edits + 1] = { s = sp.s, e = sp.e, val = val }
    end
    parts[#parts + 1] = apply_edits(body, edits)
  end
  return table.concat(parts, "; ")
end

--------------------------------------------------------------------- entry --

-- The loop must be the entire command: inside a list or under a redirect,
-- splicing in "a; b" would change precedence or redirect scope. child_count
-- (named + anonymous) guards trailing operators like the `&` of `done &`,
-- which the grammar hangs off the program next to the loop.
local function whole_command_loop(root)
  local kids = root:named_children()
  if #kids == 1 and kids[1]:type() == "for_statement" and root:child_count() == 1 then
    return kids[1]
  end
  return nil
end

-- Runs the two transforms in order over `cmd`, with these exact semantics:
--   1. When the command is exactly `for x in a b; do BODY $x; done`, expand
--      it to `BODY a; BODY b` — or bail (nil) when the expansion is not
--      exactly equivalent.
--   2. Then peel wrapper prefixes everywhere, including inside the
--      expansion's output. Nothing further to rewrite keeps the expansion.
local function transform(cmd)
  if type(cmd) ~= "string" then
    return nil
  end
  local s = cmd:match("^%s*(.-)%s*$")
  if s == "" then
    return nil
  end
  local root = common.parse(s)
  if not root then
    return nil
  end

  local loop = whole_command_loop(root)
  if loop then
    local expanded = expand_for(loop, s)
    if not expanded then
      return nil
    end
    s = expanded
    root = common.parse(s)
    if not root then
      return s -- expansion text failed to re-parse; keep it as it stands
    end
    -- Even with no wrapper left to peel, the expansion itself is the rewrite.
    return peel(root, s) or s
  end

  return peel(root, s)
end

return {
  transform = transform,
}
