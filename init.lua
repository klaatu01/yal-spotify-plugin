-- spotify.lua (uses host.socket for PKCE loopback + host.db for token persistence)
local M = {}

-- Host deps exposed by your Rust preloads
local http = require("host.http")
local json = require("host.json")
local b64 = require("host.base64")
local log = require("host.log")
local ui = require("host.ui")
local socket = require("host.socket")
local dbmod = require("host.db")

-- persistent store for this plugin
local DB = dbmod.open("spotify")

-- -----------------------------------------------------------------------------
-- Utilities
-- -----------------------------------------------------------------------------

local function file_exists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end

local function is_macos()
	return file_exists("/usr/bin/osascript")
end

local function sh_single_quote(s)
	return "'" .. tostring(s):gsub("'", "'\"'\"'") .. "'"
end

local function clamp(n, lo, hi)
	n = tonumber(n) or lo
	return math.max(lo, math.min(hi, n))
end

-- run AppleScript (best-effort)
local function run_osa(script, argv)
	if not is_macos() then
		return false
	end
	local cmd = "/usr/bin/osascript -e " .. sh_single_quote(script)
	if argv and #argv > 0 then
		for _, a in ipairs(argv) do
			cmd = cmd .. " " .. sh_single_quote(a)
		end
	end
	local ok, _, code = os.execute(cmd)
	if type(ok) == "boolean" then
		return ok
	end
	return (ok == 0) or (code == 0)
end

local function run_osa_out(script, argv)
	if not is_macos() then
		return nil
	end
	local cmd = "/usr/bin/osascript -e " .. sh_single_quote(script)
	if argv and #argv > 0 then
		for _, a in ipairs(argv) do
			cmd = cmd .. " " .. sh_single_quote(a)
		end
	end
	local p = io.popen(cmd .. " 2>/dev/null", "r")
	if not p then
		return nil
	end
	local out = p:read("*a") or ""
	p:close()
	out = out:gsub("%s+$", "")
	if out == "" then
		return nil
	end
	return out
end

-- stealth launch (no focus steal)
local function ensure_spotify()
	if not is_macos() then
		return false
	end
	local osa = [[
    tell application id "com.spotify.client"
      if not running then launch
    end tell
  ]]
	return run_osa(osa)
end

-- -----------------------------------------------------------------------------
-- AppleScript snippets (fallback playback / controls)
-- -----------------------------------------------------------------------------

local osa_play_pause = [[
  if application id "com.spotify.client" is not running then
    tell application id "com.spotify.client" to launch
    delay 0.15
    tell application id "com.spotify.client" to play
  else
    tell application id "com.spotify.client" to playpause
  end if
]]

local osa_next = [[tell application "Spotify" to next track]]
local osa_prev = [[tell application "Spotify" to previous track]]

local osa_volume_set = [[
  on run argv
    set v to (item 1 of argv) as integer
    tell application "Spotify" to set sound volume to v
  end run
]]
local osa_volume_get = [[tell application "Spotify" to sound volume as integer]]

local osa_now_playing = [[
  if application "Spotify" is running then
    tell application "Spotify"
      set s to player state
      if s is playing or s is paused then
        set t to current track
        set nm to (name of t) as text
        set ar to (artist of t) as text
        set al to (album of t) as text
        return nm & " | " & ar & " | " & al & " | " & (s as text)
      else
        return ""
      end if
    end tell
  else
    return ""
  end if
]]

local osa_play_clipboard_uri = [[
  set u to the clipboard as text
  if u starts with "spotify:" then
    tell application "Spotify" to play track u
  else
    error "Clipboard does not contain a spotify:* URI"
  end if
]]

local osa_play_uri = [[
  on run argv
    set u to (item 1 of argv) as text
    tell application id "com.spotify.client"
      if not running then launch
      play track u
    end tell
  end run
]]

-- -----------------------------------------------------------------------------
-- Simple UI helpers
-- -----------------------------------------------------------------------------

