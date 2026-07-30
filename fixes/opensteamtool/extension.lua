--[[
  OpenSteamTool — Independent Lua Extension

  All lifecycle functions run inside the mlua sandbox with access to
  the lumaforge.* API.  Every file operation uses the Rust backend
  (std::fs on the host), so all I/O is sandboxed through Tauri IPC.
]]

-- ============================================================================
-- Constants
-- ============================================================================

local MANAGED_DLLS = { "dwmapi.dll", "xinput1_4.dll", "OpenSteamTool.dll" }

-- GitHub repository for release downloads
local GITHUB_OWNER = "OpenSteam001"
local GITHUB_REPO  = "OpenSteamTool"
local GITHUB_API   = "https://api.github.com/repos/" .. GITHUB_OWNER .. "/" .. GITHUB_REPO

-- ============================================================================
-- Minimal JSON Decoder (pure Lua, handles GitHub API response subset)
-- ============================================================================

local function json_parse(str, pos)
  pos = pos or 1
  while pos <= #str do
    local c = str:sub(pos, pos)
    if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
      pos = pos + 1
    else
      break
    end
  end
  if pos > #str then return nil end

  local c = str:sub(pos, pos)

  if c == '{' then
    local obj = {}
    pos = pos + 1
    local expecting_key = true
    local key = nil
    while pos <= #str do
      local w = str:sub(pos, pos)
      if w == ' ' or w == '\t' or w == '\n' or w == '\r' then
        pos = pos + 1
      elseif w == '}' then
        return obj, pos + 1
      elseif w == ':' then
        expecting_key = false
        pos = pos + 1
      elseif w == ',' then
        expecting_key = true
        pos = pos + 1
      elseif expecting_key then
        local k, np = json_parse(str, pos)
        if k == nil then return nil end
        key = k
        pos = np
      else
        local val, np = json_parse(str, pos)
        if val == nil then return nil end
        obj[key] = val
        key = nil
        expecting_key = true
        pos = np
      end
    end
    return obj, pos
  elseif c == '[' then
    local arr = {}
    pos = pos + 1
    while pos <= #str do
      local w = str:sub(pos, pos)
      if w == ' ' or w == '\t' or w == '\n' or w == '\r' then
        pos = pos + 1
      elseif w == ']' then
        return arr, pos + 1
      elseif w == ',' then
        pos = pos + 1
      else
        local val, np = json_parse(str, pos)
        if val == nil then return nil end
        table.insert(arr, val)
        pos = np
      end
    end
    return arr, pos
  elseif c == '"' then
    local end_pos = pos + 1
    while end_pos <= #str do
      local sc = str:sub(end_pos, end_pos)
      if sc == '\\' then
        end_pos = end_pos + 2
      elseif sc == '"' then
        break
      else
        end_pos = end_pos + 1
      end
    end
    local s = str:sub(pos + 1, end_pos - 1)
    s = s:gsub('\\"', '"'):gsub('\\\\', '\\'):gsub('\\/', '/'):gsub('\\n', '\n'):gsub('\\r', '\r'):gsub('\\t', '\t')
    return s, end_pos + 1
  elseif c == 't' and str:sub(pos, pos + 3) == 'true' then
    return true, pos + 4
  elseif c == 'f' and str:sub(pos, pos + 4) == 'false' then
    return false, pos + 5
  elseif c == 'n' and str:sub(pos, pos + 3) == 'null' then
    return nil, pos + 4
  else
    local end_pos = pos
    while end_pos <= #str do
      local nc = str:sub(end_pos, end_pos)
      if (nc >= '0' and nc <= '9') or nc == '-' or nc == '+' or nc == '.' or nc == 'e' or nc == 'E' then
        end_pos = end_pos + 1
      else
        break
      end
    end
    local num_str = str:sub(pos, end_pos - 1)
    return tonumber(num_str), end_pos
  end
end

local function json_decode(str)
  local val = json_parse(str, 1)
  return val
end

-- ============================================================================
-- Helpers
-- ============================================================================

--- Log a message through the LumaForge diagnostic channel.
local function log(level, msg)
  lumaforge.log(level, "[OPENSTEAMTOOL] " .. msg)
end

