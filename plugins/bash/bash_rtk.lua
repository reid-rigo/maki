-- Optional command rewriting through `rtk`: when installed and not disabled
-- in config, some `cargo`/`find` invocations are rewritten before they run.
-- Returns nil whenever rtk is unavailable, times out, or the rewritten
-- command contains anything we cannot vouch for — the original then runs.

local RTK_REWRITE_TIMEOUT_MS = 2000
local RTK_REWRITE_TIMEOUT_MS = 2000
local RTK_UNSUPPORTED_FLAGS = {
  " -o ",
  " -not ",
  " ! ",
  " -exec ",
  " -execdir ",
  " -print0",
  " -delete",
  " -ok ",
  " -okdir ",
  " -fprint",
  " -fls ",
  " -fprintf ",
}

local rtk_available

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function find_unsupported(cmd)
  if not cmd:match("^rtk find ") then
    return false
  end
  for _, flag in ipairs(RTK_UNSUPPORTED_FLAGS) do
    if cmd:find(flag, 1, true) then
      return true
    end
  end
  return false
end

-- Returns the rewritten command, or nil to keep the original.
local function rewrite(command, ctx)
  local config = ctx:config()
  if config and not config.rtk then
    return nil
  end

  if rtk_available == nil then
    local id = maki.fn.jobstart("rtk --version")
    local result = maki.fn.jobwait(id, RTK_REWRITE_TIMEOUT_MS)
    if result then
      rtk_available = (result.exit_code == 0)
    else
      maki.fn.jobstop(id)
      rtk_available = false
    end
  end

  if not rtk_available then
    return nil
  end

  local cmd = command:match("^%s*(.-)%s*$")
  if cmd:match("^cargo ") and cmd:find(" -- ", 1, true) then
    return nil
  end

  local id = maki.fn.jobstart("rtk rewrite " .. shell_quote(command))
  local result = maki.fn.jobwait(id, RTK_REWRITE_TIMEOUT_MS)
  if not result then
    maki.fn.jobstop(id)
    return nil
  end

  if result.exit_code ~= 0 and result.exit_code ~= 3 then
    return nil
  end

  local rewritten = (result.stdout or ""):match("^%s*(.-)%s*$")
  if rewritten == "" or rewritten == command:match("^%s*(.-)%s*$") then
    return nil
  end
  if find_unsupported(rewritten) then
    return nil
  end
  return rewritten
end

return {
  rewrite = rewrite,
}
