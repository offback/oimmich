-- config-to-json.lua — load the user's config.lua, merge it over the defaults,
-- validate it, and print one line of JSON for the QML side to parse.
--
-- Why a loader instead of a parser: QML cannot execute Lua, and hand-rolled YAML
-- is a bug farm. Lua is already a hard dependency of Hyprland on this Omarchy
-- generation (pacman -Qi lua -> Required By: hyprland), so this costs no
-- dependency at all, keeps comments in the config, and lets users compute values.
--
-- Usage: lua config-to-json.lua [/path/to/config.lua]
--        no argument (or a missing file) yields the built-in defaults.
-- Exit:  0 ok, 2 the config has an error (message on stderr, defaults on stdout).

local DEFAULTS = {
  server = {
    url = "https://immich.example.com",
    api_key_file = "~/.config/omarchy/immich-screensaver/api-key",
    verify_tls = true,
  },
  source = {
    albums = {},
    mode = "shuffle",
    stills_only = true,
    from = nil,
    to = nil,
  },
  display = {
    idle_seconds = 150,
    seconds_per_photo = 30,
    crossfade_ms = 1200,
    ken_burns = true,
    order = "shuffle",
    prefetch = 3,
  },
  sizing = {
    quality = "preview",
    fill = "blur",
    blur_strength = 0.8,
    darken = 0.12,
  },
  overlay = {
    clock = false,
    date = false,
    caption = false,
  },
  monitors = {
    mode = "same",
  },
  cache = {
    dir = "~/.cache/omarchy-immich-screensaver",
    max_gb = 2,
    refresh_minutes = 60,
  },
}

-- Enum / range rules, checked after the merge so a bad user value never reaches QML.
local RULES = {
  ["source.mode"] = { enum = { "shuffle", "newest", "oldest" } },
  ["display.order"] = { enum = { "shuffle", "sequential" } },
  ["sizing.quality"] = { enum = { "preview", "fullsize" } },
  ["sizing.fill"] = { enum = { "blur", "black", "solid" } },
  ["monitors.mode"] = { enum = { "same", "independent" } },
  ["display.idle_seconds"] = { int = true, min = 0, max = 86400 },
  ["display.seconds_per_photo"] = { int = true, min = 3, max = 3600 },
  ["display.crossfade_ms"] = { int = true, min = 0, max = 10000 },
  ["display.prefetch"] = { int = true, min = 0, max = 20 },
  ["sizing.blur_strength"] = { min = 0, max = 1.5 },
  ["sizing.darken"] = { min = 0, max = 0.9 },
  ["cache.max_gb"] = { min = 0.1, max = 500 },
  ["cache.refresh_minutes"] = { int = true, min = 1, max = 10080 },
}

local function is_table(v)
  return type(v) == "table"
end

local function is_array(v)
  if not is_table(v) then return false end
  local n = 0
  for k in pairs(v) do
    if math.type(k) ~= "integer" then return false end
    n = n + 1
  end
  return n == #v
end

