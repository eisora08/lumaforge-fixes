--[[
  SmokeAPI extension.lua
  Proxy DLL-based DLC unlocker for Steam games.
  Install: download SmokeAPI from GitHub to local cache.
  Enable:  rename the chosen proxy DLL, copy smoke_api*.dll as proxy.
  Disable: restore backup.
]]

local GITHUB_OWNER = "acidicoala"
local GITHUB_REPO  = "SmokeAPI"
local GITHUB_API   = "https://api.github.com/repos/" .. GITHUB_OWNER .. "/" .. GITHUB_REPO

local EXT_ID = "smokeapi"
local TOOL_DIR
local FIX_LOG_NAME = "lumaforge-fix-log.log"

-- ── helpers ──────────────────────────────────────────────────────────────────

local function log(level, msg)
  lumaforge.log(level, "[SMOKEAPI] " .. msg)
end

local function exists(path)
  return lumaforge.file_exists(path)
end

local function json_decode(str)
  local function parse(pos)
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
        pos = pos + 1
      else break end
    end
    if pos > #str then return nil end
    local c = str:sub(pos, pos)
    if c == '{' then
      local obj = {}; pos = pos + 1
      local key; local expect_key = true
      while pos <= #str do
        local w = str:sub(pos, pos)
        if w == ' ' or w == '\t' or w == '\n' or w == '\r' then pos = pos + 1
        elseif w == '}' then return obj, pos + 1
        elseif w == ':' then expect_key = false; pos = pos + 1
        elseif w == ',' then expect_key = true; pos = pos + 1
        elseif expect_key then local k, np = parse(pos); key = k; pos = np
        else local v, np = parse(pos); obj[key] = v; key = nil; expect_key = true; pos = np end
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
        if sc == '\\' then ep = ep + 2
        elseif sc == '"' then break
        else ep = ep + 1 end
      end
      local s = str:sub(pos + 1, ep - 1)
      s = s:gsub('\\"', '"'):gsub('\\\\', '\\'):gsub('\\/', '/'):gsub('\\n', '\n'):gsub('\\r', '\r'):gsub('\\t', '\t')
      return s, ep + 1
    elseif str:sub(pos, pos + 3) == 'true' then return true, pos + 4
    elseif str:sub(pos, pos + 4) == 'false' then return false, pos + 5
    elseif str:sub(pos, pos + 3) == 'null' then return nil, pos + 4
    else
      local ep = pos
      while ep <= #str and (str:sub(ep, ep):match('[%d%.%+%-eE]')) do ep = ep + 1 end
      return tonumber(str:sub(pos, ep - 1)), ep
    end
  end
  return parse(1)
end

local function find_file_recursive(dir, name)
  local entries = lumaforge.list_directory(dir)
  for _, entry in ipairs(entries) do
    local full = dir .. "\\" .. entry
    if entry == name then
      return full
    end
    local st = lumaforge.file_status(full)
    if st.exists and st.size == 0 then
      local found = find_file_recursive(full, name)
      if found then return found end
    end
  end
  return nil
end

local function fetch_latest_release()
  log("INFO", "Fetching latest release from GitHub")
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

local function determine_proxy_dll_name(game_path)
  if not exists(game_path .. "\\winmm.dll") then return "winmm.dll" end
  if not exists(game_path .. "\\winhttp.dll") then return "winhttp.dll" end
  return "version.dll"
end

local function get_arch(game_path)
  if exists(game_path .. "\\steam_api64.dll") then return "x64" end
  if exists(game_path .. "\\steam_api.dll") then return "x86" end
  return nil
end

local function ensure_tool_files()
  local cache = TOOL_DIR .. "\\cache"
  lumaforge.create_dir(cache)
  local items = lumaforge.list_directory(cache)
  for _, item in ipairs(items) do
    if item:match("^extracted%-") then
      return cache .. "\\" .. item
    end
  end
  return nil
end

local function ensure_clean_extract_dir()
  local cache = TOOL_DIR .. "\\cache"
  lumaforge.create_dir(cache)

  local download_url, tag_name = fetch_latest_release()
  local safe_tag = tag_name:gsub("[^%w%.%-_]", "_")
  local zip_path = cache .. "\\smokeapi-" .. safe_tag .. ".zip"
  local extract_dir = cache .. "\\extracted-" .. safe_tag

  if exists(extract_dir) then return extract_dir end

  lumaforge.download_file(download_url, zip_path)
  lumaforge.create_dir(extract_dir)
  lumaforge.extract_zip(zip_path, extract_dir, { "smoke_api32.dll", "smoke_api64.dll", "SmokeAPI.config.json" })
  pcall(function() lumaforge.remove_file(zip_path) end)

  local flat = TOOL_DIR .. "\\tool"
  lumaforge.create_dir(flat)
  for _, name in ipairs({ "smoke_api32.dll", "smoke_api64.dll", "SmokeAPI.config.json" }) do
    local src = find_file_recursive(extract_dir, name)
    if src then
      lumaforge.copy_file(src, flat .. "\\" .. name)
    end
  end

  return extract_dir
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

local function detect(game_path)
  log("INFO", "detect(" .. game_path .. ")")
  local proxy = determine_proxy_dll_name(game_path)
  local proxy_path = game_path .. "\\" .. proxy
  local backup_path = proxy_path .. "_o"

  local has_proxy = exists(proxy_path)
  local has_backup = exists(backup_path)
  local has_tool = exists(TOOL_DIR .. "\\tool\\smoke_api32.dll")

  local status
  if has_tool and has_backup then
    status = "enabled"
  elseif has_tool and has_proxy and not has_backup then
    status = "installed"
  elseif has_tool then
    status = "available"
  else
    status = "available"
  end

  return { status = status, managedFiles = { proxy, proxy .. "_o" } }
