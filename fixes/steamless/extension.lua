--[[
  Steamless extension.lua
  SteamStub DRM removal tool.
  Install: download Steamless from GitHub, cache Steamless.CLI.exe.
  Enable:  backup game EXE, run Steamless.CLI.exe against it, replace with unpacked.
  Disable: restore original EXE from .bak.
]]

local GITHUB_OWNER = "atom0s"
local GITHUB_REPO  = "Steamless"
local GITHUB_API   = "https://api.github.com/repos/" .. GITHUB_OWNER .. "/" .. GITHUB_REPO

local EXT_ID = "steamless"
local TOOL_DIR
local FIX_LOG_NAME = "lumaforge-fix-log.log"

-- ── helpers ──────────────────────────────────────────────────────────────────

local function log(level, msg)
  lumaforge.log(level, "[STEAMLESS] " .. msg)
end

local function exists(path)
  return lumaforge.file_exists(path)
end

local function json_decode(str)
  local function parse(pos)
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c == ' ' or c == '\t' or c == '\n' or c == '\r' then pos = pos + 1 else break end
    end
    if pos > #str then return nil end
    local c = str:sub(pos, pos)
    if c == '{' then
      local obj = {}; pos = pos + 1; local key; local ek = true
      while pos <= #str do
        local w = str:sub(pos, pos)
        if w == ' ' or w == '\t' or w == '\n' or w == '\r' then pos = pos + 1
        elseif w == '}' then return obj, pos + 1
        elseif w == ':' then ek = false; pos = pos + 1
        elseif w == ',' then ek = true; pos = pos + 1
        elseif ek then local k, np = parse(pos); key = k; pos = np
        else local v, np = parse(pos); obj[key] = v; key = nil; ek = true; pos = np end
      end
      return obj, pos
    elseif c == '[' then
      local arr = {}; pos = pos + 1
      while pos <= #str do
        local w = str:sub(pos, pos)
        if w == ' ' or w == '\t' or w == '\n' or w == '\r' then pos = pos + 1
        elseif w == ']' then return arr, pos + 1
        elseif w == ',' then pos = pos + 1
        else local v, np = parse(pos); table.insert(arr, v); pos = np end
      end
      return arr, pos
    elseif c == '"' then
      local ep = pos + 1
      while ep <= #str do
        local sc = str:sub(ep, ep)
        if sc == '\\' then ep = ep + 2 elseif sc == '"' then break else ep = ep + 1 end
      end
      local s = str:sub(pos + 1, ep - 1)
      s = s:gsub('\\"', '"'):gsub('\\\\', '\\'):gsub('\\/', '/'):gsub('\\n', '\n'):gsub('\\r', '\r'):gsub('\\t', '\t')
      return s, ep + 1
    elseif str:sub(pos, pos + 3) == 'true' then return true, pos + 4
    elseif str:sub(pos, pos + 4) == 'false' then return false, pos + 5
    elseif str:sub(pos, pos + 3) == 'null' then return nil, pos + 4
    else
      local ep = pos
      while ep <= #str and str:sub(ep, ep):match('[%d%.%+%-eE]') do ep = ep + 1 end
      return tonumber(str:sub(pos, ep - 1)), ep
    end
  end
  return parse(1)
end

local function find_file_recursive(dir, name)
  local entries = lumaforge.list_directory(dir)
  for _, entry in ipairs(entries) do
    local full = dir .. "\\" .. entry
    if entry == name then return full end
    local st = lumaforge.file_status(full)
    if st.exists and st.size == 0 then
      local found = find_file_recursive(full, name)
      if found then return found end
    end
  end
  return nil
end

local function find_main_exe(dir)
  local largest = lumaforge.find_largest_exe(dir, {})
  return largest
end

local function fetch_latest_release()
  log("INFO", "Fetching latest Steamless release from GitHub")
  local resp = lumaforge.fetch_url(GITHUB_API .. "/releases/latest")
  local data = json_decode(resp)
  if not data then error("Failed to parse GitHub API response") end
  local tag = data.tag_name
  local assets = data.assets
  if not assets or #assets == 0 then error("No assets in release") end
  for _, a in ipairs(assets) do
    if a.name and a.name:match("%.zip$") then
      log("INFO", "Found " .. tag .. " at " .. a.browser_download_url)
      return a.browser_download_url, tag
    end
  end
  error("No zip asset found")
end

local function ensure_tool_dir()
  local tool_dir = TOOL_DIR .. "\\tool"
  lumaforge.create_dir(tool_dir)
  local steamless_exe = tool_dir .. "\\Steamless.CLI.exe"
  if exists(steamless_exe) then
    return steamless_exe
  end

  -- Download and extract
  local download_url, tag_name = fetch_latest_release()
  local safe_tag = tag_name:gsub("[^%w%.%-_]", "_")
  local cache = TOOL_DIR .. "\\cache"
  lumaforge.create_dir(cache)
  local zip_path = cache .. "\\steamless-" .. safe_tag .. ".zip"
  local extract_dir = cache .. "\\extracted-" .. safe_tag

  if not exists(zip_path) then
    lumaforge.download_file(download_url, zip_path)
  end

  if not exists(extract_dir) then
    lumaforge.create_dir(extract_dir)
    lumaforge.extract_zip(zip_path, extract_dir, { "Steamless.CLI.exe", "Steamless.exe" })
  end

  -- Find and copy Steamless.CLI.exe to tool dir
  local exe_src = find_file_recursive(extract_dir, "Steamless.CLI.exe")
  if not exe_src then
    exe_src = find_file_recursive(extract_dir, "Steamless.exe")
  end
  if not exe_src then
    error("Could not find Steamless.CLI.exe or Steamless.exe in the downloaded archive")
  end

  lumaforge.copy_file(exe_src, steamless_exe)
  log("INFO", "Steamless.CLI.exe cached at " .. steamless_exe)

  return steamless_exe
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