--- Check if a file exists on disk (Rust backend).
local function exists(path)
  return lumaforge.file_exists(path)
end

--- Safely rename a file, creating parent directories if needed.
local function rename(from, to)
  log("DEBUG", "rename " .. from .. " -> " .. to)
  lumaforge.rename_file(from, to)
end

--- Remove a file; returns true if it was removed, false if it didn't exist.
local function remove(path)
  log("DEBUG", "remove " .. path)
  return lumaforge.remove_file(path)
end

--- Return the config/lua folder path under the Steam root.
local function lua_folder(steam_root)
  return steam_root .. "\\config\\lua"
end

--- Return the config/lua.bak folder path under the Steam root.
local function lua_backup(steam_root)
  return steam_root .. "\\config\\lua.bak"
end

--- Fetch the latest release info from the GitHub API and return the
--- download URL for the zip asset and the tag name, or error on failure.
local function fetch_latest_release()
  log("INFO", "Fetching latest release from GitHub API")
  local url = GITHUB_API .. "/releases/latest"
  local response = lumaforge.fetch_url(url)
  if response == nil or response == "" then
    error("GitHub API returned an empty response")
  end

  local data = json_decode(response)
  if data == nil then
    error("Failed to parse GitHub API response JSON")
  end

  local tag_name = data.tag_name
  if tag_name == nil then
    error("GitHub API response missing 'tag_name'")
  end

  local assets = data.assets
  if assets == nil or #assets == 0 then
    error("No assets found in the latest GitHub release")
  end

  -- Find the first zip asset
  local download_url = nil
  for _, asset in ipairs(assets) do
    if asset.name and asset.name:match("%.zip$") then
      download_url = asset.browser_download_url
      if download_url then break end
    end
  end

  if download_url == nil then
    error("No zip asset found in the latest GitHub release")
  end

  log("INFO", "Found release " .. tag_name .. " at " .. download_url)
  return download_url, tag_name
end

--- Build a path string for a file in the extension's temp directory.
--- Ensures the temp directory exists.
local function temp_path(ext_dir, name)
  local tdir = ext_dir .. "\\temp"
  lumaforge.create_dir(tdir)
  return tdir .. "\\" .. name
end

-- ============================================================================
-- Detect
-- ============================================================================

