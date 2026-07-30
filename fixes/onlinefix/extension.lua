--[[
  Online-Fix extension.lua
  Multiplayer and co-op fixes for Steam games.
  Unlike other fixes, online-fix downloads per-game RAR archives from
  perondepot.xyz on-demand rather than caching a single tool binary.
]]

local EXT_ID = "onlinefix"
local FIX_LOG_NAME = "lumaforge-fix-log.log"

local PERONDEPOT_URL = "https://api.perondepot.xyz/all/"
local RAR_PASSWORD = "online-fix.me"
local MAX_MANUAL_FILES = 10
local CACHE_TTL_SECS = 86400

-- ── helpers ──────────────────────────────────────────────────────────────────

local function log(level, msg)
  lumaforge.log(level, "[ONLINEFIX] " .. msg)
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

-- ── HTML parsing helpers (minimal) ──────────────────────────────────────────

--- Extract all `<a>` links from HTML. Returns list of { url, text }.
local function parse_links(html)
  local links = {}
  local pattern = '<a[^>]*href%s*=%s*"([^"]*)"[^>]*>(.-)</a>'
  local start = 1
  while true do
    local s, e, href, text = html:find(pattern, start)
    if not s then break end
    href = href:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#039;", "'")
    text = text:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
    table.insert(links, { url = href, text = text })
    start = e + 1
  end
  return links
end

