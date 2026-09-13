-- Decomposes a bash command into permission scopes: one scope per command the
-- shell would execute, each judged against allow/deny rules on its own.
--
-- Chains (`&&`, `;`, `|`) walk through `program/list/pipeline/
-- redirected_statement`, and substitutions (`$(...)`, backticks, `<(...)`,
-- `(...)`) are walked INTO: their inner command segments become additional
-- scopes while the outer scope keeps the full raw text, so `git log $(cat f)`
-- scopes as `git log $(cat f)` plus `cat f`. Every scope must earn its own
-- allow; a deny on any one still wins.
--
-- Every bail path below is fail-closed: the caller learns force_prompt and
-- gets the identical opaque scope it would have gotten before. Not sure →
-- prompt is the invariant.
--
-- Tree-sitter's error recovery accepts invalid bash, so the walk pairs the
-- parsed tree with a reserved-word check: `cmd && done` parses but bash
-- rejects it, and only this check notices.

-- Limit on substitution nesting, not on overall parse depth: the walk is
-- fully recursive over chains, and the budget guards the constructs that
-- actually inhibit confident decomposition.
local MAX_WALK_DEPTH = 4

-- Nodes the walk descends into instead of turning into a scope.
-- `redirected_statement` has to be one of them: tree-sitter hangs a trailing
-- `2>&1` off the entire `cd x && cargo test` chain rather than off `cargo
-- test`, so treating it as a leaf turns the whole chain into a single scope
-- starting with `cd `, and a `cd *` allow rule then quietly covers whatever
-- runs after the `&&`.
local WALK_THROUGH_TYPES = {
  program = true,
  list = true,
  pipeline = true,
  redirected_statement = true,
}

local REDIRECT_TYPES = {
  file_redirect = true,
  heredoc_redirect = true,
  herestring_redirect = true,
}

-- Substitution nodes are walked into. Their own text is never emitted as a
-- scope of its own: it is already part of the containing command's raw text,
-- and omitting it is what lets a mid-command substitution stay silent when
-- only the containing command matches a rule.
local SUBST_TYPES = {
  command_substitution = true,
  process_substitution = true,
  subshell = true,
}

local RESERVED_WORD_LIST = {
  "do",
  "done",
  "if",
  "then",
  "elif",
  "else",
  "fi",
  "while",
  "until",
  "for",
  "in",
  "case",
  "esac",
  "select",
  "coproc",
  "break",
  "continue",
  "return",
  "exit",
}
local RESERVED_WORDS = {}
for _, word in ipairs(RESERVED_WORD_LIST) do
  RESERVED_WORDS[word] = true
end

-- Node kinds a substitution may hand the walk directly without bailing.
-- Assignments are judged like any command segment: their text is the scope.
-- Everything else inside a substitution — `$(! true)`, `$(for ...)`, `$(done)`
-- — is not confidently decomposable and force-prompts instead.
local SUBST_COMMAND_TYPES = {
  command = true,
  variable_assignment = true,
}

-- Nodes whose substitutions can be reached from a leaf without emitting a
-- scope of the container's own; anything else carrying a substitution (the
-- known case: `arithmetic_expansion`) is not confidently decomposable.
local EXPANSION_THROUGH_TYPES = {
  string = true,
  concatenation = true,
  array = true,
  variable_assignment = true,
}

local function node_text(node, source)
  return maki.treesitter.get_node_text(node, source):match("^%s*(.-)%s*$")
end

local function subtree_has_substitution(node)
  if SUBST_TYPES[node:type()] then
    return true
  end
  for child in node:iter_children() do
    if child:named() and subtree_has_substitution(child) then
      return true
    end
  end
  return false
end