-- Deep merge: user values win, unknown keys are kept for forward compatibility
-- but reported, since a typo ("idle_seconds" vs "idle_second") is the usual bug.
local function merge(base, override, path, unknown, errors)
  path = path or ""
  unknown = unknown or {}
  errors = errors or {}

  if not is_table(override) then
    errors[#errors + 1] = string.format("%s must be a table, got %s", path, type(override))
    return base
  end

  for k, v in pairs(override) do
    if type(k) ~= "string" then
      errors[#errors + 1] = string.format("%s: non-string key %s", path, tostring(k))
    elseif not is_table(base) or base[k] == nil then
      local full = path == "" and k or (path .. "." .. k)
      unknown[#unknown + 1] = full
      if is_table(base) then base[k] = v end
    elseif is_table(v) and not is_array(v) then
      merge(base[k], v, path == "" and k or (path .. "." .. k), unknown, errors)
    else
      base[k] = v
    end
  end

  return base
end

local function deepcopy(v)
  if not is_table(v) then return v end
  local out = {}
  for k, val in pairs(v) do out[k] = deepcopy(val) end
  return out
end

local function get_path(root, dotted)
  local cur = root
  for part in dotted:gmatch("[^%.]+") do
    if not is_table(cur) then return nil end
    cur = cur[part]
  end
  return cur
end

local function validate(cfg, errors)
  for path, rule in pairs(RULES) do
    local v = get_path(cfg, path)
    if v ~= nil then
      local ok = true
      if rule.enum then
        ok = false
        for _, allowed in ipairs(rule.enum) do
          if v == allowed then ok = true break end
        end
        if not ok then
          errors[#errors + 1] = string.format("%s must be one of %s, got %s",
            path, table.concat(rule.enum, ", "), tostring(v))
        end
      elseif type(v) ~= "number" then
        errors[#errors + 1] = string.format("%s must be a number, got %s", path, type(v))
      else
        if rule.int and math.type(v) ~= "integer" then
          errors[#errors + 1] = string.format("%s must be a whole number, got %s", path, tostring(v))
          ok = false
        end
        if rule.min and v < rule.min then
          errors[#errors + 1] = string.format("%s must be >= %s, got %s", path, tostring(rule.min), tostring(v))
          ok = false
        end
        if rule.max and v > rule.max then
          errors[#errors + 1] = string.format("%s must be <= %s, got %s", path, tostring(rule.max), tostring(v))
          ok = false
        end
      end
    end
  end

  if type(cfg.server.url) ~= "string" or not cfg.server.url:match("^https?://") then
    errors[#errors + 1] = "server.url must start with http:// or https://"
  end
  if type(cfg.server.api_key_file) ~= "string" or cfg.server.api_key_file == "" then
    errors[#errors + 1] = "server.api_key_file must be a path"
  end
  if not is_array(cfg.source.albums) then
    errors[#errors + 1] = "source.albums must be a list (use {} for all photos)"
  end
end

-- Expand a leading ~ so scripts get absolute paths; $HOME is the only expansion
-- needed and shell-style ${VAR} substitution would be a surprise here.
local function expand_home(p)
  if type(p) ~= "string" then return p end
  local home = os.getenv("HOME") or ""
  if p == "~" then return home end
  if p:sub(1, 2) == "~/" then return home .. p:sub(2) end
  return p
end

-- Minimal JSON encoder for the value types a config can hold.
local function json(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then
    if math.type(v) == "integer" then return string.format("%d", v) end
    return string.format("%.6g", v)
  end
  if t == "string" then
    local out = v:gsub('[%z\1-\31\\"]', function(c)
      if c == '"' then return '\\"' end
      if c == "\\" then return "\\\\" end
      if c == "\n" then return "\\n" end
      if c == "\r" then return "\\r" end
      if c == "\t" then return "\\t" end
      return string.format("\\u%04x", c:byte())
    end)
    return '"' .. out .. '"'
  end
  if t == "table" then
    if is_array(v) then
      local parts = {}
      for i = 1, #v do parts[i] = json(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = json(k) .. ":" .. json(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

local function main(argv)
  local path = argv[1]
  local cfg = deepcopy(DEFAULTS)
  local errors, unknown = {}, {}
  local loaded = false

  if path and path ~= "" then
    local fh, open_err = io.open(path, "r")
    if fh then
      fh:close()
      -- setfenv-style isolation is not available for dofile, so a syntax error is
      -- caught with pcall and reported rather than taking the shell down.
      local ok, result = pcall(dofile, path)
      if not ok then
        errors[#errors + 1] = "config.lua failed to load: " .. tostring(result)
      elseif not is_table(result) then
        errors[#errors + 1] = "config.lua must return a table, got " .. type(result)
      else
        loaded = true
        merge(cfg, result, "", unknown, errors)
      end
    else
      errors[#errors + 1] = "cannot read " .. tostring(path) .. ": " .. tostring(open_err)
    end
  end

  cfg.source.albums = is_array(cfg.source.albums) and cfg.source.albums or {}
  validate(cfg, errors)

  cfg.server.api_key_file = expand_home(cfg.server.api_key_file)
  cfg.cache.dir = expand_home(cfg.cache.dir)
  cfg.server.url = tostring(cfg.server.url):gsub("/+$", "")

  local payload = {
    config = cfg,
    meta = {
      path = path or "",
      loaded = loaded,
      unknown = unknown,
      errors = errors,
    },
  }

  io.stdout:write(json(payload) .. "\n")
  return #errors == 0 and 0 or 2
end

os.exit(main(arg))
