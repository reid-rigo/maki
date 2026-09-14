-- bash_unwrap spec: exact-output transform cases plus real-bash
-- loop-vs-expansion equivalence (stdout and exit code must match).
-- The equivalence section is skipped where /bin/bash cannot be spawned.

local th = require("maki.test_helpers")
local transform = require("bash_unwrap").transform

local case = th.case
local eq = th.eq

-- { input, want }: `want ~= nil` is the expected rewrite; `nil` = passthrough.
local cases = {
  --------------------------------------------------------------- peel: timeout --
  { "timeout 5 git status", "git status" },
  { "timeout -k 5 10 git status", "git status" },
  { "timeout --preserve-status 5 npm test", "npm test" },
  { "timeout 5s git status", "git status" },
  { "timeout 5 nice -n 5 git status", "git status" },
  { "git status", nil },
  { "timeout -k", nil },
  { "timeout 5 sed '-i' 's/x/y' f", "sed '-i' 's/x/y' f" },
  { "nohup git status", "git status" },
  { "command git status", "git status" },
  { "command -v git", nil },
  { "stdbuf -o0 cat big.log", "cat big.log" },
  { "stdbuf -o0 -eL ./server", "./server" },
  { "stdbuf --output=0 cat big.log", "cat big.log" },
  { "stdbuf --input=0 --error=L ./server", "./server" },
  { "stdbuf -o0 -e 2 ./server", nil }, -- separate-arg form: bail
  { "stdbuf", nil },
  { "stdbuf -x cat big.log", nil }, -- unknown flag: do not guess
  { "stdbuf -o", nil },
  { "nice git status", "git status" },
  { "nice -5 git status", "git status" },
  { "nice -n -5 git status", "git status" },
  { "nice --adjustment=5 git status", "git status" },
  { "nice -n 5 nice -n 5 git status", "git status" },
  { "timeout --signal=KILL 5 git status", "git status" },
  { "timeout -s KILL 5 git status", "git status" },
  { "timeout --foreground 5 git status", "git status" },
  { "timeout -k 5s 10m git status", "git status" },
  { "timeout --kill-after=5 10 git status", "git status" },
  { "timeout 0.5 git status", "git status" },
  { "timeout 300ms git status", "git status" },
  { "timeout --verbose 5 git status", "git status" },
  { "timeout 5x git status", nil }, -- bad duration
  { "timeout 5 -n 5 git status", nil }, -- flag after duration: getopt permutes
  { "timeout 5 > out", nil }, -- inner would become a bare redirect
  { "nohup > out", nil },

  -- env assignments are NOT peeled: dropping them changes the environment
  -- the command sees (NODE_ENV=production npm test would silently run
  -- without it). Passthrough keeps today's behavior.
  { "FOO=1 timeout 5 git status", nil },
  { "FOO=1 BAR=2 git status", nil },
  { "FOO=bar git status", nil },
  { "FOO=1", nil },
  { 'FOO="a b" git status', nil },

  -- mechanical unwrap of unknown inner commands (prompt outcome unchanged;
  -- the prompt now shows the real command)
  { "timeout 5 someunknowncmd", "someunknowncmd" },
  { "timeout 5 rm -rf /tmp/x", "rm -rf /tmp/x" },

  -- bail: structure the parser does not model
  { "timeout", nil },
  { "timeout 5", nil },
  { "", nil },
  { "   ", nil },
  -- substitutions force a prompt upstream anyway; peeling the wrapper is
  -- still sound (the gate sees the same command it would judge bare)
  { "timeout 5 echo $(x)", "echo $(x)" },
  { "timeout 5 echo `x`", "echo `x`" },
  { "timeout 5 'git' status", "'git' status" }, -- quotes are shell quoting; raw text preserved
  { 5, nil },
  { nil, nil },

  ------------------------------------- multi-segment peel (chained commands) --
  { "timeout 8 npm run dev 2>&1 | head -40", "npm run dev 2>&1 | head -40" },
  {
    "timeout 480 gh pr checks 49 --watch --interval 20 2>&1 | tail -8",
    "gh pr checks 49 --watch --interval 20 2>&1 | tail -8",
  },
  {
    "nohup npm run dev > /tmp/f.log 2>&1 & sleep 6 && tail -5 /tmp/f.log",
    "npm run dev > /tmp/f.log 2>&1 & sleep 6 && tail -5 /tmp/f.log",
  },
  {
    "nohup npm run dev:client > /tmp/dev.log 2>&1 & disown; sleep 4; tail -5 /tmp/dev.log",
    "npm run dev:client > /tmp/dev.log 2>&1 & disown; sleep 4; tail -5 /tmp/dev.log",
  },
  { "git status && timeout 5 npm test", "git status && npm test" },
  { "cd /tmp && timeout 5 cargo test", "cd /tmp && cargo test" },
  { "timeout 5 cmd1 && timeout 5 cmd2", "cmd1 && cmd2" },
  -- byte-span edits preserve the original separators verbatim
  { "timeout 5 cmd1;timeout 5 cmd2", "cmd1;cmd2" },
  { "timeout 5 a&&timeout 5 b", "a&&b" },
  { "timeout 5 cmd &", "cmd &" },
  { "timeout 5 git status | head", "git status | head" },
  { "timeout 5 git status && head x", "git status && head x" },
  { "timeout 5 git status; head x", "git status; head x" },
  { "timeout 5 git status\nrm -rf /", "git status\nrm -rf /" },
  { "git status && npm test", nil }, -- nothing to peel
  { "cat a | grep b", nil },
  { "echo hi > out && cat out", nil },
  { "timeout 5 cmd > out.log 2>&1", "cmd > out.log 2>&1" },
  { "timeout 5 cmd < in", "cmd < in" }, -- stdin redirect is part of the command
  { "timeout 5 cmd |& cat", "cmd |& cat" },
  { "timeout 5 cmd &> log", "cmd &> log" },
  { 'timeout 5 echo "a && b"', 'echo "a && b"' },
  { "timeout 5 echo 'x; y'", "echo 'x; y'" },
  { 'timeout 5 git commit -m "msg; with; semis"', 'git commit -m "msg; with; semis"' },
  { 'echo "a && b" && timeout 5 git status', 'echo "a && b" && git status' },
  { "timeout 5 echo ${x}", "echo ${x}" },
  { "timeout 5 echo ${x:-d}", "echo ${x:-d}" },
  { "timeout 5 cmd2>out", "cmd2>out" }, -- peel is sound: cmd with fd-2 redirect
  { 'timeout 5 bash -c "x && y"', 'bash -c "x && y"' },
  { "timeout 5 cmd2 x", "cmd2 x" }, -- digits mid-word are not redirects
  { "timeout 5 >out cmd", nil }, -- redirect between wrapper and inner: bail

  ------------------------------------------------------------------- env/time --
  { "env git status", "git status" },
  { "env A=1 B=2 npm test", "A=1 B=2 npm test" },
  { 'env "A=1 b" cmd', '"A=1 b" cmd' }, -- quoted assignment stays verbatim
  { "env A=1 timeout 5 cmd", "A=1 timeout 5 cmd" }, -- assignments stop the peel at env
  { "env", nil },
  { "env A=1", "A=1" },
  { "env -i git status", nil }, -- drops the environment
  { "env -u FOO git status", nil }, -- edits the environment
  { "env -0 bash -c 'true'", nil },
  { "env -- git status", nil },
  { "time git status", "git status" },
  { "time -p git status", "git status" },
  { "time", nil },
  { "time -p", nil },
  { "time -f '%e' git status", nil }, -- GNU format string: not transparent
  { "gtimeout 5 git status", "git status" },
  { "timeout -v 5 git status", "git status" },
  { "timeout --verbose 5 git status", "git status" },
  { "nohup env time git status", "git status" }, -- chained wrappers
  { "repeat 3 git status", nil }, -- zsh keyword; would become a real run if peeled
  { "time '-p' git status", "'-p' git status" }, -- quoting hides the flag from the peel matcher
  { "env FOO=1 npm test && env FOO=2 npm test", "FOO=1 npm test && FOO=2 npm test" },
  { "env FOO=1 git status > out", "FOO=1 git status > out" },
  { "time git status && time npm test", "git status && npm test" },
  { "gtimeout -k 5 10 git status", "git status" },
  { "timeout 5 nohup env time nice command git status", nil }, -- past MAX_DEPTH
  { "timeout 5 nohup env time git status", "git status" }, -- at the cap, still peels

  ------------------------------------------------------- for-loop expansion --
  { "for x in a b c; do git add $x; done", "git add a; git add b; git add c" },
  { "for d in api frontend shared; do du -sh $d; done", "du -sh api; du -sh frontend; du -sh shared" },
  { 'for x in a; do echo "$x"; done', 'echo "a"' },
  { "for x in a b; do echo ${x}.txt; done", "echo a.txt; echo b.txt" },
  { "for x in a b\ndo echo $x\ndone", "echo a; echo b" },
  { "for x in a b;do echo $x;done", "echo a; echo b" },
  { "for x in a b ; do echo $x ; done", "echo a; echo b" },
  { "for x in a b; do echo 'lit $x'; done", "echo 'lit $x'; echo 'lit $x'" },
  { 'for x in a b; do echo "v=$x"; done', 'echo "v=a"; echo "v=b"' },
  { "for x in a b; do cmd $y; done", "cmd $y; cmd $y" }, -- other vars preserved
  { "for f in a b; do mv $f $f.bak; done", "mv a a.bak; mv b b.bak" },
  { 'for x in a b; do echo "a\\$x"; done', 'echo "a\\$x"; echo "a\\$x"' }, -- escaped
  { "for x in a; do echo done; done", "echo done" }, -- done as an argument
  { "for x in a; do echo done; echo x; done", "echo done; echo x" },
  { "for x in a; do cp f done; done", "cp f done" },
  { 'for x in a; do echo "done"; done', 'echo "done"' },
  { "for i in 1 2 3; do wc -l f$i; done", "wc -l f1; wc -l f2; wc -l f3" },
  { "for x in a b; do cmd $x-y; done", "cmd a-y; cmd b-y" }, -- concatenation
  { "for x in a b; do echo $x; done &", nil }, -- loop backgrounded: precedence
  { "for x in a b; do cmd ${y}; done", "cmd ${y}; cmd ${y}" }, -- other ${} kept
  { "for x in a b; do cmd $x & done", nil }, -- body ends with &: join would be invalid

  -- loop expansion feeds back into the peel path
  { "for x in a b; do timeout 5 git add $x; done", "git add a; git add b" },
  { "for x in a; do timeout 5 cmd $x $x; done", "cmd a a" }, -- two substitution spans
  { "for x in a; do timeout --verbose 5 cmd $x; done", "cmd a" },

  -- multi-command bodies repeat faithfully
  {
    'for d in backend/lib backend/routes; do echo "== $d"; ls $d; done',
    'echo "== backend/lib"; ls backend/lib; echo "== backend/routes"; ls backend/routes',
  },
  {
    "for i in 1 2; do npx vitest run 2>&1 | grep Tests | tail -1; done",
    "npx vitest run 2>&1 | grep Tests | tail -1; npx vitest run 2>&1 | grep Tests | tail -1",
  },
  { "for x in a b; do cmd $x && echo ok; done", "cmd a && echo ok; cmd b && echo ok" },
  {
    'for e in bogus TEST; do NODE_ENV="$e" npx tsx -e "log()"; done',
    'NODE_ENV="bogus" npx tsx -e "log()"; NODE_ENV="TEST" npx tsx -e "log()"',
  },

  -- bail: not exactly equivalent
  { "for x in *.md; do cat $x; done", nil }, -- glob in list
  { "for x in $(ls); do cat $x; done", nil },
  { 'for x in "$@"; do cat $x; done', nil },
  { 'for d in a "$HOME"; do ls $d; done', nil }, -- quoted value
  { 'for pat in "a|b" c; do echo $pat; done', nil }, -- quoted value
  { "for i in $(seq 1 20); do sleep 1; done", nil },
  { "for ((i=0;i<3;i++)); do echo $i; done", nil },
  { "for x; do echo $x; done", nil }, -- no `in`
  { "for x in a; do", nil },
  { "for x in a b; do echo $x; done | head", nil }, -- pipeline around loop
  { "for x in a b; do echo $x; done > out", nil }, -- redirect after done
  { "for x in a b; do echo $x; done; echo more", nil },
  { "for x in a b; do echo $x; done # note", nil }, -- trailing comment
  { "for x in a b; do echo $((x)); done", nil },
  { "for x in a b; do cmd $x; done extra", nil },
  { "for x in a; do echo $x; done; done", nil }, -- double done
  { "for x in a; do # comment\necho $x\ndone", nil }, -- comment statement
  { "for x in a b; do break; done", nil },
  { "for x in a b; do exit 1; done", nil },
  { "cd x && for f in a; do cat $f; done", nil }, -- for not the whole command
  { "for x in a b; do cmd ${x:-d}; done", nil }, -- non-exact ${...}
  { "for x in a b; do cmd $(x); done", nil },
  { "for x in a b; do cmd `x`; done", nil },
  { "for x in a b; do cmd $x < in; done", "cmd a < in; cmd b < in" },
  { "for x in a b; do cmd $x > out; done", "cmd a > out; cmd b > out" },
  { "for x in a b; do cmd $x 2>&1; done", "cmd a 2>&1; cmd b 2>&1" },
  { "for x in a b; do cmd $x; done 2>err", nil }, -- redirect on the loop
  { "for x in a b; do cmd $x && done; done", nil },
  { "for x in a b c", nil },
  { "for", nil },
  { "for x in a b; do cmd $x", nil }, -- unterminated
}

