--[[
  GSE Fork (Goldberg) extension.lua
  Steam client emulator for offline play.
  Install: download GSE Fork from GitHub, cache steamclient.dll / steamclient64.dll.
  Enable:  copy DLLs to game folder with backup.
  Disable: restore originals from backup.
]]

local GITHUB_OWNER = "alex47exe"
local GITHUB_REPO  = "gse_fork"
local GITHUB_API   = "https://api.github.com/repos/" .. GITHUB_OWNER .. "/" .. GITHUB_REPO

local EXT_ID = "gse_fork"
local TOOL_DIR
local MANAGED_DLLS = { "steamclient.dll", "steamclient64.dll" }
local BACKUP_SUFFIX = ".bak"
local FIX_LOG_NAME = "lumaforge-fix-log.log"

-- ── helpers ──────────────────────────────────────────────────────────────────

local function log(level, msg)
  lumaforge.log(level, "[GSE_FORK] " .. msg)
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

local function fetch_latest_release()
  log("INFO", "Fetching latest GSE Fork release from GitHub")
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

  -- Check if DLLs are already cached
  local all_cached = true
  for _, dll in ipairs(MANAGED_DLLS) do
    if not exists(tool_dir .. "\\" .. dll) then
      all_cached = false
      break
    end
  end
  if all_cached then return tool_dir end

  -- Download and extract
  local download_url, tag_name = fetch_latest_release()
  local safe_tag = tag_name:gsub("[^%w%.%-_]", "_")
  local cache = TOOL_DIR .. "\\cache"
  lumaforge.create_dir(cache)
  local zip_path = cache .. "\\gse_fork-" .. safe_tag .. ".zip"
  local extract_dir = cache .. "\\extracted-" .. safe_tag

  if not exists(zip_path) then
    lumaforge.download_file(download_url, zip_path)
  end

  if not exists(extract_dir) then
    lumaforge.create_dir(extract_dir)
    lumaforge.extract_zip(zip_path, extract_dir, MANAGED_DLLS)
  end

  -- Copy DLLs to flat tool dir
  for _, dll in ipairs(MANAGED_DLLS) do
    local src = find_file_recursive(extract_dir, dll)
    if src then
      lumaforge.copy_file(src, tool_dir .. "\\" .. dll)
      log("INFO", "Cached " .. dll)
    else
      log("WARN", dll .. " not found in archive — may be optional")
    end
  end

  return tool_dir
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

local function detect(game_path)
  log("INFO", "detect(" .. game_path .. ")")
  local installed_count = 0
  local enabled_count = 0

  for _, dll in ipairs(MANAGED_DLLS) do
    local dll_path = game_path .. "\\" .. dll
    local bak_path = dll_path .. BACKUP_SUFFIX

    if exists(dll_path) and exists(bak_path) then
      enabled_count = enabled_count + 1
    elseif exists(bak_path) then
      installed_count = installed_count + 1
    end
  end

  local has_tool = exists(TOOL_DIR .. "\\tool\\steamclient.dll")
  local status
  if has_tool and enabled_count == #MANAGED_DLLS then
    status = "enabled"
  elseif has_tool and installed_count > 0 then
    status = "installed"
  elseif has_tool then
    status = "available"
  else
    status = "available"
  end

  return { status = status }
end

local function install(ctx)
  log("INFO", "install()")
  ensure_tool_dir()
  log("INFO", "Install complete")
  return { success = true }
end

local function enable(game_path)
  log("INFO", "enable(" .. game_path .. ")")

  local tool_dir = TOOL_DIR .. "\\tool"
  for _, dll in ipairs(MANAGED_DLLS) do
    local src = tool_dir .. "\\" .. dll
    if not exists(src) then
      log("WARN", dll .. " not cached, skipping")
    else
      local dst = game_path .. "\\" .. dll
      local bak = dst .. BACKUP_SUFFIX

      -- Backup existing file if not already backed up
      if exists(dst) and not exists(bak) then
        lumaforge.rename_file(dst, bak)
        log("INFO", "Backed up " .. dll)
      elseif exists(dst) and exists(bak) then
        lumaforge.remove_file(dst)
      end

      lumaforge.copy_file(src, dst)
      log("INFO", "Copied " .. dll .. " to game folder")
    end
  end

  local files_str = ""
  for _, dll in ipairs(MANAGED_DLLS) do
    files_str = files_str .. dll .. "\n"
  end
  local content = "[FIX]\nDate: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\nFix Type: GSE Fork\nFiles:\n" .. files_str .. "[/FIX]\n"
  lumaforge.write_text_file(game_path .. "\\" .. FIX_LOG_NAME, content)

  return { success = true }
end

local function disable(game_path)
  log("INFO", "disable(" .. game_path .. ")")

  for _, dll in ipairs(MANAGED_DLLS) do
    local dst = game_path .. "\\" .. dll
    local bak = dst .. BACKUP_SUFFIX

    if exists(bak) then
      if exists(dst) then lumaforge.remove_file(dst) end
      lumaforge.rename_file(bak, dst)
      log("INFO", "Restored " .. dll .. " from backup")
    elseif exists(dst) then
      lumaforge.remove_file(dst)
      log("INFO", "Removed " .. dll)
    end
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
  name        = "GSE Fork",
  version     = "0.4.0",
  description = "Steam client emulator for offline play",
  detect      = detect,
  install     = install,
  enable      = enable,
  disable     = disable,
  uninstall   = uninstall,
}
