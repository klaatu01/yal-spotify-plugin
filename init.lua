-- init.lua
local M = {}

-- --- Utilities ---------------------------------------------------------------

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

local function run_osa(script, argv)
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

-- Ensure Spotify is running (without stealing focus if already open)
local function ensure_spotify()
	if not is_macos() then
		return false
	end
	local script = [[
    tell application "System Events"
      if not (exists process "Spotify") then
        tell application "Spotify" to activate
        delay 0.25
      end if
    end tell
  ]]
	return run_osa(script)
end

-- Helpers: safe arithmetic bounds
local function clamp(n, lo, hi)
	return math.max(lo, math.min(hi, n))
end

-- --- AppleScript snippets ----------------------------------------------------

local osa_play_pause = [[
  if application "Spotify" is not running then
    tell application "Spotify" to activate
    delay 0.25
    tell application "Spotify" to play
  else
    tell application "Spotify" to playpause
  end if
]]

local osa_next = [[tell application "Spotify" to next track]]
local osa_prev = [[tell application "Spotify" to previous track]]

-- Volume set (0-100)
local osa_volume_set = [[
  on run argv
    set v to (item 1 of argv) as integer
    tell application "Spotify" to set sound volume to v
  end run
]]

-- Read current volume → toggle mute to 0 / restore prior via a scratch file
local function spotify_volume_mute_toggle()
	local scratch = os.getenv("TMPDIR") or "/tmp/"
	local file = scratch .. "yal_spotify_prev_volume"
	-- get current volume
	local get_vol = [[tell application "Spotify" to sound volume as integer]]
	local ok = run_osa(get_vol)
	-- osascript prints to stdout, but we're not capturing. Use inline toggle logic instead:
	local script = [[
    set cacheFile to POSIX file (do shell script "echo ${TMPDIR:-/tmp}/yal_spotify_prev_volume")
    tell application "Spotify"
      set v to sound volume
      if v is greater than 0 then
        do shell script "mkdir -p ${TMPDIR:-/tmp} && echo " & v & " > " & quoted form of POSIX path of cacheFile
        set sound volume to 0
      else
        try
          set oldv to do shell script "cat " & quoted form of POSIX path of cacheFile
          set sound volume to oldv as integer
        on error
          set sound volume to 50
        end try
      end if
    end tell
  ]]
	return run_osa(script)
end

-- Shuffle toggle
local osa_shuffle_toggle = [[
  tell application "Spotify"
    set shuffling to not shuffling
  end tell
]]

-- Repeat all toggle
local osa_repeat_toggle = [[
  tell application "Spotify"
    set repeating to not repeating
  end tell
]]

-- Repeat one toggle
local osa_repeat_one_toggle = [[
  tell application "Spotify"
    set repeating to true
    set repeating track to not repeating track
  end tell
]]

-- Seek relative seconds (+/-)
local osa_seek_rel = [[
  on run argv
    set delta to (item 1 of argv) as integer
    tell application "Spotify"
      set p to player position
      set np to p + delta
      if np < 0 then set np to 0
      set player position to np
    end tell
  end run
]]

-- Play a spotify:* URI from clipboard if looks valid
local osa_play_clipboard_uri = [[
  set u to the clipboard as text
  if u starts with "spotify:" then
    tell application "Spotify" to play track u
  else
    error "Clipboard does not contain a spotify:* URI"
  end if
]]

-- --- Plugin API --------------------------------------------------------------

function M.init()
	return {
		name = "spotify",
		description = "Spotify controls via osascript",
		version = "0.1.0",
		author = "YAL",
		commands = {
			{ name = "spotify_play_pause", description = "Play / pause" },
			{ name = "spotify_next", description = "Next track" },
			{ name = "spotify_previous", description = "Previous track" },
			{ name = "spotify_volume_up", description = "Volume +6" },
			{ name = "spotify_volume_down", description = "Volume -6" },
			{ name = "spotify_volume_mute_toggle", description = "Mute / restore volume" },
			{ name = "spotify_shuffle_toggle", description = "Toggle shuffle" },
			{ name = "spotify_repeat_toggle", description = "Toggle repeat all" },
			{ name = "spotify_repeat_one_toggle", description = "Toggle repeat one" },
			{ name = "spotify_seek_forward", description = "Seek +10 seconds" },
			{ name = "spotify_seek_back", description = "Seek -10 seconds" },
			{ name = "spotify_play_clipboard_uri", description = "Play URI from clipboard (spotify:...)" },
		},
	}
end

function M.execute(req)
	local cmd = req and req.command
	if not (cmd and is_macos()) then
		return { hide = false }
	end

	-- Make sure Spotify is ready for commands
	ensure_spotify()

	local ok = false
	if cmd == "spotify_play_pause" then
		ok = run_osa(osa_play_pause)
	elseif cmd == "spotify_next" then
		ok = run_osa(osa_next)
	elseif cmd == "spotify_previous" then
		ok = run_osa(osa_prev)
	elseif cmd == "spotify_volume_up" then
		ok = run_osa(osa_volume_set, { tostring(clamp(100, 0, 100)) }) -- placeholder, overwritten below
	elseif cmd == "spotify_volume_down" then
		ok = run_osa(osa_volume_set, { tostring(clamp(0, 0, 100)) }) -- placeholder, overwritten below
	elseif cmd == "spotify_volume_mute_toggle" then
		ok = spotify_volume_mute_toggle()
	elseif cmd == "spotify_shuffle_toggle" then
		ok = run_osa(osa_shuffle_toggle)
	elseif cmd == "spotify_repeat_toggle" then
		ok = run_osa(osa_repeat_toggle)
	elseif cmd == "spotify_repeat_one_toggle" then
		ok = run_osa(osa_repeat_one_toggle)
	elseif cmd == "spotify_seek_forward" then
		ok = run_osa(osa_seek_rel, { "10" })
	elseif cmd == "spotify_seek_back" then
		ok = run_osa(osa_seek_rel, { "-10" })
	elseif cmd == "spotify_play_clipboard_uri" then
		ok = run_osa(osa_play_clipboard_uri)
	else
		return { hide = false }
	end

	-- For volume up/down we need to read current volume; do it inline with AppleScript:
	if cmd == "spotify_volume_up" then
		local script = [[
      tell application "Spotify"
        set v to sound volume
        set v to v + 6
        if v > 100 then set v to 100
        set sound volume to v
      end tell
    ]]
		ok = run_osa(script)
	elseif cmd == "spotify_volume_down" then
		local script = [[
      tell application "Spotify"
        set v to sound volume
        set v to v - 6
        if v < 0 then set v to 0
        set sound volume to v
      end tell
    ]]
		ok = run_osa(script)
	end

	return { hide = ok }
end

return M