local function detect(game_path)
  log("INFO", "detect(" .. game_path .. ")")
  local exe_name = find_main_exe(game_path)
  local status = "available"
  local managed = {}

  if exe_name then
    local exe_path = game_path .. "\\" .. exe_name
    local bak_path = exe_path .. ".bak"
    local has_tool = exists(TOOL_DIR .. "\\tool\\Steamless.CLI.exe")

    if has_tool and exists(bak_path) then
      status = "enabled"
    elseif has_tool then
      status = "available"
    end
    managed = { exe_name, exe_name .. ".bak" }
  end

  return { status = status, managedFiles = managed, mainExe = exe_name }
end

local function install(ctx)
  log("INFO", "install()")
  ensure_tool_dir()
  log("INFO", "Install complete")
  return { success = true }
end

local function enable(game_path)
  log("INFO", "enable(" .. game_path .. ")")

  local steamless_exe = TOOL_DIR .. "\\tool\\Steamless.CLI.exe"
  if not exists(steamless_exe) then
    error("Steamless not installed. Run install first.")
  end

  local exe_name = find_main_exe(game_path)
  if not exe_name then
    error("Could not find a main executable in " .. game_path)
  end

  local exe_path = game_path .. "\\" .. exe_name
  local bak_path = exe_path .. ".bak"
  local unpacked_path = game_path .. "\\" .. exe_name .. ".unpacked.exe"

  if exe_name:match("%.bak$") or exe_name:match("%.unpacked") then
    error("Invalid target exe (already unpacked or backup): " .. exe_name)
  end
  if exists(bak_path) then
    error("Steamless already applied (backup exists: " .. exe_name .. ".bak)")
  end

  log("INFO", "Running Steamless against " .. exe_path)
  local result = lumaforge.run_process(steamless_exe, { exe_path })

  if not result.success then
    local stdout = result.stdout or ""
    local stderr = result.stderr or ""

    -- Check if it's a "no DRM" scenario (all unpackers failed)
    if stdout:find("All unpackers failed") or stdout:find("is not supported") then
      log("INFO", "No SteamStub detected — nothing to unpack")
      local content = "[FIX]\nDate: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\nFix Type: Steamless\nStatus: No DRM detected (skipped)\n[/FIX]\n"
      lumaforge.write_text_file(game_path .. "\\" .. FIX_LOG_NAME, content)
      return { success = true, noDrm = true }
    end

    error("Steamless failed (exit " .. tostring(result.exitCode) .. "):\nstdout: " .. stdout .. "\nstderr: " .. stderr)
  end

  if not exists(unpacked_path) then
    error("Steamless reported success but unpacked file not found at " .. unpacked_path)
  end

  -- Backup original and replace with unpacked
  lumaforge.rename_file(exe_path, bak_path)
  lumaforge.rename_file(unpacked_path, exe_path)
  log("INFO", "Replaced " .. exe_name .. " with unpacked version (backup: " .. exe_name .. ".bak)")

  local content = "[FIX]\nDate: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\nFix Type: Steamless\nFiles:\n" .. exe_name .. "\n" .. exe_name .. ".bak\n[/FIX]\n"
  lumaforge.write_text_file(game_path .. "\\" .. FIX_LOG_NAME, content)

  return { success = true, files = { exe_name, exe_name .. ".bak" } }
end

local function disable(game_path)
  log("INFO", "disable(" .. game_path .. ")")

  local exe_name = find_main_exe(game_path)
  if not exe_name then
    log("WARN", "No main exe found, nothing to disable")
    return { success = true }
  end

  local exe_path = game_path .. "\\" .. exe_name
  local bak_path = exe_path .. ".bak"

  if exists(bak_path) then
    if exists(exe_path) then lumaforge.remove_file(exe_path) end
    lumaforge.rename_file(bak_path, exe_path)
    log("INFO", "Restored original " .. exe_name .. " from backup")
  end

  -- Clean up any orphan unpacked files
  local unpacked_path = game_path .. "\\" .. exe_name .. ".unpacked.exe"
  if exists(unpacked_path) then
    lumaforge.remove_file(unpacked_path)
  end

  if exists(game_path .. "\\" .. FIX_LOG_NAME) then
    lumaforge.remove_file(game_path .. "\\" .. FIX_LOG_NAME)
  end

  return { success = true }
end

local function uninstall(ctx)
  log("INFO", "uninstall()")

  local function rmdir(dir)
    if not exists(dir) then return end
    local sub = lumaforge.list_directory(dir)
    for _, s in ipairs(sub) do
      local sp = dir .. "\\" .. s
      local st = lumaforge.file_status(sp)
      if st.exists and st.size == 0 then rmdir(sp) else lumaforge.remove_file(sp) end
    end
    pcall(function() lumaforge.remove_file(dir) end)
  end

  rmdir(TOOL_DIR .. "\\tool")
  rmdir(TOOL_DIR .. "\\cache")
  log("INFO", "Uninstall complete")
  return { success = true }
end

-- ── init ────────────────────────────────────────────────────────────────────

TOOL_DIR = lumaforge.get_extension_dir(EXT_ID)

extension = {
  id          = EXT_ID,
  name        = "Steamless",
  version     = "3.0.0",
  description = "SteamStub DRM removal tool",
  detect      = detect,
  install     = install,
  enable      = enable,
  disable     = disable,
  uninstall   = uninstall,
}
