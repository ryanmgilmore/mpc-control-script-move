-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Ryan Gilmore
-- abletonMoveSchwung.lua: "Ableton Move (Schwung)", the MPC half of Move MPC Control, a controller script for MPC OS 3.10's
-- Lua engine. The Ableton Move (running the Move MPC Control Schwung tool) becomes clip
-- launcher, pads and Q-Link knobs. Wire protocol: version 4.
--
-- The script is the model, the Move the view. It maps nothing but SysEx until
-- the Move says HELLO, only ever maps MIDI channel 16, and unmaps everything on
-- BYE or when heartbeats stop.
--
-- Robustness rules, because this runs inside the MPC application:
--   * every call into the MPC API goes through safe()/read() (pcall), so an API
--     mismatch costs one feature, not the script;
--   * every handler MPC calls is wrapped in guard(), so nothing errors out;
--   * state is polled and diffed as well as listened to, so a listener that
--     never fires costs latency, not correctness.
-- docs/MPC-SCRIPT-API.md says which calls are proven on a device.
--
-- Lua 5.4 (MPC's). Single file, no require.

-----------------------------------------------------------------------------
-- Tunables
-----------------------------------------------------------------------------

-- Group constants and helpers to leave headroom below Lua's 200 active-local
-- limit in the main chunk. These tables are allocated once, never per tick.
local CFG, MSG, CC, MODE, ANIM, CS, COLOUR = {}, {}, {}, {}, {}, {}, {}
local safety, coords, colourFns, v2 = {}, {}, {}, {}

CFG.PROTOCOL_VERSION      = 4
CFG.CH                    = 15     -- MIDI channel 16, 0-based
CFG.OUT_PORT              = 0      -- output index, order of output= in the .ini
CFG.LISTENER              = "abletonMoveSchwung" -- listener name for :listen/:stopListening

CFG.TICK_MS               = 20     -- timer interval; pacing is per tick
CFG.MAX_SYSEX_PER_TICK    = 4      -- the wire protocol
CFG.QUEUE_LIMIT           = 64     -- more than this pending: drop, full refresh
CFG.HEARTBEAT_TIMEOUT_MS  = 3500   -- no HELLO/PING for this long = BYE
CFG.PASSIVE_GOODBYE_MS    = 1000   -- min gap between GOODBYEs answering PINGs while passive

CFG.STATE_POLL_MS         = 100    -- STATE and TEXT re-read and diffed
CFG.GRID_POLL_MS          = 250    -- clip/scene/track cells re-read and diffed
CFG.PAD_POLL_MS           = 40     -- Pads mode: all 32 pad colours re-read per interval (property reads)
CFG.PERF_LOG              = false  -- handler timing to the journal (v2.perfNote); on for an audio-dropout test
CFG.PERF_LOG_MS           = 10000  -- one perf line this often
CFG.PERF_SLOW_MS          = 5      -- a handler call this long is listed by name
CFG.QUANT_WAIT_TICKS      = 10     -- quantise with Timing Correct off: ticks TC is held on before and after the press
CFG.LANE_PICK_VELOCITY    = 0.001  -- Step Seq lane pick from the Move: Pad Sel + pads.Press at this velocity (0-1), so the pad does not sound (Ryan, 2026-11-19). 0 is no hit (seventh bench); 1/127 picks but is faintly audible
CFG.LANE_PICK_RETRY       = 1 / 127 -- if the lane did not move at LANE_PICK_VELOCITY, one retry at this one
CFG.LANE_OTHER_BANK       = false  -- Step Seq: let a pad outside the MPC's current bank pick the lane (broken: SetCurrentBank is ignored there)
CFG.LANE_POLL             = true   -- Step Seq: send the MPC's lane (its last-hit pad) to the Move
CFG.LANE_POLL_MS          = 300    -- Step Seq: how often pads.LastHitPad() is read for the lane (one native call)
CFG.MUTE_FLASH_MS         = 1200   -- mute modes: a pad seen both black and mute-orange inside this is muted (the MPC blinks them at 1 Hz)
CFG.QLINK_POLL_MS         = 100    -- touched Q-Link name/value re-read
CFG.PAD_BURST_MIN_MS      = 500    -- Pads mode: least time between full 32-pad re-reads after a change
CFG.QLINK_IDLE_POLL_MS    = 125    -- ONE untouched knob per interval (eight = 1 s)

CFG.ARM_POLL_MS           = 1000
CFG.POSITION_POLL_MS      = 125
CFG.NUM_PADS              = 32
CFG.PADS_PER_MSG          = 8
CFG.NUM_STEPS             = 16
CFG.NUM_ROW_BUTTONS       = 4
CFG.SESSION_COLS, CFG.SESSION_ROWS = 8, 4
CFG.ROWS_COLS, CFG.ROWS_ROWS  = 4, 8
CFG.MAX_PAD_BANK          = 6      -- left-hand bank 0..6 (A|B .. G|H)
CFG.PADS_PER_BANK         = 16
CFG.QLINKS_PER_PAGE       = 8
CFG.NUM_QLINK_PAGES       = 4

CFG.MAX_TEXT              = 40
CFG.MAX_QLINK_NAME        = 20
CFG.MAX_QLINK_VALUE       = 16

-- Unproven indexing conventions, kept here so the bench can flip them.
CFG.LIGHT_RGB_INDEX_BASE  = 1      -- pads.LightRGBColor is 1-based ("{rrggbb}", all banks): device-proven
CFG.CURRENT_BANK_BASE     = 0      -- pads.CurrentBank.value for bank A
CFG.SHOW_APERTURE_IN_PAD_MODES = true -- keep the clip window drawn in Pads/Notes

CFG.APERTURE_LABEL        = "Move"

-----------------------------------------------------------------------------
-- Protocol constants
-----------------------------------------------------------------------------

MSG.HDR = { 0x7D, 0x4D, 0x50 }     -- after F0; MPC strips F0/F7 (§8)

MSG.IN_HELLO, MSG.IN_PING, MSG.IN_BYE = 0x01, 0x02, 0x03
MSG.OUT_WELCOME, MSG.OUT_STATE, MSG.OUT_PADS, MSG.OUT_ROWS = 0x41, 0x42, 0x43, 0x44
MSG.OUT_STEPS, MSG.OUT_TEXT, MSG.OUT_QLINK, MSG.OUT_GOODBYE = 0x45, 0x46, 0x47, 0x48

MSG.OUT_PONG, MSG.OUT_POSITION = 0x49, 0x4A

CC.NAV_LEFT, CC.NAV_RIGHT, CC.NAV_UP, CC.NAV_DOWN = 0x01, 0x02, 0x03, 0x04
CC.SHIFT, CC.PLAY, CC.REC, CC.UNDO = 0x05, 0x06, 0x07, 0x08
CC.STOP_ALL, CC.TRACK_PREV, CC.TRACK_NEXT = 0x09, 0x0A, 0x0B
CC.CAPTURE, CC.MODE, CC.NOTE_REPEAT, CC.ARM = 0x0C, 0x0D, 0x0E, 0x0F
CC.COPY, CC.DELETE, CC.AUTOMATION, CC.JOG_TOUCH, CC.TEMPO = 0x14, 0x15, 0x16, 0x17, 0x34
CC.STEP_SEQ, CC.MUTE, CC.ARRANGE, CC.DUP_CLIP, CC.MAIN, CC.QUANT = 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D
CC.ROW_FIRST, CC.ROW_LAST = 0x10, 0x13
CC.STEP_FIRST, CC.STEP_LAST = 0x20, 0x2F
CC.SET_MODE, CC.SET_QLINK_PAGE, CC.SET_PAD_BANK, CC.REFRESH = 0x30, 0x31, 0x32, 0x33
CC.KNOB_FIRST = 0x47           -- knobs 0..7 = CC 0x47..0x4E
CFG.NOTE_KNOB_TOUCH_FIRST = 0x40   -- touch notes 0x40..0x47

MODE.SESSION, MODE.ROWS, MODE.PADS, MODE.NOTES = 0, 1, 2, 3
MODE.NAMES = { [0] = "Matrix", "Transposed", "Pads", "Notes" }

ANIM.SOLID, ANIM.DIM, ANIM.PULSE, ANIM.BLINK = 0, 1, 2, 3

-- Clip State values (static analysis of the 3.10.1 binary: a switch on them).
CS.NOSLOT, CS.EMPTY, CS.READY = 0, 1, 2
CS.WILLPLAY, CS.PLAYING, CS.WILLSTOP = 3, 4, 5
CS.WILLREC, CS.RECORDING, CS.WILLSTOPREC = 6, 7, 8
CS.WILLOD, CS.OVERDUBBING, CS.WILLSTOPOD = 9, 10, 11

COLOUR.OFF = { 0, 0, 0, ANIM.SOLID }
COLOUR.MUTED = { 127, 56, 0, ANIM.DIM } -- a muted pad or track in the mute modes
COLOUR.RED = { 127, 0, 0 }
COLOUR.WHITE = { 127, 127, 127 }
COLOUR.FALLBACK_CLIP_RGB = { 80, 80, 80 } -- a clip whose colour reads as black

CFG.BANK_LETTERS = "ABCDEFGH"

-- Zero-based MPC Q-Link index for a physical knob.
local function qlinkIndex(page, k)
    if page < 2 then return page * CFG.QLINKS_PER_PAGE + k end
    local c, r = 2 * (page - 2) + k // 4, k % 4
    return 12 + c - 4 * r
end

-----------------------------------------------------------------------------
-- Script state
-----------------------------------------------------------------------------

local active = false
local mode = MODE.SESSION
local qlinkPage = 0
local padBank = 0
local shiftHeld = false
local lastHeard = -math.huge
local lastPassiveGoodbye = nil
local tickCount = 0

local queue = {}              -- pending outgoing SysEx bodies (no F0/F7)
local queueKeys = {}          -- key -> index in queue, for replace-in-place
local needFull = false

local sent = {}               -- last values sent: pads[], steps[], rows, state, text[]
local dirty = { state = false, grid = false, text = false }
local lastPoll = { state = -1e18, grid = -1e18, pads = -1e18, qlink = -1e18 }

local touched = {}            -- knob k -> { idx = qlink index, props = listeners }
local heldPads = {}           -- script-observed pad note -> original virtual pad (or false for clips)
local mapped = {}             -- key -> function that removes the mapping
local listenedGrid = {}       -- property objects listened to for the aperture view
local listenedGlobal = {}     -- property objects listened to for global state

local errors = {}             -- label -> count
local lastError = nil
local broken = {}             -- label -> true: optional source disabled after an error

-----------------------------------------------------------------------------
-- Safety
-----------------------------------------------------------------------------

local enqueueText -- forward

function safety.noteError(label, err)
    local n = (errors[label] or 0) + 1
    errors[label] = n
    lastError = tostring(label) .. ": " .. tostring(err)
    -- ShowTUIFeedback shows nothing on the device, so the
    -- first failure of each kind goes to the Move's transient text line.
    if n == 1 and active and enqueueText then
        enqueueText(2, "! " .. tostring(label))
    end
end

-- Call fn(...) protected. Returns ok, results.
function safety.safe(label, fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        safety.noteError(label, a)
        return false
    end
    return true, a, b, c
end

-- Evaluate getter() protected; nil on failure.
function safety.read(label, getter)
    local ok, v = pcall(getter)
    if not ok then
        safety.noteError(label, v)
        return nil
    end
    return v
end

-- Like read(), but a source that has failed once is not tried again until the
-- next HELLO (for polled optional sources, to avoid an error per poll).
function safety.readOptional(label, getter)
    if broken[label] then return nil end
    local ok, v = pcall(getter)
    if not ok then
        broken[label] = true
        safety.noteError(label, v)
        return nil
    end
    return v
end

local function dev() return abletonMoveSchwung end
local function aperture() return abletonMoveSchwung.clipMatrixAperture end

local function nowMs()
    local ok, t = pcall(function() return abletonMoveSchwung.timer.Now() end)
    if ok and type(t) == "number" then return t end
    return tickCount * CFG.TICK_MS
end

-----------------------------------------------------------------------------
-- Encoding: the single place each outgoing message is built
-----------------------------------------------------------------------------

local function b7(v)
    v = tonumber(v) or 0
    v = math.floor(v)
    if v < 0 then return 0 end
    if v > 127 then return 127 end
    return v
end

local function ascii7(s, maxLen)
    s = tostring(s or "")
    local out = {}
    for i = 1, #s do
        if #out >= maxLen then break end
        local c = s:byte(i)
        if c >= 0x80 then
            -- skip UTF-8 continuation bytes; one '?' per multibyte character
            if c >= 0xC0 then out[#out + 1] = 0x3F end
        elseif c < 0x20 or c == 0x7F then
            out[#out + 1] = 0x20
        else
            out[#out + 1] = c
        end
    end
    return string.char(table.unpack(out))
end

local function frame(cmd, data)
    return string.char(MSG.HDR[1], MSG.HDR[2], MSG.HDR[3], cmd) .. (data or "")
end

local function ledBytes(led)
    led = led or COLOUR.OFF
    return string.char(b7(led[1]), b7(led[2]), b7(led[3]), b7(led[4]))
end

local enc = {}

function enc.welcome(ver, flags)
    return frame(MSG.OUT_WELCOME, string.char(b7(ver), b7(flags)))
end

-- s: { mode, qlinkPage, padBank, playing, recording, overdubbing,
--      originX, originY, globalCols, globalRows,
--      canLeft, canRight, canUp, canDown }
function enc.state(s)
    local transport = (s.playing and 1 or 0) | (s.recording and 2 or 0) | (s.overdubbing and 4 or 0)
    local canMove = (s.canLeft and 1 or 0) | (s.canRight and 2 or 0)
        | (s.canUp and 4 or 0) | (s.canDown and 8 or 0)
    return frame(MSG.OUT_STATE, string.char(b7(s.mode), b7(s.qlinkPage), b7(s.padBank), transport,
        b7(s.originX), b7(s.originY), b7(s.globalCols), b7(s.globalRows), canMove,
        (s.armed and 1 or 0) | ((s.repeatOn or s.noteRepeat) and 2 or 0) | (s.metronome and 4 or 0) | (s.popup and 8 or 0) | (s.aux and 16 or 0) | (s.muted and 32 or 0) | (s.solo and 64 or 0),
        b7(s.automation), b7((s.available or 0) | (s.marks and 16 or 0)), b7((s.bpm10 or ((s.bpm or 120) * 10)) % 128), b7((s.bpm10 or ((s.bpm or 120) * 10)) // 128), b7(s.mpcMode == nil and 4 or s.mpcMode)))
end

function enc.pads(first, leds)
    local parts = { string.char(b7(first), #leds) }
    for i = 1, #leds do parts[#parts + 1] = ledBytes(leds[i]) end
    return frame(MSG.OUT_PADS, table.concat(parts))
end

function enc.rows(leds)
    local parts = {}
    for i = 1, CFG.NUM_ROW_BUTTONS do parts[i] = ledBytes(leds[i]) end
    return frame(MSG.OUT_ROWS, table.concat(parts))
end

function enc.steps(first, leds)
    local parts = { string.char(b7(first), #leds) }
    for i = 1, #leds do parts[#parts + 1] = ledBytes(leds[i]) end
    return frame(MSG.OUT_STEPS, table.concat(parts))
end

function enc.text(slot, text)
    return frame(MSG.OUT_TEXT, string.char(b7(slot)) .. ascii7(text, CFG.MAX_TEXT))
end

function enc.qlink(k, name, value)
    return frame(MSG.OUT_QLINK, string.char(b7(k)) .. ascii7(name, CFG.MAX_QLINK_NAME) .. "\0"
        .. ascii7(value, CFG.MAX_QLINK_VALUE))
end

function enc.pong()
    return frame(MSG.OUT_PONG)
end

function enc.goodbye()
    return frame(MSG.OUT_GOODBYE)
end

-----------------------------------------------------------------------------
-- Parsing: the single place an incoming SysEx is read
-----------------------------------------------------------------------------

-- Returns cmd, data (array of ints, data[1] = first byte after cmd), or nil.
-- Accepts a string (what MPC passes) or an array of ints; tolerates F0/F7 left on.
local function parseSysex(bytes)
    local t = {}
    if type(bytes) == "string" then
        for i = 1, #bytes do t[i] = bytes:byte(i) end
    elseif type(bytes) == "table" then
        for i = 1, #bytes do t[i] = tonumber(bytes[i]) or 0 end
    else
        return nil
    end
    if t[1] == 0xF0 then table.remove(t, 1) end
    if t[#t] == 0xF7 then t[#t] = nil end
    if #t < 4 or t[1] ~= MSG.HDR[1] or t[2] ~= MSG.HDR[2] or t[3] ~= MSG.HDR[3] then return nil end
    local data = {}
    for i = 5, #t do data[#data + 1] = t[i] end
    return t[4], data
end

-----------------------------------------------------------------------------
-- Outgoing queue and pacing
-----------------------------------------------------------------------------

local function sendNow(body)
    return safety.safe("SendMIDISysex", function() abletonMoveSchwung.midiOut.SendMIDISysex(body, CFG.OUT_PORT) end)
end

local function clearQueue()
    queue = {}
    queueKeys = {}
end

-- key: optional; a pending message with the same key is replaced in place, so
-- a burst of changes to one thing costs one message.
local function enqueue(body, key, front)
    if key and queueKeys[key] then
        queue[queueKeys[key]] = body
        return
    end
    if front then
        table.insert(queue, 1, body)
        for k, idx in pairs(queueKeys) do queueKeys[k] = idx + 1 end
        if key then queueKeys[key] = 1 end
    else
        queue[#queue + 1] = body
        if key then queueKeys[key] = #queue end
    end
    if #queue > CFG.QUEUE_LIMIT then
        clearQueue()
        needFull = true
    end
end

local function flush(limit)
    local n = math.min(limit, #queue)
    if n == 0 then return end
    for i = 1, n do sendNow(queue[i]) end
    local rest = {}
    for i = n + 1, #queue do rest[#rest + 1] = queue[i] end
    local keys = {}
    for k, idx in pairs(queueKeys) do
        if idx > n then keys[k] = idx - n end
    end
    queue, queueKeys = rest, keys
end

enqueueText = function(slot, text)
    enqueue(enc.text(slot, text), "text" .. slot)
end

-----------------------------------------------------------------------------
-- Coordinates
-----------------------------------------------------------------------------

-- Pad p (row 0 = bottom) -> aperture clip column, row; nil outside clip modes.
function coords.padToClip(m, p)
    local row, col = p // 8, p % 8
    if m == MODE.SESSION then
        return col, 3 - row
    elseif m == MODE.ROWS then
        return 3 - row, col
    end
    return nil
end

function coords.padToVirtual(bank, p)
    local row, col = p // 8, p % 8
    return (bank + (col >= 4 and 1 or 0)) * CFG.PADS_PER_BANK + row * 4 + (col % 4)
end

function coords.apertureSize(m)
    if m == MODE.ROWS then return CFG.ROWS_COLS, CFG.ROWS_ROWS end
    return CFG.SESSION_COLS, CFG.SESSION_ROWS
end

-----------------------------------------------------------------------------
-- Colours
-----------------------------------------------------------------------------

function colourFns.argbTo7(argb)
    argb = tonumber(argb)
    if not argb then return nil end
    argb = math.tointeger(argb) or math.floor(argb)
    return ((argb >> 16) & 0xFF) >> 1, ((argb >> 8) & 0xFF) >> 1, (argb & 0xFF) >> 1
end

-- "#RRGGBB", "RRGGBB", "FFRRGGBB", "0xRRGGBB" -> r, g, b in 0..127, or nil.
function colourFns.hexTo7(s)
    if type(s) ~= "string" then return nil end
    local hex = s:gsub("^0[xX]", ""):gsub("[^%x]", "")
    if #hex < 6 then return nil end
    local v = tonumber(hex:sub(-6), 16)
    if not v then return nil end
    return colourFns.argbTo7(v)
end

function colourFns.withAnim(rgb, anim)
    return { rgb[1], rgb[2], rgb[3], anim }
end

function colourFns.isTransitional(state)
    return state == CS.WILLPLAY or state == CS.WILLSTOP or state == CS.WILLREC
        or state == CS.WILLSTOPREC or state == CS.WILLOD or state == CS.WILLSTOPOD
end

function colourFns.isRecordFamily(state)
    return state >= CS.WILLREC
end

function colourFns.colourOrFallback(argb)
    local r, g, b = colourFns.argbTo7(argb)
    if not r or (r == 0 and g == 0 and b == 0) then return COLOUR.FALLBACK_CLIP_RGB end
    return { r, g, b }
end

-- A clip cell: empty/no slot off; stopped dim (selected: solid); playing slow
-- pulse; queued fast blink; recording/overdubbing red.
function colourFns.clipLed(colour, state, selected)
    state = tonumber(state)
    if not state or state <= CS.EMPTY then
        if selected and state == CS.EMPTY then return colourFns.withAnim(COLOUR.WHITE, ANIM.DIM) end
        return COLOUR.OFF
    end
    if colourFns.isRecordFamily(state) then
        return colourFns.withAnim(COLOUR.RED, colourFns.isTransitional(state) and ANIM.BLINK or ANIM.PULSE)
    end
    local rgb = colourFns.colourOrFallback(colour)
    if colourFns.isTransitional(state) then return colourFns.withAnim(rgb, ANIM.BLINK) end
    if state == CS.PLAYING then return colourFns.withAnim(rgb, ANIM.PULSE) end
    return colourFns.withAnim(rgb, selected and ANIM.SOLID or ANIM.DIM)
end

-- A track or scene (group state: 0 NoGroup, 1 Empty, 2 Stopped, then as clips).
-- showEmpty: light a group that exists but holds no clips (tracks yes, scenes no).
function colourFns.groupLed(colour, state, selected, showEmpty)
    state = tonumber(state)
    if not state or state == 0 or (state == CS.EMPTY and not showEmpty) then return COLOUR.OFF end
    if colourFns.isRecordFamily(state) then
        return colourFns.withAnim(COLOUR.RED, colourFns.isTransitional(state) and ANIM.BLINK or ANIM.PULSE)
    end
    local rgb = colourFns.colourOrFallback(colour)
    if colourFns.isTransitional(state) then return colourFns.withAnim(rgb, ANIM.BLINK) end
    if state == CS.PLAYING then return colourFns.withAnim(rgb, ANIM.PULSE) end
    return colourFns.withAnim(rgb, selected and ANIM.SOLID or ANIM.DIM)
end

function colourFns.sameLed(a, b)
    return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end

-----------------------------------------------------------------------------
-- Reading MPC state
-----------------------------------------------------------------------------

local function readCell(c, r)
    local ok, colour, state, selected = pcall(function()
        local p = abletonMoveSchwung.clipMatrixAperture.clipProperties[c][r]
        return p.Colour.value, p.State.value, p.Selected.value
    end)
    if not ok then
        safety.noteError("clipProperties", colour)
        return nil
    end
    return colour, state, selected
end

local function readGroup(kind, i)
    local ok, colour, state, selected = pcall(function()
        local p = abletonMoveSchwung.clipMatrixAperture[kind][i]
        return p.Colour.value, p.State.value, p.Selected.value
    end)
    if not ok then
        safety.noteError(kind, colour)
        return nil
    end
    return colour, state, selected
end

-- A track's select button (Matrix: the odd step; Transposed: its row button)
-- and its stop step. Every track as the MPC shows it (dim when stopped,
-- pulsing while it plays, blinking while queued, red recording); the active
-- track's select button in white instead of its colour, full brightness,
-- with the same animation (Ryan, 2026-11-19). "Active" is
-- currentTrack.Index, not the aperture's unproven Selected flag.
-- c: column in the window.
function colourFns.trackLed(c, select)
    local colour, state = readGroup("trackProperties", c)
    local ox = tonumber(safety.read("OriginX", function() return aperture().OriginX.value end)) or 0
    local active = select and v2.trackIndex ~= nil and math.floor(v2.trackIndex) == math.floor(ox) + c
    local led = colourFns.groupLed(colour, state, active, true)
    if active and led ~= COLOUR.OFF and not colourFns.isRecordFamily(tonumber(state) or 0) then
        led = colourFns.withAnim(COLOUR.WHITE, led[4])
    end
    return led
end

-- Colour of virtual pad vp (0..127), as r,g,b 0..127, or nil if unknown.
-- Device-proven virtual properties cover every bank without native function polls.
local function virtualPadColour(vp)
    -- The property first: the pads FUNCTIONS (LightRGBColor, LightBrightness,
    -- IsPressedVirtual) each cost about 2.9 ms on the device, one audio block,
    -- so 32 of them stall the MPC's screen for 90 ms (bench, 2026-11-13).
    -- Same colours, device-proven: 0-based ARGB, every bank.
    local argb = safety.readOptional("pads.virtual.Colour", function()
        return mpc.controlSurface.pads.virtual[vp].Colour.value
    end)
    local r, g, b = colourFns.argbTo7(argb)
    if r then return r, g, b end

    return nil
end

v2.seq = { mode = 4, pads = {} }

-- The MPC's own pad bank holds the step lights, and it need not be the bank
-- pair the Move shows. One ~2.9 ms read on entering Step Seq and one a
-- second while there; never per tick.
function v2.seq.readBank()
    v2.seq.bankAt = nowMs()
    local bank = safety.readOptional("pads.CurrentBank", function() return mpc.controlSurface.pads.CurrentBank.value end)
    bank = tonumber(bank)
    bank = bank and math.floor(bank - CFG.CURRENT_BANK_BASE)
    bank = (bank and bank >= 0 and bank <= 7) and bank or nil
    -- The Move's pads follow the MPC's bank in Step Seq: repaint on a change.
    if bank ~= v2.seq.bank then dirty.grid = true end
    v2.seq.bank = bank
end

-- Lane select (device, 2026-11-14): fKey4 is the Step Seq screen's Pad Sel;
-- while it is on, the pads read yellow (lane green) and a pad press picks
-- the lane instead of writing a step. One native call per tick.
function v2.seq.padSelOn()
    local bank, yellow = v2.seq.bank or padBank, 0
    for i = 0, 15 do
        local r, g, b = virtualPadColour(bank * CFG.PADS_PER_BANK + i)
        if r and r > 100 and g > 100 and b < 28 then yellow = yellow + 1 end
    end
    return yellow >= 8
end

function v2.seq.lane(vp)
    -- Only the MPC's current bank can be picked: SetCurrentBank is ignored in
    -- Step Seq, so a pad of the other bank ended in "No lane". Its pads are
    -- dark and do nothing until that is solved (Ryan, 2026-11-14).
    if not CFG.LANE_OTHER_BANK and v2.seq.bank and vp // CFG.PADS_PER_BANK ~= v2.seq.bank then return end
    v2.seq.job = { vp = vp, stage = 0, wait = 0 }
    enqueueText(2, "Lane " .. string.char(65 + vp // 16) .. string.format("%02d", vp % 16 + 1))
end

-- The MPC's own lane, for the Move's Step Seq screen (Ryan, 2026-11-14).
-- Step Seq edits the last pad hit: Ryan hit A10 in Main, entered Step Seq,
-- and the MPC showed A10. pads.LastHitPad() reads it (1 for A01, device).
-- One native call on entry, on a track change and every LANE_POLL_MS there.
-- "@" marks a text the Move stores and does not flash. An earlier try read
-- the lane from the Pad Sel lights; they lag the button and it was dropped.
function v2.seq.readLane()
    v2.seq.laneHit, v2.seq.laneAt = nil, nil
end

function v2.seq.lanePoll(now)
    if not CFG.LANE_POLL or v2.seq.mode ~= 1 or v2.seq.job then return end
    if now - (v2.seq.laneAt or -math.huge) < CFG.LANE_POLL_MS then return end
    v2.seq.laneAt = now
    local n = tonumber(safety.readOptional("pads.LastHitPad", function() return mpc.controlSurface.pads.LastHitPad() end))
    if not n or n < 1 or n > 128 then return end
    n = math.floor(n)
    if n == v2.seq.laneHit then return end
    v2.seq.laneHit = n
    enqueueText(2, "@Lane " .. string.char(65 + (n - 1) // 16) .. string.format("%02d", (n - 1) % 16 + 1))
end

function v2.seq.work()
    local j = v2.seq.job
    if not j then return false end
    if v2.seq.mode ~= 1 then v2.seq.job = nil; return false end
    if j.wait > 0 then j.wait = j.wait - 1; return true end
    local fkey, pads = mpc.controlSurface.fKey4, mpc.controlSurface.pads
    local bank = j.vp // CFG.PADS_PER_BANK
    if j.stage == 0 then
        -- The MPC's bank first, and read back: only its current bank answers
        -- in Pad Sel, and a tap sent before the bank had moved picked the
        -- bank-A pad (bench, 2026-11-14).
        local cur = tonumber(safety.read("pads.CurrentBank", function() return pads.CurrentBank.value end))
        if cur == bank + CFG.CURRENT_BANK_BASE then
            v2.seq.bank, v2.seq.bankAt = bank, nowMs()
            j.stage = 1
        elseif not j.asked then
            safety.safe("pads.SetCurrentBank", function() pads.SetCurrentBank(bank + CFG.CURRENT_BANK_BASE) end)
            j.asked, j.wait = true, 1
        else
            j.tries = (j.tries or 0) + 1
            if j.tries > 15 then
                enqueueText(2, "No lane")
                v2.seq.job = nil
            else j.wait = 1 end
        end
    elseif j.stage == 1 then
        if v2.seq.padSelOn() then j.stage = 3 else
            safety.safe("fKey4.Press", function() fkey.Press() end); j.stage = 2
        end
    elseif j.stage == 2 then
        safety.safe("fKey4.Release", function() fkey.Release() end); j.stage, j.wait = 3, 2
    elseif j.stage == 3 then
        -- Pad functions are 1-based; the colour properties are 0-based.
        -- Not Tap: a full-velocity hit sounds the pad, which Ryan does not
        -- want on a lane change (2026-11-19). Press at LANE_PICK_VELOCITY,
        -- then check LastHitPad moved; one retry at LANE_PICK_RETRY if not.
        local n, v = j.vp % CFG.PADS_PER_BANK + 1, j.retried and CFG.LANE_PICK_RETRY or CFG.LANE_PICK_VELOCITY
        -- Already the lane: press nothing, so nothing can sound.
        if not j.retried and tonumber(safety.readOptional("pads.LastHitPad", function() return pads.LastHitPad() end)) == j.vp + 1 then
            j.stage, j.wait = 4, 0
            return true
        end
        safety.safe("pads.Press", function() pads.Press(n, v) end)
        safety.safe("pads.Release", function() pads.Release(n) end)
        j.velocity, j.stage, j.wait = v, 6, 2
    elseif j.stage == 6 then
        local hit = tonumber(safety.readOptional("pads.LastHitPad", function() return pads.LastHitPad() end))
        local picked = hit == j.vp + 1
        if not picked and not j.retried then j.retried, j.stage = true, 3
        else j.stage, j.wait = 4, 2 end
    elseif j.stage == 4 then
        if v2.seq.padSelOn() then
            safety.safe("fKey4.Press", function() fkey.Press() end); j.stage = 5
        else v2.seq.job = nil end
    else
        safety.safe("fKey4.Release", function() fkey.Release() end)
        v2.seq.job = nil; v2.seq.quietUntil = nowMs() + 100
    end
    return true
end

-- Mute follows the MPC's own button: Track Mute, then Pad Mute on a drum
-- track, then back to Main (Ryan, 2026-11-14).
function v2.seq.mute()
    local target = "Track Mute"
    if v2.seq.mode == 2 then
        local kind = safety.read("currentTrack.Type", function() return mpc.tracks.currentTrack.Type.value end)
        target = kind == "Drum" and "Pad Mute" or "Main Mode"
    elseif v2.seq.mode == 3 then target = "Main Mode" end
    safety.safe("engineMode.RequestModeChange", function() mpc.engineMode.RequestModeChange(target) end)
end

-- Submix, return and output tracks come after the project's own tracks in
-- the jog's order. They are not numbered and the pads do nothing on them
-- (Ryan, 2026-11-14). The count is read once a second at most.
function v2.seq.aux(mixerOnly)
    -- Device, 2026-11-14: Type reads "Submix", "Send" (the returns) and
    -- "Output" on them, and their index starts at SizeNormalTracks().
    local kind = safety.read("currentTrack.Type", function() return mpc.tracks.currentTrack.Type.value end)
    if kind == "Submix" or kind == "Send" or kind == "Output" or kind == "Input" then return true end
    -- Audio tracks too: no pads or notes to play there (Ryan, 2026-11-14),
    -- but they are project tracks and keep their number. "Audio" is the
    -- expected Type string, not yet read on the device.
    return kind == "Audio" and not mixerOnly
end

-- Main from anywhere: closes the 16 Levels popup, else asks for Main Mode.
function v2.seq.main()
    if v2.seq.popup == "Sixteen Level" then v2.button("sixteenLevel", 2); return end
    safety.safe("engineMode.RequestModeChange", function() mpc.engineMode.RequestModeChange("Main Mode") end)
end

-- One pad's LED for PADS. What the MPC's lights do in Track Mute and Pad
-- Mute (device log, 2026-11-14): a muted pad alternates
-- FF7700 and black, about half a second each; while any pad is muted the
-- others drop to 40% of their own colour, and they go to full while they
-- play. So a muted pad is one seen both black and that orange inside
-- MUTE_FLASH_MS and showing one of the two now; it is drawn a steady dim
-- orange (Ryan). Every other pad is drawn as the MPC shows it. A pad whose
-- own colour is that orange never goes black, so it is not taken for muted.
function v2.seq.padLed(vp, now)
    local r, g, b = virtualPadColour(vp)
    if not r then return COLOUR.OFF end
    if v2.seq.mode == 2 or v2.seq.mode == 3 then
        v2.seq.flash = v2.seq.flash or {}
        local f = v2.seq.flash[vp]
        if not f then f = {}; v2.seq.flash[vp] = f end
        local black = r + g + b == 0
        local orange = r >= 120 and g >= 50 and g <= 68 and b <= 4
        local win = CFG.MUTE_FLASH_MS
        local d = v2.seq.dim
        if f.muted and v2.seq.mode == 3 and d and d.seen and d.fullPolls >= 2 and d.lit >= 1 and f.mutedAt and d.at and d.at >= f.mutedAt then
            -- The dimming has ended: nothing is muted (v2.seq.dimScan). Forget
            -- the blink, and keep the colour so the jump rule does not fire.
            f.muted, f.black, f.orange, f.prev = false, nil, nil, { r, g, b }
        end
        if not (black or orange) then
            -- Its own colour: unmuted, and nothing seen before counts.
            f.muted, f.black, f.orange = false, nil, nil
        elseif not f.muted then
            -- Muted at once, not a blink later (Ryan saw a muted track's pad
            -- dark for a moment): a lit pad that goes black, since unmuted
            -- pads never do; or a pad that jumps to the orange from a colour
            -- of another hue. From its own dimmed orange it may just be
            -- sounding, so that case waits for the black.
            local p = f.prev
            local otherHue = p and not (p[3] <= 4 and p[1] > 0 and p[2] * 127 >= p[1] * 50 and p[2] * 127 <= p[1] * 68)
            -- A pad whose own colour is the mute orange shows no change on the
            -- blink's first phase, so it waited for the black: 200-500 ms
            -- late (Ryan, 2026-11-19). The others' dimming says it sooner, but
            -- only with the transport stopped: playing, a sounding pad jumps
            -- to full as well. First mute: the others dim and this one stays
            -- at full orange. A further mute: it jumps from its own dimmed
            -- colour to full orange while the others stay dim.
            local mx = d and d.max[vp]
            local full = mx and (r + g + b) * 10 >= mx * 9
            local fromDim = p and mx and (p[1] + p[2] + p[3]) * 10 < mx * 6
            -- Other pads must still be dimmed: when the last mute ends, every
            -- pad goes back to full in one tick, this one included, and that
            -- is an unmute. With no other dimmed pad it waits for the black.
            local jump = v2.seq.mode == 3 and orange and full and d and d.any and (d.onset or fromDim)
            -- Playing it waits for the black: pads.IsPressedVirtual never saw a
            -- Move press (seventh bench, 861 calls, all false) and cost 2.9 ms
            -- each. A later version may have the Move name the pad it pressed instead.
            if jump and d.stopped then f.muted = true
            elseif black and f.lit and now - f.lit < win then f.muted = true
            elseif orange and otherHue then f.muted = true
            elseif f.black and f.orange and now - f.black < win and now - f.orange < win then f.muted = true end
            if f.muted then f.mutedAt = now end
        elseif orange and now - f.mutedAt >= win and not (f.black and now - f.black < win) then
            -- Steady orange, no black: it is the pad's own colour, unmuted.
            -- Remember the orange so the jump rule does not fire again.
            f.muted, f.prev = false, { r, g, b }
        elseif black and not (f.lit and now - f.lit < win) then
            f.muted = false -- steady black: an empty pad now
        end
        if black then f.black = now else f.lit = now end
        if orange then f.orange = now end
        if not black and not orange then f.prev = { r, g, b } end
        if f.muted then return COLOUR.MUTED end
    end
    return { r, g, b, ANIM.SOLID }
end

-- Pad Mute: while any pad is muted the MPC drops every other pad to 40%, and
-- puts them all back to full in one tick when the last mute ends (device
-- log, 2026-11-14). A pad whose own colour IS the mute orange shows the same
-- light muted (blink phase) and unmuted, so the light alone could not say it
-- was unmuted until MUTE_FLASH_MS had passed: 840-860 ms late on the
-- seventh bench (Ryan, 2026-11-19; A12 and B02 of that kit). The end of the
-- dimming says it at once. Once per pad poll, before padLed, over the 32
-- shown pads: "dimmed" is an unmuted lit pad below 60% of the brightest it
-- has shown in this Pad Mute visit. Property reads only.
function v2.seq.dimScan(now)
    if v2.seq.mode ~= 3 then return end
    local d = v2.seq.dim
    if not d then d = { max = {}, seen = false, fullPolls = 0, lit = 0 }; v2.seq.dim = d end
    local any, lit = false, 0
    local flash = v2.seq.flash or {}
    for p = 0, CFG.NUM_PADS - 1 do
        local vp = coords.padToVirtual(padBank, p)
        local r, g, b = virtualPadColour(vp)
        local f = flash[vp]
        if r and r + g + b > 0 and not (f and f.muted) then
            local sum = r + g + b
            if sum > (d.max[vp] or 0) then d.max[vp] = sum end
            lit = lit + 1
            if sum * 10 < d.max[vp] * 6 then any = true end
        end
    end
    if any then d.seen, d.fullPolls, d.at = true, 0, now else d.fullPolls = d.fullPolls + 1 end
    d.onset, d.any = any and not d.any, any
    d.lit = lit
    d.stopped = safety.read("sequencer.Playing", function() return mpc.sequencer.Playing.value end) == false
end

-- A fast jog turn sent track steps faster than the MPC took them, and the
-- extra ones were lost (bench, 2026-11-14). Count them and feed the MPC one
-- every other tick; opposite turns cancel.
function v2.seq.trackStep(d)
    local n = (v2.seq.pendingTracks or 0) + d
    v2.seq.pendingTracks = math.max(-32, math.min(32, n))
end

function v2.seq.trackWork()
    if tickCount % 2 ~= 0 then return end
    local n = v2.seq.pendingTracks
    if n > 0 then
        safety.safe("currentTrack.Next", function() mpc.tracks.currentTrack.Next() end); v2.seq.pendingTracks = n - 1
    else
        safety.safe("currentTrack.Previous", function() mpc.tracks.currentTrack.Previous() end); v2.seq.pendingTracks = n + 1
    end
    dirty.text, dirty.grid = true, true
end

function v2.seq.changed(value)
    local nextMode = ({["Main Mode"]=0, ["Step Sequencer"]=1, ["Track Mute"]=2, ["Pad Mute"]=3})[value] or 4
    if nextMode == v2.seq.mode then return end
    local wasStep = v2.seq.mode == 1
    local wasMute = v2.seq.mode == 2 or v2.seq.mode == 3
    v2.seq.mode = nextMode
    v2.seq.flash = nil
    v2.seq.dim = nil -- the Pad Mute dimming signal starts again (v2.seq.dimScan)
    if active and mode >= MODE.PADS and (wasMute or nextMode == 2 or nextMode == 3) and v2.seq.setMode then v2.seq.setMode(MODE.PADS) end
    if nextMode == 1 then v2.seq.readBank() end
    if wasStep or nextMode == 1 then
        v2.seq.job = nil
        if active and mode == MODE.PADS and v2.seq.remap then v2.seq.remap() end
        -- Step Seq has knob pages 1 and 2 only (the steps' velocities).
        if active and nextMode == 1 and qlinkPage > 1 and v2.seq.setPage then v2.seq.setPage(0) end
        sent.steps = {} -- both transitions need a complete STEPS refresh
        if wasStep then lastPoll.cacheKey = nil end
        if nextMode == 1 then v2.seq.readLane() end
    end
    dirty.state, dirty.grid, dirty.text = true, true, true
end

local function desiredPads()
    local out = {}
    if mode == MODE.SESSION or mode == MODE.ROWS then
        for p = 0, CFG.NUM_PADS - 1 do
            local c, r = coords.padToClip(mode, p)
            out[p] = colourFns.clipLed(readCell(c, r))
        end
    elseif mode == MODE.PADS then
        -- From a cache: reading all 32 colours at once, often, makes the MPC's
        -- screen choppy (bench, 2026-11-13). The cache is filled whole when the
        -- bank pair changes or on a full refresh, then HandleTimer re-reads one
        -- pad at a time (lastPoll.rr).
        if v2.seq.mode == 1 then
            for p = 0, CFG.NUM_PADS - 1 do
                local vp = coords.padToVirtual(padBank, p)
                out[p] = v2.seq.pads[vp]
                if not CFG.LANE_OTHER_BANK and v2.seq.bank and vp // CFG.PADS_PER_BANK ~= v2.seq.bank then out[p] = COLOUR.OFF end
            end
            return out -- never read step lights into PADS, even on full refresh
        end
        local cache = lastPoll.cache
        if lastPoll.cacheKey ~= padBank or not cache then
            cache = {}
            for p = 0, CFG.NUM_PADS - 1 do
                local vp = coords.padToVirtual(padBank, p)
                cache[p] = v2.seq.padLed(vp, nowMs())
                if cache[p] ~= COLOUR.OFF and cache[p][4] == ANIM.SOLID and v2.seq.mode == 0 then v2.seq.pads[vp] = cache[p] end
            end
            lastPoll.cache, lastPoll.cacheKey = cache, padBank
        end
        for p = 0, CFG.NUM_PADS - 1 do out[p] = cache[p] end
    else
        for p = 0, CFG.NUM_PADS - 1 do out[p] = COLOUR.OFF end
    end
    return out
end

local function desiredRows()
    local out = {}
    for i = 1, CFG.NUM_ROW_BUTTONS do out[i] = COLOUR.OFF end
    if mode == MODE.SESSION then
        for r = 0, CFG.NUM_ROW_BUTTONS - 1 do
            out[r + 1] = colourFns.groupLed(readGroup("sceneProperties", r))
        end
    elseif mode == MODE.ROWS then
        for c = 0, CFG.NUM_ROW_BUTTONS - 1 do out[c + 1] = colourFns.trackLed(c, true) end
    end
    return out
end

local function desiredSteps()
    local out = {}
    for i = 0, CFG.NUM_STEPS - 1 do out[i] = COLOUR.OFF end
    if v2.seq.mode == 1 then
        local bank = v2.seq.bank or padBank
        for i = 0, CFG.NUM_STEPS - 1 do
            local r, g, b = virtualPadColour(bank * CFG.PADS_PER_BANK + i)
            out[i] = r and { r, g, b, ANIM.SOLID } or COLOUR.OFF
        end
    elseif mode == MODE.SESSION then
        for c = 0, 7 do
            out[c * 2] = colourFns.trackLed(c, true)
            out[c * 2 + 1] = colourFns.trackLed(c, false)
        end
    elseif mode == MODE.ROWS then
        -- Each scene on the odd step under its pad column; step 16 stop all.
        for r = 0, 7 do out[r * 2] = colourFns.groupLed(readGroup("sceneProperties", r)) end
        out[15] = {127, 0, 0, ANIM.DIM}
    end
    return out
end

local function readApertureGeometry()
    local g = {}
    g.originX = safety.read("OriginX", function() return aperture().OriginX.value end) or 0
    g.originY = safety.read("OriginY", function() return aperture().OriginY.value end) or 0
    g.globalCols = safety.read("GetGlobalColumns", function() return aperture().GetGlobalColumns() end) or 0
    g.globalRows = safety.read("GetGlobalRows", function() return aperture().GetGlobalRows() end) or 0
    g.canLeft = safety.read("CanMoveLeft", function() return aperture().CanMoveLeft.value end) and true or false
    g.canRight = safety.read("CanMoveRight", function() return aperture().CanMoveRight.value end) and true or false
    g.canUp = safety.read("CanMoveUp", function() return aperture().CanMoveUp.value end) and true or false
    g.canDown = safety.read("CanMoveDown", function() return aperture().CanMoveDown.value end) and true or false
    return g
end

local function desiredState()
    local s = readApertureGeometry()
    if mode == MODE.ROWS then
        s.canLeft, s.canRight, s.canUp, s.canDown = s.canUp, s.canDown, s.canLeft, s.canRight
    elseif mode == MODE.PADS then
        s.canLeft, s.canRight, s.canUp, s.canDown = padBank > 0, padBank < CFG.MAX_PAD_BANK, false, false
    elseif mode == MODE.NOTES then
        s.canLeft, s.canRight, s.canUp, s.canDown = false, false, false, false
    end
    if v2.seq.mode == 1 then s.canLeft, s.canRight, s.canUp, s.canDown = true, true, false, false end
    s.mpcMode = v2.seq.mode
    s.mode, s.qlinkPage, s.padBank = mode, qlinkPage, padBank
    s.playing = safety.read("sequencer.Playing", function() return mpc.sequencer.Playing.value end) and true or false
    -- 1 is armed with the transport stopped, 2 is recording: the LED shows both.
    s.recording = ((tonumber(safety.read("sequencer.RecordState", function() return mpc.sequencer.RecordState.value end)) or 0) >= 1)
    s.overdubbing = ((tonumber(safety.read("sequencer.OverdubState", function() return mpc.sequencer.OverdubState.value end)) or 0) >= 1)
    s.armed, s.repeatOn = v2.armed or false, v2.repeatOn or false
    s.popup = v2.seq.popup == "Sixteen Level"
    -- Mute is a property (Akai's own script reads it so); solo is a function,
    -- polled with arm once a second.
    -- Plain pcall: a track with no entry here (returns, submixes) is not an error.
    local okMute, muted = pcall(function() return mpc.tracks.normalTracks[v2.trackIndex].Mute.value end)
    s.muted = okMute and muted == true
    s.solo = v2.solo == true
    s.aux = v2.seq.aux() and not (v2.seq.mode == 2 or v2.seq.mode == 3)
    s.metronome = safety.readOptional("MetronomeEnabled", function() return mpc.sequencer.MetronomeEnabled.value end) == true
    s.automation = ({Off=0, Read=1, Write=2})[safety.readOptional("GlobalAutomationFilterType", function() return mpc.project.GlobalAutomationFilterType.value end)] or 0
    s.available = v2.available or 0
    s.marks = not v2.seq.aux(true) -- mute and solo are readable: any track but a mixer track
    s.bpm10 = math.floor((tonumber(safety.readOptional("BPM.read", function() return mpc.project.BPM.value end)) or v2.bpm or 120) * 10 + 0.5)
    return s
end

local function trackTitle()
    local name = safety.read("currentTrack.Name", function() return mpc.tracks.currentTrack.Name.value end)
    local index = safety.read("currentTrack.Index", function() return mpc.tracks.currentTrack.Index.value end)
    if index and not v2.seq.aux(true) then
        return tostring(math.floor(index) + 1) .. ": " .. tostring(name or "")
    end
    return tostring(name or "")
end

local function subtitle()
    -- One line saying what the track is (Ryan, 2026-11-14): a plugin track's
    -- preset, otherwise the track's type. The view (banks, key, clip window)
    -- is the Move's to show; it knows all of it.
    local kind = safety.read("currentTrack.Type", function() return mpc.tracks.currentTrack.Type.value end)
    if kind == "Plugin" then
        local preset = safety.readOptional("PluginPresetName", function() return mpc.tracks.currentTrack.PluginPresetName.value end)
        -- The preset on the Move did not follow a change made on the MPC
        -- until the track was left and re-entered (Ryan, 2026-11-15), though
        -- this is re-read every state poll. Akai's MPK mini script follows it
        -- by LISTENING and using the callback's value (mpkMiniPlusII.lua:511),
        -- so we do too (listenGlobal); the read is the fallback. Confirmed on
        -- the device, 2026-11-19.
        if type(v2.presetHeard) == "string" and v2.presetHeard ~= "" then return v2.presetHeard end
        if type(preset) == "string" and preset ~= "" then return preset end
    end
    if kind == "Send" then return "Return" end -- the MPC calls a Send track a return
    return type(kind) == "string" and kind or ""
end

local function readQLink(idx)
    local name = safety.read("qlinks.TargetName", function()
        return mpc.controlSurface.qlinks[idx].TargetName.value
    end)
    local value = safety.read("qlinks.ValueString", function()
        return mpc.controlSurface.qlinks[idx].ValueString.value
    end)
    if name == nil or value == nil then return nil end
    return tostring(name), tostring(value)
end

-----------------------------------------------------------------------------
-- Diff and send
-----------------------------------------------------------------------------

local function sameState(a, b)
    if not a or not b then return false end
    for _, k in ipairs({ "mode", "qlinkPage", "padBank", "playing", "recording", "overdubbing",
        "originX", "originY", "globalCols", "globalRows", "canLeft", "canRight", "canUp", "canDown",
        "armed", "repeatOn", "metronome", "popup", "aux", "muted", "solo", "marks", "automation", "available", "bpm10", "mpcMode" }) do
        if a[k] ~= b[k] then return false end
    end
    return true
end

-- Send the changed entries of want[0..n-1] against cache[], as runs of <= 8.
local function sendRuns(want, cache, n, encoder)
    local i = 0
    while i < n do
        if want[i] and not colourFns.sameLed(want[i], cache[i]) then
            local first, leds = i, {}
            while i < n and want[i] and #leds < CFG.PADS_PER_MSG and not colourFns.sameLed(want[i], cache[i]) do
                leds[#leds + 1] = want[i]
                cache[i] = want[i]
                i = i + 1
            end
            enqueue(encoder(first, leds))
        else
            i = i + 1
        end
    end
end

-- Reset the shared touch/idle cache. Remove pending old-page QLINKs too,
-- so the new STATE always reaches the Move before its page assignments.
function enc.resetQLinks()
    sent.qlink = {}
    lastPoll.qlinkRead = {}
    lastPoll.qlinkRR = -1
    lastPoll.qlinkIdle = nowMs()
    for i = #queue, 1, -1 do
        if queue[i]:byte(4) == MSG.OUT_QLINK then
            table.remove(queue, i)
            for key, idx in pairs(queueKeys) do
                if idx == i then queueKeys[key] = nil
                elseif idx > i then queueKeys[key] = idx - 1 end
            end
        end
    end
end

local function sendQLink(k, poll)
    if poll and lastPoll.qlinkRead[k] == tickCount then return end
    lastPoll.qlinkRead[k] = tickCount
    local name, value = readQLink(qlinkIndex(qlinkPage, k))
    if name == nil then return end -- one failing knob must not poison its cache
    local key = name .. "\0" .. value
    if key ~= sent.qlink[k] then
        sent.qlink[k] = key
        enqueue(enc.qlink(k, name, value), "qlink" .. k)
    end
end

-- parts: { state=bool, grid=bool, text=bool }; force resends everything.
local function sync(parts, force)
    if force then
        sent = { pads = {}, steps = {}, text = {} }
        parts = { state = true, grid = true, text = true }
        enc.resetQLinks()
    end
    sent.pads = sent.pads or {}
    sent.steps = sent.steps or {}
    sent.text = sent.text or {}

    -- Each part is protected on its own: a fault in one costs only that part.
    if parts.state then
        safety.safe("sync.state", function()
            local s = desiredState()
            if not sameState(s, sent.state) then
                sent.state = s
                enqueue(enc.state(s), "state")
            end
        end)
    end
    if parts.grid then
        safety.safe("sync.pads", function() sendRuns(desiredPads(), sent.pads, CFG.NUM_PADS, enc.pads) end)
        safety.safe("sync.rows", function()
            local rows = desiredRows()
            local changed = not sent.rows
            for i = 1, CFG.NUM_ROW_BUTTONS do
                if not changed and not colourFns.sameLed(rows[i], sent.rows[i]) then changed = true end
            end
            if changed then
                sent.rows = rows
                enqueue(enc.rows(rows), "rows")
            end
        end)
    end
    if (parts.grid or parts.steps) and not (v2.seq.mode == 1 and (v2.seq.job or nowMs() < (v2.seq.quietUntil or -math.huge))) then
        safety.safe("sync.steps", function() sendRuns(desiredSteps(), sent.steps, CFG.NUM_STEPS, enc.steps) end)
    end
    if parts.text then
        safety.safe("sync.text", function()
            local t0, t1 = trackTitle(), subtitle()
            if sent.text[0] ~= t0 then sent.text[0] = t0; enqueueText(0, t0); v2.seq.readLane() end
            if sent.text[1] ~= t1 then sent.text[1] = t1; enqueueText(1, t1) end
        end)
    end
    if force then
        for k = 0, CFG.QLINKS_PER_PAGE - 1 do safety.safe("sync.qlink", sendQLink, k) end
    end
end

-----------------------------------------------------------------------------
-- Mappings (channel 16 only). Every mapping is recorded with its removal.
-----------------------------------------------------------------------------

local function scriptMapper() return abletonMoveSchwung.mappings.script end

-- inMusic's scripts reach Q-Links through mappings.controlSurface.qlinks; the
-- Static analysis also lists mappings.qlinks. Try the proven path first.
local function qlinkMapper()
    local ok, m = pcall(function() return abletonMoveSchwung.mappings.controlSurface.qlinks end)
    if ok and m then return m end
    return abletonMoveSchwung.mappings.qlinks
end

local function unmapKey(key)
    local remove = mapped[key]
    if remove then
        mapped[key] = nil
        remove()
    end
end

local function mapScriptNote(note)
    local key = "note" .. note
    unmapKey(key)
    if safety.safe("AddNoteToScript", function() scriptMapper().AddNoteToScript(CFG.CH, note) end) then
        mapped[key] = function()
            local vp = heldPads[note]
            if vp then
                -- UNPROVEN: release a script-observed virtual pad before unmapping.
                safety.safe("ReleaseVirtual", function() mpc.controlSurface.pads.ReleaseVirtual(vp) end)
            end
            heldPads[note] = nil
            safety.safe("RemoveNoteToScript", function() scriptMapper().RemoveNoteToScript(CFG.CH, note) end)
        end
    end
end

local function mapVirtualPad(note, vp)
    local key = "note" .. note
    unmapKey(key)
    if safety.safe("AddNoteToVirtualPad", function() abletonMoveSchwung.mappings.pads.AddNoteToVirtualPad(CFG.CH, note, vp) end) then
        mapped[key] = function()
            -- UNPROVEN: native mappings bypass Lua's note handlers, so release
            -- every old virtual pad before removing/rebinding its note mapping.
            safety.safe("ReleaseVirtual", function() mpc.controlSurface.pads.ReleaseVirtual(vp) end)
            heldPads[note] = nil
            safety.safe("RemoveNoteToVirtualPad", function() abletonMoveSchwung.mappings.pads.RemoveNoteToVirtualPad(CFG.CH, note) end)
        end
    end
end

local function mapScriptCC(cc)
    local key = "cc" .. cc
    unmapKey(key)
    if safety.safe("AddCCToScript", function() scriptMapper().AddCCToScript(CFG.CH, cc) end) then
        mapped[key] = function()
            safety.safe("RemoveCCToScript", function() scriptMapper().RemoveCCToScript(CFG.CH, cc) end)
        end
    end
end

local function mapQLink(cc, idx)
    local key = "cc" .. cc
    unmapKey(key)
    if safety.safe("AddInfiniteCCToQLink", function() qlinkMapper().AddInfiniteCCToQLink(CFG.CH, cc, idx) end) then
        mapped[key] = function()
            safety.safe("RemoveInfiniteCCToQLink", function() qlinkMapper().RemoveInfiniteCCToQLink(CFG.CH, cc) end)
        end
    end
end

local COMMAND_CCS = {}
for cc = CC.NAV_LEFT, CC.QUANT do COMMAND_CCS[#COMMAND_CCS + 1] = cc end
for cc = CC.STEP_FIRST, CC.STEP_LAST do COMMAND_CCS[#COMMAND_CCS + 1] = cc end
for cc = CC.SET_MODE, CC.TEMPO do COMMAND_CCS[#COMMAND_CCS + 1] = cc end

local function mapQLinkPage()
    for k = 0, CFG.QLINKS_PER_PAGE - 1 do
        mapQLink(CC.KNOB_FIRST + k, qlinkIndex(qlinkPage, k))
    end
end

local function mapPadsForMode()
    for p = 0, CFG.NUM_PADS - 1 do unmapKey("note" .. p) end
    if mode == MODE.SESSION or mode == MODE.ROWS then
        for p = 0, CFG.NUM_PADS - 1 do mapScriptNote(p) end
    elseif mode == MODE.PADS then
        -- In Step Seq a native pad press writes a step, so the script takes
        -- the notes instead and uses them to pick the lane (v2.seq.lane).
        for p = 0, CFG.NUM_PADS - 1 do
            if v2.seq.mode == 1 then mapScriptNote(p) else mapVirtualPad(p, coords.padToVirtual(padBank, p)) end
        end
    end
    -- Notes mode: the Move sends ordinary notes on channels 1-15; nothing bound.
end
v2.seq.remap = mapPadsForMode

local function mapAll()
    for _, cc in ipairs(COMMAND_CCS) do mapScriptCC(cc) end
    for k = 0, CFG.QLINKS_PER_PAGE - 1 do mapScriptNote(CFG.NOTE_KNOB_TOUCH_FIRST + k) end
    mapQLinkPage()
    mapPadsForMode()
end

local function unmapAll()
    local keys = {}
    for key in pairs(mapped) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do unmapKey(key) end
end

-----------------------------------------------------------------------------
-- Listeners: they mark parts dirty; the timer does the work.
-----------------------------------------------------------------------------

local function listenProp(list, label, getProp, part)
    local ok, prop = pcall(getProp)
    if not ok or prop == nil then
        if not ok then safety.noteError(label, prop) end
        return
    end
    local cb = function()
        dirty[part] = true
        if label == "currentTrack.Index" then enc.resetQLinks() end
    end
    if safety.safe(label .. ":listen", function() prop:listen(cb, CFG.LISTENER) end) then
        list[#list + 1] = { prop = prop, label = label }
    end
end

local function unlisten(list)
    for _, e in ipairs(list) do
        safety.safe(e.label .. ":stopListening", function() e.prop:stopListening(CFG.LISTENER) end)
    end
    for i = #list, 1, -1 do list[i] = nil end
end

local function listenGrid()
    unlisten(listenedGrid)
    if mode ~= MODE.SESSION and mode ~= MODE.ROWS then return end
    local cols, rows = coords.apertureSize(mode)
    for c = 0, cols - 1 do
        for r = 0, rows - 1 do
            for _, field in ipairs({ "Colour", "State", "Selected" }) do
                listenProp(listenedGrid, "clipProperties." .. field, function()
                    return aperture().clipProperties[c][r][field]
                end, "grid")
            end
        end
    end
    for c = 0, cols - 1 do
        for _, field in ipairs({ "Colour", "State", "Selected" }) do
            listenProp(listenedGrid, "trackProperties." .. field, function()
                return aperture().trackProperties[c][field]
            end, "grid")
        end
    end
    for r = 0, rows - 1 do
        for _, field in ipairs({ "Colour", "State", "Selected" }) do
            listenProp(listenedGrid, "sceneProperties." .. field, function()
                return aperture().sceneProperties[r][field]
            end, "grid")
        end
    end
end

local function listenGlobal()
    unlisten(listenedGlobal)
    safety.safe("engineMode.CurrentMode:listenOldNew", function()
        local prop = mpc.engineMode.CurrentMode
        prop:listenOldNew(function(_, value) v2.seq.changed(value) end, CFG.LISTENER)
        listenedGlobal[#listenedGlobal + 1] = { prop = prop, label = "engineMode.CurrentMode" }
    end)
    safety.safe("engineMode.CurrentPopup:listenOldNew", function()
        local prop = mpc.engineMode.CurrentPopup
        v2.seq.popup = prop.value
        prop:listenOldNew(function(_, value) v2.seq.popup = value; dirty.state = true end, CFG.LISTENER)
        listenedGlobal[#listenedGlobal + 1] = { prop = prop, label = "engineMode.CurrentPopup" }
    end)
    listenProp(listenedGlobal, "sequencer.Playing", function() return mpc.sequencer.Playing end, "state")
    listenProp(listenedGlobal, "sequencer.RecordState", function() return mpc.sequencer.RecordState end, "state")
    listenProp(listenedGlobal, "sequencer.OverdubState", function() return mpc.sequencer.OverdubState end, "state")
    listenProp(listenedGlobal, "currentTrack.Name", function() return mpc.tracks.currentTrack.Name end, "text")
    listenProp(listenedGlobal, "currentTrack.Index", function() return mpc.tracks.currentTrack.Index end, "text")
    safety.safe("currentTrack.PluginPresetName:listen", function()
        local prop = mpc.tracks.currentTrack.PluginPresetName
        prop:listen(function(name) v2.presetHeard = name; dirty.text = true end, CFG.LISTENER)
        listenedGlobal[#listenedGlobal + 1] = { prop = prop, label = "currentTrack.PluginPresetName" }
    end)
    listenProp(listenedGlobal, "OriginX", function() return aperture().OriginX end, "state")
    listenProp(listenedGlobal, "OriginY", function() return aperture().OriginY end, "state")
end

-- Q-Link touch: listen to TargetName and ValueString of one Q-Link.
local function listenQLink(k)
    local t = touched[k]
    if not t then return end
    t.props = {}
    for _, field in ipairs({ "TargetName", "ValueString" }) do
        local ok, prop = pcall(function() return mpc.controlSurface.qlinks[t.idx][field] end)
        if ok and prop then
            local cb = function()
                if touched[k] then
                    local okSend, err = pcall(sendQLink, k)
                    if not okSend then safety.noteError("qlink listener", err) end
                end
            end
            if safety.safe("qlinks." .. field .. ":listen", function() prop:listen(cb, CFG.LISTENER) end) then
                t.props[#t.props + 1] = { prop = prop, label = "qlinks." .. field }
            end
        elseif not ok then
            safety.noteError("qlinks[" .. tostring(t.idx) .. "]", prop)
        end
    end
end

local function unlistenQLink(k)
    local t = touched[k]
    if t and t.props then unlisten(t.props) end
end

-----------------------------------------------------------------------------
-- Aperture
-----------------------------------------------------------------------------

local function applyGeometry()
    local cols, rows = coords.apertureSize(mode)
    safety.safe("SetColumns", function() aperture().SetColumns(cols) end)
    safety.safe("SetRows", function() aperture().SetRows(rows) end)
    if mode == MODE.SESSION or mode == MODE.ROWS or CFG.SHOW_APERTURE_IN_PAD_MODES then
        safety.safe("Show", function() aperture().Show() end)
    else
        safety.safe("Hide", function() aperture().Hide() end)
    end
end

local function setupAperture()
    safety.safe("SetFollowsTUI", function() aperture().SetFollowsTUI(false) end)
    safety.safe("SetFollowsTUIActiveMatrix", function() aperture().SetFollowsTUIActiveMatrix(false) end)
    safety.safe("ActiveMatrix", function() aperture().ActiveMatrix.value = "Normal" end)
    safety.safe("SetLabel", function() aperture().SetLabel(CFG.APERTURE_LABEL) end)
    applyGeometry()
end

-- Entering a clip layout shows the current track (Ryan, 2026-11-19: track 6
-- active, Transposed opened on tracks 1-4). The window takes the page that
-- holds it, but never runs past the last track: it slides back so the last
-- track sits at the right edge (Ryan: 6 of 6 in Transposed shows 3-6; 9 of 9
-- in Matrix shows 2-9, not 9-16). Left alone when the track is in view and the
-- window does not run past the end. Mixer tracks have no clip column. Moves
-- with MoveLeft/Right, as the arrows do (device-proven), not the unproven
-- MoveTo. The track count is normalTracks.Count, as Akai's own script reads it.
function v2.showCurrentTrack()
    if v2.seq.aux(true) then return end
    local idx = tonumber(safety.read("currentTrack.Index", function() return mpc.tracks.currentTrack.Index.value end))
    local ox = tonumber(safety.read("OriginX", function() return aperture().OriginX.value end))
    if not idx or not ox then return end
    idx, ox = math.floor(idx), math.floor(ox)
    local cols = coords.apertureSize(mode)
    local okN, n = pcall(function() return mpc.tracks.normalTracks.Count.value end)   -- optional: without it, no clamp
    n = okN and tonumber(n) or nil
    local overhang = n and ox > 0 and ox + cols > n
    if idx >= ox and idx < ox + cols and not overhang then return end
    local target = (idx // cols) * cols
    if n then target = math.max(0, math.min(target, n - cols)) end
    local d = target - ox
    if d > 0 then safety.safe("MoveRight", function() aperture().MoveRight(d) end)
    elseif d < 0 then safety.safe("MoveLeft", function() aperture().MoveLeft(-d) end) end
end

-- dir: "Left" | "Right" | "Up" | "Down"; page: by the aperture's size.
local function moveAperture(dir, page)
    local cols, rows = coords.apertureSize(mode)
    local amount = page and ((dir == "Left" or dir == "Right") and cols or rows) or 1
    safety.safe("Move" .. dir, function() aperture()["Move" .. dir](amount) end)
    dirty.state, dirty.grid, dirty.text = true, true, true
end

-----------------------------------------------------------------------------
-- Lifecycle
-----------------------------------------------------------------------------

local function resetSession()
    v2.seq.mode = 4
    v2.available, v2.armAt, v2.armPending = nil, nil, true
    v2.trackIndex, v2.trackName, v2.meta, v2.metaAt = nil, nil, nil, nil
    v2.positionAt, v2.wasPlaying = nil, false
    v2.position, v2.length, v2.loopStart = nil, nil, nil
    v2.armed, v2.jogTouched = false, false
    heldPads = {}
    shiftHeld = false
    touched = {}
    clearQueue()
    needFull = false
    sent = { pads = {}, steps = {}, text = {} }
    enc.resetQLinks()
    dirty = { state = false, grid = false, text = false }
    broken = {}
end

local function goPassive(reason)
    v2.releaseRepeat()
    v2.job = nil
    if not active then return end
    for k in pairs(touched) do unlistenQLink(k) end
    unlisten(listenedGrid)
    unlisten(listenedGlobal)
    unmapAll()
    safety.safe("Hide", function() aperture().Hide() end)
    active = false
    resetSession()
    enqueue(enc.goodbye(), "goodbye", true)
end

local function clipWorkflowAvailable()
    return safety.read("features.UseClipWorkflow", function() return mpc.features.UseClipWorkflow.value end) and true or false
end

local function goActive()
    local wasActive = active
    if not wasActive then
        resetSession()
        active = true
        v2.seq.readLane() -- a fresh Move knows no lane
        if not clipWorkflowAvailable() and mode ~= MODE.NOTES then mode = MODE.PADS end
        setupAperture()
        mapAll()
        listenGrid()
        listenGlobal()
        safety.safe("timer.Start", function() abletonMoveSchwung.timer.Start(CFG.TICK_MS) end)
    else
        clearQueue()
        needFull = false
    end
    v2.seq.changed(safety.read("engineMode.CurrentMode", function() return mpc.engineMode.CurrentMode.value end))
    lastHeard = nowMs()
    v2.trackIndex = safety.read("currentTrack.Index", function() return mpc.tracks.currentTrack.Index.value end)
    v2.trackName = safety.read("currentTrack.Name", function() return mpc.tracks.currentTrack.Name.value end)
    enqueue(enc.welcome(CFG.PROTOCOL_VERSION, clipWorkflowAvailable() and 1 or 0), "welcome", true)
    sync(nil, true)
end

-----------------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------------

local function setMode(m)
    if m < MODE.SESSION or m > MODE.NOTES then return end
    if (m == MODE.SESSION or m == MODE.ROWS) and not clipWorkflowAvailable() then
        enqueue(enc.state(desiredState()), "state")
        return
    end
    if m >= MODE.PADS then m = v2.playMode() else v2.clipMode = m end
    if m < MODE.SESSION or m > MODE.NOTES or m == mode then return end
    for k in pairs(touched) do unlistenQLink(k) end
    mode = m
    applyGeometry()
    if m == MODE.SESSION or m == MODE.ROWS then v2.showCurrentTrack() end
    mapPadsForMode()
    listenGrid()
    for k in pairs(touched) do listenQLink(k) end
    -- No message on a mode change: the pads show it, as on stock Move (Ryan).
    dirty.state, dirty.grid, dirty.text = true, true, true
end

local function setQLinkPage(page)
    if page < 0 or page >= CFG.NUM_QLINK_PAGES or page == qlinkPage then return end
    qlinkPage = page
    mapQLinkPage()
    for k, t in pairs(touched) do
        unlistenQLink(k)
        t.idx = qlinkIndex(qlinkPage, k)
        listenQLink(k)
    end
    enc.resetQLinks()
    sent.state = desiredState()
    enqueue(enc.state(sent.state), "state")
    for k = 0, CFG.QLINKS_PER_PAGE - 1 do safety.safe("page.qlink", sendQLink, k) end
    enqueueText(2, ({ [0] = "Q-Links 1-8", "Q-Links 9-16", "Q-Links Col 1-2", "Q-Links Col 3-4" })[page])
    dirty.state = true
end

v2.seq.setPage = setQLinkPage
v2.seq.setMode = setMode

local function setPadBank(bank)
    if bank < 0 then bank = 0 end
    if bank > CFG.MAX_PAD_BANK then bank = CFG.MAX_PAD_BANK end
    if bank == padBank then return end
    padBank = bank
    if mode == MODE.PADS then mapPadsForMode() end
    dirty.state, dirty.grid, dirty.text = true, true, true
end

local function handleNav(cc)
    if v2.seq.mode == 1 then
        local name = ({[CC.NAV_LEFT]="stepSeqPrev", [CC.NAV_RIGHT]="stepSeqNext"})[cc]
        if name then
            safety.safe(name .. ".Press", function() mpc.controlSurface[name].Press() end)
            safety.safe(name .. ".Release", function() mpc.controlSurface[name].Release() end)
        end
        return
    end
    if mode == MODE.SESSION then
        local dir = ({ [CC.NAV_LEFT] = "Left", [CC.NAV_RIGHT] = "Right",
            [CC.NAV_UP] = "Up", [CC.NAV_DOWN] = "Down" })[cc]
        moveAperture(dir, shiftHeld)
    elseif mode == MODE.ROWS then
        -- left/right: scenes (aperture rows); up/down: tracks (aperture columns)
        local dir = ({ [CC.NAV_LEFT] = "Up", [CC.NAV_RIGHT] = "Down",
            [CC.NAV_UP] = "Left", [CC.NAV_DOWN] = "Right" })[cc]
        moveAperture(dir, shiftHeld)
    elseif mode == MODE.PADS then
        if cc == CC.NAV_LEFT then setPadBank(padBank - 1)
        elseif cc == CC.NAV_RIGHT then setPadBank(padBank + 1) end
    end
    -- Notes mode: the Move handles octaves itself.
end

local function handleRow(r)
    if mode == MODE.SESSION then
        if not shiftHeld then
            safety.safe("TriggerRow", function() aperture().TriggerRow(r) end)
        end
    elseif mode == MODE.ROWS then
        if shiftHeld then
            safety.safe("StopClipsOnTrack", function() aperture().StopClipsOnTrack(r) end)
        else
            safety.safe("SelectTrack", function() aperture().SelectTrack(r) end)
        end
    end
    dirty.grid = true
end

-- V2 helpers share a table to preserve main-chunk local headroom.
function v2.optional(label, fn, bit)
    if broken[label] then return false end
    local ok = safety.safe(label, fn)
    if not ok then
        broken[label] = true
        if bit then v2.available = (v2.available or 0) & ~bit end
    end
    dirty.state = true
    return ok
end
function v2.button(name, bit)
    v2.optional(name, function()
        local button = name == "quantise" and (mpc.controlSurface.quantiseApply or mpc.controlSurface.quantizeApply) or mpc.controlSurface[name]
        button.Press()
    end, bit)
end
-- CC.QUANT, sent when the Move's Setup says "Quantise: Always" (Ryan,
-- 2026-11-15: a setting, the default staying as the MPC behaves).
-- Quantise without turning Timing Correct on first (Ryan, 2026-11-14): the
-- MPC's quantise applies the global TC and does nothing while it is off.
-- sequencer.quantiser.Enabled is that switch by its registered help text
-- ("Whether the Quantiser is enabled"); writing it is unproven. If it reads
-- off: on, press a tick later, off again a tick after that. If it cannot be
-- read or written, the plain press as before.
function v2.quantise()
    if v2.quant then return end
    local ok, on = pcall(function() return mpc.sequencer.quantiser.Enabled.value end)
    if not ok or on ~= false then v2.button("quantise", 8); return end
    if not pcall(function() mpc.sequencer.quantiser.Enabled.value = true end) then v2.button("quantise", 8); return end
    v2.quant, v2.quantWait = 1, CFG.QUANT_WAIT_TICKS
end
-- Device, 2026-11-14: with one tick each way Timing Correct came on and
-- went off again and nothing was quantised. QUANT_WAIT_TICKS holds it on
-- for longer on both sides of the press; whether that is enough is unread.
function v2.quantWork()
    v2.quantWait = v2.quantWait - 1
    if v2.quantWait > 0 then return end
    if v2.quant == 1 then v2.button("quantise", 8); v2.quant, v2.quantWait = 2, CFG.QUANT_WAIT_TICKS
    else
        pcall(function() mpc.sequencer.quantiser.Enabled.value = false end)
        v2.quant = nil
    end
end
function v2.playMode()
    if v2.seq.mode == 2 or v2.seq.mode == 3 then return MODE.PADS end -- the mute modes are pad screens
    return safety.readOptional("currentTrack.Type", function() return mpc.tracks.currentTrack.Type.value end) == "Drum" and MODE.PADS or MODE.NOTES
end
function v2.releaseRepeat()
    -- Always attempt the release: even a failed Hold may have reached the device.
    safety.safe("noteRepeat.Release", function() mpc.controlSurface.noteRepeat.Release() end)
    v2.repeatOn, v2.latched, v2.repeatDown = false, false, false
    dirty.state = true
end
function v2.repeatCommand(press)
    if press then
        if shiftHeld then
            v2.repeatDown = false
            local held = safety.safe("noteRepeat.shift.Hold", function() mpc.controlSurface.shift.Hold() end)
            local ok = held and safety.safe("noteRepeat.Press", function() mpc.controlSurface.noteRepeat.Press() end)
            safety.safe("noteRepeat.shift.Release", function() mpc.controlSurface.shift.Release() end)
            v2.latched = ok and not v2.latched or false
            v2.repeatOn = v2.latched
            if not ok then v2.releaseRepeat() end
        elseif v2.latched then v2.releaseRepeat()
        else
            v2.repeatDown = true
            v2.repeatOn = safety.safe("noteRepeat.Hold", function() mpc.controlSurface.noteRepeat.Hold() end)
        end
    elseif v2.repeatDown then v2.releaseRepeat() end
    dirty.state = true
end
function v2.armRead(now)
    v2.armAt = now
    local name = safety.read("currentTrack.Name", function() return mpc.tracks.currentTrack.Name.value end)
    if type(name) ~= "string" then return end
    local okArm, value = pcall(function() return mpc.tracks.GetTrackRecordArmed(name) end)
    if not okArm then value = nil end
    if type(value) == "boolean" then v2.armed = value; dirty.state = true end
    local okSolo, solo = pcall(function() return mpc.tracks.GetSolo(name) end)
    if not okSolo then solo = false end -- unreadable: never leave SOLO lit
    if type(solo) == "boolean" and solo ~= v2.solo then v2.solo = solo; dirty.state = true end
end
function v2.armToggle()
    local name = safety.read("currentTrack.Name", function() return mpc.tracks.currentTrack.Name.value end)
    if type(name) ~= "string" then return end
    -- A press may arrive before the next track poll or immediately after
    -- another press. Read the named track here, then read back next tick.
    local armed = safety.readOptional("GetTrackRecordArmed", function() return mpc.tracks.GetTrackRecordArmed(name) end)
    if type(armed) ~= "boolean" then return end
    if v2.optional("SetTrackRecordArmed", function() mpc.tracks.SetTrackRecordArmed(name, not armed) end) then
        v2.armed = not armed
        v2.armPending = true -- read back on the next tick, never a burst
    end
end
function v2.automation()
    v2.optional("Automation", function()
        local p = mpc.project.GlobalAutomationFilterType
        -- Read / Write only; Off goes to Read. Sent on Shift + volume touch,
        -- so Shift is always held here and means nothing (Ryan, 2026-11-14).
        p.value = p.value == "Read" and "Write" or "Read"
        enqueueText(2, "Automation: " .. tostring(p.value))
    end)
end
function v2.tempo(delta)
    if delta == 0 or delta == 64 then return end
    delta = delta < 64 and delta or delta - 128
    local bpm = tonumber(safety.readOptional("BPM.read", function() return mpc.project.BPM.value end)) or v2.bpm or 120
    bpm = math.max(20, math.min(999, bpm + delta * (shiftHeld and 0.1 or 1)))
    if not v2.optional("BPM.write", function()
        assert(mpc.project.BPM.value ~= nil, "unavailable")
        mpc.project.BPM.value = bpm
    end) then v2.optional("SetBPM", function() mpc.sequencer.SetBPM(bpm) end) end
    v2.bpm = bpm
end
function v2.trackList()
    local index = safety.read("currentTrack.Index", function() return mpc.tracks.currentTrack.Index.value end)
    if type(index) ~= "number" then return end
    for offset = -1, 1 do
        local name = ""
        if offset == 0 then name = safety.read("currentTrack.Name", function() return mpc.tracks.currentTrack.Name.value end) or ""
        elseif index + offset >= 0 then
            name = safety.readOptional("normalTracks.Name", function()
                local track = mpc.tracks.normalTracks[index + offset]
                return track and track.Name.value
            end) or ""
        end
        enqueueText(4 + offset, name)
    end
end
function v2.copy()
    if not v2.job and mode < MODE.PADS then v2.job = {kind=shiftHeld and "scene" or "clip", stage=0} end
end
function v2.work()
    local j = v2.job
    if not j then return false end
    -- One native function per tick, including selection and empty-slot search.
    local ok = v2.optional("clip." .. j.kind, function()
        if j.stage == 0 then j.col = mpc.clipMatrix.GetSelectedClipColumn(); j.stage = 1
        elseif j.stage == 1 then
            j.row = mpc.clipMatrix.GetSelectedClipRow()
            if type(j.col) ~= "number" or type(j.row) ~= "number" or j.col < 0 or j.row < 0 or j.col % 1 ~= 0 or j.row % 1 ~= 0 then
                enqueueText(2, "No clip selected"); v2.job = nil
            else j.stage = 2 end
        elseif j.kind == "select" then
            pcall(function() mpc.clipMatrix.SelectClip(j.col, j.next) end)
            -- clipMatrix.SelectClip left the focus on the original (bench); the
            -- aperture's own SelectClip is what a pad press uses, when in view.
            pcall(function()
                local ox, oy = math.floor(aperture().OriginX.value), math.floor(aperture().OriginY.value)
                local cols, rows = coords.apertureSize(mode)
                local c, r = j.col - ox, j.next - oy
                if c >= 0 and r >= 0 and c < cols and r < rows then aperture().SelectClip(c, r) end
            end)
            -- The original was playing: launch the copy, so what is edited is
            -- what is heard (Ryan, 2026-11-14). It takes over at the MPC's
            -- launch quantise.
            if j.playing then j.kind = "launch" else v2.job = nil end
        elseif j.kind == "launch" then
            pcall(function() mpc.clipMatrix.TriggerClip(j.col, j.next) end)
            v2.job = nil
        elseif j.kind == "delete" then
            mpc.clipMatrix.DeleteClip(j.col, j.row); enqueueText(2, "Clip deleted"); v2.job = nil
        elseif j.kind == "scene" then
            if j.stage == 2 then mpc.clipMatrix.InsertRows(j.row + 1, 1); j.stage = 3
            else mpc.clipMatrix.CopyRow(j.row, j.row + 1); enqueueText(2, "Scene duplicated"); v2.job = nil end
        elseif j.stage == 2 then
            j.rows = mpc.clipMatrix.GetRows()
            assert(type(j.rows) == "number" and j.rows > j.row, "invalid row count")
            j.next = j.row + 1; j.stage = 3
        elseif j.stage == 3 then
            if j.next >= j.rows then enqueueText(2, "Track column is full"); v2.job = nil
            else
                local has = mpc.clipMatrix.HasClip(j.col, j.next)
                assert(type(has) == "boolean", "invalid HasClip result")
                if not has then j.stage = j.select and 4 or 5 else j.next = j.next + 1 end
            end
        elseif j.stage == 4 then
            local okPlaying, playing = pcall(function() return mpc.clipMatrix.ClipIsPlaying(j.col, j.row) end)
            j.playing = okPlaying and playing == true
            j.stage = 5
        else
            mpc.clipMatrix.CopyClip(j.col, j.row, j.col, j.next)
            enqueueText(2, "Clip duplicated")
            if j.select and not j.selected then j.selected = true; j.kind, j.stage = "select", 9 else v2.job = nil end
        end
    end)
    if not ok then v2.job = nil end
    dirty.grid = true
    return true
end
function enc.position(position, length, numerator, denominator)
    local bytes = {}
    for _, value in ipairs({position, length}) do
        value = math.max(0, math.min(0xfffffff, math.floor(tonumber(value) or 0)))
        for _ = 1, 4 do bytes[#bytes + 1] = value % 128; value = value // 128 end
    end
    bytes[#bytes + 1], bytes[#bytes + 2] = b7(numerator or 4), b7(denominator or 4)
    return frame(MSG.OUT_POSITION, string.char(table.unpack(bytes)))
end
function v2.poll(now)
    local index = safety.read("currentTrack.Index", function() return mpc.tracks.currentTrack.Index.value end)
    local name = safety.read("currentTrack.Name", function() return mpc.tracks.currentTrack.Name.value end)
    local changed = v2.trackIndex ~= index or v2.trackName ~= name
    if changed and v2.trackIndex ~= nil then enc.resetQLinks() end
    if changed then
        v2.trackIndex, v2.trackName = index, name
        dirty.grid = true -- the active track's button moves
        v2.presetHeard = nil -- heard for the old track; the read stands until the listener speaks
        if v2.jogTouched then v2.trackList() end
        v2.armPending = true
    end
    if mode >= MODE.PADS then setMode(v2.playMode()) end
    if v2.available == nil then
        v2.available = 0
        for _, item in ipairs({{"MetronomeEnabled",1}, {"sixteenLevel",2}, {"fullLevel",4}, {"quantise",8}}) do
            local exists = safety.readOptional(item[1], function()
                if item[2] == 1 then return mpc.sequencer.MetronomeEnabled.value ~= nil end
                local button = item[1] == "quantise" and (mpc.controlSurface.quantiseApply or mpc.controlSurface.quantizeApply) or mpc.controlSurface[item[1]]
                return button ~= nil and type(button.Press) == "function"
            end)
            if exists then v2.available = v2.available | item[2] end
        end
    end
    local playing = safety.read("sequencer.Playing", function() return mpc.sequencer.Playing.value end) == true
    if v2.wasPlaying and not playing then
        enqueue(enc.position(v2.position or 0, v2.length or 3840, v2.num, v2.den), "position")
    end
    v2.wasPlaying = playing
    -- Metadata is paced too; sequence timing is used in clip modes until a
    -- per-clip API is available (bench proved the attempted paths unavailable).
    if v2.work() then return end
    if v2.armPending or now - (v2.armAt or -1e18) >= CFG.ARM_POLL_MS then
        v2.armPending = false; v2.armRead(now); return
    end
    if v2.meta == nil or now - (v2.metaAt or -1e18) >= 1000 then v2.meta = 0; v2.metaAt = now end
    if v2.meta == 0 then
        v2.loopStart = tonumber(safety.readOptional("GetLoopStart", function() return mpc.sequencer.GetLoopStart() end)) or 0
        v2.meta = 1; return
    elseif v2.meta == 1 then
        local finish = tonumber(safety.readOptional("GetEndOrLoop", function() return mpc.sequencer.GetEndOrLoop() end)) or 3840
        v2.length = math.max(1, finish - (v2.loopStart or 0)); v2.meta = 2
        -- Time signature properties are unproven; missing values assume 4/4.
        v2.num = safety.readOptional("TimeSignatureNumerator", function() local p = mpc.sequencer.TimeSignatureNumerator; return p and p.value end) or 4
        v2.den = safety.readOptional("TimeSignatureDenominator", function() local p = mpc.sequencer.TimeSignatureDenominator; return p and p.value end) or 4
        v2.num = tonumber(v2.num) or 4; v2.den = tonumber(v2.den) or 4
        if v2.num < 1 or v2.num > 127 then v2.num = 4 end
        if v2.den < 1 or v2.den > 127 then v2.den = 4 end
        return
    end
    if playing and now - (v2.positionAt or -1e18) >= CFG.POSITION_POLL_MS then
        v2.positionAt = now
        local position = safety.readOptional("PlayheadPosition", function() return mpc.sequencer.PlayheadPosition() end)
        if type(position) == "number" then
            v2.position = math.max(0, position - (v2.loopStart or 0))
            enqueue(enc.position(v2.position, v2.length or 3840, v2.num, v2.den), "position")
        end
    end
end

local function handleStep(s)
    if shiftHeld then
        if s == 5 then
            v2.optional("MetronomeEnabled", function()
                assert(mpc.sequencer.MetronomeEnabled.value ~= nil, "unavailable")
                mpc.sequencer.MetronomeEnabled.value = not mpc.sequencer.MetronomeEnabled.value
            end, 1)
        elseif s == 12 then v2.button("sixteenLevel", 2)
        elseif s == 9 then v2.button("fullLevel", 4)
        elseif s == 15 then v2.button("quantise", 8) end -- as the MPC does it: no effect while Timing Correct is off
    elseif v2.seq.mode == 1 then
        -- The Q-Links are the steps' velocities: follow the half pressed.
        v2.seq.setPage(s < 8 and 0 or 1)
        safety.safe("stepSequencer.Tap", function() mpc.controlSurface.stepSequencer.Tap(s + 1) end)
    elseif mode == MODE.ROWS then
        -- Transposed: the odd steps launch the scene in the pad column above
        -- (each column sits over two steps), step 16 stops all; track select
        -- and stop are on the row buttons (Ryan, 2026-11-19).
        if s == 15 then
            safety.safe("StopAllClips", function() mpc.clipMatrix.StopAllClips() end)
        elseif s % 2 == 0 then
            safety.safe("TriggerRow", function() aperture().TriggerRow(s // 2) end)
        end
    elseif mode == MODE.SESSION then
        if s < 16 then
            if s % 2 == 0 then safety.safe("SelectTrack", function() aperture().SelectTrack(s // 2) end)
            else safety.safe("StopClipsOnTrack", function() aperture().StopClipsOnTrack(s // 2) end) end
        end
    end
    dirty.state, dirty.grid = true, true
end

local function handleCC(cc, value)
    local press = value > 0
    if cc == CC.SHIFT then
        shiftHeld = press
    elseif cc >= CC.NAV_LEFT and cc <= CC.NAV_DOWN then
        if press then handleNav(cc) end
    elseif cc == CC.PLAY then
        if press then
            if shiftHeld then
                if safety.read("sequencer.Playing", function() return mpc.sequencer.Playing.value end) then
                    safety.safe("StopAllClips", function() mpc.clipMatrix.StopAllClips() end)
                else safety.safe("TogglePlay", function() mpc.sequencer.TogglePlay() end) end
            else safety.safe("TogglePlayStart", function() mpc.sequencer.TogglePlayStart() end) end
            dirty.state = true
        end
    elseif cc == CC.REC then
        if press then
            -- Plain Rec overdubs, as Move's own Rec does; Shift+Rec is the destructive record.
            if shiftHeld then safety.safe("Record", function() mpc.sequencer.Record() end)
            else safety.safe("Overdub", function() mpc.sequencer.Overdub() end) end
            dirty.state = true
        end
    elseif cc == CC.UNDO then
        if press then
            if shiftHeld then safety.safe("Redo", function() mpc.commandManager.Redo() end)
            else safety.safe("Undo", function() mpc.commandManager.Undo() end) end
        end
    elseif cc == CC.STOP_ALL then
        if press then
            safety.safe("StopAllClips", function() mpc.clipMatrix.StopAllClips() end)
            dirty.grid = true
        end
    elseif cc == CC.TRACK_PREV then
        if press then
            v2.seq.trackStep(-1)
        end
    elseif cc == CC.TRACK_NEXT then
        if press then
            v2.seq.trackStep(1)
        end
    elseif cc == CC.CAPTURE then
        -- Retrospective record. No script function reaches it; the MPC's own
        -- Shift+Rec does, when Preferences > "Record and Overdub Shift
        -- Behaviour" is "Retrospective Record". So press those two buttons.
        if press then
            safety.safe("Capture", function()
                local cs = mpc.controlSurface
                cs.shift.Hold()
                local ok, err = pcall(function() cs.record.Press() end)
                cs.shift.Release()
                if not ok then error(err, 0) end
            end)
            dirty.state, dirty.grid = true, true
        end
    elseif cc == CC.MODE then
        if press then
            if mode < MODE.PADS then
                if shiftHeld then setMode(mode == MODE.SESSION and MODE.ROWS or MODE.SESSION)
                else setMode(MODE.PADS) end
            elseif not shiftHeld then setMode(v2.clipMode or MODE.SESSION) end
        end
    elseif cc == CC.NOTE_REPEAT then v2.repeatCommand(press)
    elseif cc == CC.ARM then if press then v2.armToggle() end
    elseif cc == CC.AUTOMATION then if press then v2.automation() end
    elseif cc == CC.COPY then if press then v2.copy() end
    elseif cc == CC.DELETE then
        if press and not shiftHeld and not v2.job and mode < MODE.PADS then v2.job = {kind="delete", stage=0} end
    elseif cc == CC.JOG_TOUCH then
        v2.jogTouched = press; if press then v2.trackList() end
    elseif cc == CC.MAIN then if press then v2.seq.main() end
    elseif cc == CC.QUANT then if press then v2.quantise() end
    elseif cc == CC.DUP_CLIP then if press and not v2.job then v2.job = {kind="clip", stage=0, select=true} end
    elseif cc == CC.MUTE then if press then v2.seq.mute() end
    elseif cc == CC.ARRANGE then if press then v2.button("arrange") end
    elseif cc == CC.STEP_SEQ then
        if press then
            safety.safe("engineMode.RequestModeChange", function()
                mpc.engineMode.RequestModeChange(v2.seq.mode == 1 and "Main Mode" or "Step Sequencer")
            end)
        end
    elseif cc == CC.TEMPO then v2.tempo(value)
    elseif cc >= CC.ROW_FIRST and cc <= CC.ROW_LAST then
        if press then handleRow(cc - CC.ROW_FIRST) end
    elseif cc >= CC.STEP_FIRST and cc <= CC.STEP_LAST then
        if press then handleStep(cc - CC.STEP_FIRST) end
    elseif cc == CC.SET_MODE then
        setMode(value)
    elseif cc == CC.SET_QLINK_PAGE then
        -- Step Seq has pages 1 and 2 only; a refused page is answered with STATE.
        if v2.seq.mode == 1 and value > 1 then dirty.state = true; sent.state = nil else setQLinkPage(value) end
    elseif cc == CC.SET_PAD_BANK then
        setPadBank(value)
    elseif cc == CC.REFRESH then
        needFull = true
    end
end

local function handlePadDown(p)
    local c, r = coords.padToClip(mode, p)
    if not c then return end
    safety.safe("SelectClip", function() aperture().SelectClip(c, r) end)
    safety.safe("TriggerClip", function() aperture().TriggerClip(c, r) end)
    dirty.grid = true
end

local function knobTouch(k)
    if touched[k] then unlistenQLink(k) end
    touched[k] = { idx = qlinkIndex(qlinkPage, k) }
    listenQLink(k)
    sent.qlink[k] = nil -- touch always answers, even if the idle cache is current
    sendQLink(k)
end

local function knobRelease(k)
    unlistenQLink(k)
    touched[k] = nil
end

-- Channel voice from the Move. kind: "on" | "off" | "cc".
local function handleVoice(kind, channel, num, value)
    if CFG.PERF_LOG then v2.perfWhat = tostring(kind) .. ":" .. tostring(num) end
    if channel ~= CFG.CH or not active then return end
    if kind == "cc" then
        handleCC(num, value)
        return
    end
    local down = (kind == "on" and value > 0)
    if num >= CFG.NOTE_KNOB_TOUCH_FIRST and num < CFG.NOTE_KNOB_TOUCH_FIRST + CFG.QLINKS_PER_PAGE then
        local k = num - CFG.NOTE_KNOB_TOUCH_FIRST
        if down then knobTouch(k) else knobRelease(k) end
    elseif num >= 0 and num < CFG.NUM_PADS then
        if down then
            if mode == MODE.PADS and v2.seq.mode == 1 then
                heldPads[num] = false
                v2.seq.lane(coords.padToVirtual(padBank, num))
            else
                heldPads[num] = mode == MODE.PADS and coords.padToVirtual(padBank, num) or false
                handlePadDown(num)
            end
        else
            local vp = heldPads[num]
            heldPads[num] = nil
            if vp then
                -- UNPROVEN: only needed if a virtual pad's notes reach Lua.
                safety.safe("ReleaseVirtual", function() mpc.controlSurface.pads.ReleaseVirtual(vp) end)
            end
        end
    end
end

local function handleSysex(bytes)
    local cmd, data = parseSysex(bytes)
    if not cmd then return end
    if CFG.PERF_LOG then v2.perfWhat = string.format("sx%02x", cmd) end
    if cmd == MSG.IN_HELLO then
        if data[1] == nil or data[2] == nil then return end
        if data[1] ~= CFG.PROTOCOL_VERSION then
            if active then goPassive("version") else enqueue(enc.goodbye(), "goodbye", true) end
            return
        end
        goActive()
    elseif cmd == MSG.IN_PING then
        if active then
            lastHeard = nowMs()
            enqueue(enc.pong())
        else
            -- A Move that still thinks it is connected (MPC restarted, or we
            -- timed out): tell it, so it says HELLO again.
            local now = nowMs()
            if not lastPassiveGoodbye or now - lastPassiveGoodbye >= CFG.PASSIVE_GOODBYE_MS then
                lastPassiveGoodbye = now
                enqueue(enc.goodbye(), "goodbye", true)
            end
        end
    elseif cmd == MSG.IN_BYE then
        goPassive("bye")
    end
    -- anything else, including the reserved 0x60-0x6F: ignored (§5, §7)
end

local function handleTimer()
    tickCount = tickCount + 1
    -- Before anything that can return: Timing Correct must be put back even
    -- if the Move went away mid-quantise.
    if v2.quant then safety.safe("quantWork", v2.quantWork) end
    if active and nowMs() - lastHeard >= CFG.HEARTBEAT_TIMEOUT_MS then goPassive("timeout") end
    if not active then
        safety.safe("flush", flush, CFG.MAX_SYSEX_PER_TICK)
        return
    end
    local now = nowMs()
    v2.poll(now)
    if v2.seq.job then safety.safe("seq.work", v2.seq.work) end
    safety.safe("seq.lanePoll", v2.seq.lanePoll, now)
    if v2.seq.pendingTracks and v2.seq.pendingTracks ~= 0 then v2.seq.trackWork() end
    if needFull then
        needFull = false
        lastPoll.cacheKey = nil
        sync(nil, true)
    else
        local parts = { state = dirty.state, grid = dirty.grid, text = dirty.text }
        if now - lastPoll.state >= CFG.STATE_POLL_MS then parts.state, parts.text = true, true end
        if mode == MODE.PADS then
            -- All 32 colours every PAD_POLL_MS. They are property reads, which
            -- cost nothing (measured on the device); the one-pad round robin this replaces
            -- dated from when colours came from pads functions, and it held a
            -- pressed pad's bright colour, or one phase of a blink, for seconds
            -- (Ryan, 2026-11-14).
            if v2.seq.mode ~= 1 and lastPoll.cache and lastPoll.cacheKey == padBank and now - lastPoll.pads >= CFG.PAD_POLL_MS then
                lastPoll.pads = now
                safety.safe("poll.pads", function()
                    v2.seq.dimScan(now)
                    for p = 0, CFG.NUM_PADS - 1 do
                        local vp = coords.padToVirtual(padBank, p)
                        local new = v2.seq.padLed(vp, now)
                        if new[4] == ANIM.SOLID and new ~= COLOUR.OFF and v2.seq.mode == 0 then v2.seq.pads[vp] = new end
                        if not colourFns.sameLed(lastPoll.cache[p], new) then
                            lastPoll.cache[p] = new
                            parts.grid = true
                        end
                    end
                end)
            end
        elseif now - lastPoll.grid >= CFG.GRID_POLL_MS then parts.grid = true end
        if parts.state then lastPoll.state = now end
        if parts.grid then lastPoll.grid = now end
        dirty = { state = false, grid = false, text = false }
        -- No step lights while Pad Sel is on: they would be its yellow.
        parts.steps = v2.seq.mode == 1 and not v2.seq.job and now >= (v2.seq.quietUntil or -math.huge)
        if parts.steps and now - (v2.seq.bankAt or -math.huge) >= 1000 then v2.seq.readBank() end
        if parts.state or parts.grid or parts.text or parts.steps then sync(parts) end
    end
    if now - lastPoll.qlink >= CFG.QLINK_POLL_MS then
        lastPoll.qlink = now
        for k in pairs(touched) do safety.safe("poll.qlink", sendQLink, k, true) end
    end
    if now - lastPoll.qlinkIdle >= CFG.QLINK_IDLE_POLL_MS then
        -- Preserve the 125 ms cadence on a 20 ms timer, without catch-up bursts.
        lastPoll.qlinkIdle = math.max(lastPoll.qlinkIdle + CFG.QLINK_IDLE_POLL_MS,
            now - CFG.QLINK_IDLE_POLL_MS + CFG.TICK_MS)
        for _ = 1, CFG.QLINKS_PER_PAGE do
            lastPoll.qlinkRR = (lastPoll.qlinkRR + 1) % CFG.QLINKS_PER_PAGE
            local k = lastPoll.qlinkRR
            if not touched[k] then
                safety.safe("poll.qlinkIdle", sendQLink, k, true)
                break
            end
        end
    end
    safety.safe("flush", flush, CFG.MAX_SYSEX_PER_TICK)
end

-----------------------------------------------------------------------------
-- Entry points called by MPC. guard() keeps every error inside the script.
-----------------------------------------------------------------------------

-- Timing of every entry point, for the audio-dropout question (Ryan,
-- 2026-11-15): how long each handler holds the MPC's script thread, and how
-- late the 20 ms timer runs. With CFG.PERF_LOG on, one journal line every
-- PERF_LOG_MS: per handler the call count, total and worst time, and the
-- labels of calls over PERF_SLOW_MS; for the timer the worst gap between
-- ticks and how many gaps passed 30 and 50 ms. timer.Now() is the clock, so
-- the figures are only as fine as it is (its resolution is printed first).
function v2.perfNote(label, t0, t1)
    local P = v2.perf
    if not P then P = { since = t0, by = {}, gapMax = 0, gap30 = 0, gap50 = 0, slow = {} }; v2.perf = P end
    local e = P.by[label]
    if not e then e = { n = 0, sum = 0, max = 0 }; P.by[label] = e end
    local d = t1 - t0
    e.n, e.sum = e.n + 1, e.sum + d
    if d > e.max then e.max = d end
    if d >= CFG.PERF_SLOW_MS and #P.slow < 12 then P.slow[#P.slow + 1] = string.format("%s:%.1f", v2.perfWhat or label, d) end
    if label == "HandleTimer" then
        if P.lastTick then
            local gap = t0 - P.lastTick
            if gap > P.gapMax then P.gapMax = gap end
            if gap > 30 then P.gap30 = P.gap30 + 1 end
            if gap > 50 then P.gap50 = P.gap50 + 1 end
        end
        P.lastTick = t0
        if t1 - P.since >= CFG.PERF_LOG_MS then
            local parts = {}
            for name, x in pairs(P.by) do
                parts[#parts + 1] = string.format("%s n=%d sum=%.1f max=%.1f", name:gsub("HandleMIDI", ""):gsub("Handle", ""), x.n, x.sum, x.max)
            end
            table.sort(parts)
            print(string.format("MOVEPADS perf %.0fs active=%s mode=%d mpc=%d gapMax=%.1f gap>30=%d gap>50=%d | %s | slow: %s",
                (t1 - P.since) / 1000, tostring(active), mode, v2.seq.mode, P.gapMax, P.gap30, P.gap50,
                table.concat(parts, " ; "), table.concat(P.slow, " ")))
            v2.perf = { since = t1, by = {}, gapMax = 0, gap30 = 0, gap50 = 0, slow = {}, lastTick = t0 }
        end
    end
end

function safety.guard(label, fn, ...)
    if not CFG.PERF_LOG then
        local ok, err = pcall(fn, ...)
        if not ok then safety.noteError(label, err) end
        return
    end
    local t0 = nowMs()
    v2.perfWhat = nil
    local ok, err = pcall(fn, ...)
    if not ok then safety.noteError(label, err) end
    v2.perfNote(label, t0, nowMs())
end

function abletonMoveSchwung.OnLoad()
    safety.guard("OnLoad", function()
        active = false
        mode, qlinkPage, padBank = MODE.SESSION, 0, 0
        lastPassiveGoodbye = nil
        resetSession()
        -- Passive: SysEx only, to hear HELLO. Nothing on any channel is mapped.
        safety.safe("SetHandleSysex", function() abletonMoveSchwung.mappings.script.SetHandleSysex(true) end)
        -- A Move left connected from before an MPC restart re-says HELLO on this.
        enqueue(enc.goodbye(), "goodbye", true)
        safety.safe("timer.Start", function() abletonMoveSchwung.timer.Start(CFG.TICK_MS) end)
    end)
end

function abletonMoveSchwung.OnUnload()
    safety.guard("OnUnload", function()
        if active then goPassive("unload") else v2.releaseRepeat() end
        clearQueue()
        sendNow(enc.goodbye()) -- no future timer tick after unload
        safety.safe("timer.Stop", function() abletonMoveSchwung.timer.Stop() end)
        safety.safe("SetHandleSysex", function() abletonMoveSchwung.mappings.script.SetHandleSysex(false) end)
    end)
end

function abletonMoveSchwung.HandleMIDINoteOn(channel, note, velocity)
    safety.guard("HandleMIDINoteOn", handleVoice, "on", channel, note, velocity)
end

function abletonMoveSchwung.HandleMIDINoteOff(channel, note, velocity)
    safety.guard("HandleMIDINoteOff", handleVoice, "off", channel, note, velocity)
end

function abletonMoveSchwung.HandleMIDICC(channel, cc, value)
    safety.guard("HandleMIDICC", handleVoice, "cc", channel, cc, value)
end

function abletonMoveSchwung.HandleMIDISysex(bytes)
    safety.guard("HandleMIDISysex", handleSysex, bytes)
end

function abletonMoveSchwung.HandleTimer()
    safety.guard("HandleTimer", handleTimer)
end

-- For the test suite (mpc/test/). Harmless on the device.
pcall(function()
    abletonMoveSchwung._internal = {
        cfg = CFG,
        enc = enc,
        parseSysex = parseSysex,
        padToClip = coords.padToClip,
        padToVirtual = coords.padToVirtual,
        clipLed = colourFns.clipLed,
        groupLed = colourFns.groupLed,
        hexTo7 = colourFns.hexTo7,
        argbTo7 = colourFns.argbTo7,
        enqueue = enqueue,
        queueLength = function() return #queue end,
        status = function()
            return { active = active, mode = mode, qlinkPage = qlinkPage, padBank = padBank,
                shift = shiftHeld, needFull = needFull, mpcMode = v2.seq.mode }
        end,
        errors = function() return errors end,
        lastError = function() return lastError end,
        tunables = { TICK_MS = CFG.TICK_MS, MAX_SYSEX_PER_TICK = CFG.MAX_SYSEX_PER_TICK,
            QUEUE_LIMIT = CFG.QUEUE_LIMIT, HEARTBEAT_TIMEOUT_MS = CFG.HEARTBEAT_TIMEOUT_MS },
    }
end)
