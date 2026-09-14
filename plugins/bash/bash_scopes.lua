-- Decomposes a bash command into permission scopes: one per command the
-- shell would execute; substitutions are walked into and their inner
-- commands become extra scopes. Every bail is fail-closed: the caller
-- force-prompts the full command as before. Not sure → prompt.
local common = require("bash_common")

local MAX_WALK_DEPTH = 4

local REDIRECT_TYPES = {
  file_redirect = true,
  heredoc_redirect = true,
  herestring_redirect = true,
}

-- Walked into; their text already appears inside the containing scope's text.
local SUBST_TYPES = {
  command_substitution = true,
  process_substitution = true,
  subshell = true,
}

local SUBST_COMMAND_TYPES = {
  command = true,
  variable_assignment = true,
}

-- Elevated execution is never delegated to allow rules: always prompted
-- (allow-once), whatever a `sudo *`-shaped rule says.
local ALWAYS_PROMPT_COMMANDS = {
  sudo = true,
  doas = true,
  su = true,
}

-- Expansion containers walked through; substitutions elsewhere
-- (`arithmetic_expansion` etc.) are not confidently decomposable.
local EXPANSION_THROUGH_TYPES = {
  string = true,
  concatenation = true,
  array = true,
  variable_assignment = true,
}

local function node_text(node, source)
  return common.text(node, source):match("^%s*(.-)%s*$")
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

-- Appends a collected scope list; false means the walk bailed.
local function push_scopes(out, scopes)
  if not scopes then
    return false
  end
  for _, scope in ipairs(scopes) do
    out[#out + 1] = scope
  end
  return true
end

local collect_scopes

-- Collects the scopes of the substitutions a redirect expands (unquoted
-- heredoc bodies, here-strings): they really execute, so their inner
-- commands are scoped under their own text; user rules then decide.
local function collect_redirect_scopes(node, source, depth, inner)
  local out = {}
  for child in node:iter_children() do
    if child:named() then
      local scopes
      if SUBST_TYPES[child:type()] then
        scopes = collect_scopes(child, source, depth + 1, inner)
      else
        scopes = collect_redirect_scopes(child, source, depth, inner)
      end
      if not push_scopes(out, scopes) then
        return nil
      end
    end
  end
  return out
end

-- Collects the scopes of substitutions nested inside a scope's own text;
-- intermediate nodes here must not emit scopes, or the containing scope
-- could never match a rule silently.
local function collect_expansion_scopes(node, source, depth, inner)
  if not subtree_has_substitution(node) then
    return {}
  end
  local out = {}
  for child in node:iter_children() do
    if child:named() then
      local scopes
      if SUBST_TYPES[child:type()] then
        scopes = collect_scopes(child, source, depth + 1, inner)
      elseif EXPANSION_THROUGH_TYPES[child:type()] then
        scopes = collect_expansion_scopes(child, source, depth + 1, inner)
      elseif REDIRECT_TYPES[child:type()] then
        scopes = collect_redirect_scopes(child, source, depth, inner)
      elseif subtree_has_substitution(child) then
        return nil
      else
        scopes = {}
      end
      if not push_scopes(out, scopes) then
        return nil
      end
    end
  end
  return out
end

-- Chain nodes (substitutions and everything walked through) yield one scope
-- per inner command plus a bind position for outer redirects. The bind
-- position is the list index an outer redirect of this chain would bind to:
-- the last chain-level scope, never a substitution scope.
local function collect_chain(node, source, depth, inner)
  local outer, redirects = {}, {}
  local bind
  local child_inner = SUBST_TYPES[node:type()] and true or inner
  for child in node:iter_children() do
    local child_kind = child:type()
    if child:named() and child_kind ~= "comment" then
      if REDIRECT_TYPES[child_kind] then
        -- Unquoted heredoc bodies / here-strings expand: their substitutions really execute.
        local sub_scopes = collect_redirect_scopes(child, source, depth, child_inner)
        if not sub_scopes then
          return nil
        end
        push_scopes(outer, sub_scopes)
        redirects[#redirects + 1] = node_text(child, source)
      else
        local scopes, child_bind = collect_scopes(child, source, depth, child_inner)
        if not scopes then
          return nil
        end
        local base = #outer
        push_scopes(outer, scopes)
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
    elseif SUBST_TYPES[node:type()] then
      return nil -- $(> f): a bare redirect, nothing to judge
    else
      -- Bodiless `> log` still truncates: it must be its own scope.
      outer[1] = text
      bind = 1
    end
  end

  if SUBST_TYPES[node:type()] and #outer == 0 then
    return nil
  end
  return outer, bind
end

-- Anything unknown becomes a scope of its own raw text: it has to end up
-- in front of the user, not get dropped. Inside a walked substitution
-- though, only what the grammar puts at command position is trusted.
local function collect_leaf(node, source, depth, inner)
  local text = node_text(node, source)
  local first_word = text:match("^(%a+)")

  for child in node:iter_children() do
    if child:named() and child:type() ~= "comment" then
      -- A substitution at command position runs its output as the command
      -- (`"$(echo ls)"` executes `ls`): no rule can cover that payload.
      local cmd_kind = child:type()
      if
        SUBST_TYPES[cmd_kind]
        or (cmd_kind ~= "variable_assignment" and EXPANSION_THROUGH_TYPES[cmd_kind] and subtree_has_substitution(child))
      then
        return nil
      end
      break
    end
  end

  if inner then
    if not SUBST_COMMAND_TYPES[node:type()] then
      return nil
    end
    if first_word and common.RESERVED_WORDS[first_word] then
      return nil
    end
  elseif ALWAYS_PROMPT_COMMANDS[first_word] then
    return nil
  end

  local outer = text ~= "" and { text } or {}
  local inner_scopes = collect_expansion_scopes(node, source, depth, inner)
  if not inner_scopes then
    return nil
  end
  push_scopes(outer, inner_scopes)
  if #outer == 0 then
    return outer
  end
  return outer, 1
end

collect_scopes = function(node, source, depth, inner)
  if depth > MAX_WALK_DEPTH then
    return nil
  end
  local kind = node:type()
  if common.WALK_THROUGH_TYPES[kind] or SUBST_TYPES[kind] then
    return collect_chain(node, source, depth, inner)
  end
  return collect_leaf(node, source, depth, inner)
end

local function scopes(command)
  local bail = { scopes = { command }, force_prompt = true }

  local root = common.parse(command)
  if not root then
    return bail
  end

  local segments = collect_scopes(root, command, 0, false)
  return (segments and #segments > 0) and { scopes = segments, force_prompt = false } or bail
end

return {
  scopes = scopes,
}
