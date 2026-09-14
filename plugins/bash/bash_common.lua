-- Shared helpers for the bash plugin: parsing, node text, and the
-- type/word tables both the permission walk and the unwrap rewrites use.

-- tree-sitter error recovery accepts invalid bash (`cmd && done` parses
-- clean), and these words do not repeat faithfully when expanded
local RESERVED_WORDS = {
  ["do"] = true,
  ["done"] = true,
  ["if"] = true,
  ["then"] = true,
  ["elif"] = true,
  ["else"] = true,
  ["fi"] = true,
  ["while"] = true,
  ["until"] = true,
  ["for"] = true,
  ["in"] = true,
  ["case"] = true,
  ["esac"] = true,
  ["select"] = true,
  ["coproc"] = true,
  ["break"] = true,
  ["continue"] = true,
  ["return"] = true,
  ["exit"] = true,
}

-- Nodes both passes descend into instead of treating as a command of
-- their own.
local WALK_THROUGH_TYPES = {
  program = true,
  list = true,
  pipeline = true,
  redirected_statement = true,
}

-- Local root, or nil when the grammar cannot parse cleanly (bail: fail-closed)
local function parse(cmd)
  local parser = maki.treesitter.get_parser(cmd, "bash")
  if not parser then
    return nil
  end
  local trees = parser:parse()
  local tree = trees and trees[1]
  if not tree then
    return nil
  end
  local root = tree:root()
  if root:has_error() then
    return nil
  end
  return root
end

local function text(node, source)
  return maki.treesitter.get_node_text(node, source)
end

return {
  RESERVED_WORDS = RESERVED_WORDS,
  WALK_THROUGH_TYPES = WALK_THROUGH_TYPES,
  parse = parse,
  text = text,
}