--- Percent-encode non-ASCII bytes while preserving existing %XX sequences.
local function encode_non_ascii(input)
  local bytes = { input:byte(1, #input) }
  local out = {}
  local i = 1
  while i <= #bytes do
    if bytes[i] == 37 and i + 2 <= #bytes then -- '%'
      table.insert(out, string.char(bytes[i], bytes[i+1], bytes[i+2]))
      i = i + 3
    elseif bytes[i] < 128 then
      table.insert(out, string.char(bytes[i]))
      i = i + 1
    else
      table.insert(out, string.format("%%%02X", bytes[i]))
      i = i + 1
    end
  end
  return table.concat(out)
end

-- ── perondepot directory ────────────────────────────────────────────────────

local function fetch_perondepot_directory()
  log("INFO", "Fetching perondepot directory")
  local html = lumaforge.fetch_url(PERONDEPOT_URL)

  local links = parse_links(html)
  local entries = {}
  for _, link in ipairs(links) do
    local url = link.url
    local text = link.text

    if url:match("%.rar$") or text:match("%.rar$") then
      local full_url
      if url:match("^https?://") then
        full_url = encode_non_ascii(url)
      else
        full_url = PERONDEPOT_URL .. encode_non_ascii(url:gsub("^/", ""))
      end

      local filename = url:match("[^/]+$") or url
      local decoded = filename:gsub("%%([0-9A-Fa-f][0-9A-Fa-f])", function(h) return string.char(tonumber(h, 16)) end)
      local display_name = decoded:gsub("%.rar$", "")

      table.insert(entries, { url = full_url, displayName = display_name })
    end
  end

  log("INFO", "Found " .. #entries .. " entries")
  return entries
end

-- ── fuzzy matching ──────────────────────────────────────────────────────────

local function normalize(text)
  local s = text:lower()
  s = s:gsub("по сети", "")
  s = s:gsub("  ", " ")
  s = s:gsub("[%._%-]", " ")
  s = s:gsub("[^%a%d%s]", "")
  s = s:gsub("%s+", " ")
  return s:match("^%s*(.-)%s*$") or s
end

local function extract_game_name(display_name)
  local name = display_name:gsub("%.rar$", "")
  local pos = name:find("_")
  if pos then
    local prefix = name:sub(1, pos - 1):match("^%s*(.-)%s*$")
    local lower = prefix:lower()
    if lower ~= "fix" and lower ~= "crack" and lower ~= "update" and lower ~= "patch" then
      return prefix
    end
  end
  pos = name:find("-")
  if pos then
    local prefix = name:sub(1, pos - 1):match("^%s*(.-)%s*$")
    local lower = prefix:lower()
    if lower ~= "fix" and lower ~= "crack" and lower ~= "update" and lower ~= "patch" then
      return prefix
    end
  end
  return name:match("^%s*(.-)%s*$") or name
end

local function fuzzy_match(game_name, entries)
  local normalized_game = normalize(game_name)
  local game_words = {}
  for w in normalized_game:gmatch("%S+") do
    if #w > 1 then table.insert(game_words, w) end
  end
  local abbreviation = ""
  for _, w in ipairs(game_words) do
    abbreviation = abbreviation .. w:sub(1, 1)
  end

  local scored = {}
  for idx, entry in ipairs(entries) do
    local file_game = extract_game_name(entry.displayName)
    local normalized_file = normalize(file_game)

    local score
    if normalized_file == normalized_game then
      score = 0
    elseif normalized_file:find(normalized_game, 1, true) or normalized_game:find(normalized_file, 1, true) then
      score = 1
    else
      local file_words = {}
      for w in normalized_file:gmatch("%S+") do
        if #w > 1 then table.insert(file_words, w) end
      end
      local common = 0
      for _, gw in ipairs(game_words) do
        for _, fw in ipairs(file_words) do
          if fw == gw then common = common + 1; break end
        end
      end
      if common >= 2 then
        score = 2
      else
        local compact_file = normalized_file:gsub(" ", "")
        if compact_file:find(abbreviation, 1, true) or abbreviation:find(compact_file, 1, true) then
          score = 3
        else
          score = 999 + idx
        end
      end
    end

    table.insert(scored, { score = score, entry = entry })
  end

  table.sort(scored, function(a, b) return a.score < b.score end)

  local suggestions = {}
  for i = 1, math.min(MAX_MANUAL_FILES, #scored) do
    table.insert(suggestions, scored[i].entry.displayName)
  end

  if #scored > 0 and scored[1].score <= 3 then
    log("INFO", "Matched '" .. game_name .. "' -> " .. scored[1].entry.displayName)
    return scored[1].entry.url, suggestions
  end

  log("INFO", "No close match for '" .. game_name .. "'")
  return nil, suggestions
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

local function detect(game_path)
  log("INFO", "detect(" .. game_path .. ")")
  -- Check if a fix log exists — that's the best indicator
  if exists(game_path .. "\\" .. FIX_LOG_NAME) then
    return { status = "enabled" }
  end
  return { status = "available" }
end

local function install(ctx)
  log("INFO", "install() — online-fix has no global tool to install")
  return { success = true }
end

local function enable(game_path)
  log("INFO", "enable(" .. game_path .. ")")

  -- Extract game folder name as the game name
  local game_name = game_path:match([[\\([^\\]+)$]])
  if not game_name then
    game_name = game_path
  end
  log("INFO", "Game name: " .. game_name)

  -- Fetch perondepot directory
  local entries = fetch_perondepot_directory()
  if #entries == 0 then
    error("No entries found in perondepot directory")
  end

  -- Fuzzy match
  local matched_url, suggestions = fuzzy_match(game_name, entries)
  if not matched_url then
    local sug_list = table.concat(suggestions, ", ")
    return {
      success = false,
      requiresManualSelection = true,
      suggestions = suggestions,
      message = "Could not auto-match '" .. game_name .. "'. Available: " .. sug_list
    }
  end

  -- Download and extract RAR
  log("INFO", "Downloading " .. matched_url)

  -- Use extension temp directory for download
  local ext_dir = lumaforge.get_extension_dir(EXT_ID)
  local temp_dir = ext_dir .. "\\temp"
  lumaforge.create_dir(temp_dir)

  local rar_path = temp_dir .. "\\onlinefix.rar"
  lumaforge.download_file(matched_url, rar_path)

  local rar_size = lumaforge.file_status(rar_path)
  if rar_size.exists and rar_size.size < 1024 then
    error("Downloaded file is too small (" .. rar_size.size .. " bytes) — likely not a valid RAR")
  end

  log("INFO", "Extracting RAR to " .. game_path)
  local extracted = lumaforge.extract_rar(rar_path, game_path, RAR_PASSWORD)

  -- Cleanup
  pcall(function() lumaforge.remove_file(rar_path) end)

  -- Write fix log
  local files_str = ""
  for _, f in ipairs(extracted) do
    files_str = files_str .. f .. "\n"
  end
  local content = "[FIX]\nDate: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\nFix Type: OnlineFix\nMatched URL: " .. matched_url .. "\nFiles:\n" .. files_str .. "[/FIX]\n"
  lumaforge.write_text_file(game_path .. "\\" .. FIX_LOG_NAME, content)

  log("INFO", "Online-fix applied: " .. #extracted .. " files extracted")
  return { success = true, files = extracted }
end

local function disable(game_path)
  log("INFO", "disable(" .. game_path .. ")")

  -- Read fix log to determine which files were installed
  local log_path = game_path .. "\\" .. FIX_LOG_NAME
  if not exists(log_path) then
    log("INFO", "No fix log found — nothing to disable")
    return { success = true }
  end

  local content = lumaforge.read_text_file(log_path)
  local in_files = false
  local installed_files = {}

  for line in content:gmatch("[^\r\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$") or line
    if trimmed == "Files:" then
      in_files = true
    elseif trimmed == "[/FIX]" then
      in_files = false
    elseif in_files and #trimmed > 0 then
      table.insert(installed_files, trimmed)
    end
  end

  -- Remove installed files
  local removed_count = 0
  for _, f in ipairs(installed_files) do
    local full_path = game_path .. "\\" .. f
    if exists(full_path) then
      -- Check if there's a .bak to restore
      local bak_path = full_path .. ".bak"
      if exists(bak_path) then
        lumaforge.remove_file(full_path)
        lumaforge.rename_file(bak_path, full_path)
        log("INFO", "Restored " .. f .. " from backup")
      else
        lumaforge.remove_file(full_path)
        log("INFO", "Removed " .. f)
      end
      removed_count = removed_count + 1
    end
  end

  -- Remove fix log
  lumaforge.remove_file(log_path)

  log("INFO", "Disabled: " .. removed_count .. " files reverted")
  return { success = true, filesReverted = removed_count }
end

local function uninstall(ctx)
  log("INFO", "uninstall() — online-fix has no global tool to uninstall")
  return { success = true }
end

-- ── init ────────────────────────────────────────────────────────────────────

extension = {
  id          = EXT_ID,
  name        = "Online-Fix",
  version     = "1.0.0",
  description = "Multiplayer and co-op fixes for Steam games",
  detect      = detect,
  install     = install,
  enable      = enable,
  disable     = disable,
  uninstall   = uninstall,
}