local function volume_popup(current)
	local vol = clamp(current, 0, 100)
	return {
		hide = false,
		popup = {
			title = "Spotify Volume",
			ui_schema_version = 1,
			content = {
				{
					type = "form",
					name = "volume",
					submit_on_enter = true,
					submit_label = "Set",
					fields = {
						{
							kind = "slider",
							name = "vol",
							label = "Volume",
							min = 0,
							max = 100,
							step = 10,
							value = vol,
							show_value = true,
						},
					},
					submit = {
						kind = "command",
						plugin = "spotify",
						command = "volume_apply",
						presentation = "close_popup",
						args = {},
					},
				},
			},
			actions = {},
		},
	}
end

local function info_popup(now)
	local name = now and now.name or nil
	local artist = now and now.artist or ""
	local album = now and now.album or ""
	local state = now and now.state or ""

	local md
	if name and name ~= "" then
		md = ("**%s**\n\n%s\n%s\n\n_%s_"):format(name, artist, album, state)
	else
		md = "_Not playing_"
	end

	return {
		hide = false,
		popup = {
			title = "Spotify Info",
			ui_schema_version = 1,
			content = { { type = "markdown", md = md } },
			actions = {
				{ kind = "command", plugin = "spotify", command = "close", presentation = "close_popup", args = {} },
			},
		},
	}
end

local function current_volume()
	local out = run_osa_out(osa_volume_get)
	if not out then
		return 50
	end
	return clamp(tonumber(out) or 50, 0, 100)
end

local function now_playing()
	local out = run_osa_out(osa_now_playing)
	if not out or out == "" then
		return nil
	end
	local name, artist, album, state = out:match("^(.-)%s*|%s*(.-)%s*|%s*(.-)%s*|%s*(.-)$")
	if not name or name == "" then
		return nil
	end
	return { name = name or "", artist = artist or "", album = album or "", state = state or "" }
end

-- -----------------------------------------------------------------------------
-- Client Credentials (search)
-- -----------------------------------------------------------------------------

local CONFIG = {} -- set via init
local _cc_token, _cc_exp = nil, 0

local function have_cc()
	return type(CONFIG) == "table"
		and type(CONFIG.client_id) == "string"
		and CONFIG.client_id ~= ""
		and type(CONFIG.client_secret) == "string"
		and CONFIG.client_secret ~= ""
end

local function cc_get_token()
	local now = os.time()
	if _cc_token and now < _cc_exp then
		return _cc_token
	end
	if not have_cc() then
		return nil, "Missing client_id/client_secret"
	end

	local auth = b64.encode(CONFIG.client_id .. ":" .. CONFIG.client_secret)
	local res = http.request({
		method = "POST",
		url = "https://accounts.spotify.com/api/token",
		headers = {
			["Authorization"] = "Basic " .. auth,
			["Content-Type"] = "application/x-www-form-urlencoded",
		},
		body = "grant_type=client_credentials",
		timeout_ms = 8000,
		max_body_bytes = 256 * 1024,
	})
	if not res or res.status ~= 200 then
		return nil, "token http " .. tostring(res and res.status or "nil")
	end
	local obj = json.decode(res.body)
	if not obj or not obj.access_token then
		return nil, "token parse error"
	end
	_cc_token = obj.access_token
	local ttl = tonumber(obj.expires_in or 3600) or 3600
	_cc_exp = now + math.max(60, ttl - 60)
	return _cc_token
end

local function search_tracks(tok, q)
	local res = http.get("https://api.spotify.com/v1/search", {
		headers = { Authorization = "Bearer " .. tok },
		query = { q = q, type = "track", limit = "10" },
		timeout_ms = 10000,
	})
	assert(res and res.status == 200, "search failed: " .. tostring(res and res.status))
	return json.decode(res.body)
end

