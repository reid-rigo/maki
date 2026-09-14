-- Shared helpers for the bash plugin: tree-sitter parsing, node text, and
-- the node-type / reserved-word tables both the permission walk and the
-- unwrap rewrites use. One home so the two passes cannot drift apart.

local M = {}

-- tree-sitter's error recovery accepts invalid bash (`cmd && done` parses
-- clean), and these words do not repeat faithfully when expanded, so both
-- passes bail on them at command position.
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

-- Nodes both passes descend into instead of treating as a command of their
-- own. Note that tree-sitter hangs a trailing `2>&1` off the whole
-- `cd x && cargo test` chain, not off `cargo test`.
local WALK_THROUGH_TYPES = {
  program = true,
  list = true,
  pipeline = true,
  redirected_statement = true,
}

-- Parses a command and returns the root node, or nil when the grammar
-- cannot parse it cleanly (which every caller treats as a bail: fail-closed).
function M.parse(cmd)
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

function M.text(node, source)
  return maki.treesitter.get_node_text(node, source)
end

M.RESERVED_WORDS = RESERVED_WORDS
M.WALK_THROUGH_TYPES = WALK_THROUGH_TYPES

return M