--- Check physical presence of the 3 managed DLLs and their .bak states.
--- Returns a table with status, installedFiles, missingFiles, backupFiles.
local function detect(steam_root)
  log("INFO", "detect(steam_root=" .. steam_root .. ")")

  local installed = {}
  local missing   = {}
  local backups   = {}

  for _, dll in ipairs(MANAGED_DLLS) do
    local dll_path  = steam_root .. "\\" .. dll
    local bak_path  = dll_path .. ".bak"

    if exists(dll_path) then
      table.insert(installed, dll)
    else
      table.insert(missing, dll)
    end

    if exists(bak_path) then
      table.insert(backups, dll)
    end
  end

  local all_installed = #installed == #MANAGED_DLLS
  local all_backup    = #backups == #MANAGED_DLLS
  local none_exist    = #installed == 0 and not all_backup

  local status
  if none_exist and #backups == 0 then
    status = "available"
  elseif all_backup and #installed == 0 then
    status = "disabled"
  elseif all_installed then
    status = "enabled"
  else
    status = "installed"
  end

  log("INFO", "detect status=" .. status ..
              " installed=" .. #installed ..
              " missing=" .. #missing ..
              " backups=" .. #backups)

  return {
    status          = status,
    installedFiles  = installed,
    missingFiles    = missing,
    backupFiles     = backups,
    installedVersion = nil
  }
end

-- ============================================================================
-- Install
-- ============================================================================

--- Download the latest release from GitHub, extract the 3 DLLs, and
--- place them into the Steam root directory.  Also ensures the
--- config/lua directory exists after installation.
local function install(steam_root)
  log("INFO", "install(steam_root=" .. steam_root .. ")")

  -- Skip if already fully installed
  local current = detect(steam_root)
  if #current.installedFiles == #MANAGED_DLLS then
    log("INFO", "Already fully installed — skipping")
    return { success = true }
  end

  -- Resolve temp directory inside extension data dir
  local ext_dir = lumaforge.get_extension_dir("opensteamtool")

  -- Fetch latest release metadata from GitHub
  local download_url, tag_name = fetch_latest_release()
  local safe_tag = tag_name:gsub("[^%w%.%-_]", "_")

  -- Download zip
  local zip_path = temp_path(ext_dir, "opensteamtool-" .. safe_tag .. ".zip")
  log("INFO", "Downloading " .. download_url .. " -> " .. zip_path)
  lumaforge.download_file(download_url, zip_path)

  -- Extract DLLs
  local extract_dir = temp_path(ext_dir, "extracted-" .. safe_tag)
  lumaforge.create_dir(extract_dir)
  log("INFO", "Extracting to " .. extract_dir)
  local extracted = lumaforge.extract_zip(zip_path, extract_dir, MANAGED_DLLS)
  if #extracted == 0 then
    error("No managed DLLs found in the downloaded archive")
  end
  log("INFO", "Extracted " .. #extracted .. " files: " .. table.concat(extracted, ", "))

  -- Copy each DLL to the Steam root
  for _, dll in ipairs(MANAGED_DLLS) do
    local src = extract_dir .. "\\" .. dll
    local dst = steam_root .. "\\" .. dll

    -- Remove existing DLL first (rename fails if target exists)
    if exists(dst) then
      remove(dst)
    end

    rename(src, dst)
    log("INFO", "Placed " .. dll .. " into Steam root")
  end

  -- Safe config/lua lifecycle: restore backup if available, create if missing
  local lua_dir  = lua_folder(steam_root)
  local lua_bak  = lua_backup(steam_root)

  if exists(lua_bak) then
    -- Restore backup instead of creating empty directory (data preservation)
    if exists(lua_dir) then
      log("INFO", "config/lua already exists — backup preserved, using existing")
    else
      rename(lua_bak, lua_dir)
      log("INFO", "Restored config/lua from backup")
    end
  else
    -- No backup exists — create new directory only if missing
    if not exists(lua_dir) then
      lumaforge.create_dir(lua_dir)
      log("INFO", "Created empty config/lua directory")
    end
  end

  -- Cleanup temp files
  log("DEBUG", "Cleaning up temp files")
  pcall(function() remove(zip_path) end)
  for _, f in ipairs(extracted) do
    pcall(function() remove(extract_dir .. "\\" .. f) end)
  end

  log("INFO", "Install complete")
  return { success = true }
end

-- ============================================================================
-- Enable
-- ============================================================================

--- Restore .bak files to active .dll files and restore the config/lua
--- folder from its backup.  Skips files that are already active.
--- Safe no-op when already fully enabled.
local function enable(steam_root)
  log("INFO", "enable(steam_root=" .. steam_root .. ")")

  local any_work = false

  -- Rename .bak -> .dll for each managed DLL
  for _, dll in ipairs(MANAGED_DLLS) do
    local dll_path = steam_root .. "\\" .. dll
    local bak_path = dll_path .. ".bak"

    if exists(bak_path) then
      -- Remove active DLL if present (prevents rename collision)
      if exists(dll_path) then
        remove(dll_path)
      end
      rename(bak_path, dll_path)
      any_work = true
      log("INFO", "Enabled " .. dll)
    end
  end

  -- Safe config/lua lifecycle: restore backup if available, create if missing
  local lua_dir = lua_folder(steam_root)
  local lua_bak = lua_backup(steam_root)

  if exists(lua_bak) then
    -- Backup exists: restore it
    if not exists(lua_dir) then
      rename(lua_bak, lua_dir)
      any_work = true
      log("INFO", "Restored config/lua from backup")
    else
      log("INFO", "config/lua already exists — backup preserved, using existing")
    end
  else
    -- No backup: create if missing
    if not exists(lua_dir) then
      lumaforge.create_dir(lua_dir)
      any_work = true
      log("INFO", "Created empty config/lua directory")
    end
  end

  if not any_work then
    log("INFO", "Already enabled — no work done")
  end

  -- Verify: all DLLs should be active now
  for _, dll in ipairs(MANAGED_DLLS) do
    if not exists(steam_root .. "\\" .. dll) then
      error("Verification failed: " .. dll .. " not found after enable")
    end
  end

  return { success = true }
end

-- ============================================================================
-- Disable
-- ============================================================================

--- Move active .dll files to .bak and hide the config/lua folder.
--- Skips files already in the disabled state.  Safe no-op when already
--- fully disabled.
local function disable(steam_root)
  log("INFO", "disable(steam_root=" .. steam_root .. ")")

  local any_work = false

  -- Rename .dll -> .bak for each managed DLL
  for _, dll in ipairs(MANAGED_DLLS) do
    local dll_path = steam_root .. "\\" .. dll
    local bak_path = dll_path .. ".bak"

    if exists(dll_path) then
      -- Remove stale .bak if present (pre-emptive to avoid rename collision)
      if exists(bak_path) then
        remove(bak_path)
      end
      rename(dll_path, bak_path)
      any_work = true
      log("INFO", "Disabled " .. dll)
    end
  end

  -- Hide config/lua -> config/lua.bak (preserves user data)
  local lua_dir = lua_folder(steam_root)
  local lua_bak = lua_backup(steam_root)

  if exists(lua_dir) and exists(lua_bak) then
    log("WARN", "Cannot hide config/lua: config/lua.bak already exists — leaving as-is")
  elseif exists(lua_dir) then
    rename(lua_dir, lua_bak)
    any_work = true
    log("INFO", "Moved config/lua to config/lua.bak")
  end

  if not any_work then
    log("INFO", "Already disabled — no work done")
  end

  -- Verify: all DLLs should now be .bak
  for _, dll in ipairs(MANAGED_DLLS) do
    if not exists(steam_root .. "\\" .. dll .. ".bak") then
      error("Verification failed: " .. dll .. ".bak not found after disable")
    end
  end

  return { success = true }
end

-- ============================================================================
-- Uninstall
-- ============================================================================

--- Remove all managed DLLs (both .dll and .dll.bak) from the Steam root.
--- Also hides config/lua if it exists.  Works from any state (enabled,
--- disabled, or partially installed).
local function uninstall(steam_root)
  log("INFO", "uninstall(steam_root=" .. steam_root .. ")")

  local any_work = false

  -- Remove both .dll and .dll.bak for each managed DLL
  for _, dll in ipairs(MANAGED_DLLS) do
    local dll_path = steam_root .. "\\" .. dll
    local bak_path = dll_path .. ".bak"

    if exists(dll_path) then
      remove(dll_path)
      any_work = true
      log("INFO", "Removed " .. dll)
    end

    if exists(bak_path) then
      remove(bak_path)
      any_work = true
      log("INFO", "Removed " .. dll .. ".bak")
    end
  end

  -- Hide config/lua -> config/lua.bak (preserves user data)
  local lua_dir = lua_folder(steam_root)
  local lua_bak = lua_backup(steam_root)

  if exists(lua_dir) and exists(lua_bak) then
    log("WARN", "Cannot hide config/lua: config/lua.bak already exists — leaving as-is")
  elseif exists(lua_dir) then
    rename(lua_dir, lua_bak)
    any_work = true
    log("INFO", "Moved config/lua to config/lua.bak")
  end

  if not any_work then
    log("INFO", "Nothing to uninstall — already clean")
  end

  -- Verify: no DLLs or .bak files should remain
  for _, dll in ipairs(MANAGED_DLLS) do
    local dll_path = steam_root .. "\\" .. dll
    local bak_path = dll_path .. ".bak"
    if exists(dll_path) or exists(bak_path) then
      error("Verification failed: " .. dll .. " or " .. dll .. ".bak still exists after uninstall")
    end
  end

  return { success = true }
end

-- ============================================================================
-- Extension Contract
-- ============================================================================

extension = {
  -- Metadata (captured by load_and_evaluate into LuaExtensionTable)
  id          = "opensteamtool",
  name        = "OpenSteamTool (Community)",
  version     = "1.4.8",
  description = "DLL-based Steam integration tool (independent Lua module)",

  -- Lifecycle handlers (called by call_extension_* commands)
  detect      = detect,
  install     = install,
  enable      = enable,
  disable     = disable,
  uninstall   = uninstall
}