local function fmt_artist_list(artists)
	if type(artists) ~= "table" or #artists == 0 then
		return ""
	end
	local names = {}
	for _, a in ipairs(artists) do
		if a.name and a.name ~= "" then
			names[#names + 1] = a.name
		end
	end
	return table.concat(names, ", ")
end

local function build_items_from_search(obj)
	local items = {}
	if obj and obj.tracks and obj.tracks.items then
		for _, t in ipairs(obj.tracks.items) do
			local title = t.name or ""
			local artist = fmt_artist_list(t.artists or {})
			items[#items + 1] = {
				value = { uri = t.uri },
				label = artist ~= "" and (title .. " — " .. artist) or title,
			}
		end
	end
	return items
end

-- -----------------------------------------------------------------------------
-- PKCE (user auth) using host.socket loopback + persistent token storage
-- -----------------------------------------------------------------------------

local OAUTH = {
	client_id = nil, -- CONFIG.client_id
	redirect_uri = nil, -- e.g. "http://localhost:8888/callback"
	scopes = "user-modify-playback-state user-read-playback-state user-read-currently-playing",
}

local _user_tok = nil -- { access_token, refresh_token, expires_at }

-- persistence helpers
local function load_user_token_from_db()
	local t = DB:get("user_token")
	if t and type(t) == "table" and t.access_token then
		_user_tok = t
	end
end

local function save_user_token_to_db(t)
	if not t then
		return
	end
	DB:set("user_token", {
		access_token = t.access_token,
		refresh_token = t.refresh_token,
		expires_at = t.expires_at,
	})
end

local function urlenc(s)
	return (tostring(s):gsub("([^%w%-._~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function b64url_no_pad(raw_bytes_str)
	return b64.encode_url(raw_bytes_str, { pad = false })
end

local function random_bytes(n)
	local f = assert(io.open("/dev/urandom", "rb"))
	local d = f:read(n)
	f:close()
	assert(d and #d == n, "urandom failed")
	return d
end

-- Use openssl for SHA-256 (portable enough on macOS/Linux)
-- returns 32 raw bytes (Lua string) or errors
local function sha256_bytes(s)
	local tmp = os.tmpname()
	local f = assert(io.open(tmp, "wb"))
	f:write(s)
	f:close()

	-- macOS Lua only supports "r"/"w" modes; "rb" is invalid
	local cmd = "/usr/bin/openssl dgst -binary -sha256 " .. sh_single_quote(tmp) .. " 2>/dev/null"
	local p = assert(io.popen(cmd, "r"))
	local out = p:read("*a")
	p:close()
	os.remove(tmp)

	assert(out and #out == 32, "sha256 failed")
	return out
end

local function make_pkce()
	local verifier = b64url_no_pad(random_bytes(32)) -- ~43 chars
	local challenge = b64url_no_pad(sha256_bytes(verifier))
	return verifier, challenge
end

local function open_browser(url)
	if is_macos() then
		os.execute("open " .. sh_single_quote(url))
	else
		log.info("Open this URL in your browser:\n" .. url)
	end
end

local function try_bind_loopback(port, timeout_s)
	-- prefer IPv4 explicit, fall back to hostname (may map to ::1)
	local servers = {}
	local s1 = socket.bind("127.0.0.1", port)
	if s1 then
		s1:settimeout(timeout_s or 180)
		servers[#servers + 1] = s1
	end
	-- if 127 bind failed, try "localhost"
	if #servers == 0 then
		local s2 = socket.bind("localhost", port)
		if s2 then
			s2:settimeout(timeout_s or 180)
			servers[#servers + 1] = s2
		end
	end
	return servers[1] -- return the first that worked
end

local function wait_for_code_on(port, expected_state, timeout_s)
	local server = assert(try_bind_loopback(port, timeout_s), "loopback bind failed")
	local client, err = server:accept()
	if not client then
		return nil, err
	end
	client:settimeout(2)

	-- Read minimal HTTP request headers
	local lines = {}
	while true do
		local l = select(1, client:receive("*l"))
		if not l or l == "" then
			break
		end
		lines[#lines + 1] = l
	end

	local first = lines[1] or ""
	local path = first:match("GET%s+([^%s]+)") or ""
	local qs = path:match("%?(.*)") or ""
	local q = {}
	for k, v in qs:gmatch("([^&=?]+)=([^&=?]+)") do
		q[k] = v
	end
	local function urld(s)
		return (s or ""):gsub("%%(%x%x)", function(h)
			return string.char(tonumber(h, 16))
		end)
	end

	local code = urld(q.code)
	local state = urld(q.state)
	local ok = (state == expected_state)
	local body = ok and "OK, you can close this tab." or "State mismatch."

	client:send(
		"HTTP/1.1 "
			.. (ok and "200 OK" or "400 Bad Request")
			.. "\r\nContent-Type: text/plain\r\nContent-Length: "
			.. #body
			.. "\r\n\r\n"
			.. body
	)
	client:close()

	if not ok then
		return nil, "state mismatch"
	end
	if not code then
		return nil, "no code"
	end
	return code
end

local function token_exchange(code, verifier)
	local body = table.concat({
		"grant_type=authorization_code",
		"code=" .. urlenc(code),
		"redirect_uri=" .. urlenc(OAUTH.redirect_uri),
		"client_id=" .. urlenc(OAUTH.client_id),
		"code_verifier=" .. urlenc(verifier),
	}, "&")

	local r = http.request({
		method = "POST",
		url = "https://accounts.spotify.com/api/token",
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
		body = body,
		timeout_ms = 10000,
	})
	assert(r and r.status == 200, "token exchange http " .. tostring(r and r.status))
	local t = json.decode(r.body)
	assert(t and t.access_token, "bad token json")
	t.expires_at = os.time() + math.max(60, tonumber(t.expires_in or 3600) - 30)
	save_user_token_to_db(t)
	return t
end

local function token_refresh(refresh_token)
	local body = table.concat({
		"grant_type=refresh_token",
		"refresh_token=" .. urlenc(refresh_token),
		"client_id=" .. urlenc(OAUTH.client_id),
	}, "&")

	local r = http.request({
		method = "POST",
		url = "https://accounts.spotify.com/api/token",
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
		body = body,
		timeout_ms = 10000,
	})
	assert(r and r.status == 200, "refresh http " .. tostring(r and r.status))
	local t = json.decode(r.body)
	assert(t and t.access_token, "bad refresh json")
	t.refresh_token = t.refresh_token or refresh_token
	t.expires_at = os.time() + math.max(60, tonumber(t.expires_in or 3600) - 30)
	save_user_token_to_db(t)
	return t
end

local function get_user_token()
	-- cached and valid?
	if _user_tok and _user_tok.access_token and os.time() < (_user_tok.expires_at or 0) then
		return _user_tok.access_token
	end

	-- try persisted
	if not _user_tok then
		load_user_token_from_db()
		if _user_tok and _user_tok.access_token and os.time() < (_user_tok.expires_at or 0) then
			return _user_tok.access_token
		end
	end

	-- refresh if possible
	if _user_tok and _user_tok.refresh_token then
		local rr = token_refresh(_user_tok.refresh_token)
		_user_tok = rr
		return _user_tok.access_token
	end

	-- interactive PKCE
	if not OAUTH.client_id or not OAUTH.redirect_uri then
		return nil, "Missing client_id/redirect_uri in config"
	end

	local verifier, challenge = make_pkce()
	local state = b64url_no_pad(random_bytes(16))
	-- parse any :port; default to 8888 (and recommend localhost in config)
	local port = tonumber((OAUTH.redirect_uri or ""):match(":(%d+)")) or 8888

	local url = "https://accounts.spotify.com/authorize"
		.. "?client_id="
		.. urlenc(OAUTH.client_id)
		.. "&response_type=code"
		.. "&redirect_uri="
		.. urlenc(OAUTH.redirect_uri)
		.. "&code_challenge_method=S256"
		.. "&code_challenge="
		.. urlenc(challenge)
		.. "&scope="
		.. urlenc(OAUTH.scopes)
		.. "&state="
		.. urlenc(state)

	open_browser(url)
	local code, err = wait_for_code_on(port, state, 180)
	if not code then
		return nil, err or "auth failed"
	end

	_user_tok = token_exchange(code, verifier)
	return _user_tok.access_token
end

-- -----------------------------------------------------------------------------
-- Web API playback (requires user token + Premium + active device)
-- -----------------------------------------------------------------------------

local function api_get_devices(at)
	local r = http.request({
		method = "GET",
		url = "https://api.spotify.com/v1/me/player/devices",
		headers = { Authorization = "Bearer " .. at },
		timeout_ms = 8000,
	})
	if not r or r.status ~= 200 then
		return nil, r and r.status
	end
	local obj = json.decode(r.body) or {}
	return obj.devices or {}, 200
end

local function api_play_uri(at, uri, device_id)
	local url = "https://api.spotify.com/v1/me/player/play"
	if device_id and device_id ~= "" then
		url = url .. "?device_id=" .. urlenc(device_id)
	end
	local r = http.request({
		method = "PUT",
		url = url,
		headers = { Authorization = "Bearer " .. at, ["Content-Type"] = "application/json" },
		body = json.encode({ uris = { uri } }),
		timeout_ms = 8000,
	})
	return r and (r.status == 204 or r.status == 202), r and r.status, r and r.body
end

-- -----------------------------------------------------------------------------
-- Search flow (client credentials) + selection + playback (PKCE or AppleScript)
-- -----------------------------------------------------------------------------

local function search_flow(prefill)
	local query_prompt = ui.prompt({
		title = "Spotify Search",
		ui_schema_version = 1,
		content = {
			{
				type = "form",
				name = "spotify_search",
				fields = {
					{
						kind = "text",
						name = "query",
						label = "Query",
						placeholder = "track:One More Time artist:Daft Punk",
						value = prefill or "",
					},
				},
			},
		},
	})

	local query = (query_prompt and query_prompt.query) or ""
	if query:gsub("%s+", "") == "" then
		return { hide = true }
	end

	local cc_at, terr = cc_get_token()
	if not cc_at then
		ui.prompt({
			title = "Spotify API credentials required",
			ui_schema_version = 1,
			content = { { type = "markdown", md = "_Error:_ " .. tostring(terr) } },
		})
		return { hide = false }
	end

	local search_results = search_tracks(cc_at, query)
	local items = build_items_from_search(search_results)

	local select_prompt = ui.prompt({
		title = ("Results for “%s”"):format(query),
		ui_schema_version = 1,
		content = {
			{
				type = "form",
				name = "spotify_results",
				fields = {
					{ kind = "select", name = "choice", label = "Pick an item", options = items },
				},
			},
		},
	})

	local uri = select_prompt and select_prompt.choice and select_prompt.choice.uri
	if not (uri and uri:match("^spotify:")) then
		return { hide = true }
	end

	-- Prefer Web API playback (user token), fallback to AppleScript on macOS
	do
		local at = select(1, get_user_token() or {})
		if at then
			local devs = api_get_devices(at) or {}
			local device_id = nil
			if type(devs) == "table" then
				for _, d in ipairs(devs) do
					if d.is_active then
						device_id = d.id
						break
					end
					if not device_id and d.type == "Computer" then
						device_id = d.id
					end
				end
			end
			local ok = select(1, api_play_uri(at, uri, device_id))
			if not ok and is_macos() then
				ensure_spotify()
				run_osa(osa_play_uri, { uri })
			end
		elseif is_macos() then
			ensure_spotify()
			run_osa(osa_play_uri, { uri })
		end
	end

	return { hide = true }
end

-- -----------------------------------------------------------------------------
-- Plugin API
-- -----------------------------------------------------------------------------

function M.init(cfg)
	CONFIG = cfg or {}
	_cc_token, _cc_exp = nil, 0

	-- load persisted token (if any)
	_user_tok = nil
	load_user_token_from_db()

	OAUTH.client_id = CONFIG.client_id
	-- Spotify requires localhost for loopback redirect; default here if not provided
	OAUTH.redirect_uri = CONFIG.redirect_uri or "http://localhost:8888/callback"

	return {
		name = "spotify",
		description = "Spotify search (API) + playback (PKCE or AppleScript)",
		version = "0.4.0",
		author = "YAL",
		commands = {
			{ name = "play/pause", description = "Play / pause" },
			{ name = "next", description = "Next track" },
			{ name = "previous", description = "Previous track" },

			{ name = "volume", description = "Open volume slider" },
			{ name = "info", description = "Show current track info" },
			{ name = "play clipboard uri", description = "Play URI from clipboard (spotify:...)" },

			{ name = "connect", description = "Connect Spotify account (PKCE)" },
			{ name = "search", description = "Search & Play (API)" },

			{ name = "close", description = "Close popup (internal)", hidden = true },
		},
	}
end

function M.execute(req)
	local cmd = req and req.command

	if cmd == "connect" then
		local at, err = get_user_token()
		if not at then
			ui.prompt({
				title = "Spotify Connect Error",
				ui_schema_version = 1,
				content = { { type = "markdown", md = ("_Error:_ %s"):format(tostring(err)) } },
			})
			return { hide = false }
		end
		ui.prompt({
			title = "Spotify Connected",
			ui_schema_version = 1,
			content = { { type = "markdown", md = "Your account is connected. You can close this." } },
		})
		return { hide = false }
	end

	if cmd == "search" then
		return search_flow("")
	end

	if cmd == "play_uri" then
		local uri = req and req.args and req.args.uri
		if not (uri and type(uri) == "string" and uri:match("^spotify:")) then
			return { hide = true }
		end
		local at = select(1, get_user_token() or {})
		if at then
			local devs = api_get_devices(at) or {}
			local device_id = nil
			if type(devs) == "table" then
				for _, d in ipairs(devs) do
					if d.is_active then
						device_id = d.id
						break
					end
					if not device_id and d.type == "Computer" then
						device_id = d.id
					end
				end
			end
			local ok = select(1, api_play_uri(at, uri, device_id))
			if ok then
				return { hide = true }
			end
		end
		if is_macos() then
			ensure_spotify()
			local ok = run_osa(osa_play_uri, { uri })
			return { hide = ok }
		end
		return { hide = true }
	end

	-- macOS controls
	if not is_macos() then
		return { hide = false }
	end

	ensure_spotify()

	if cmd == "volume" then
		return volume_popup(current_volume())
	elseif cmd == "info" then
		return info_popup(now_playing())
	elseif cmd == "volume_apply" then
		local vol = 50
		local fields = (req and req.args and req.args.fields) or (req and req.fields)
		if fields and fields.vol ~= nil then
			vol = tonumber(fields.vol) or vol
		end
		vol = clamp(vol, 0, 100)
		local ok = run_osa(osa_volume_set, { tostring(vol) })
		return { hide = ok }
	elseif cmd == "close" then
		return { hide = true }
	end

	local ok = false
	if cmd == "play/pause" then
		ok = run_osa(osa_play_pause)
	elseif cmd == "next" then
		ok = run_osa(osa_next)
	elseif cmd == "previous" then
		ok = run_osa(osa_prev)
	elseif cmd == "play clipboard uri" then
		ok = run_osa(osa_play_clipboard_uri)
	else
		return { hide = false }
	end

	return { hide = ok }
end

return M