for i, c in ipairs(cases) do
  case(("case %d: %s"):format(i, tostring(c[1])), function()
    eq(transform(c[1]), c[2])
  end)
end

-- Loop vs expansion: both run under real bash; stdout and exit code must
-- match. These verify the expansion-equivalence claim end to end.
local equivalence = {
  { 'for x in a b c; do echo "v=$x"; done', 'echo "v=a"; echo "v=b"; echo "v=c"' },
  {
    'for d in p q; do echo "== $d"; ls /nonexist_$d; done',
    'echo "== p"; ls /nonexist_p; echo "== q"; ls /nonexist_q',
  },
  { "for x in a b; do false && echo ok; done", "false && echo ok; false && echo ok" },
  {
    'for i in 1 2; do printf "%s\\n" "$i" | tr a-z A-Z; done',
    'printf "%s\\n" "1" | tr a-z A-Z; printf "%s\\n" "2" | tr a-z A-Z',
  },
  {
    "for f in a b; do mv --help >/dev/null 2>&1; echo $f; done",
    "mv --help >/dev/null 2>&1; echo a; mv --help >/dev/null 2>&1; echo b",
  },
  { "for x in a b; do echo done; done", "echo done; echo done" },
  { "for x in a b; do echo ${x}.txt; done", "echo a.txt; echo b.txt" },
  { 'for x in a b; do FOO="$x" printenv FOO; done', 'FOO="a" printenv FOO; FOO="b" printenv FOO' },
  { "for x in a b; do timeout 5 echo $x; done", "echo a; echo b" },
}

local function bash_out(cmd)
  local id = maki.fn.jobstart({ "/bin/bash", "-c", cmd }, { scope = "plugin" })
  local result = maki.fn.jobwait(id, 15000)
  assert(result, "timeout")
  return (result.stdout or ""), result.exit_code
end

local has_bash = pcall(bash_out, "exit 0")

for i, ec in ipairs(equivalence) do
  if has_bash then
    case(("equivalence %d: %s"):format(i, ec[1]), function()
      eq(transform(ec[1]), ec[2], "transform")
      local out1, code1 = bash_out(ec[1])
      local out2, code2 = bash_out(ec[2])
      eq(out1, out2, "stdout")
      eq(code1, code2, "exit code")
    end)
  end
end

th.report()
