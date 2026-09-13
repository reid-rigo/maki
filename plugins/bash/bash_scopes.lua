-- Decomposes a bash command into permission scopes: one scope per command the
-- shell would execute. Substitutions are walked into, their inner commands
-- become extra scopes; every scope must earn its own allow.
--
-- Every bail path is fail-closed: the caller force-prompts the full command,
-- exactly as it would have before. Not sure → prompt. Tree-sitter's error
-- recovery accepts invalid bash (`cmd && done` parses clean), which is why
-- the walk pairs the tree with a reserved-word check.
local MAX_WALK_DEPTH = 4

-- Nodes the walk descends into instead of turning into a scope. Note that
-- tree-sitter hangs a trailing `2>&1` off the whole `cd x && cargo test`
-- chain, not off `cargo test`; treating that as a leaf would put the entire
-- chain behind a `cd *` allow rule.
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

-- Walked into; their text is never a scope of its own (it already appears
-- inside the containing command's raw text).
local SUBST_TYPES = {
  command_substitution = true,
  process_substitution = true,
  subshell = true,
}

-- Node kinds a substitution may hand the walk directly without bailing.
local SUBST_COMMAND_TYPES = {
  command = true,
  variable_assignment = true,
}

-- Evaluating commands run their argv as a program rather than treating it as
-- data: shells and interpreters evaluate it as source text, argument-
-- forwarding launchers (sudo/find -exec/xargs/timeout…) evaluate it as which
-- command to run. Either way no rule can cover what they actually execute, so
-- force-prompt when a substitution is anywhere in their argv.
--
-- Interpreter names that are treesitter *language* names (`bash`, `python`,
-- `ruby`, `lua`) resolve through `get_lang` in `is_evaluating` and are not
-- duplicated here; filetype-only aliases like `sh`/`zsh` are NOT guaranteed
-- to be registered, so they stay pinned. This list holds only what no
-- grammar registry can know.
local EVALUATING_COMMANDS = {
  "eval",
  "exec",
  "source",
  "sh",
  "zsh",
  "ksh",
  "dash",
  "ash",
  "awk",
  "perl",
  "python3",
  "node",
  "find",
  "xargs",
  "sudo",
  "doas",
  "env",
  "ssh",
  "docker",
  "nohup",
  "nice",
  "timeout",
  "su",
  "setsid",
  "stdbuf",
  "watch",
  "command",
  "builtin",
}

-- Expansion containers walked through; substitutions elsewhere
-- (`arithmetic_expansion` etc.) are not confidently decomposable.
local EXPANSION_THROUGH_TYPES = {
  string = true,
  concatenation = true,
  array = true,
  variable_assignment = true,
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
-- Evaluating commands the language registry already names: anything that
-- resolves through `get_lang` (`bash`, `sh`, `zsh`, `python`, `ruby`, `lua`,
-- `go`, `rust`, …). Union with the static list above — new grammars extend
-- the bail set without touching this file.
local function is_evaluating(word)
  for _, command in ipairs(EVALUATING_COMMANDS) do
    if command == word then
      return true
    end
  end
  return maki.treesitter.language.get_lang(word) ~= nil
end
for _, word in ipairs(RESERVED_WORD_LIST) do
  RESERVED_WORDS[word] = true
end

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

-- Collects the scopes of substitutions nested inside a scope's own text
-- (string values, assignment values); intermediate nodes here must not
-- emit scopes, or the containing scope could never match a rule silently.
local function collect_expansion_scopes(node, source, depth, inner)
  if not subtree_has_substitution(node) then
    return {}
  end
  local out = {}
  for child in node:iter_children() do
    if child:named() then
      if SUBST_TYPES[child:type()] then
        local scopes = collect_scopes(child, source, depth + 1, inner)
        if not scopes then
          return nil
        end
        extend(out, scopes)
      elseif EXPANSION_THROUGH_TYPES[child:type()] then
        local scopes = collect_expansion_scopes(child, source, depth + 1, inner)
        if not scopes then
          return nil
        end
        extend(out, scopes)
      elseif subtree_has_substitution(child) then
        return nil
      end
    end
  end
  return out
end

-- Returns `{ outer, ...substitution_scopes }` plus a bind position, or `nil`
-- on bail. The bind position is the list index an outer redirect of this
-- chain would bind to: the last chain-level scope, never a substitution scope.
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
          -- An unquoted heredoc body / here-string is expanded by bash: its
          -- substitutions really execute, so text-only scopes would miss them.
          if subtree_has_substitution(child) then
            return nil
          end
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
      local text = table.concat(redirects, " ")
      if bind then
        outer[bind] = outer[bind] .. " " .. text
      elseif subst then
        return nil -- $(> f): a bare redirect, nothing to judge
      else
        -- Bodiless `> log`: still truncates, so it must be its own scope.
        outer[1] = text
        bind = 1
      end
    end

    if subst and #outer == 0 then
      return nil
    end

    return outer, bind
  end

  -- Anything unknown becomes a scope of its own raw text: it has to end up
  -- in front of the user, not get dropped. Inside a walked substitution
  -- though, only what the grammar puts at command position is trusted.
  local text = node_text(node, source)
  local first_word = text:match("^(%a+)")

  local cmd_word
  for child in node:iter_children() do
    if child:named() and child:type() ~= "comment" then
      cmd_word = child
      break
    end
  end
  -- A substitution at command position runs its output as the command
  -- (`"$(echo ls)"` executes `ls`): no rule can cover that payload.
  if cmd_word then
    local cmd_kind = cmd_word:type()
    local wraps_substitution = SUBST_TYPES[cmd_kind]
      or (
        cmd_kind ~= "variable_assignment"
        and EXPANSION_THROUGH_TYPES[cmd_kind]
        and subtree_has_substitution(cmd_word)
      )
    if wraps_substitution then
      return nil
    end
  end

  if inner then
    if not SUBST_COMMAND_TYPES[kind] then
      return nil
    end
    if first_word and RESERVED_WORDS[first_word] then
      return nil
    end
  elseif first_word and is_evaluating(first_word) and subtree_has_substitution(node) then
    return nil
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
  local bail = { scopes = { command }, force_prompt = true }

  local parser = maki.treesitter.get_parser(command, "bash")
  if not parser then
    return bail
  end

  local root = parser:parse()[1]:root()
  if root:has_error() then
    return bail
  end

  local segments = collect_scopes(root, command, 0, false)
  return (segments and #segments > 0) and { scopes = segments, force_prompt = false } or bail
end

return {
  scopes = scopes,
  evaluating_commands = EVALUATING_COMMANDS,
}