local function extend(out, scopes)
  for _, scope in ipairs(scopes) do
    out[#out + 1] = scope
  end
end

local collect_scopes

-- Walking in and collecting the scopes of the substitutions nested inside a
-- scope's own text (strings, assignment values). Only scopes are collected:
-- the containing scope's text already covers the substitution's raw text, so
-- an intermediate node here must not emit a scope, or
-- `echo "pre$(cat f)"`'s `"pre$(cat f)"` would have to earn its own allow and
-- the decomposition would never go quiet.
local function collect_expansion_scopes(node, source, depth, inner)
  local out = {}
  for child in node:iter_children() do
    if child:named() then
      if SUBST_TYPES[child:type()] then
        local scopes = collect_scopes(child, source, depth + 1, inner)
        if not scopes then
          return nil
        end
        extend(out, scopes)
      elseif EXPANSION_THROUGH_TYPES[child:type()] and subtree_has_substitution(child) then
        local scopes = collect_expansion_scopes(child, source, depth + 1, inner)
        if not scopes then
          return nil
        end
        extend(out, scopes)
      elseif subtree_has_substitution(child) then
        -- An `arithmetic_expansion` wrapped around a substitution and any
        -- other unknown container is not confidently decomposable.
        return nil
      end
    end
  end
  return out
end

-- Returns `{ outer, ...substitution_scopes }` plus a bind position, or `nil`
-- when the walk bailed. `outer[1..n]` are the chain-level scopes at this
-- node; any further entries are substitution scopes, appended right after
-- their containing command's scope. The bind position is the index in that
-- list an outer redirect of this chain would bind to: the last chain-level
-- scope, never a substitution scope.
collect_scopes = function(node, source, depth, inner)
  if depth > MAX_WALK_DEPTH then
    return nil
  end
  local kind = node:type()
  local subst = SUBST_TYPES[kind]

  if subst or WALK_THROUGH_TYPES[kind] then
    local outer, redirects = {}, {}
    local bind
    local child_inner = subst and true or inner
    for child in node:iter_children() do
      local child_kind = child:type()
      if child:named() and child_kind ~= "comment" then
        if REDIRECT_TYPES[child_kind] then
          redirects[#redirects + 1] = node_text(child, source)
        else
          local scopes, child_bind = collect_scopes(child, source, depth, child_inner)
          if not scopes then
            return nil
          end
          local base = #outer
          extend(outer, scopes)
          if child_bind then
            bind = base + child_bind
          end
        end
      end
    end

    if #redirects > 0 then
      -- The redirect belongs to the command bash would actually apply it to.
      local text = table.concat(redirects, " ")
      if bind then
        outer[bind] = outer[bind] .. " " .. text
      elseif subst then
        -- `$(> f)` runs a bare redirect with no command to judge.
        return nil
      else
        -- A bodiless `> log` has no command and still truncates the file,
        -- so it becomes a scope of its own instead of vanishing.
        outer[1] = text
        bind = 1
      end
    end

    if subst and #outer == 0 then
      -- Degenerate substitution: nothing left to judge.
      return nil
    end

    return outer, bind
  end

  -- Whatever is left becomes a scope of its own raw text. That covers plain
  -- commands and the block forms (`if`, `while`) we deliberately keep whole,
  -- plus any node type we never thought of, which is what we want: an
  -- unknown node has to end up in front of the user, not get dropped. Inside
  -- a walked substitution though, only what the substitution grammar puts at
  -- command position is trusted; anything else — `$(! true)`, `$(done)` —
  -- bails to force-prompt.
  local text = node_text(node, source)
  if inner then
    if not SUBST_COMMAND_TYPES[kind] then
      return nil
    end
    local first_word = text:match("^(%a+)")
    if first_word and RESERVED_WORDS[first_word] then
      return nil
    end
  end

  local outer = text ~= "" and { text } or {}
  local inner_scopes = collect_expansion_scopes(node, source, depth, inner)
  if not inner_scopes then
    return nil
  end
  extend(outer, inner_scopes)
  if #outer == 0 then
    return outer
  end
  return outer, 1
end

local function scopes(command)
  local parser = maki.treesitter.get_parser(command, "bash")
  if not parser then
    return { scopes = { command }, force_prompt = true }
  end

  local root = parser:parse()[1]:root()
  if root:has_error() then
    return { scopes = { command }, force_prompt = true }
  end

  local segments = collect_scopes(root, command, 0, false)
  if not segments or #segments == 0 then
    return { scopes = { command }, force_prompt = true }
  end
  return { scopes = segments, force_prompt = false }
end

return {
  scopes = scopes,
}
