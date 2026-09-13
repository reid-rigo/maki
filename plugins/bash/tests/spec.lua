local th = require("maki.test_helpers")
local scopes = require("bash_scopes").scopes

local case = th.case
local eq = th.eq

local function scopes_err(result, expected)
  local msg = "expected scopes:\n  "
    .. table.concat(expected, " | ")
    .. "\n  actual:\n    "
    .. table.concat(result.scopes, " | ")
  eq(#result.scopes, #expected, msg .. "\n(count mismatch)")
  for i, scope in ipairs(expected) do
    eq(result.scopes[i], scope, msg .. "\n(scope " .. i .. ")")
  end
end

local function decomposes(command, expected)
  local result = scopes(command)
  eq(result.force_prompt, false, command)
  scopes_err(result, expected)
end

local function force_prompts(command)
  local result = scopes(command)
  eq(result.force_prompt, true, command)
  scopes_err(result, { command })
end

-- Substitutions decompose instead of force-prompting as one opaque scope.

case("command_substitution_decomposes", function()
  decomposes("git log $(cat f)", { "git log $(cat f)", "cat f" })
end)

case("backtick_decomposes", function()
  decomposes("cmd `cat f`", { "cmd `cat f`", "cat f" })
end)

case("process_substitution_decomposes", function()
  decomposes("cat <(ls) d", { "cat <(ls) d", "ls" })
  decomposes("diff <(a) <(b)", { "diff <(a) <(b)", "a", "b" })
end)

case("subshell_decomposes", function()
  decomposes("x && (b c)", { "x", "b c" })
end)

case("mid_command_substitution_decomposes", function()
  decomposes("echo $(date) > log", { "echo $(date) > log", "date" })
end)

case("assignment_with_substitution_judged_like_a_command_segment", function()
  decomposes("x=$(cat f)", { "x=$(cat f)", "cat f" })
end)

case("arithmetic_arg_is_part_of_the_outer_scope", function()
  -- The arithmetic itself executes nothing; only a substitution wrapped
  -- inside one is beyond the walk, so the plain arithmetic stays in the
  -- outer scope's raw text.
  decomposes("echo $((x+1))", { "echo $((x+1))" })
end)

-- The force cases keep today's behavior: the identical opaque scope prompt.

case("degenerate_empty_substitution_force_prompts", function()
  force_prompts("echo $( )")
  force_prompts("x=$( )")
end)

case("bare_redirect_substitution_force_prompts", function()
  force_prompts("echo $(< f)")
  force_prompts("echo $(> f)")
end)

case("reserved_word_in_substitution_force_prompts", function()
  force_prompts("echo $(cmd && done)")
  force_prompts("x=$(a b; done)")
  force_prompts("echo $(exit 1)")
end)

case("unknown_node_in_substitution_force_prompts", function()
  force_prompts("echo $( ! true )")
  force_prompts("echo $(for f in a; do echo; done)")
  force_prompts("echo $(if x; then y; fi)")
  force_prompts("echo $( { a; } )")
  force_prompts("echo $(( $(a) + 1 ))")
end)

case("walk_beyond_depth_limit_force_prompts", function()
  decomposes(
    "git log $(a $(b $(c $(d))))",
    { "git log $(a $(b $(c $(d))))", "a $(b $(c $(d)))", "b $(c $(d))", "c $(d)", "d" }
  )
  force_prompts("git log $(a $(b $(c $(d $(e)))))")
end)

case("parse_error_force_prompts", function()
  force_prompts("echo $( )  ;  cmd && done  ]  [")
end)

-- Operator chains and redirects keep their existing piecewise decomposition.

case("operator_chains_decompose", function()
  decomposes("git status && npm test", { "git status", "npm test" })
  decomposes("cat f | head -1", { "cat f", "head -1" })
end)

case("redirect_scope_binds_to_the_last_command_of_the_chain", function()
  decomposes("echo a; cat b > out", { "echo a", "cat b > out" })
  decomposes("echo a > log", { "echo a > log" })
  decomposes("git log $(cat f) > log", { "git log $(cat f) > log", "cat f" })
  decomposes("cat <(cat f) > out", { "cat <(cat f) > out", "cat f" })
end)

case("redirects_inside_substitutions_bind_within_them", function()
  decomposes("echo $(cat a; cat b > out)", { "echo $(cat a; cat b > out)", "cat a", "cat b > out" })
end)

case("string_wrapped_substitution_decomposes", function()
  decomposes('echo "$(a)$(b)"', { 'echo "$(a)$(b)"', "a", "b" })
  decomposes('x="pre$(cat f)post"', { 'x="pre$(cat f)post"', "cat f" })
end)

case("comment_only_prefix_is_dropped", function()
  decomposes("echo a # note", { "echo a" })
end)

-- Mid-command and mixed shapes, all verified against the tree the bash
-- grammar actually produces.
case("mixed_shapes_decompose", function()
  decomposes("echo $(x; > f)", { "echo $(x; > f)", "x", "> f" })
  decomposes("y=$(cat f) run", { "y=$(cat f) run", "cat f" })
  decomposes("git log $(a) && git b", { "git log $(a)", "a", "git b" })
  decomposes("echo $(git status) | wc -l", { "echo $(git status)", "git status", "wc -l" })
  decomposes("git log $(cat $(cat f))", { "git log $(cat $(cat f))", "cat $(cat f)", "cat f" })
  decomposes("(cd x && cargo build)", { "cd x", "cargo build" })
  decomposes('cat <(echo -e "$(whoami)")', { 'cat <(echo -e "$(whoami)")', 'echo -e "$(whoami)"', "whoami" })
  decomposes("cmd $(cat f; )", { "cmd $(cat f; )", "cat f" })
  decomposes('git -c x=$"$(a)" push', { 'git -c x=$"$(a)" push', "a" })
  decomposes("grep -r --include='*.py' pat", { "grep -r --include='*.py' pat" })
  decomposes("echo 'quoted $(not a subst)'", { "echo 'quoted $(not a subst)'" })
  decomposes("x=$((1+2)) cd y && rm -rf /tmp/a/b/c/*", { "x=$((1+2)) cd y", "rm -rf /tmp/a/b/c/*" })
end)

th.report()