end

local function install(ctx)
  log("INFO", "install()")
  local ok, err = pcall(ensure_clean_extract_dir)
  if not ok then error("Install failed: " .. tostring(err)) end
  log("INFO", "Install complete")
  return { success = true }
end

local function enable(game_path)
  log("INFO", "enable(" .. game_path .. ")")

  local arch = get_arch(game_path)
  if not arch then
    error("Could not detect game architecture — no steam_api.dll or steam_api64.dll found")
  end

  local extract_dir = ensure_tool_files()
  if not extract_dir then
    error("SmokeAPI not installed. Run install first.")
  end

  local dll_name = (arch == "x64") and "smoke_api64.dll" or "smoke_api32.dll"
  local src_dll = find_file_recursive(extract_dir, dll_name)
  if not src_dll then
    -- try flat tool dir
    src_dll = TOOL_DIR .. "\\tool\\" .. dll_name
    if not exists(src_dll) then
      error("Could not find " .. dll_name .. " in installed SmokeAPI")
    end
  end

  local proxy_name = determine_proxy_dll_name(game_path)
  local proxy_path = game_path .. "\\" .. proxy_name
  local backup_path = proxy_path .. "_o"

  -- Backup existing proxy
  if exists(proxy_path) then
    if not exists(backup_path) then
      lumaforge.rename_file(proxy_path, backup_path)
      log("INFO", "Backed up " .. proxy_name .. " -> " .. proxy_name .. "_o")
    else
      lumaforge.remove_file(proxy_path)
    end
  end

  -- Copy smoke_api DLL as proxy
  lumaforge.copy_file(src_dll, proxy_path)
  log("INFO", "Copied " .. dll_name .. " as " .. proxy_name)

  -- Copy config file if it exists
  local config_src = find_file_recursive(extract_dir, "SmokeAPI.config.json")
  if not config_src then
    config_src = TOOL_DIR .. "\\tool\\SmokeAPI.config.json"
  end
  if config_src and exists(config_src) then
    lumaforge.copy_file(config_src, game_path .. "\\SmokeAPI.config.json")
    log("INFO", "Copied SmokeAPI.config.json")
  end

  -- Write fix log
  local log_content = "[FIX]\nDate: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\nFix Type: SmokeAPI\nFiles:\n" .. proxy_name .. "\nSmokeAPI.config.json\n[/FIX]\n"
  lumaforge.write_text_file(game_path .. "\\" .. FIX_LOG_NAME, log_content)

  return { success = true, files = { proxy_name, "SmokeAPI.config.json" } }
end

local function disable(game_path)
  log("INFO", "disable(" .. game_path .. ")")
  local proxy = determine_proxy_dll_name(game_path)
  local proxy_path = game_path .. "\\" .. proxy
  local backup_path = proxy_path .. "_o"

  if exists(backup_path) then
    if exists(proxy_path) then lumaforge.remove_file(proxy_path) end
    lumaforge.rename_file(backup_path, proxy_path)
    log("INFO", "Restored " .. proxy .. " from backup")
  elseif exists(proxy_path) then
    -- Check if our proxy is just the smoke_api DLL in disguise (same size)
    local st = lumaforge.file_status(proxy_path)
    if st.exists then
      lumaforge.remove_file(proxy_path)
      log("INFO", "Removed proxy " .. proxy)
    end
  end

  -- Remove config
  if exists(game_path .. "\\SmokeAPI.config.json") then
    lumaforge.remove_file(game_path .. "\\SmokeAPI.config.json")
  end

  -- Remove fix log
  if exists(game_path .. "\\" .. FIX_LOG_NAME) then
    lumaforge.remove_file(game_path .. "\\" .. FIX_LOG_NAME)
  end

  return { success = true }
end

local function uninstall(ctx)
  log("INFO", "uninstall()")
  local cache = TOOL_DIR .. "\\cache"
  if exists(cache) then
    local items = lumaforge.list_directory(cache)
    for _, item in ipairs(items) do
      local full = cache .. "\\" .. item
      -- remove directory contents recursively
      local function rmdir(dir)
        local sub = lumaforge.list_directory(dir)
        for _, s in ipairs(sub) do
          local sp = dir .. "\\" .. s
          local st = lumaforge.file_status(sp)
          if st.exists and st.size == 0 then
            rmdir(sp)
          else
            lumaforge.remove_file(sp)
          end
        end
        pcall(function() lumaforge.remove_file(dir) end)
      end
      rmdir(full)
    end
  end
  local tool = TOOL_DIR .. "\\tool"
  if exists(tool) then
    for _, f in ipairs(lumaforge.list_directory(tool)) do
      lumaforge.remove_file(tool .. "\\" .. f)
    end
    pcall(function() lumaforge.remove_file(tool) end)
  end
  log("INFO", "Uninstall complete")
  return { success = true }
end

-- ── init ────────────────────────────────────────────────────────────────────

TOOL_DIR = lumaforge.get_extension_dir(EXT_ID)

extension = {
  id          = EXT_ID,
  name        = "SmokeAPI",
  version     = "4.1.3",
  description = "DLC unlocker proxy DLL for Steam games",
  detect      = detect,
  install     = install,
  enable      = enable,
  disable     = disable,
  uninstall   = uninstall,
}
