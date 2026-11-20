-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Ryan Gilmore
-- Test suite for abletonMoveSchwung.lua against a mock MPC API.
-- Run from the repo root:  lua test/run.lua   (non-zero exit on failure)

local here = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local mock = require("mock")
local json = require("json")

local SCRIPT = here .. "/../abletonMoveSchwung/abletonMoveSchwung.lua"
local VECTORS = here .. "/vectors.json"
local vectors = json.readFile(VECTORS)

-----------------------------------------------------------------------------
-- Tiny harness
-----------------------------------------------------------------------------

local passed, failed, checks = 0, 0, 0
local failures = {}

local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        io.write("  ok    ", name, "\n")
    else
        failed = failed + 1
        failures[#failures + 1] = name
        io.write("  FAIL  ", name, "\n        ", tostring(err):gsub("\n", "\n        "), "\n")
    end
end

local function hex(s)
    if type(s) == "table" then
        local t = {}
        for i, b in ipairs(s) do t[i] = string.format("%02X", b) end
        return table.concat(t, " ")
    end
    return (tostring(s):gsub(".", function(c) return string.format("%02X ", c:byte()) end))
end

local function eq(a, b, msg)
    checks = checks + 1
    if a ~= b then
        error(string.format("%s: expected %s, got %s", msg or "eq", tostring(b), tostring(a)), 2)
    end
end

local function ok(v, msg)
    checks = checks + 1
    if not v then error(msg or "expected true", 2) end
end

local function bytesEq(a, b, msg)
    checks = checks + 1
    if a ~= b then
        error(string.format("%s:\n  expected %s\n  got      %s", msg or "bytes", hex(b), hex(a)), 2)
    end
end

-- wire (with F0/F7) -> the body MPC hands the script / takes from it
local function body(wire)
    local t = {}
    for i = 2, #wire - 1 do t[#t + 1] = wire[i] end
    return string.char(table.unpack(t))
end

local function vector(section, name)
    for _, v in ipairs(vectors[section]) do
        if v.name == name then return v end
    end
    error("no vector " .. name)
end

-----------------------------------------------------------------------------
-- Loading the script into a fresh mock
-----------------------------------------------------------------------------

local function load(opts)
    local w = mock.new(opts)
    _G.mpc = w.mpc
    _G.abletonMoveSchwung = w.dev
    -- The MPC's Lua has no os or io (bench 2026-11-13, 2026-11-14: the v3
    -- probe died on os.clock). Load with both hidden; writes still reach _G.
    local hidden = { os = true, io = true }
    local env = setmetatable({}, {
        __index = function(_, k) if hidden[k] then return nil end return _G[k] end,
        __newindex = function(_, k, v) _G[k] = v end,
    })
    local chunk = assert(loadfile(SCRIPT, "t", env))
    chunk()
    w.I = w.dev._internal
    -- The lane poll (pads.LastHitPad in Step Seq) is off unless a test asks for it.
    w.I.cfg.LANE_POLL = opts and opts.lanePoll and true or false
    w.I.cfg.PERF_LOG = opts and opts.perfLog and true or false -- device diagnostics, off in tests
    w.I.cfg.QUANT_WAIT_TICKS = 1 -- the quantise tests are written for one tick each way
    w.dev.OnLoad()
    return w
end

local HELLO = { 0xF0, 0x7D, 0x4D, 0x50, 0x01, 0x04, 0x00, 0xF7 }
local PING = { 0xF0, 0x7D, 0x4D, 0x50, 0x02, 0xF7 }
local BYE = { 0xF0, 0x7D, 0x4D, 0x50, 0x03, 0xF7 }

local function cc(n, v) return { 0xBF, n, v } end
local function press(n, w) w.wire(cc(n, 127)); w.wire(cc(n, 0)) end

local function noErrors(w)
    local errs = w.I.errors()
    local list = {}
    for k, n in pairs(errs) do list[#list + 1] = k .. " x" .. n end
    table.sort(list)
    eq(#list, 0, "script errors (" .. table.concat(list, ", ") .. "; last: " .. tostring(w.I.lastError()) .. ")")
end

-- Connect, drain the dump, return the dump messages.
local function connect(w)
    w.takeSysex()
    w.wire(HELLO)
    w.tick(10)
    return w.takeSysex()
end

local function cmdOf(msg) return msg:byte(4) end

local function ofCmd(msgs, cmd)
    local out = {}
    for _, m in ipairs(msgs) do if cmdOf(m) == cmd then out[#out + 1] = m end end
    return out
end

-- Decode PADS/STEPS messages into { [index] = {r,g,b,anim} }.
local function decodeRuns(msgs, cmd)
    local out = {}
    for _, m in ipairs(ofCmd(msgs, cmd)) do
        local first, n = m:byte(5), m:byte(6)
        for i = 0, n - 1 do
            local o = 7 + i * 4
            out[first + i] = { m:byte(o), m:byte(o + 1), m:byte(o + 2), m:byte(o + 3) }
        end
    end
    return out
end

local function decodeState(m)
    local t = { m:byte(5, 13) }
    return { mode = t[1], qlinkPage = t[2], padBank = t[3], transport = t[4],
        originX = t[5], originY = t[6], globalCols = t[7], globalRows = t[8], canMove = t[9], mpcMode = m:byte(19) }
end

local function lastOf(msgs, cmd)
    local l = ofCmd(msgs, cmd)
    return l[#l]
end

local function ledEq(led, r, g, b, anim, msg)
    ok(led, (msg or "led") .. ": missing")
    eq(led[1], r, (msg or "led") .. " r"); eq(led[2], g, (msg or "led") .. " g")
    eq(led[3], b, (msg or "led") .. " b"); eq(led[4], anim, (msg or "led") .. " anim")
end

local function scriptMappedCount(w)
    local n = 0
    for k in pairs(w.mapped) do n = n + 1 end
    return n
end

-----------------------------------------------------------------------------
-- Tests
-----------------------------------------------------------------------------

print("abletonMoveSchwung.lua tests")

test("main chunk locals stay below 150 (Lua's hard limit is 200)", function()
    assert(loadfile(SCRIPT)) -- report syntax/compiler errors even without luac
    local quoted = "'" .. SCRIPT:gsub("'", "'\\''") .. "'"
    local pipe = assert(io.popen("luac -p -l -l " .. quoted .. " 2>/dev/null", "r"))
    local listing = pipe:read("*a")
    local success = pipe:close()
    -- Only the first header: nested functions have their own local budgets.
    local count = success and tonumber(listing:match("^%s*main[^\n]*\n[^\n]-, (%d+) locals"))
    if not count then
        -- Conservative fallback when luac is unavailable: count declarations
        -- in ALL scopes, including for-loop variables. This can overcount and
        -- require installing luac, but cannot hide excess main-chunk locals.
        -- Tokenize comments/strings first (including Lua long brackets), so
        -- words in device findings and string literals are never declarations.
        local file = assert(io.open(SCRIPT, "r"))
        local source = file:read("*a")
        file:close()
        local tokens, i = {}, 1
        while i <= #source do
            local rest = source:sub(i)
            local comment = rest:sub(1, 2) == "--"
            local start = comment and 3 or 1
            local equals = rest:sub(start):match("^%[(=*)%[")
            if equals then
                local _, finish = source:find("]" .. equals .. "]", i + start + #equals + 1, true)
                i = assert(finish, "unterminated long string/comment") + 1
            elseif comment then
                i = source:find("\n", i, true) or (#source + 1)
            elseif rest:sub(1, 1) == '"' or rest:sub(1, 1) == "'" then
                local quote = rest:sub(1, 1)
                i = i + 1
                while source:sub(i, i) ~= quote do
                    i = i + (source:sub(i, i) == "\\" and 2 or 1)
                    assert(i <= #source, "unterminated quoted string")
                end
                i = i + 1
            else
                local word = rest:match("^[%a_][%w_]*")
                local token = word or rest:sub(1, 1)
                if not token:match("^%s$") then tokens[#tokens + 1] = token end
                i = i + #token
            end
        end
        count = 0
        for n, token in ipairs(tokens) do
            if token == "local" or token == "for" then
                count = count + 1
                local nextName = n + 2
                while tokens[nextName] == "," do
                    count = count + 1
                    nextName = nextName + 2
                end
            end
        end
        io.write("  luac unavailable: conservative all-scope declaration count\n")
    end
    ok(count <= 150, string.format("main chunk locals: %d exceeds threshold 150; Lua's limit is 200", count))
    io.write(string.format("  main chunk locals: %d (threshold 150; Lua's limit is 200)\n", count))
end)

test("script loads under plain Lua and defines every handler", function()
    local w = load()
    for _, h in ipairs({ "OnLoad", "OnUnload", "HandleMIDINoteOn", "HandleMIDINoteOff", "HandleMIDICC",
        "HandleMIDISysex", "HandleTimer" }) do
        eq(type(w.dev[h]), "function", h)
    end
    noErrors(w)
end)

test("passive at OnLoad: only SysEx handling, nothing mapped, paced timer", function()
    local w = load()
    eq(w.handleSysex, true, "SetHandleSysex(true)")
    eq(scriptMappedCount(w), 0, "mappings at OnLoad")
    eq(w.timerRunning, true, "passive pacing timer running")
    eq(w.shown, false, "aperture shown")
    -- channel 16 and channel 1 both pass through untouched
    eq(w.wire({ 0x9F, 0, 100 }), "passthrough", "ch16 pad while passive")
    eq(w.wire(cc(0x02, 127)), "passthrough", "ch16 CC while passive")
    eq(w.wire({ 0x90, 60, 100 }), "passthrough", "ch1 note")
    -- OnLoad says GOODBYE once, so a Move left connected re-says HELLO
    eq(#w.takeSysex(), 0, "nothing sent immediately at OnLoad")
    w.tick()
    local s = w.takeSysex()
    eq(#s, 1, "sysex on first passive tick")
    bytesEq(s[1], body(vector("mpc_to_move", "goodbye").wire), "GOODBYE at OnLoad")
    noErrors(w)
end)

test("HELLO -> WELCOME then full dump: STATE, PADS x4, ROWS, STEPS x2, TEXT", function()
    local w = load()
    local msgs = connect(w)
    bytesEq(msgs[1], body(vector("mpc_to_move", "welcome v4, clip workflow available").wire), "WELCOME first")
    eq(cmdOf(msgs[2]), 0x42, "STATE second")
    eq(#ofCmd(msgs, 0x43), 4, "PADS messages")
    for i, m in ipairs(ofCmd(msgs, 0x43)) do
        eq(m:byte(5), (i - 1) * 8, "PADS first"); eq(m:byte(6), 8, "PADS n")
    end
    eq(#ofCmd(msgs, 0x44), 1, "ROWS messages")
    eq(#ofCmd(msgs, 0x45), 2, "STEPS messages")
    ok(#ofCmd(msgs, 0x46) >= 1, "TEXT")
    local t0 = ofCmd(msgs, 0x46)[1]
    eq(t0:byte(5), 0, "TEXT slot 0")
    eq(t0:sub(6), "1: Drum 001", "TEXT slot 0 content")
    eq(w.timerRunning, true, "timer started")
    eq(w.timerInterval, 20, "tick")
    eq(w.shown, true, "aperture shown")
    eq(w.label, "Move", "label")
    eq(w.followsTUI, false, "SetFollowsTUI(false)")
    for _, m in ipairs(msgs) do ok(#m + 2 <= 48, "message over 48 bytes: " .. hex(m)) end
    noErrors(w)
end)

test("WELCOME flags clear without clip workflow; defaults to Pads mode", function()
    local w = load({ noClipWorkflow = true })
    local msgs = connect(w)
    bytesEq(msgs[1], string.char(0x7D, 0x4D, 0x50, 0x41, 4, 0), "WELCOME no clip workflow")
    eq(w.I.status().mode, 2, "mode")
    noErrors(w)
end)

test("HELLO v1/v2/v3 -> GOODBYE and passive, including an active session", function()
    for _, ver in ipairs({1, 2, 3}) do
        for _, activeFirst in ipairs({false, true}) do
            local w = load()
            if activeFirst then connect(w) end
            w.takeSysex()
            w.wire(vectors.version_mismatch["hello_v" .. ver]); w.tick(5)
            local messages = w.takeSysex()
            eq(#messages, 1, "one reply")
            bytesEq(messages[1], body(vectors.version_mismatch.goodbye), "GOODBYE")
            eq(w.I.status().active, false, "passive")
            eq(scriptMappedCount(w), 0, "unmapped")
        end
    end
end)

test("active mappings: channel 16 only, commands + knob touch + Q-Links + pads", function()
    local w = load()
    connect(w)
    for k in pairs(w.mapped) do
        ok(k:match("%.15%.%d+$"), "mapping not on channel 16: " .. k)
    end
    for _, c in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0x10, 0x13, 0x20, 0x2F, 0x30, 0x31, 0x32, 0x33 }) do
        ok(w.mapped["script.cc.15." .. c], "command CC " .. c)
    end
    ok(not w.mapped["script.cc.15.79"], "master knob 0x4F reserved, unmapped")
    for k = 0, 7 do
        ok(w.mapped["script.note.15." .. (0x40 + k)], "knob touch " .. k)
        eq(w.mapped["qlink.15." .. (0x47 + k)], k, "Q-Link knob " .. k)
    end
    for p = 0, 31 do ok(w.mapped["script.note.15." .. p], "pad " .. p) end
    eq(w.wire({ 0x90, 0, 100 }), "passthrough", "ch1 note 0 untouched")
    eq(w.wire({ 0x9E, 0, 100 }), "passthrough", "ch15 note 0 untouched")
    eq(w.wire({ 0xB0, 0x02, 127 }), "passthrough", "ch1 CC untouched")
    noErrors(w)
end)

test("heartbeat: PING keeps it alive; 3.5 s silence -> unmapped, hidden, GOODBYE", function()
    local w = load()
    connect(w)
    for _ = 1, 10 do w.tick(50); w.wire(PING) end -- 10 s of 1 s pings
    eq(w.I.status().active, true, "still active with pings")
    w.takeSysex()
    w.tick(170) -- 3.4 s
    eq(w.I.status().active, true, "active at 3.4 s")
    w.tick(10)  -- 3.6 s
    eq(w.I.status().active, false, "passive after 3.5 s")
    eq(scriptMappedCount(w), 0, "everything unmapped")
    eq(w.shown, false, "aperture hidden")
    eq(w.timerRunning, true, "passive pacing timer running")
    local s = w.takeSysex()
    eq(cmdOf(s[#s]), 0x48, "GOODBYE sent")
    eq(w.wire({ 0x9F, 0, 100 }), "passthrough", "pad passes through again")
    -- listeners all released
    eq(mock.listenerCount(w.aperture.clipProperties[0][0].State), 0, "clip listeners")
    eq(mock.listenerCount(w.mpc.sequencer.Playing), 0, "sequencer listeners")
    noErrors(w)
end)

test("BYE -> passive at once; PING while passive -> GOODBYE (rate limited); HELLO again works", function()
    local w = load()
    connect(w)
    w.wire(BYE)
    eq(w.I.status().active, false, "passive")
    eq(scriptMappedCount(w), 0, "unmapped")
    w.takeSysex()
    w.wire(PING); w.wire(PING)
    eq(#w.takeSysex(), 0, "passive replies are paced")
    w.tick()
    local s = w.takeSysex()
    eq(#s, 1, "one GOODBYE for two quick PINGs"); eq(cmdOf(s[1]), 0x48, "GOODBYE")
    local msgs = connect(w)
    eq(cmdOf(msgs[1]), 0x41, "WELCOME again")
    eq(w.I.status().active, true, "active again")
    noErrors(w)
end)

test("OnUnload while active: GOODBYE, all unmapped, sysex released", function()
    local w = load()
    connect(w)
    w.dev.OnUnload()
    eq(scriptMappedCount(w), 0, "unmapped")
    eq(w.handleSysex, false, "SetHandleSysex(false)")
    local s = w.takeSysex()
    eq(cmdOf(s[#s]), 0x48, "GOODBYE")
    noErrors(w)
end)

test("coordinates: every vectors.json case", function()
    local w = load()
    for _, c in ipairs(vectors.coordinates) do
        eq(c.moveRow * 8 + c.moveCol, c.pad, "pad numbering")
        if c.mode == 0 or c.mode == 1 then
            local col, row = w.I.padToClip(c.mode, c.pad)
            eq(col, c.clipColumn, "mode " .. c.mode .. " pad " .. c.pad .. " column")
            eq(row, c.clipRow, "mode " .. c.mode .. " pad " .. c.pad .. " row")
        else
            eq(w.I.padToVirtual(c.padBank, c.pad), c.virtualPad, "bank " .. c.padBank .. " pad " .. c.pad)
        end
    end
end)

test("Session: pad down -> SelectClip + TriggerClip at the vector coordinates", function()
    local w = load()
    connect(w)
    for _, c in ipairs(vectors.coordinates) do
        if c.mode == 0 then
            w.clearCalls()
            eq(w.wire({ 0x9F, c.pad, 100 }), "script", "routed to script")
            local calls = {}
            for _, x in ipairs(w.calls) do
                if x.name == "SelectClip" or x.name == "TriggerClip" then calls[#calls + 1] = x end
            end
            eq(#calls, 2, "two calls")
            eq(calls[1].name, "SelectClip", "select first")
            eq(calls[2].name, "TriggerClip", "then trigger")
            eq(calls[2].args[1], c.clipColumn, "column"); eq(calls[2].args[2], c.clipRow, "row")
            w.clearCalls()
            w.wire({ 0x8F, c.pad, 0 })
            eq(#w.callsNamed("TriggerClip"), 0, "pad up does nothing")
        end
    end
    noErrors(w)
end)

test("Rows: aperture 4x8, pad down at the vector coordinates", function()
    local w = load()
    connect(w)
    w.wire(cc(0x30, 1))
    eq(w.I.status().mode, 1, "mode Rows")
    eq(w.cols, 4, "columns"); eq(w.rows, 8, "rows")
    for _, c in ipairs(vectors.coordinates) do
        if c.mode == 1 then
            w.clearCalls()
            w.wire({ 0x9F, c.pad, 100 })
            local t = w.callsNamed("TriggerClip")[1]
            local s = w.callsNamed("SelectClip")[1]
            eq(t[1], c.clipColumn, "column"); eq(t[2], c.clipRow, "row")
            eq(s[1], c.clipColumn, "select column"); eq(s[2], c.clipRow, "select row")
        end
    end
    noErrors(w)
end)

test("Pads: native AddNoteToVirtualPad at the vector coordinates, script not in the path", function()
    local w = load()
    connect(w)
    for _, c in ipairs(vectors.coordinates) do
        if c.mode == 2 then
            w.wire(cc(0x30, 2))
            w.wire(cc(0x32, c.padBank))
            eq(w.I.status().padBank, c.padBank, "bank")
            eq(w.mapped["vpad.15." .. c.pad], c.virtualPad, "virtual pad for pad " .. c.pad)
            ok(not w.mapped["script.note.15." .. c.pad], "pad not also mapped to script")
            w.clearCalls()
            eq(w.wire({ 0x9F, c.pad, 100 }), "vpad", "routed natively")
            eq(#w.callsNamed("TriggerClip"), 0, "no clip trigger")
        end
    end
    -- all 32 pads mapped, within 0..127
    for p = 0, 31 do ok(w.mapped["vpad.15." .. p], "pad " .. p .. " mapped") end
    noErrors(w)
end)

test("Pads: NAV left/right shifts the bank pair, clamped 0..6, remaps", function()
    local w = load()
    connect(w)
    w.wire(cc(0x30, 2))
    press(0x02, w)
    eq(w.I.status().padBank, 1, "right")
    eq(w.mapped["vpad.15.0"], 16, "pad 0 -> B1")
    for _ = 1, 10 do press(0x02, w) end
    eq(w.I.status().padBank, 6, "clamped at 6")
    eq(w.mapped["vpad.15.7"], 7 * 16 + 3, "pad 7 -> H4")
    for _ = 1, 10 do press(0x01, w) end
    eq(w.I.status().padBank, 0, "clamped at 0")
    w.wire(cc(0x32, 9))
    eq(w.I.status().padBank, 6, "SET_PAD_BANK clamped")
    noErrors(w)
end)

test("Notes: no pad bindings at all; knobs and commands still mapped", function()
    local w = load()
    connect(w)
    mock.set(w.currentTrack.Type, "Plugin"); w.wire(cc(0x30, 3))
    for p = 0, 31 do
        ok(not w.mapped["script.note.15." .. p] and not w.mapped["vpad.15." .. p], "pad " .. p .. " unbound")
    end
    eq(w.mapped["qlink.15.71"], 0, "knob 0")
    ok(w.mapped["script.cc.15.6"], "PLAY")
    eq(w.wire({ 0x90, 60, 100 }), "passthrough", "ordinary notes pass through")
    w.clearCalls()
    press(0x01, w); press(0x03, w)
    eq(#w.callsNamed("MoveLeft") + #w.callsNamed("MoveUp"), 0, "NAV ignored in Notes")
    noErrors(w)
end)

test("Session NAV: by one; with SHIFT by a page (BankX)", function()
    local w = load()
    connect(w)
    press(0x02, w)
    eq(w.ox, 1, "right by one")
    press(0x04, w)
    eq(w.oy, 1, "down by one")
    w.wire(cc(0x05, 127))
    eq(w.I.status().shift, true, "shift held")
    press(0x02, w)
    eq(w.ox, 8, "shift-right: +8 (clamped to 16-8)")
    eq(w.callsNamed("MoveRight")[2][1], 8, "MoveRight(8) used")
    press(0x04, w)
    eq(w.oy, 5, "shift-down by 4")
    w.wire(cc(0x05, 0))
    press(0x01, w)
    eq(w.ox, 7, "left by one")
    press(0x03, w)
    eq(w.oy, 4, "up by one")
    -- STATE follows the move
    w.tick(10)
    local st = decodeState(lastOf(w.takeSysex(), 0x42))
    eq(st.originX, 7, "STATE originX"); eq(st.originY, 4, "STATE originY")
    eq(st.globalCols, 16, "globalCols"); eq(st.globalRows, 32, "globalRows")
    eq(st.canMove, 1 | 2 | 4 | 8, "canMove")
    noErrors(w)
end)

test("Rows NAV: left/right = scenes, up/down = tracks; SHIFT by a page", function()
    local w = load()
    connect(w)
    w.wire(cc(0x30, 1))
    press(0x02, w); eq(w.oy, 1, "right -> later scene")
    press(0x04, w); eq(w.ox, 1, "down -> next track")
    press(0x01, w); eq(w.oy, 0, "left -> earlier scene")
    press(0x03, w); eq(w.ox, 0, "up -> previous track")
    w.wire(cc(0x05, 127))
    press(0x02, w); eq(w.oy, 8, "shift-right: a page of 8 scenes")
    press(0x04, w); eq(w.ox, 4, "shift-down: a page of 4 tracks")
    noErrors(w)
end)

test("NAV page falls back to MoveX(size) if BankX fails", function()
    local w = load()
    w.aperture.BankRight = function() error("no such function") end
    connect(w)
    w.wire(cc(0x05, 127))
    press(0x02, w)
    eq(w.ox, 8, "moved by width via MoveRight")
    eq(w.callsNamed("MoveRight")[1][1], 8, "MoveRight(8)")
    eq(w.I.status().active, true, "still active")
end)

test("clip ROW and paired STEP functions in both layouts", function()
    for mode = 0, 1 do
        local w = load(); connect(w); w.wire(cc(0x30, mode)); w.clearCalls()
        press(0x10, w); press(0x13, w)
        local rows = w.callsNamed(mode == 0 and "TriggerRow" or "SelectTrack")
        eq(#rows, 2, "row actions"); eq(rows[1][1], 0); eq(rows[2][1], 3)
        w.clearCalls()
        if mode == 0 then
            for i = 0, 7 do
                press(0x20 + i * 2, w); press(0x21 + i * 2, w)
                eq(w.callsNamed("SelectTrack")[i + 1][1], i, "odd selects")
                eq(w.callsNamed("StopClipsOnTrack")[i + 1][1], i, "even stops")
            end
        else
            -- Transposed (Ryan, 2026-11-19): odd steps launch the scene above, even do nothing
            for i = 0, 6 do press(0x20 + i * 2, w); press(0x21 + i * 2, w) end
            press(0x2E, w)
            local trig = w.callsNamed("TriggerRow")
            eq(#trig, 8, "eight scenes"); for i = 0, 7 do eq(trig[i + 1][1], i, "odd step -> scene in its column") end
            eq(#w.callsNamed("SelectTrack"), 0); eq(#w.callsNamed("StopClipsOnTrack"), 0, "even steps do nothing")
        end
        w.clearCalls(); press(0x2F, w)
        eq(#w.callsNamed(mode == 0 and "StopClipsOnTrack" or "StopAllClips"), 1)
        w.wire(cc(5,127)); w.clearCalls(); press(0x11,w)
        eq(#w.callsNamed("StopClipsOnTrack"), mode, "only Transposed shift row stops")
        noErrors(w)
    end
end)

test("Pads mode: ROW and STEP do nothing", function()
    local w = load()
    connect(w)
    w.wire(cc(0x30, 2)); w.clearCalls()
    press(0x10, w); press(0x20, w)
    eq(#w.calls, 0, "no calls")
end)

test("transport, undo, stop all, track prev/next (with and without SHIFT)", function()
    local w = load()
    connect(w)
    w.clearCalls()
    press(0x06, w); press(0x07, w); press(0x08, w); press(0x09, w); press(0x0B, w); w.tick(2); press(0x0A, w); w.tick(2)
    eq(#w.callsNamed("TogglePlayStart"), 1, "PLAY")
    eq(#w.callsNamed("Overdub"), 1, "REC")
    eq(#w.callsNamed("Undo"), 1, "UNDO")
    eq(#w.callsNamed("StopAllClips"), 1, "STOP_ALL")
    eq(#w.callsNamed("currentTrack.Next"), 1, "TRACK_NEXT")
    eq(#w.callsNamed("currentTrack.Previous"), 1, "TRACK_PREV")
    w.wire(cc(0x05, 127)); w.clearCalls()
    press(0x06, w); press(0x07, w); press(0x08, w)
    eq(#w.callsNamed("TogglePlay"), 1, "SHIFT+PLAY")
    eq(#w.callsNamed("Record"), 1, "SHIFT+REC")
    eq(#w.callsNamed("Redo"), 1, "SHIFT+UNDO")
    eq(#w.callsNamed("TogglePlayStart"), 0, "not TogglePlayStart")
    w.wire(cc(0x05, 0)); w.clearCalls()
    press(0x0C, w)
    eq(#w.callsNamed("shift.Hold"), 1, "CAPTURE holds Shift")
    eq(#w.callsNamed("record.Press"), 1, "CAPTURE presses Rec")
    eq(#w.callsNamed("shift.Release"), 1, "CAPTURE releases Shift")
    eq(#w.callsNamed("Record"), 0, "CAPTURE is not Record()")
    noErrors(w)
end)

test("TEXT slot 0 follows the current track", function()
    local w = load()
    connect(w)
    press(0x0B, w)
    w.tick(10)
    local t = lastOf(w.takeSysex(), 0x46)
    ok(t, "TEXT sent")
    eq(t:byte(5), 0, "slot 0"); eq(t:sub(6), "2: Track 2", "content")
    noErrors(w)
end)

test("STATE transport bits follow the sequencer", function()
    local w = load()
    connect(w)
    mock.set(w.mpc.sequencer.Playing, true)
    mock.set(w.mpc.sequencer.RecordState, 2)
    w.tick(3)
    local st = decodeState(lastOf(w.takeSysex(), 0x42))
    eq(st.transport, 3, "playing + recording")
    mock.set(w.mpc.sequencer.RecordState, 0)
    mock.set(w.mpc.sequencer.OverdubState, 2)
    w.tick(3)
    eq(decodeState(lastOf(w.takeSysex(), 0x42)).transport, 5, "playing + overdubbing")
    mock.set(w.mpc.sequencer.Playing, false)
    mock.set(w.mpc.sequencer.OverdubState, 1) -- armed, transport stopped: still shown
    w.tick(10)
    eq(decodeState(lastOf(w.takeSysex(), 0x42)).transport, 4, "armed overdub shows while stopped")
    noErrors(w)
end)

test("Q-Links: touch -> QLINK; value change resends; release stops listeners", function()
    local w = load()
    connect(w)
    mock.set(w.qlinks[2].TargetName, "Cutoff")
    mock.set(w.qlinks[2].ValueString, "1.2 kHz")
    w.wire({ 0x9F, 0x42, 127 })
    w.tick(2)
    local q = w.takeSysex()
    bytesEq(lastOf(q, 0x47), body(vector("mpc_to_move", "qlink knob 2 'Cutoff' = '1.2 kHz'").wire), "QLINK on touch")
    mock.set(w.qlinks[2].ValueString, "1.5 kHz")
    w.tick(2)
    local m = lastOf(w.takeSysex(), 0x47)
    ok(m, "QLINK resent on change")
    ok(m:find("1.5 kHz", 1, true), "new value")
    -- a burst of changes coalesces into one pending message per knob
    for i = 1, 30 do mock.set(w.qlinks[2].ValueString, tostring(i)) end
    ok(w.I.queueLength() <= 2, "coalesced, queue " .. w.I.queueLength())
    w.wire({ 0x8F, 0x42, 0 })
    w.tick(5); w.takeSysex()
    eq(mock.listenerCount(w.qlinks[2].ValueString), 0, "listener released")
    mock.set(w.qlinks[2].ValueString, "9")
    w.tick(51)
    local idle = ofCmd(w.takeSysex(), 0x47)
    eq(#idle, 1, "idle sweep updates after release")
    ok(idle[1]:find("9", 1, true), "idle value")
    noErrors(w)
end)

test("Q-Links: unprompted page reports, refresh, track restart and idle dedup", function()
    local w = load()
    local function pageReport(msgs, page)
        local qs = ofCmd(msgs, 0x47)
        eq(#qs, 8, "eight assignments")
        for k = 0, 7 do
            bytesEq(qs[k + 1], w.I.enc.qlink(k, "Target " .. (page * 8 + k + 1), "0"), "page knob " .. k)
        end
    end
    pageReport(connect(w), 0)
    w.wire(cc(0x31, 1)); w.tick(10)
    local msgs = w.takeSysex()
    pageReport(msgs, 1)
    eq(cmdOf(msgs[1]), 0x42, "page STATE precedes assignments")
    w.tick(51)
    eq(#ofCmd(w.takeSysex(), 0x47), 0, "unchanged sweep silent")
    mock.set(w.qlinks[15].TargetName, "Changed untouched")
    w.tick(51)
    local qs = ofCmd(w.takeSysex(), 0x47)
    eq(#qs, 1, "only changed knob sent within sweep")
    bytesEq(qs[1], w.I.enc.qlink(7, "Changed untouched", "0"), "changed name")
    w.wire(cc(0x33, 0)); w.tick(10)
    eq(#ofCmd(w.takeSysex(), 0x47), 8, "force refresh clears dedup")
    w.wire(PING)
    mock.set(w.currentTrack.Index, 1)
    w.qlinkReads = {}
    w.tick(51)
    eq(#ofCmd(w.takeSysex(), 0x47), 8, "track change clears dedup within sweep")
    eq(w.qlinkReads[1].idx, 8, "track restarts at knob zero")
    for _, n in pairs(w.sysexPerTick) do ok(n <= 4, "paced page reports") end
    noErrors(w)
end)

test("Q-Links: idle reads one untouched knob per interval; touch polls at 100 ms without duplicate reads", function()
    local w = load()
    connect(w)
    w.qlinkReads = {}
    w.tick(50)
    local perTick, times = {}, {}
    for _, r in ipairs(w.qlinkReads) do
        perTick[r.tick] = (perTick[r.tick] or 0) + 1
        if r.field == "TargetName" then times[#times + 1] = r.time end
    end
    eq(#times, 8, "eight idle reads in one second")
    for _, n in pairs(perTick) do eq(n, 2, "one knob = two properties per tick") end
    for i = 2, #times do ok(times[i] - times[i-1] >= 120, "idle interval rounded to tick") end
    w.wire({ 0x9F, 0x40, 127 }); w.tick(5); w.takeSysex()
    -- Bypass listeners to prove the touched polling fallback.
    rawset(w.qlinks[0].ValueString, "_v", "Touched poll")
    w.qlinkReads = {}
    w.tick(5)
    local qs = ofCmd(w.takeSysex(), 0x47)
    eq(#qs, 1, "touched change within 100 ms")
    bytesEq(qs[1], w.I.enc.qlink(0, "Target 1", "Touched poll"), "touched poll value")
    w.tick(45)
    local touchedTimes, idlePerTick, touchedPerTick = {}, {}, {}
    for _, r in ipairs(w.qlinkReads) do
        if r.idx == 0 then
            touchedPerTick[r.tick] = (touchedPerTick[r.tick] or 0) + 1
            if r.field == "TargetName" then touchedTimes[#touchedTimes + 1] = r.time end
        else idlePerTick[r.tick] = (idlePerTick[r.tick] or 0) + 1 end
    end
    for _, n in pairs(touchedPerTick) do eq(n, 2, "touched knob never double-read") end
    for _, n in pairs(idlePerTick) do eq(n, 2, "one untouched knob maximum") end
    for i = 2, #touchedTimes do eq(touchedTimes[i] - touchedTimes[i-1], 100, "touched cadence") end
    noErrors(w)
end)

test("Q-Links: queued old-page reports are replaced before STATE; passive reconnect resends", function()
    local w = load()
    w.wire(HELLO) -- page zero report is still queued
    w.wire(cc(0x31, 1))
    w.wire(cc(0x31, 2))
    w.wire(cc(0x31, 3))
    w.tick(10)
    local msgs = w.takeSysex()
    local qs = ofCmd(msgs, 0x47)
    eq(#qs, 8, "only final page survives the pending queue")
    local sawState = false
    for _, m in ipairs(msgs) do
        if cmdOf(m) == 0x42 then
            eq(decodeState(m).qlinkPage, 3, "final page STATE")
            sawState = true
        elseif cmdOf(m) == 0x47 then ok(sawState, "STATE before every QLINK") end
    end
    for k = 0, 7 do bytesEq(qs[k+1], w.I.enc.qlink(k, "Target " .. (vectors.qlink_pages[4][k+1]+1), "0"), "final assignment") end
    w.wire(BYE)
    w.qlinkReads = {}
    w.tick(50)
    eq(#w.qlinkReads, 0, "no passive Q-Link reads")
    eq(#ofCmd(connect(w), 0x47), 8, "all assignments resent after passive")
    noErrors(w)
end)

test("Q-Links: a failing idle read costs only that knob and retries next sweep", function()
    local w = load()
    connect(w)
    w.qlinks[0].TargetName._onRead = function() error("broken knob") end
    mock.set(w.qlinks[1].TargetName, "Still works")
    w.tick(51)
    local qs = ofCmd(w.takeSysex(), 0x47)
    eq(#qs, 1, "other knob still updates")
    eq(qs[1]:byte(5), 1, "healthy knob")
    w.qlinks[0].TargetName._onRead = nil
    mock.set(w.qlinks[0].TargetName, "Recovered")
    w.tick(51)
    qs = ofCmd(w.takeSysex(), 0x47)
    eq(#qs, 1, "recovered knob retried")
    eq(qs[1]:byte(5), 0, "recovered knob")
end)

test("Q-Links: twist is native (script not in the path)", function()
    local w = load()
    connect(w)
    w.clearCalls()
    eq(w.wire({ 0xBF, 0x47, 1 }), "qlink", "knob 0 routed to Q-Link")
    eq(w.routed[#w.routed][2], 0, "Q-Link index 0")
    eq(w.wire({ 0xBF, 0x4E, 126 }), "qlink", "knob 7 routed to Q-Link")
    eq(w.routed[#w.routed][2], 7, "Q-Link index 7")
end)

test("Q-Links: page switch rebinds 9-16 and re-targets a held knob", function()
    local w = load()
    connect(w)
    w.wire({ 0x9F, 0x40, 127 })
    w.wire(cc(0x31, 1))
    eq(w.I.status().qlinkPage, 1, "page")
    for k = 0, 7 do eq(w.mapped["qlink.15." .. (0x47 + k)], 8 + k, "knob " .. k .. " -> Q-Link " .. (9 + k)) end
    w.tick(5)
    local msgs = w.takeSysex()
    local q = ofCmd(msgs, 0x47)[1]
    ok(q and q:find("Target 9", 1, true), "held knob now shows Q-Link 9")
    eq(decodeState(lastOf(msgs, 0x42)).qlinkPage, 1, "STATE qlinkPage")
    eq(mock.listenerCount(w.qlinks[0].ValueString), 0, "old Q-Link released")
    eq(mock.listenerCount(w.qlinks[8].ValueString), 1, "new Q-Link listened")
    noErrors(w)
end)

test("Q-Links: all four pages bind, route and report the matching MPC indices", function()
    local w = load()
    -- Distinct values catch a name/value mapping mismatch as well as names.
    for i = 0, 15 do mock.set(w.qlinks[i].ValueString, "Value " .. (i + 1)) end
    local initial = connect(w)
    local initialBindings = w.callsNamed("AddInfiniteCCToQLink")
    for page = 0, 3 do
        w.clearCalls()
        local msgs, bindings = initial, initialBindings
        if page ~= 0 then
            w.wire(cc(0x31, page)); w.tick(10)
            msgs = w.takeSysex()
            bindings = w.callsNamed("AddInfiniteCCToQLink")
        end
        eq(#bindings, 8, "exactly eight bindings")
        for k = 0, 7 do
            eq(table.concat(bindings[k+1], ","), "15," .. (0x47+k) .. "," .. vectors.qlink_pages[page+1][k+1], "binding args")
        end
        local qs = ofCmd(msgs, 0x47)
        eq(#qs, 8, "eight assignments on page " .. page)
        eq(decodeState(lastOf(msgs, 0x42)).qlinkPage, page, "STATE page")
        for k = 0, 7 do
            local idx = vectors.qlink_pages[page+1][k+1]
            eq(w.mapped["qlink.15." .. (0x47+k)], idx, "binding index")
            eq(w.wire(cc(0x47+k, 1)), "qlink", "native route")
            eq(w.routed[#w.routed][2], idx, "routed index")
            bytesEq(qs[k+1], w.I.enc.qlink(k, "Target " .. (idx+1), "Value " .. (idx+1)), "mapped name/value")
            w.wire({0x9F, 0x40+k, 127})
            eq(mock.listenerCount(w.qlinks[idx].ValueString), 1, "touch starts on mapped index")
            w.wire({0x8F, 0x40+k, 0})
            eq(mock.listenerCount(w.qlinks[idx].ValueString), 0, "touch releases mapped index")
        end
        w.tick(10); w.takeSysex()
    end
    for _, invalid in ipairs({4, 127}) do
        w.clearCalls(); w.wire(cc(0x31, invalid))
        eq(w.I.status().qlinkPage, 3, "invalid page ignored")
        eq(#w.callsNamed("AddInfiniteCCToQLink"), 0, "no invalid rebinding")
    end
    noErrors(w)
end)

test("Q-Links: held touches retarget across numeric and column pages", function()
    local w = load(); connect(w)
    w.wire({0x9F, 0x40, 127}); w.wire({0x9F, 0x47, 127})
    for _, page in ipairs({2, 3, 1, 0}) do
        local old = vectors.qlink_pages[w.I.status().qlinkPage+1]
        w.wire(cc(0x31, page)); w.tick(10)
        local qs = ofCmd(w.takeSysex(), 0x47)
        for _, k in ipairs({0, 7}) do
            local idx = vectors.qlink_pages[page+1][k+1]
            eq(mock.listenerCount(w.qlinks[old[k+1]].ValueString), 0, "old listener removed")
            eq(mock.listenerCount(w.qlinks[idx].ValueString), 1, "new mapped listener")
            bytesEq(qs[k+1], w.I.enc.qlink(k, "Target " .. (idx+1), "0"), "held mapped report")
        end
        local idx = vectors.qlink_pages[page+1][1]
        mock.set(w.qlinks[idx].ValueString, "Held change"); w.tick(2)
        bytesEq(lastOf(w.takeSysex(), 0x47), w.I.enc.qlink(0, "Target " .. (idx+1), "Held change"), "new listener resends")
        -- Restore value before this index appears on another page.
        mock.set(w.qlinks[idx].ValueString, "0"); w.tick(2); w.takeSysex()
    end
    w.wire({0x8F, 0x40, 0}); w.wire({0x8F, 0x47, 0})
    for i = 0, 15 do eq(mock.listenerCount(w.qlinks[i].ValueString), 0, "all touches released") end
    noErrors(w)
end)

test("Q-Links: works through mappings.qlinks when controlSurface.qlinks is absent", function()
    local w = load({ noControlSurfaceQLinks = true })
    connect(w)
    eq(w.mapped["qlink.15.71"], 0, "mapped via fallback")
    noErrors(w)
end)

test("clip colour/state -> PADS rgb and anim", function()
    local w = load()
    connect(w)
    -- Session pad 24 = clip (0,0) = global (0,0); pad 7 = clip (7,3)
    local cases = {
        { 0xFF00FF00, 2, false, { 0, 127, 0, 1 }, "stopped: dim clip colour" },
        { 0xFF00FF00, 2, true, { 0, 127, 0, 0 }, "selected stopped: solid" },
        { 0xFF0000FF, 4, false, { 0, 0, 127, 2 }, "playing: slow pulse" },
        { 0xFF0000FF, 3, false, { 0, 0, 127, 3 }, "will play: fast blink" },
        { 0xFF0000FF, 5, false, { 0, 0, 127, 3 }, "will stop: fast blink" },
        { 0xFF0000FF, 7, false, { 127, 0, 0, 2 }, "recording: red" },
        { 0xFF0000FF, 10, false, { 127, 0, 0, 2 }, "overdubbing: red" },
        { 0xFF0000FF, 6, false, { 127, 0, 0, 3 }, "will record: red blink" },
        { 0xFF0000FF, 1, false, { 0, 0, 0, 0 }, "empty: off" },
        { 0xFF0000FF, 0, false, { 0, 0, 0, 0 }, "no slot: off" },
        { 0xFF808080, 2, false, { 64, 64, 64, 1 }, "8-bit shifted right by one" },
    }
    for _, c in ipairs(cases) do
        w.setCell(0, 0, 0xFF123456, 2, true) -- a distinct LED first, so each case is a change
        w.tick(2); w.takeSysex()
        w.setCell(0, 0, c[1], c[2], c[3])
        w.tick(2)
        local pads = decodeRuns(w.takeSysex(), 0x43)
        ledEq(pads[24], c[4][1], c[4][2], c[4][3], c[4][4], c[5])
        eq(pads[25], nil, c[5] .. ": only the changed pad is sent")
    end
    w.setCell(7, 3, 0xFFFF0000, 4)
    w.tick(2)
    ledEq(decodeRuns(w.takeSysex(), 0x43)[7], 127, 0, 0, 2, "pad 7 = clip (7,3)")
    -- Rows mode: pad 7 = clip (3,7)
    w.wire(cc(0x30, 1))
    w.setCell(3, 7, 0xFF00FF00, 4)
    w.tick(5)
    ledEq(decodeRuns(w.takeSysex(), 0x43)[7], 0, 127, 0, 2, "Rows pad 7 = clip (3,7)")
    noErrors(w)
end)

test("clip changes are found by polling even if no listener fires", function()
    local w = load()
    connect(w)
    -- change the property silently (bypassing listeners)
    rawset(w.aperture.clipProperties[1][0].State, "_v", 4)
    rawset(w.aperture.clipProperties[1][0].Colour, "_v", 0xFFFFFFFF)
    w.tick(20) -- > GRID_POLL_MS
    ledEq(decodeRuns(w.takeSysex(), 0x43)[25], 127, 127, 127, 2, "pad 25 via poll")
end)

test("ROWS and STEPS: scenes and tracks per mode", function()
    local w = load()
    w.setScene(0, 0xFFFFFFFF, 2, false)
    w.setScene(3, 0xFF0000FF, 3, false)
    w.setTrack(0, 0xFFFFFFFF, 2, true)
    w.setTrack(1, 0xFFFFFFFF, 1, false)
    local msgs = connect(w)
    local rows = ofCmd(msgs, 0x44)[1]
    local r = { rows:byte(5, 20) }
    eq(table.concat(r, ","), "127,127,127,1,0,0,0,0,0,0,0,0,0,0,127,3", "ROWS")
    local steps = decodeRuns(msgs, 0x45)
    ledEq(steps[0], 127, 127, 127, 0, "selected track solid")
    ledEq(steps[1], 127, 127, 127, 1, "track stop dim")
    ledEq(steps[4], 0, 0, 0, 0, "no track off")
    ledEq(steps[15], 0, 0, 0, 0, "step 15 off")
    -- Rows: ROWS are tracks, STEPS scenes
    w.wire(cc(0x30, 1))
    w.tick(10)
    local m2 = w.takeSysex()
    local r2 = { lastOf(m2, 0x44):byte(5, 20) }
    eq(r2[4], 0, "row 0 = selected track solid"); eq(r2[8], 1, "row 1 = track dim")
    local s2 = decodeRuns(m2, 0x45)
    ledEq(s2[15], 127, 0, 0, 1, "step 16 stops all")
    noErrors(w)
end)

test("Pads mode colours from virtual properties, polled", function()
    local w = load()
    connect(w)
    w.vpadColour[0] = 0xFF0000
    w.vpadColour[16] = 0x00FF00
    w.vpadColour[63] = 0x0000FE
    w.wire(cc(0x30, 2))
    w.tick(10)
    local pads = decodeRuns(w.takeSysex(), 0x43)
    ledEq(pads[0], 127, 0, 0, 0, "A1 on pad 0")
    ledEq(pads[4], 0, 127, 0, 0, "B1 on pad 4")
    w.wire(cc(0x32, 2))
    w.tick(10)
    pads = decodeRuns(w.takeSysex(), 0x43)
    ledEq(pads[31], 0, 0, 127, 0, "D16 on pad 31 at bank C|D")
    w.vpadColour[48 + 12] = 0xFFFFFF -- D13 = pad 28 at bank C|D
    w.tick(10) -- two 100 ms poll intervals, including output pacing
    pads = decodeRuns(w.takeSysex(), 0x43)
    ledEq(pads[28], 127, 127, 127, 0, "change found by polling")
    noErrors(w)
end)

test("Pads mode: all 32 changed kit colours arrive within two poll intervals", function()
    local w = load()
    connect(w)
    w.wire(cc(0x30, 2))
    w.tick(10)
    w.takeSysex()
    -- A "kit load": every pad of banks A and B changes at once.
    for vp = 0, 31 do w.vpadColour[vp] = 0x00FF00 end
    w.tick(10) -- 200 ms: one poll plus time to flush the four PADS runs
    local pads = decodeRuns(w.takeSysex(), 0x43)
    local n = 0
    for p = 0, 31 do if pads[p] then n = n + 1 end end
    eq(n, 32, "all 32 pads resent")
    noErrors(w)
end)

-- Count actual outgoing entries, including duplicate sends inside one capture.
local function padEntries(msgs, pad)
    local out = {}
    for _, m in ipairs(ofCmd(msgs, 0x43)) do
        local first, n = m:byte(5, 6)
        if pad >= first and pad < first + n then
            local o = 7 + (pad - first) * 4
            out[#out + 1] = { m:byte(o, o + 3) }
        end
    end
    return out
end

-- Counters catch even calls swallowed by the script's safety wrappers.
local function watchPadPolls(w)
    local counts = { functions = 0, bank = 0, colours = {} }
    for name, fn in pairs(w.pads) do
        if type(fn) == "function" then
            w.pads[name] = function(...)
                counts.functions = counts.functions + 1
                return fn(...)
            end
        end
    end
    w.pads.CurrentBank._onRead = function() counts.bank = counts.bank + 1 end
    local virtual = w.pads.virtual
    w.pads.virtual = setmetatable({}, { __index = function(_, vp)
        counts.colours[vp] = (counts.colours[vp] or 0) + 1
        return virtual[vp]
    end })
    return counts
end

local function noExpensivePadPolls(w, counts)
    eq(counts.functions, 0, "no pads function calls")
    eq(counts.bank, 0, "no CurrentBank reads")
    noErrors(w)
end

test("Main polls every pad every 40 ms and a one-interval colour reverts", function()
    local w = load(); connect(w); w.wire(cc(0x30, 2)); w.tick(10); w.takeSysex()
    local counts = watchPadPolls(w)
    -- Check every position independently: a full sweep triggered by one lucky
    -- round-robin position must not mask slow detection of the other pads.
    for p = 0, 31 do
        local vp = w.I.padToVirtual(0, p)
        w.vpadColour[vp] = 0xFF0000
        w.tick(2) -- visible for exactly one 40 ms interval
        local changed = padEntries(w.takeSysex(), p)
        eq(#changed, 1, "one changed entry for pad " .. p)
        ledEq(changed[1], 127, 0, 0, 0)
        w.vpadColour[vp] = 0
        w.tick(4) -- back on the wire within two intervals
        local reverted = padEntries(w.takeSysex(), p)
        eq(#reverted, 1, "one reverted entry for pad " .. p)
        ledEq(reverted[1], 0, 0, 0, 0)
        w.wire(PING) -- keep long coverage runs active
    end
    for vp = 0, 31 do eq(counts.colours[vp], 96, "all pads read every poll") end
    w.tick(10); eq(#ofCmd(w.takeSysex(), 0x43), 0, "transient does not stick or reappear")
    noExpensivePadPolls(w, counts)
end)

-- Mute-mode helpers. A tick is 20 ms and the script polls pads every 100 ms.
-- drive() runs [from, to) ms, calling set(t) before each tick, and records
-- every PADS entry sent for the pads in `watch` as { t = ms, [1..4] = bytes }.
local function enterMute(muteMode, pre)
    local w = load(); connect(w)
    w.wire(cc(0x30, 2)); w.tick(10)
    -- Colours the MPC already shows when the mode is entered.
    for vp, c in pairs(pre or {}) do w.vpadColour[vp] = c end
    mock.set(w.mpc.engineMode.CurrentMode, muteMode); w.tick(10); w.takeSysex()
    return w
end

local function drive(w, from, to, set, watch, rec)
    for t = from, to - 1, 20 do
        set(t)
        w.tick(1)
        if (t // 20) % 40 == 0 then w.wire(PING) end
        local msgs = w.takeSysex()
        for _, pad in ipairs(watch) do
            for _, e in ipairs(padEntries(msgs, pad)) do
                e.t = t
                rec[pad] = rec[pad] or {}
                table.insert(rec[pad], e)
            end
        end
    end
end

local function isMuted(e) return e[1] == 127 and e[2] == 56 and e[3] == 0 and e[4] == 1 end
local function countMuted(list)
    local n = 0
    for _, e in ipairs(list or {}) do if isMuted(e) then n = n + 1 end end
    return n
end
-- Blink: 500 ms phases, orange first.
local function blink(t) return (t // 500) % 2 == 0 and 0xFF7700 or 0x000000 end

for _, muteMode in ipairs({"Track Mute", "Pad Mute"}) do
    test(muteMode .. " coalesces 500 ms blinking into one muted entry, restores after it stops", function()
        local w = enterMute(muteMode, { [31] = 0x0000FF })
        local counts = watchPadPolls(w)
        local rec = {}
        drive(w, 0, 6000, function(t) w.vpadColour[0] = blink(t) end, {0}, rec)
        eq(countMuted(rec[0]), 1, "one muted entry, no per-phase resends")
        ok(isMuted(rec[0][#rec[0]]), "muted entry is the last thing sent")
        -- Blink stops on an unmuted colour: restored on the next poll.
        local before = #rec[0]
        drive(w, 6000, 6200, function() w.vpadColour[0] = 0xFF0000 end, {0}, rec)
        eq(#rec[0], before + 1, "one restoration")
        ledEq(rec[0][#rec[0]], 127, 0, 0, 0)
        -- A refresh shows the steady pad as read (before a second load() swaps the globals).
        w.wire(PING); w.wire(cc(0x33, 127)); w.tick(10)
        ledEq(decodeRuns(w.takeSysex(), 0x43)[31], 0, 0, 127, 0, "steady pad read solid")
        noExpensivePadPolls(w, counts)
        -- Blink stops on black (pad emptied): muted until history expires.
        local w2 = enterMute(muteMode)
        local rec2 = {}
        drive(w2, 0, 2000, function(t) w2.vpadColour[0] = blink(t) end, {0}, rec2)
        ok(isMuted(rec2[0][#rec2[0]]), "muted")
        local n = #rec2[0]
        drive(w2, 2000, 2600, function() w2.vpadColour[0] = 0 end, {0}, rec2)
        eq(#rec2[0], n, "still muted while history is fresh")
        drive(w2, 2600, 4000, function() w2.vpadColour[0] = 0 end, {0}, rec2)
        eq(#rec2[0], n + 1, "expired once")
        ledEq(rec2[0][#rec2[0]], 0, 0, 0, 0)
        noErrors(w2)
    end)

    test(muteMode .. ": a pad blinking FF7700 / black is muted within one blink period and stays so for 5 s", function()
        local w = enterMute(muteMode)
        local rec = {}
        drive(w, 0, 8000, function(t) w.vpadColour[0] = blink(t) end, {0}, rec)
        local first
        for _, e in ipairs(rec[0]) do if isMuted(e) then first = first or e.t end end
        ok(first and first <= 1100, "muted by " .. tostring(first))
        eq(countMuted(rec[0]), 1)
        for _, e in ipairs(rec[0]) do if e.t > first then error("entry after muting at t=" .. e.t) end end
        noErrors(w)
    end)

    test(muteMode .. ": the instant global dim makes no pad muted and sends dimmed colours as read", function()
        local full = { [0] = 0xFF0000, 0x00FF00, 0xFFFF00, 0xFF7700 }
        local w = enterMute(muteMode, full)
        local dim  = { [0] = 0x660000, 0x006600, 0x666600, 0x662F00 }
        local want = { [0] = {51,0,0}, {0,51,0}, {51,51,0}, {51,23,0} }
        local rec = {}
        drive(w, 0, 1000, function() for i = 0, 3 do w.vpadColour[i] = full[i] end end, {0,1,2,3}, rec)
        drive(w, 1000, 4000, function() for i = 0, 3 do w.vpadColour[i] = dim[i] end end, {0,1,2,3}, rec)
        for i = 0, 3 do
            eq(countMuted(rec[i]), 0, "pad " .. i .. " never muted")
            local last = rec[i][#rec[i]]
            ledEq(last, want[i][1], want[i][2], want[i][3], 0, "pad " .. i .. " dimmed, solid")
        end
        -- and back to full when nothing is muted
        drive(w, 4000, 4400, function() for i = 0, 3 do w.vpadColour[i] = full[i] end end, {0,1,2,3}, rec)
        ledEq(rec[0][#rec[0]], 127, 0, 0, 0)
        for i = 0, 3 do eq(countMuted(rec[i]), 0) end
        noErrors(w)
    end)

    test(muteMode .. ": playback flashes between 40% and full never mute a pad", function()
        local w = enterMute(muteMode)
        local rec = {}
        local seq, i = { 100, 300, 100, 200, 300, 100, 200 }, 0
        local phaseEnd, hi = 0, false
        drive(w, 0, 6000, function(t)
            if t >= phaseEnd then
                i = i % #seq + 1; phaseEnd = t + seq[i]; hi = not hi
            end
            w.vpadColour[0] = hi and 0xFF0000 or 0x660000
        end, {0}, rec)
        ok(#rec[0] > 0, "flashes were sent")
        eq(countMuted(rec[0]), 0)
        noErrors(w)
    end)

    test(muteMode .. ": a pad whose own colour is FF7700 is never muted, nor its dimmed 662F00", function()
        local w = enterMute(muteMode, { [0] = 0xFF7700 })
        local rec = {}
        drive(w, 0, 4000, function() w.vpadColour[0] = 0xFF7700 end, {0}, rec)
        drive(w, 4000, 8000, function() w.vpadColour[0] = 0x662F00 end, {0}, rec)
        eq(countMuted(rec[0]), 0)
        ledEq(rec[0][#rec[0]], 51, 23, 0, 0)
        noErrors(w)
    end)

    test(muteMode .. ": an always-black empty pad is never muted", function()
        local w = enterMute(muteMode)
        local rec = {}
        drive(w, 0, 5000, function() w.vpadColour[0] = 0 end, {0}, rec)
        eq(countMuted(rec[0]), 0)
        noErrors(w)
    end)

    test(muteMode .. ": unmute restores at the next poll, or within the flash window for an orange pad", function()
        -- to a non-orange colour: next poll
        local w = enterMute(muteMode)
        local rec = {}
        drive(w, 0, 2000, function(t) w.vpadColour[0] = blink(t) end, {0}, rec)
        ok(isMuted(rec[0][#rec[0]]), "muted")
        local n = #rec[0]
        drive(w, 2000, 2140, function() w.vpadColour[0] = 0x660000 end, {0}, rec)
        eq(#rec[0], n + 1, "restored within a poll plus a tick")
        ledEq(rec[0][#rec[0]], 51, 0, 0, 0)
        -- to steady FF7700 (an orange pad unmuted): within MUTE_FLASH_MS plus a poll
        local w2 = enterMute(muteMode)
        local rec2 = {}
        drive(w2, 0, 2000, function(t) w2.vpadColour[0] = blink(t) end, {0}, rec2)
        ok(isMuted(rec2[0][#rec2[0]]), "muted")
        local n2 = #rec2[0]
        drive(w2, 2000, 2000 + 1200 + 100 + 40, function() w2.vpadColour[0] = 0xFF7700 end, {0}, rec2)
        eq(#rec2[0], n2 + 1, "restored once")
        ledEq(rec2[0][#rec2[0]], 127, 59, 0, 0)
        noErrors(w); noErrors(w2)
    end)

    if muteMode == "Pad Mute" then
    test("Pad Mute: a pad whose own colour is the mute orange unmutes when the dimming ends, not 1.2 s later (seventh bench)", function()
        -- Pad 0's own colour is FF7700; pad 1 is red. Mute pad 0: it blinks
        -- (orange first, the same light as its own) and pad 1 drops to 40%.
        local w = enterMute(muteMode, { [0] = 0xFF7700, [1] = 0xFF0000 })
        local rec = {}
        drive(w, 0, 1000, function() w.vpadColour[0] = 0xFF7700; w.vpadColour[1] = 0xFF0000 end, {0, 1}, rec)
        drive(w, 1000, 3000, function(t) w.vpadColour[0] = blink(t); w.vpadColour[1] = 0x660000 end, {0, 1}, rec)
        ok(isMuted(rec[0][#rec[0]]), "muted")
        -- Unmute at 3000, during an orange phase: pad 0 steady orange, pad 1 back to full.
        local n = #rec[0]
        drive(w, 3000, 3200, function() w.vpadColour[0] = 0xFF7700; w.vpadColour[1] = 0xFF0000 end, {0, 1}, rec)
        eq(#rec[0], n + 1, "restored within 200 ms")
        ledEq(rec[0][#rec[0]], 127, 59, 0, 0)
        -- and it stays unmuted, steady orange, with nothing muted
        drive(w, 3200, 6000, function() w.vpadColour[0] = 0xFF7700; w.vpadColour[1] = 0xFF0000 end, {0, 1}, rec)
        eq(#rec[0], n + 1, "no further change")
        -- Mute it again: muted again (the end-of-dim rule must not undo a fresh mute).
        drive(w, 6000, 8000, function(t) w.vpadColour[0] = blink(t); w.vpadColour[1] = 0x660000 end, {0, 1}, rec)
        ok(isMuted(rec[0][#rec[0]]), "muted again")
        noErrors(w)
    end)
    test("Pad Mute, stopped: an orange pad is muted in the poll the others dim, not at its first black (seventh bench)", function()
        local w = enterMute(muteMode, { [0] = 0xFF7700, [1] = 0xFF0000, [2] = 0x00FF00 })
        local rec = {}
        drive(w, 0, 1000, function() w.vpadColour[0] = 0xFF7700; w.vpadColour[1] = 0xFF0000; w.vpadColour[2] = 0x00FF00 end, {0, 1, 2}, rec)
        -- mute pad 0 at 1000: its blink starts on orange (no change), the others dim
        drive(w, 1000, 1600, function(t) w.vpadColour[0] = blink(t - 1000); w.vpadColour[1] = 0x660000; w.vpadColour[2] = 0x006600 end, {0, 1, 2}, rec)
        local first
        for _, e in ipairs(rec[0]) do if isMuted(e) then first = first or e.t end end
        ok(first and first <= 1100, "muted by " .. tostring(first) .. ", before the black at 1500")
        eq(countMuted(rec[1]), 0); eq(countMuted(rec[2]), 0)
        noErrors(w)
    end)
    test("Pad Mute, stopped: a further mute of a dimmed orange pad is seen when it jumps to full orange", function()
        local w = enterMute(muteMode, { [0] = 0xFF7700, [1] = 0xFF0000, [2] = 0x00FF00 })
        local rec = {}
        drive(w, 0, 1000, function() w.vpadColour[0] = 0xFF7700; w.vpadColour[1] = 0xFF0000; w.vpadColour[2] = 0x00FF00 end, {0, 1, 2}, rec)
        -- pad 1 muted first: it blinks, pads 0 and 2 dim
        drive(w, 1000, 3000, function(t) w.vpadColour[1] = blink(t - 1000); w.vpadColour[0] = 0x662F00; w.vpadColour[2] = 0x006600 end, {0, 1, 2}, rec)
        ok(isMuted(rec[1][#rec[1]]), "pad 1 muted"); eq(countMuted(rec[0]), 0, "dimmed orange pad 0 not muted")
        -- then pad 0 muted at 3000: from its dimmed 662F00 to the blink's full orange
        drive(w, 3000, 3400, function(t) w.vpadColour[1] = blink(t - 1000); w.vpadColour[0] = blink(t - 3000); w.vpadColour[2] = 0x006600 end, {0, 1, 2}, rec)
        local first
        for _, e in ipairs(rec[0]) do if isMuted(e) then first = first or e.t end end
        ok(first and first <= 3100, "muted by " .. tostring(first))
        noErrors(w)
    end)
    test("Pad Mute, playing: an orange pad sounding from dim to full is not muted", function()
        local w = enterMute(muteMode, { [0] = 0xFF7700, [1] = 0xFF0000 })
        mock.set(w.mpc.sequencer.Playing, true)
        local rec = {}
        drive(w, 0, 1000, function() w.vpadColour[0] = 0xFF7700; w.vpadColour[1] = 0xFF0000 end, {0, 1}, rec)
        -- pad 1 muted, pad 0 dimmed, and pad 0 sounds (full for 200 ms) twice
        drive(w, 1000, 4000, function(t)
            w.vpadColour[1] = blink(t - 1000)
            local sounding = (t >= 1600 and t < 1800) or (t >= 2600 and t < 2800)
            w.vpadColour[0] = sounding and 0xFF7700 or 0x662F00
        end, {0, 1}, rec)
        eq(countMuted(rec[0]), 0, "never muted while playing")
        noErrors(w)
    end)
    test("Pad Mute: a black first blink one poll before the others dim is still a mute", function()
        local w = enterMute(muteMode, { [0] = 0xFF0000, [1] = 0x00FF00 })
        local rec = {}
        drive(w, 0, 1000, function() w.vpadColour[0] = 0xFF0000; w.vpadColour[1] = 0x00FF00 end, {0, 1}, rec)
        -- an earlier mute and unmute, so the dimming signal has been seen
        drive(w, 1000, 2000, function(t) w.vpadColour[0] = blink(t + 500); w.vpadColour[1] = 0x006600 end, {0, 1}, rec)
        drive(w, 2000, 3000, function() w.vpadColour[0] = 0xFF0000; w.vpadColour[1] = 0x00FF00 end, {0, 1}, rec)
        -- now black at 3000, the dimming of pad 1 only from 3080
        drive(w, 3000, 5000, function(t)
            w.vpadColour[0] = blink(t + 500); w.vpadColour[1] = t >= 3080 and 0x006600 or 0x00FF00
        end, {0, 1}, rec)
        ok(isMuted(rec[0][#rec[0]]), "muted at the end")
        local cleared = false
        for _, e in ipairs(rec[0]) do if e.t >= 3000 and not isMuted(e) and e[1] + e[2] + e[3] > 0 then cleared = true end end
        ok(not cleared, "never shown unmuted after the mute")
        noErrors(w)
    end)
    end

    test(muteMode .. ": two pads blinking in phase are both muted, a dimmed third is not", function()
        local w = enterMute(muteMode)
        local rec = {}
        drive(w, 0, 4000, function(t)
            w.vpadColour[0] = blink(t); w.vpadColour[1] = blink(t); w.vpadColour[2] = 0x660000
        end, {0, 1, 2}, rec)
        eq(countMuted(rec[0]), 1); eq(countMuted(rec[1]), 1)
        ok(isMuted(rec[0][#rec[0]]) and isMuted(rec[1][#rec[1]]))
        eq(countMuted(rec[2]), 0)
        ledEq(rec[2][#rec[2]], 51, 0, 0, 0)
        noErrors(w)
    end)
end

-- Immediate-mute state machine (padLed). A hold of `ms` at colour c from t,
-- returning the end time. An "on that very poll" claim allows one poll
-- interval plus two ticks after the change.
local function hold(w, rec, t, c, ms)
    rec[0] = rec[0] or {}
    drive(w, t, t + ms, function() w.vpadColour[0] = c end, {0}, rec)
    return t + ms
end
local SOON = 80 -- CFG.PAD_POLL_MS (40) + two 20 ms ticks, ms

for _, muteMode in ipairs({"Track Mute", "Pad Mute"}) do
    test(muteMode .. ": a lit pad of any colour that goes black is muted on that poll and stays muted", function()
        for _, lit in ipairs({ 0xFFFF00, 0x660000, 0x00FF00, 0x0D3F53, 0xFF7700, 0x662F00 }) do
            local w = enterMute(muteMode, { [0] = lit })
            local rec = {}
            local t = hold(w, rec, 0, lit, 600)
            eq(countMuted(rec[0]), 0, string.format("%06X not muted while lit", lit))
            local n = #rec[0]
            t = hold(w, rec, t, 0x000000, SOON)
            eq(countMuted(rec[0]), 1, string.format("%06X muted on the black poll", lit))
            eq(#rec[0], n + 1)
            ok(isMuted(rec[0][#rec[0]]) and rec[0][#rec[0]].t < 600 + SOON)
            -- then the blink continues: orange / black phases leave it muted, no more entries
            local after = #rec[0]
            drive(w, t, t + 2400, function(tt) w.vpadColour[0] = blink(tt) end, {0}, rec)
            eq(#rec[0], after, string.format("%06X no entries through the blink", lit))
            noErrors(w)
        end
    end)

    test(muteMode .. ": a pad that jumps to FF7700 from another hue is muted on that poll", function()
        for _, from in ipairs({ 0xFFFF00, 0x660000, 0x00FF00, 0x0D3F53 }) do
            local w = enterMute(muteMode, { [0] = from })
            local rec = {}
            local t = hold(w, rec, 0, from, 600)
            eq(countMuted(rec[0]), 0)
            t = hold(w, rec, t, 0xFF7700, SOON)
            eq(countMuted(rec[0]), 1, string.format("%06X -> FF7700 muted at once", from))
            ok(rec[0][1].t < 600 + SOON)
            noErrors(w)
        end
    end)

    test(muteMode .. ": a pad muted by the jump to FF7700 stays muted through the orange phase and the blink", function()
        for _, from in ipairs({ 0xFFFF00, 0x660000, 0x00FF00, 0x0D3F53 }) do
            local w = enterMute(muteMode, { [0] = from })
            local rec = {}
            local t = hold(w, rec, 0, from, 600)
            t = hold(w, rec, t, 0xFF7700, 400) -- the rest of a 500 ms orange phase
            ok(isMuted(rec[0][#rec[0]]), string.format("%06X still muted 400 ms into the orange phase", from))
            local after = #rec[0]
            drive(w, t, t + 2400, function(tt) w.vpadColour[0] = blink(tt + 100) end, {0}, rec)
            eq(#rec[0], after, string.format("%06X stays muted through the blink", from))
            noErrors(w)
        end
    end)

    test(muteMode .. ": a jump to FF7700 from 662F00 or full FF7700 is not muted until black is seen", function()
        for _, from in ipairs({ 0x662F00, 0xFF7700 }) do
            local w = enterMute(muteMode, { [0] = from }) -- lit on entry: no earlier black to pair with
            local rec = {}
            local t = hold(w, rec, 0, from, 600)
            t = hold(w, rec, t, 0xFF7700, 1500)
            eq(countMuted(rec[0]), 0, string.format("%06X -> FF7700 alone is not muted", from))
            -- sounding flashes between the two stay unmuted too
            t = hold(w, rec, t, 0x662F00, 300)
            t = hold(w, rec, t, 0xFF7700, 300)
            eq(countMuted(rec[0]), 0)
            -- black: muted on that very poll
            t = hold(w, rec, t, 0x000000, SOON)
            eq(countMuted(rec[0]), 1, string.format("%06X then black is muted at once", from))
            ok(isMuted(rec[0][#rec[0]]))
            noErrors(w)
        end
    end)

    test(muteMode .. ": a muted pad is un-muted on the first poll of any other colour, in either phase", function()
        -- rule 1 mute, black phase
        local w = enterMute(muteMode)
        local rec = {}
        local t = hold(w, rec, 0, 0x00FF00, 600)
        t = hold(w, rec, t, 0x000000, 300)
        ok(isMuted(rec[0][#rec[0]]), "muted in the black phase")
        local n = #rec[0]
        t = hold(w, rec, t, 0x660000, SOON)
        eq(#rec[0], n + 1, "restored on the first poll")
        ledEq(rec[0][#rec[0]], 51, 0, 0, 0)
        eq(countMuted({ table.unpack(rec[0], n + 1) }), 0)
        -- rule 2 mute, orange phase
        local w2 = enterMute(muteMode)
        local rec2 = {}
        local t2 = hold(w2, rec2, 0, 0xFFFF00, 600)
        t2 = hold(w2, rec2, t2, 0xFF7700, 300)
        ok(isMuted(rec2[0][#rec2[0]]), "muted in the orange phase")
        local n2 = #rec2[0]
        t2 = hold(w2, rec2, t2, 0x00FF00, SOON)
        eq(#rec2[0], n2 + 1, "restored on the first poll")
        ledEq(rec2[0][#rec2[0]], 0, 127, 0, 0)
        noErrors(w); noErrors(w2)
    end)

    test(muteMode .. ": a muted pad on steady orange with no black for 1200 ms is un-muted", function()
        local w = enterMute(muteMode)
        local rec = {}
        drive(w, 0, 2000, function(t) w.vpadColour[0] = blink(t) end, {0}, rec)
        ok(isMuted(rec[0][#rec[0]]), "muted")
        local n = #rec[0]
        drive(w, 2000, 2000 + 1200 + SOON, function() w.vpadColour[0] = 0xFF7700 end, {0}, rec)
        eq(#rec[0], n + 1, "un-muted once")
        ledEq(rec[0][#rec[0]], 127, 59, 0, 0)
        drive(w, 3280, 6000, function() w.vpadColour[0] = 0xFF7700 end, {0}, rec)
        eq(#rec[0], n + 1, "and stays un-muted on steady orange")
        noErrors(w)
    end)

    test(muteMode .. ": steady orange after a jump-mute from another hue settles un-muted, not flickering", function()
        local w = enterMute(muteMode, { [0] = 0x660000 })
        local rec = {}
        local t = hold(w, rec, 0, 0x660000, 600)
        t = hold(w, rec, t, 0xFF7700, 3000) -- never blinks: an orange pad, not a muted one
        local n = #rec[0]
        t = hold(w, rec, t, 0xFF7700, 3000)
        eq(#rec[0], n, "no entries in the last 3 s of steady orange")
        ledEq(rec[0][#rec[0]], 127, 59, 0, 0, "ends drawn as read")
        noErrors(w)
    end)

    test(muteMode .. ": a muted pad on steady black with no lit reading for 1200 ms is un-muted", function()
        local w = enterMute(muteMode)
        local rec = {}
        local t = hold(w, rec, 0, 0x00FF00, 600)
        t = hold(w, rec, t, 0x000000, 100)
        ok(isMuted(rec[0][#rec[0]]), "muted")
        local n = #rec[0]
        t = hold(w, rec, t, 0x000000, 900)
        eq(#rec[0], n, "still muted inside the window")
        t = hold(w, rec, t, 0x000000, 600)
        eq(#rec[0], n + 1, "un-muted once")
        ledEq(rec[0][#rec[0]], 0, 0, 0, 0)
        t = hold(w, rec, t, 0x000000, 3000)
        eq(#rec[0], n + 1, "and stays empty")
        eq(countMuted({ table.unpack(rec[0], n + 1) }), 0)
        noErrors(w)
    end)

    test(muteMode .. ": a pad black on entry and never lit is not muted, whatever else changes", function()
        local w = enterMute(muteMode, { [0] = 0x000000 })
        local rec = {}
        drive(w, 0, 3000, function(t)
            w.vpadColour[0] = 0
            w.vpadColour[1] = blink(t) -- a neighbour blinking must not touch pad 0
        end, {0, 1}, rec)
        eq(countMuted(rec[0]), 0)
        eq(countMuted(rec[1]), 1, "the neighbour is muted")
        noErrors(w)
    end)
end

test("outside the mute modes a pad alternating FF7700 / black is sent as read", function()
    local w = load(); connect(w)
    w.wire(cc(0x30, 2)); w.tick(10); w.takeSysex()
    local rec = {}
    drive(w, 0, 5000, function(t) w.vpadColour[0] = blink(t) end, {0}, rec)
    ok(#rec[0] >= 4, "phases sent, got " .. #rec[0])
    eq(countMuted(rec[0]), 0)
    for _, e in ipairs(rec[0]) do eq(e[4], 0, "solid") end
    noErrors(w)
end)

test("an Audio track is aux (STATE bit) but keeps its numbered title; Submix has none", function()
    local w = load(); connect(w)
    local function read(kind)
        mock.set(w.currentTrack.Type, kind); mock.set(w.currentTrack.Index, 2); mock.set(w.currentTrack.Name, "Audio 003")
        w.wire(cc(0x33, 127)); w.tick(10); local msgs = w.takeSysex()
        local title
        for _, m in ipairs(ofCmd(msgs, 0x46)) do if m:byte(5) == 0 then title = m:sub(6) end end
        return lastOf(msgs, 0x42):byte(14) & 16, title
    end
    local aux, title = read("Audio")
    eq(aux, 16, "audio is aux"); eq(title, "3: Audio 003")
    aux, title = read("Submix")
    eq(aux, 16); eq(title, "Audio 003")
    noErrors(w)
end)

test("Step Seq skips the 32-pad PADS sampler, including full refresh", function()
    local w = load(); connect(w); w.wire(cc(0x30, 2)); w.tick(10)
    mock.set(w.mpc.engineMode.CurrentMode, "Step Sequencer"); w.tick(10); w.takeSysex()
    local counts = watchPadPolls(w)
    for vp = 0, 31 do w.vpadColour[vp] = 0x00FF00 end
    w.tick(10)
    eq(#ofCmd(w.takeSysex(), 0x43), 0, "no PADS from step colours")
    for vp = 0, 15 do eq(counts.colours[vp], 10, "only the per-tick STEPS reader") end
    for vp = 16, 31 do eq(counts.colours[vp], nil, "second PADS bank never sampled") end
    w.wire(cc(0x33, 127)); w.tick(10)
    local pads = decodeRuns(w.takeSysex(), 0x43)
    for p = 0, 31 do ledEq(pads[p], 0, 0, 0, 0, "refresh uses cached Main colours") end
    for vp = 16, 31 do eq(counts.colours[vp], nil, "refresh never samples second bank") end
    noExpensivePadPolls(w, counts)
end)

test("every mute-mode exit drops flash history, including switching mute modes", function()
    for _, from in ipairs({"Track Mute", "Pad Mute"}) do
        for _, to in ipairs({"Main Mode", "Track Mute", "Pad Mute", "Other", "Step Sequencer"}) do
            if from ~= to then
                local w = enterMute(from)
                local rec = {}
                drive(w, 0, 2000, function(t) w.vpadColour[0] = blink(t) end, {0}, rec)
                ok(isMuted(rec[0][#rec[0]]), "muted before leaving")
                w.vpadColour[0] = 0; w.takeSysex()
                mock.set(w.mpc.engineMode.CurrentMode, to); w.tick(10)
                local msgs = w.takeSysex()
                if to ~= "Step Sequencer" then
                    ledEq(decodeRuns(msgs, 0x43)[0], 0, 0, 0, 0, "history cleared on exit")
                end
                -- Re-enter within 1200 ms of the last orange: stale history would still mute.
                mock.set(w.mpc.engineMode.CurrentMode, from); w.tick(10)
                w.wire(cc(0x33, 127)); w.tick(10)
                ledEq(decodeRuns(w.takeSysex(), 0x43)[0], 0, 0, 0, 0, "fresh history on re-entry")
                noErrors(w)
            end
        end
    end
end)

test("missing virtual pad colours never polls expensive pads functions or CurrentBank", function()
    local w = load({ noLightRGB = true }); connect(w)
    w.pads.CurrentBank = setmetatable({}, {__index=function() error("must not poll bank") end})
    w.pads.LightRGBColor = function() error("must not poll colours") end
    w.pads.LightBrightness = function() error("must not poll brightness") end
    w.wire(cc(0x30, 2)); w.tick(20)
    eq(w.I.status().active, true)
    eq(w.I.errors()["pads.CurrentBank"], nil)
    eq(w.I.errors()["pads.LightRGBColor"], nil)
end)

test("pacing: never more than 4 SysEx per tick", function()
    local w = load()
    w.takeSysex()
    w.wire(HELLO)
    eq(#w.takeSysex(), 0, "nothing sent outside the timer")
    for i = 1, 6 do w.tick(1) end
    for t, n in pairs(w.sysexPerTick) do ok(n <= 4, "tick " .. t .. " sent " .. n) end
    -- a dump is >4 messages, so it took several ticks
    local ticksUsed = 0
    for _ in pairs(w.sysexPerTick) do ticksUsed = ticksUsed + 1 end
    ok(ticksUsed >= 3, "dump spread over ticks, used " .. ticksUsed)
end)

test("pacing: queue overflow drops the queue and sends a full refresh", function()
    local w = load()
    connect(w)
    for i = 1, 65 do w.I.enqueue(w.I.enc.text(2, "spam " .. i)) end
    eq(w.I.queueLength(), 0, "queue dropped")
    eq(w.I.status().needFull, true, "full refresh pending")
    w.tick(20)
    local msgs = w.takeSysex()
    eq(#ofCmd(msgs, 0x43), 4, "full PADS refresh")
    eq(#ofCmd(msgs, 0x42), 1, "STATE"); eq(#ofCmd(msgs, 0x44), 1, "ROWS"); eq(#ofCmd(msgs, 0x45), 2, "STEPS")
    for _, m in ipairs(msgs) do ok(not m:find("spam", 1, true), "dropped message was sent") end
    for t, n in pairs(w.sysexPerTick) do ok(n <= 4, "tick " .. t .. " sent " .. n) end
end)

test("REFRESH resends the full state", function()
    local w = load()
    connect(w)
    w.wire(cc(0x33, 127))
    w.tick(10)
    local msgs = w.takeSysex()
    eq(#ofCmd(msgs, 0x43), 4, "PADS x4"); eq(#ofCmd(msgs, 0x45), 2, "STEPS x2")
end)

test("an API that throws costs one feature, not the script", function()
    local w = load()
    w.aperture.TriggerClip = function() error("boom") end
    w.mpc.clipMatrix = nil
    connect(w)
    w.wire({ 0x9F, 0, 100 })
    press(0x09, w)
    eq(w.I.status().active, true, "still active")
    ok(w.I.errors()["TriggerClip"], "error recorded")
    ok(w.I.errors()["StopAllClips"], "error recorded")
    w.tick(5)
    local t = ofCmd(w.takeSysex(), 0x46)
    local found = false
    for _, m in ipairs(t) do if m:byte(5) == 2 and m:find("StopAllClips", 1, true) then found = true end end
    ok(found, "error reported on TEXT slot 2 (newest pending one wins)")
    -- handlers themselves never raise
    w.dev.HandleMIDICC(15, 0x30, 1)
    w.dev.HandleMIDISysex(nil)
    w.dev.HandleMIDINoteOn(15, nil, nil)
end)

-----------------------------------------------------------------------------
-- vectors.json
-----------------------------------------------------------------------------

test("vectors: every move_to_mpc message is accepted without error (passive and active)", function()
    for _, phase in ipairs({ "passive", "active" }) do
        local w = load()
        if phase == "active" then connect(w) end
        for _, v in ipairs(vectors.move_to_mpc) do
            if not (phase == "passive" and v.name == "hello") then
                local route = w.wire(v.wire)
                ok(route, v.name)
                w.tick(1)
            end
        end
        noErrors(w)
    end
end)

test("vectors: move_to_mpc routes as expected when active", function()
    local w = load()
    connect(w)
    local expect = {
        ["pad 0 (bottom-left, Move note 68) down vel 100"] = "script",
        ["pad 31 (top-right, Move note 99) up"] = "script",
        ["pad 12 pressure 64"] = "passthrough", -- Session: no native pad, no script handler
        ["knob 0 one step clockwise"] = "qlink",
        ["knob 7 two steps counter-clockwise"] = "qlink",
        ["knob 3 touched"] = "script",
        ["knob 3 released"] = "script",
        ["NAV_RIGHT press"] = "script",
        ["SHIFT release"] = "script",
        ["ROW 0 (top) press"] = "script",
        ["STEP 15 press"] = "script",
        ["SET_MODE play side (auto)"] = "script",
        ["SET_QLINK_PAGE 9-16"] = "script",
        ["SET_QLINK_PAGE Col 1-2"] = "script",
        ["SET_QLINK_PAGE Col 3-4"] = "script",
        ["SET_PAD_BANK C|D"] = "script",
        ["REFRESH"] = "script",
        ["ping"] = "script",
    }
    for _, v in ipairs(vectors.move_to_mpc) do
        if expect[v.name] then eq(w.wire(v.wire), expect[v.name], v.name) end
    end
    eq(w.I.status().mode, 2, "SET_MODE play side (auto) applied")
    eq(w.I.status().qlinkPage, 3, "SET_QLINK_PAGE applied")
    eq(w.I.status().padBank, 2, "SET_PAD_BANK applied")
    eq(w.wire({ 0xAF, 12, 64 }), "vpad", "pressure follows the native pad in Pads mode")
    noErrors(w)
end)

test("vectors: every mpc_to_move message is produced byte-exactly by its encoder", function()
    local w = load()
    local E = w.I.enc
    local produce = {
        ["state: muted"] = function(d) return E.state(d) end,
        ["state: solo"] = function(d) return E.state(d) end,
        ["state: mute solo arm"] = function(d) return E.state(d) end,
        ["welcome v4, clip workflow available"] = function() return E.welcome(4, 1) end,
        ["state: Session, qlink page 0, bank 0, playing, origin 2,5, matrix 16x32, can move left+right+down"] = function(d)
            return E.state(d)
        end,
        ["state: Step Seq in Pads, navigation left+right"] = function()
            return E.state({mode=2, qlinkPage=0, padBank=2, globalCols=16, globalRows=32,
                canLeft=true, canRight=true, automation=1, available=15, marks=true, bpm=120, mpcMode=1})
        end,
        ["steps 0..2: Step Seq note, empty, playhead"] = function()
            return E.steps(0, {{127,0,0,0}, {0,0,0,0}, {0,127,0,0}})
        end,
        ["text slot 1 'Drum'"] = function(d) return E.text(d.slot, d.text) end,
        ["state: column page 2 (Col 1-2)"] = function(d) return E.state(d) end,
        ["state: column page 3 (Col 3-4)"] = function(d) return E.state(d) end,
        ["pads 8..9: full red solid, half green slow pulse"] = function(d)
            local leds = {}
            for i, p in ipairs(d.pads) do leds[i] = { p.r, p.g, p.b, p.anim } end
            return E.pads(d.first, leds)
        end,
        ["rows: white, off, off, blue blink"] = function()
            return E.rows({ { 127, 127, 127, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 127, 3 } })
        end,
        ["steps 0..1: dim white, off"] = function()
            return E.steps(0, { { 127, 127, 127, 1 }, { 0, 0, 0, 0 } })
        end,
        ["text slot 0 'Drum 001'"] = function(d) return E.text(d.slot, d.text) end,
        ["qlink knob 2 'Cutoff' = '1.2 kHz'"] = function(d) return E.qlink(d.knob, d.name, d.value) end,
        ["goodbye"] = function() return E.goodbye() end,
        ["pong"] = function() return E.pong() end,
        ["track list slot 3"] = function(d) return E.text(d.slot,d.text) end,
        ["track list slot 4"] = function(d) return E.text(d.slot,d.text) end,
        ["track list slot 5"] = function(d) return E.text(d.slot,d.text) end,

        ["position: 1 quarter in a two-bar loop, 4/4"] = function() return E.position(960, 7680, 4, 4) end,
    }
    local n = 0
    for _, v in ipairs(vectors.mpc_to_move) do
        local f = produce[v.name]
        ok(f, "no encoder case for vector '" .. v.name .. "'")
        bytesEq(f(v.decoded), body(v.wire), v.name)
        n = n + 1
    end
    eq(n, #vectors.mpc_to_move, "all covered")
end)

test("vectors: the STATE vector is produced by the script from MPC state", function()
    local w = load()
    connect(w)
    mock.set(w.mpc.sequencer.Playing, true)
    w.armed["Drum 001"] = true
    press(0x0E,w) -- plain press/release does not latch
    w.wire(cc(5,127)); press(0x0E,w); w.wire(cc(5,0))
    mock.set(w.mpc.project.GlobalAutomationFilterType,"Write")
    w.tick(50); w.takeSysex()
    w.moveTo(2, 5)
    mock.set(w.aperture.CanMoveUp, false) -- the vector's case
    w.tick(10)
    local st = lastOf(w.takeSysex(), 0x42)
    bytesEq(st, body(vector("mpc_to_move",
        "state: Session, qlink page 0, bank 0, playing, origin 2,5, matrix 16x32, can move left+right+down").wire),
        "STATE from the mock")
end)

test("vectors: PADS vector produced by the script from clip state", function()
    local w = load()
    connect(w)
    -- pads 8, 9 in Session = clips (0,2), (1,2): red stopped selected, half-green playing
    w.setCell(0, 2, 0xFFFF0000, 2, true)
    w.setCell(1, 2, 0xFF007F00, 4, false)
    w.tick(3)
    local m = ofCmd(w.takeSysex(), 0x43)
    bytesEq(m[#m], body(vector("mpc_to_move", "pads 8..9: full red solid, half green slow pulse").wire),
        "PADS run of the two changed pads")
end)

test("parser: header check, F0/F7 tolerated, short and unknown ignored", function()
    local w = load()
    local P = w.I.parseSysex
    local cmd, data = P(body(HELLO))
    eq(cmd, 1, "cmd"); eq(data[1], 4, "ver"); eq(data[2], 0, "caps")
    cmd = P(string.char(0xF0, 0x7D, 0x4D, 0x50, 0x02, 0xF7))
    eq(cmd, 2, "with F0/F7")
    eq(P(string.char(0x7E, 0x4D, 0x50, 0x02)), nil, "wrong header")
    eq(P(string.char(0x7D, 0x4D)), nil, "short")
    eq(P(nil), nil, "nil")
    w.wire({ 0xF0, 0x7D, 0x4D, 0x50, 0x60, 1, 2, 3, 0xF7 }) -- reserved clip transfer
    w.wire({ 0xF0, 0x7D, 0x4D, 0x50, 0x01, 0xF7 })          -- HELLO without version
    eq(w.I.status().active, false, "short HELLO ignored")
    noErrors(w)
end)

test("encoders: text is 7-bit and truncated so no message exceeds 48 bytes", function()
    local w = load()
    local E = w.I.enc
    local t = E.text(1, string.rep("x", 100))
    eq(#t + 2, 47, "TEXT max: 4 header + slot + 40 chars + F0/F7")
    local q = E.qlink(7, string.rep("n", 50), string.rep("v", 50))
    ok(#q + 2 <= 48, "QLINK max " .. (#q + 2))
    local u = E.text(0, "Caf\xC3\xA9 \xE2\x80\x94 1\t2")
    for i = 1, #u do ok(u:byte(i) < 0x80, "7-bit") end
    eq(u:sub(6), "Caf? ? 1 2", "sanitised")
end)

-----------------------------------------------------------------------------

test("PING while active queues one PONG per heartbeat, within pacing", function()
    local w = load()
    connect(w)
    for _ = 1, 3 do w.wire(PING) end
    eq(#w.takeSysex(), 0, "PONG is paced")
    w.tick()
    local replies = ofCmd(w.takeSysex(), 0x49)
    eq(#replies, 3, "one PONG per PING")
    for _, reply in ipairs(replies) do
        bytesEq(reply, body(vector("mpc_to_move", "pong").wire), "PONG bytes")
    end
    w.wire(BYE); w.takeSysex()
    w.wire(PING)
    eq(#ofCmd(w.takeSysex(), 0x49), 0, "no passive PONG")
    noErrors(w)
end)

test("STATE canMove uses Move arrow directions in every mode", function()
    local w = load()
    connect(w)
    for m = 0, 3 do
        mock.set(w.currentTrack.Type, m == 3 and "Plugin" or "Drum")
        w.wire(cc(0x30, m))
        mock.set(w.aperture.CanMoveLeft, true)
        mock.set(w.aperture.CanMoveRight, false)
        mock.set(w.aperture.CanMoveUp, false)
        mock.set(w.aperture.CanMoveDown, true)
        w.wire(cc(0x33, 127)); w.tick(10)
        eq(decodeState(lastOf(w.takeSysex(), 0x42)).canMove,
            ({ [0] = 9, 6, 2, 0 })[m], "mode " .. m)
    end
    mock.set(w.currentTrack.Type,"Drum"); w.wire(cc(0x30, 2))
    for _, bank in ipairs({ 0, 3, 6 }) do
        w.wire(cc(0x32, bank)); w.wire(cc(0x33, 127)); w.tick(10)
        eq(decodeState(lastOf(w.takeSysex(), 0x42)).canMove,
            ({ [0] = 2, [3] = 3, [6] = 1 })[bank], "bank " .. bank)
    end
    noErrors(w)
end)

test("no clip workflow refuses both clip modes and answers STATE", function()
    local w = load({ noClipWorkflow = true })
    local dump = connect(w)
    eq(ofCmd(dump, 0x41)[1]:byte(6), 0, "WELCOME flag")
    eq(w.I.status().mode, 2, "starts in Pads")
    for _, m in ipairs({ 0, 1 }) do
        w.wire(cc(0x30, m)); w.tick(10)
        eq(w.I.status().mode, 2, "refused clip mode")
        eq(decodeState(lastOf(w.takeSysex(), 0x42)).mode, 2, "STATE corrects Move")
    end
    mock.set(w.currentTrack.Type, "Plugin"); w.wire(cc(0x30, 3)); w.tick(10); w.takeSysex()
    w.wire(cc(0x30, 0)); w.tick(10)
    eq(decodeState(lastOf(w.takeSysex(), 0x42)).mode, 3, "Notes also preserved")
    noErrors(w)
end)

test("native held pads release before rebinding or going passive", function()
    for _, action in ipairs({ cc(0x32, 2), cc(0x30, 3), BYE }) do
        local w = load()
        connect(w)
        w.wire(cc(0x30, 2))
        w.wire({ 0x9F, 0, 100 }); w.wire({ 0x9F, 4, 100 })
        w.clearCalls()
        if action[2] == 0x30 then mock.set(w.currentTrack.Type,"Plugin") end
        w.wire(action)
        eq(next(w.virtualHeld), nil, "no stranded native pads")
        local released = {}
        for _, c in ipairs(w.calls) do
            if c.name == "ReleaseVirtual" then released[c.args[1]] = true end
            if c.name == "RemoveNoteToVirtualPad" then
                local p = c.args[2]
                ok(released[w.I.padToVirtual(0, p)], "released before removal")
            end
        end
        noErrors(w)
    end
end)

test("script-observed virtual-pad note-offs use the original pad, including zero velocity", function()
    for _, status in ipairs({ 0x80, 0x90 }) do
        local w = load()
        connect(w); w.wire(cc(0x30, 2))
        -- Exercise a note stream delivered to Lua rather than the native route.
        w.dev.HandleMIDINoteOn(15, 4, 100)
        w.clearCalls()
        if status == 0x80 then w.dev.HandleMIDINoteOff(15, 4, 0)
        else w.dev.HandleMIDINoteOn(15, 4, 0) end
        local calls = w.callsNamed("ReleaseVirtual")
        eq(#calls, 1, "one release for the observed note")
        eq(calls[1][1], 16, "original virtual pad B1")
        noErrors(w)
    end
end)

test("missing ReleaseVirtual cannot prevent unmapping or passive cleanup", function()
    local w = load()
    connect(w); w.wire(cc(0x30, 2))
    w.pads.ReleaseVirtual = function() error("unproven API unavailable") end
    w.wire(BYE)
    eq(w.I.status().active, false, "still goes passive")
    eq(scriptMappedCount(w), 0, "all mappings removed")
    ok(w.I.errors().ReleaseVirtual, "protected failure recorded")
end)

test("lifecycle messages are prioritized and share the four-message tick budget", function()
    local w = load()
    eq(#w.takeSysex(), 0, "OnLoad is paced")
    w.tick(); eq(cmdOf(w.takeSysex()[1]), 0x48, "passive timer delivers GOODBYE")
    connect(w)
    for _ = 1, 4 do w.wire(PING) end
    w.tick()
    w.wire(BYE)
    w.wire({ 0xF0, 0x7D, 0x4D, 0x50, 1, 1, 0, 0xF7 })
    eq(#w.takeSysex(), 4, "no immediate lifecycle sends after full tick")
    w.I.enqueue(w.I.enc.text(2, "pending"))
    w.wire({ 0xF0, 0x7D, 0x4D, 0x50, 1, 1, 0, 0xF7 })
    w.tick(); eq(cmdOf(w.takeSysex()[1]), 0x48, "GOODBYE first next tick")
    for t, n in pairs(w.sysexPerTick) do ok(n <= 4, "tick budget " .. t) end
    w.dev.OnUnload()
    eq(cmdOf(w.takeSysex()[1]), 0x48, "unload sends immediately")
end)

test("HELLO requires both version and caps, passive and active", function()
    for _, activeFirst in ipairs({ false, true }) do
        local w = load()
        w.tick(); w.takeSysex()
        if activeFirst then connect(w) end
        w.wire({ 0xF0, 0x7D, 0x4D, 0x50, 1, 1, 0xF7 })
        w.tick()
        eq(w.I.status().active, activeFirst, "short HELLO ignored")
        eq(#w.takeSysex(), 0, "no response or refresh")
    end
end)

test("heartbeat expires at exactly 3500 ms", function()
    local w = load()
    connect(w); w.wire(PING)
    w.tick(174)
    eq(w.I.status().active, true, "active at 3480 ms")
    w.tick()
    eq(w.I.status().active, false, "passive at 3500 ms")
end)

test("v2 MODE remembers layout, ignores shifted play MODE, follows only Drum", function()
    local w=load(); connect(w)
    w.wire(cc(5,127)); press(13,w); w.wire(cc(5,0)); eq(w.I.status().mode,1)
    press(13,w); eq(w.I.status().mode,2)
    w.wire(cc(5,127)); press(13,w); w.wire(cc(5,0)); eq(w.I.status().mode,2)
    mock.set(w.currentTrack.Type,"Keygroup"); w.tick(); eq(w.I.status().mode,3)
    mock.set(w.currentTrack.Type,"Drum"); w.tick(); eq(w.I.status().mode,2)
    press(13,w); eq(w.I.status().mode,1)
    w.wire(cc(0x30,127)); eq(w.I.status().mode,1,"invalid mode ignored")
    noErrors(w)
end)

test("v2 native Shift steps only; button failures clear availability", function()
    local w=load(); connect(w); w.clearCalls(); w.wire(cc(5,127))
    for i=0,15 do press(0x20+i,w) end
    eq(w.mpc.sequencer.MetronomeEnabled.value,true)
    eq(#w.callsNamed("sixteenLevel.Press"),1); eq(#w.callsNamed("fullLevel.Press"),1)
    eq(#w.callsNamed("quantiseApply.Press"),1)
    eq(#w.callsNamed("SelectTrack"),0); eq(#w.callsNamed("StopClipsOnTrack"),0)
    noErrors(w)
    w.mpc.controlSurface.quantiseApply.Press=function() error("unavailable") end
    press(0x2F,w); w.tick(10)
    eq(lastOf(w.takeSysex(),0x42):byte(16) & 8,0,"unavailable bit cleared")
    local count=w.I.errors().quantise; press(0x2F,w); eq(w.I.errors().quantise,count,"no repeat failures")
    eq(w.I.status().active,true)
end)

test("v2 held and latched repeat releases on every lifecycle and failed latch", function()
    for _, exit in ipairs({"bye","timeout","unload"}) do
        local w=load(); connect(w)
        w.wire(cc(14,127)); eq(w.repeatOn,true); w.wire(cc(14,0)); eq(w.repeatOn,false)
        w.wire(cc(5,127)); press(14,w); press(14,w); eq(w.repeatOn,false,"second Shift LOOP unlatches")
        press(14,w); w.wire(cc(5,0)); eq(w.repeatOn,true)
        if exit=="bye" then w.wire(BYE) elseif exit=="unload" then w.dev.OnUnload() else w.tick(175) end
        eq(w.repeatOn,false,exit); eq(w.I.status().active,false,exit); noErrors(w)
    end
    local w=load(); connect(w)
    w.mpc.controlSurface.noteRepeat.Press=function() error("button failed") end
    w.wire(cc(5,127)); press(14,w)
    ok(#w.callsNamed("shift.Release")>0,"modifier cleanup even after failure")
    eq(w.repeatOn,false); eq(w.I.status().active,true)
end)

test("v2 arm follows named track; automation toggles Read/Write; tempo coarse/fine/clamped", function()
    local w=load(); connect(w)
    press(15,w); w.tick(2); eq(w.armed["Drum 001"],true)
    press(15,w); w.tick(2); eq(w.armed["Drum 001"],false)
    w.armed.Synth=true; mock.set(w.currentTrack.Name,"Synth"); w.tick(2)
    press(15,w); w.tick(2); eq(w.armed.Synth,false)
    press(22,w); eq(w.mpc.project.GlobalAutomationFilterType.value,"Write")
    press(22,w); eq(w.mpc.project.GlobalAutomationFilterType.value,"Read")
    mock.set(w.mpc.project.GlobalAutomationFilterType,"Off"); press(22,w); eq(w.mpc.project.GlobalAutomationFilterType.value,"Read")
    w.wire(cc(5,127)); press(22,w); eq(w.mpc.project.GlobalAutomationFilterType.value,"Write") -- Shift means nothing
    w.wire(cc(5,0))
    w.wire(cc(52,1)); eq(w.mpc.project.BPM.value,121)
    w.wire(cc(5,127)); w.wire(cc(52,127)); eq(w.mpc.project.BPM.value,120.9)
    w.wire(cc(5,0)); mock.set(w.mpc.project.BPM,998); w.wire(cc(52,63)); eq(w.mpc.project.BPM.value,999)
    mock.set(w.mpc.project.BPM,21); w.wire(cc(52,65)); eq(w.mpc.project.BPM.value,20)
    noErrors(w)
end)

test("v2 arm handles rapid presses and external track changes before the next tick", function()
    local w=load(); connect(w)
    press(15,w); press(15,w); eq(w.armed["Drum 001"],false)
    w.armed.Synth=true; mock.set(w.currentTrack.Name,"Synth"); press(15,w)
    eq(w.armed.Synth,false); noErrors(w)
end)

test("v2 optional APIs fail independently, including tempo fallback and quantize alias", function()
    local w=load()
    w.mpc.sequencer.MetronomeEnabled=nil
    w.mpc.controlSurface.quantiseApply=nil
    w.mpc.controlSurface.quantizeApply={Press=function() w.log("quantizeApply.Press") end}
    w.mpc.project.BPM=nil
    connect(w); w.wire(cc(5,127)); press(0x25,w); press(0x2F,w); w.wire(cc(5,0))
    eq(#w.callsNamed("quantizeApply.Press"),1)
    w.wire(cc(52,1)); eq(w.callsNamed("SetBPM")[1][1],121)
    eq(w.I.status().active,true)
    eq(w.I.errors().MetronomeEnabled,1,"no repeated missing-feature errors")
    eq(w.I.errors()["BPM.write"],1)
end)

test("v2 copy scans one slot per tick; scene and delete use global selection", function()
    local w=load(); connect(w); w.selectedCol,w.selectedRow=3,5
    for r=5,7 do w.setCell(3,r,0xFF0000,2,false) end
    w.clearCalls(); press(20,w)
    for _=1,12 do
        local before=#w.callsNamed("HasClip"); w.tick()
        ok(#w.callsNamed("HasClip")-before<=1,"one HasClip per tick")
    end
    local c=w.callsNamed("CopyClip")[1]; eq(table.concat(c,","),"3,5,3,8")
    w.clearCalls(); w.selectedRow=5; w.wire(cc(5,127)); press(20,w); w.wire(cc(5,0))
    for _=1,5 do w.tick() end
    eq(table.concat(w.callsNamed("InsertRows")[1],","),"6,1")
    eq(table.concat(w.callsNamed("CopyRow")[1],","),"5,6")
    w.clearCalls(); press(21,w); w.tick(4)
    eq(table.concat(w.callsNamed("DeleteClip")[1],","),"3,5")
    w.clearCalls(); w.wire(cc(5,127)); press(21,w); w.wire(cc(5,0)); w.tick(4)
    eq(#w.callsNamed("DeleteClip"),0,"no Shift delete")
    w.wire(cc(0x30,2)); press(20,w); press(21,w); w.tick(4)
    eq(#w.callsNamed("CopyClip"),0,"no edits on play side"); noErrors(w)
end)

test("v2 full column and missing selection never edit; failed copy is contained", function()
    local w=load({globalRows=4}); connect(w)
    for r=0,3 do w.setCell(0,r,1,2,false) end
    w.clearCalls(); press(20,w); w.tick(12)
    eq(#w.callsNamed("CopyClip"),0); eq(#w.callsNamed("InsertRows"),0)
    w.selectedRow=-1; press(21,w); w.tick(4); eq(#w.callsNamed("DeleteClip"),0)
    w.selectedRow=0; w.mpc.clipMatrix.HasClip=function() error("missing") end
    press(20,w); w.tick(10); eq(w.I.status().active,true)
    eq(w.I.errors()["clip.clip"],1)
end)

test("v2 playing Shift PLAY stops clips; stopped resumes; guarded jog neighbours", function()
    local w=load(); connect(w); w.clearCalls(); w.wire(cc(5,127))
    press(6,w); eq(#w.callsNamed("TogglePlay"),1)
    mock.set(w.mpc.sequencer.Playing,true); press(6,w); eq(#w.callsNamed("StopAllClips"),1)
    w.wire(cc(5,0)); press(6,w); eq(#w.callsNamed("TogglePlayStart"),1)
    mock.set(w.currentTrack.Index,1); press(23,w); w.tick(10)
    local names={}; for _,m in ipairs(ofCmd(w.takeSysex(),0x46)) do names[m:byte(5)]=m:sub(6) end
    eq(names[3],"Track 1"); eq(names[4],"Drum 001"); eq(names[5],"Track 3")
    w.mpc.tracks.normalTracks=nil; press(23,w); eq(w.I.status().active,true)
end)

test("v2 position: real loop pulses, <=8 reads/sec only playing, no catchup bursts", function()
    local w=load(); connect(w); w.clearCalls(); w.tick(50)
    eq(#w.callsNamed("PlayheadPosition"),0,"never reads while stopped")
    local times={}; w.mpc.sequencer.PlayheadPosition=function() times[#times+1]=w.now; return 2880 end
    w.loopStart=960; w.loopEnd=8640; mock.set(w.mpc.sequencer.Playing,true)
    for _=1,2 do w.wire(PING); w.tick(50) end
    ok(#times<=16,"at most 8 Hz")
    for i=2,#times do ok(times[i]-times[i-1]>=125,"no bursts") end
    local messages=w.takeSysex(); local p=lastOf(messages,0x4A); ok(p,"position sent")
    local function u28(m,i) local a,b,c,d=m:byte(i,i+3); return a+b*128+c*16384+d*2097152 end
    eq(u28(p,5),1920); eq(u28(p,9),7680)
    local before=#times; w.now=w.now+1000; w.tick(4); eq(#times,before+1,"one read after delay")
    mock.set(w.mpc.sequencer.Playing,false); w.tick(15); eq(#times,before+1)
    ok(lastOf(w.takeSysex(),0x4A),"cached position on stop")
    noErrors(w)
end)

test("v4 mode mapping is listened to, read once on activation and cleaned up", function()
    local w = load()
    local prop, reads = w.mpc.engineMode.CurrentMode, 0
    prop._onRead = function() reads = reads + 1 end
    eq(mock.listenerCount(prop), 0, "passive")
    connect(w)
    eq(reads, 1, "one activation read")
    eq(mock.listenerCount(prop), 1, "one listener")
    ok(rawget(prop, "_lon").abletonMoveSchwung, "listenOldNew with the normal name")
    for _, case in ipairs({{"Step Sequencer",1}, {"Track Mute",2}, {"Pad Mute",3}, {"Other",4}, {"Main Mode",0}}) do
        mock.set(prop, case[1]); w.tick(10)
        eq(decodeState(lastOf(w.takeSysex(),0x42)).mpcMode, case[2], case[1])
    end
    eq(reads, 1, "never polled")
    w.wire(HELLO); w.tick(10); eq(reads, 2, "HELLO reads once again")
    eq(mock.listenerCount(prop), 1, "no duplicate listener")
    w.wire(BYE); eq(mock.listenerCount(prop), 0, "BYE removes listener")
    connect(w); w.tick(175); eq(mock.listenerCount(prop), 0, "timeout removes listener")
    connect(w); w.dev.OnUnload(); eq(mock.listenerCount(prop), 0, "unload removes listener")
    noErrors(w)
end)

test("v4 STEP_SEQ press toggles modes; release never requests a mode", function()
    local w = load(); connect(w); w.clearCalls()
    for _, name in ipairs({"STEP_SEQ press", "STEP_SEQ release"}) do
        eq(w.wire(vector("move_to_mpc",name).wire), "script", "new CC mapped")
    end
    eq(#w.callsNamed("RequestModeChange"),1)
    eq(w.callsNamed("RequestModeChange")[1][1],"Step Sequencer")
    press(0x18,w)
    eq(#w.callsNamed("RequestModeChange"),2)
    eq(w.callsNamed("RequestModeChange")[2][1],"Main Mode")
    for _, name in ipairs({"Track Mute", "Pad Mute", "Other"}) do
        mock.set(w.mpc.engineMode.CurrentMode,name); press(0x18,w)
        eq(w.callsNamed("RequestModeChange")[#w.callsNamed("RequestModeChange")][1],"Step Sequencer")
    end
    noErrors(w)
end)

test("v4 STEP and NAV vectors override every clip and play mode, including Shift navigation", function()
    for mode = 0,3 do
        local w = load({engineMode="Step Sequencer"}); connect(w)
        if mode==3 then mock.set(w.currentTrack.Type,"Plugin") end
        w.wire(cc(0x30,mode)); w.wire(cc(0x32,2)); w.tick(10); w.takeSysex()
        local ox,oy,bank,position = w.ox,w.oy,w.I.status().padBank,w.position
        for _, v in ipairs(vectors.step_seq) do
            w.clearCalls(); w.wire(v.wire)
            if v.call == "stepSequencer.Tap" then
                local taps=w.callsNamed(v.call); eq(#taps,1,v.name); eq(taps[1][1],v.args[1]); eq(w.calls[#w.calls].name,v.call,"page mapping precedes tap")
                eq(w.I.status().qlinkPage,v.args[1]<=8 and 0 or 1)
            elseif v.call then
                eq(#w.calls,2,v.name); eq(w.calls[1].name,v.call..".Press"); eq(w.calls[2].name,v.call..".Release")
            else eq(#w.calls,0,v.name) end
        end
        for n=0,15 do press(0x20+n,w) end
        local taps=w.callsNamed("stepSequencer.Tap")
        eq(#taps,16,"all steps, presses only")
        for n=1,16 do eq(taps[n][1],n) end
        w.wire(cc(5,127)); w.clearCalls(); press(1,w); press(2,w); press(3,w); press(4,w)
        eq(#w.calls,4,"Shift nav still moves one bar")
        eq(w.calls[1].name,"stepSeqPrev.Press"); eq(w.calls[3].name,"stepSeqNext.Press")
        w.clearCalls(); press(0x27,w); eq(#w.calls,0,"shifted Step 8 is handled by Move"); press(0x2C,w)
        eq(#w.callsNamed("sixteenLevel.Press"),1,"common Shift layer retained")
        eq(#w.callsNamed("stepSequencer.Tap"),0,"Shift never taps steps")
        eq(w.ox,ox); eq(w.oy,oy); eq(w.I.status().padBank,bank); eq(w.position,position)
        w.tick(10)
        local msgs=w.takeSysex()
        local subtitle
        for _, m in ipairs(ofCmd(msgs,0x46)) do if m:byte(5)==1 then subtitle=m:sub(6) end end
        -- The subtitle was already delivered in the initial Step Seq dump.
        w.wire(cc(0x33,127)); w.tick(10)
        msgs=w.takeSysex()
        local state=decodeState(lastOf(msgs,0x42)); eq(state.canMove,3); eq(state.mpcMode,1)
        for _, m in ipairs(ofCmd(msgs,0x46)) do if m:byte(5)==1 then subtitle=m:sub(6) end end
        eq(subtitle,mode==3 and "Plugin" or "Drum")
        noErrors(w)
    end
end)

test("v4 step lights use zero-based properties each tick, solid, diffed and paced", function()
    for mode=0,3 do
        local w=load({engineMode="Step Sequencer"}); connect(w)
        if mode==3 then mock.set(w.currentTrack.Type,"Plugin") end
        w.wire(cc(0x30,mode)); w.wire(cc(0x32,2)); w.tick(10); w.takeSysex()
        -- The MPC's own bank (B here), not the Move's bank pair (C|D), holds
        -- the step lights. CurrentBank is read on entry and once a second.
        local bankReads=0
        w.pads.CurrentBank=setmetatable({}, {__index=function(_,k) if k=="value" then bankReads=bankReads+1; return 1 end end})
        mock.set(w.mpc.engineMode.CurrentMode,"Main Mode"); mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer")
        eq(bankReads,1,"bank read on entering Step Seq")
        w.pads.LightRGBColor=function() error("expensive colour query") end
        local reads=0
        w.pads.virtual=setmetatable({}, {__index=function(_,vp)
            assert(vp>=16 and vp<32,"must use the MPC bank, zero-based")
            reads=reads+1
            return {Colour={value=w.vpadColour[vp] or 0}}
        end})
        w.vpadColour[16]=0xFF0000; w.vpadColour[17]=0; w.vpadColour[18]=0x00FF00
        -- Force black -> note/empty/playhead as one run, then compare the vector.
        w.wire(cc(0x33,127)); w.tick(10); w.takeSysex()
        eq(reads,160,"sixteen properties per tick including refresh")
        w.vpadColour[16]=0; w.vpadColour[17]=0xFF0000; w.vpadColour[18]=0
        w.tick(); local changed=decodeRuns(w.takeSysex(),0x45)
        ledEq(changed[0],0,0,0,0); ledEq(changed[1],127,0,0,0); ledEq(changed[2],0,0,0,0)
        w.vpadColour[16]=0xFF0000; w.vpadColour[17]=0; w.vpadColour[18]=0x00FF00
        w.tick()
        bytesEq(lastOf(w.takeSysex(),0x45),body(vector("mpc_to_move","steps 0..2: Step Seq note, empty, playhead").wire))
        w.tick(10); eq(#ofCmd(w.takeSysex(),0x45),0,"unchanged lights silent")
        for _,n in pairs(w.sysexPerTick) do ok(n<=4,"pacing") end
        ok(bankReads<=2,"bank read at most once a second, never per tick: "..bankReads)
        noErrors(w)
    end
end)

test("v4 a Move pad in Step Seq picks the lane through Pad Sel and writes no step", function()
    local w=load(); connect(w)
    w.wire(cc(0x30,2)); w.tick(10)
    mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer"); w.tick(10); w.takeSysex()
    w.clearCalls()
    w.wire({0x9F,1,100}); w.wire({0x8F,1,0}); w.tick(20)
    local names={}
    for _,c in ipairs(w.calls) do
        if c.name:find("fKey4") or c.name:find("Tap") or c.name=="pads.Press" or c.name:find("stepSequencer") then names[#names+1]=c.name end
    end
    eq(table.concat(names," "),"fKey4.Press fKey4.Release pads.Press fKey4.Press fKey4.Release")
    for _,c in ipairs(w.calls) do if c.name=="pads.Press" then eq(c.args[1],2,"pad functions are 1-based") end end
    eq(w.padSel,false,"Pad Sel left off")
    local text
    for _, m in ipairs(ofCmd(w.takeSysex(),0x46)) do if m:byte(5)==2 then text=m:sub(6) end end
    eq(text,"Lane A02")
    for _, m in ipairs(ofCmd(w.takeSysex(),0x45)) do error("no yellow step lights") end
    mock.set(w.mpc.engineMode.CurrentMode,"Main Mode"); w.tick(5); w.clearCalls()
    noErrors(w)
end)

local function laneTexts(msgs)
    local out={}
    for _,m in ipairs(ofCmd(msgs,0x46)) do if m:byte(5)==2 then out[#out+1]=m:sub(6) end end
    return out
end

local function enterStepSeq(w)
    w.wire(cc(0x30,2)); w.tick(10)
    w.takeSysex(); w.clearCalls()
    mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer")
end

local function noPadSelCalls(w)
    eq(#w.callsNamed("fKey4.Press"),0,"no Pad Sel press")
    eq(#w.callsNamed("pads.Press"),0,"no pad press")
    eq(#w.callsNamed("stepSequencer.Tap"),0,"no step Tap")
end

test("lane poll on entering Step Seq sends @Lane A10 from LastHitPad, with no press or Tap", function()
    local w=load({lanePoll=true}); connect(w)
    w.lastHitPad=10
    enterStepSeq(w); w.tick(30)
    local texts=laneTexts(w.takeSysex())
    eq(#texts,1); eq(texts[1],"@Lane A10")
    noPadSelCalls(w)
    ok(#w.callsNamed("pads.LastHitPad")>=1,"LastHitPad was read")
    noErrors(w)
end)

test("lane poll maps pad 19 to B03 and sends nothing for 0, 129, nil or a non-number", function()
    local w=load({lanePoll=true}); connect(w)
    w.lastHitPad=19
    enterStepSeq(w); w.tick(30)
    local texts=laneTexts(w.takeSysex())
    eq(texts[#texts],"@Lane B03"); eq(#texts,1)
    noErrors(w)
    for _,bad in ipairs({0,129,"x",false,{}}) do
        local w2=load({lanePoll=true}); connect(w2)
        w2.lastHitPad=bad
        enterStepSeq(w2); w2.tick(30)
        eq(#laneTexts(w2.takeSysex()),0,"no lane text for "..tostring(bad))
        ok(#w2.callsNamed("pads.LastHitPad")>=1)
        noErrors(w2)
    end
    local w3=load({lanePoll=true}); connect(w3)
    w3.lastHitPad=nil
    enterStepSeq(w3); w3.tick(30)
    eq(#laneTexts(w3.takeSysex()),0,"no lane text for nil")
    noErrors(w3)
end)

test("lane poll follows a changed pad, never re-sends an unchanged one, and reads at most once per LANE_POLL_MS", function()
    local w=load({lanePoll=true}); connect(w)
    w.lastHitPad=3
    enterStepSeq(w); w.tick(30)
    eq(laneTexts(w.takeSysex())[1],"@Lane A03")
    w.clearCalls(); w.tick(50) -- 1000 ms at 20 ms per tick
    eq(#laneTexts(w.takeSysex()),0,"unchanged value not re-sent")
    local reads=#w.callsNamed("pads.LastHitPad")
    local maxReads=1000//w.I.cfg.LANE_POLL_MS+1
    ok(reads>=1 and reads<=maxReads,"reads in 1000 ms: "..reads.." (max "..maxReads..")")
    w.lastHitPad=22
    w.tick(math.ceil(w.I.cfg.LANE_POLL_MS/20)+2)
    local texts=laneTexts(w.takeSysex())
    eq(#texts,1); eq(texts[1],"@Lane B06")
    noErrors(w)
end)

test("lane poll re-sends on a track-name change in Step Seq and polls nothing outside it", function()
    local w=load({lanePoll=true}); connect(w)
    w.lastHitPad=5
    w.wire(cc(0x30,2)); w.tick(10)
    mock.set(w.currentTrack.Name,"Other 001"); w.tick(30)
    eq(#w.callsNamed("pads.LastHitPad"),0,"Main: not polled")
    eq(#laneTexts(w.takeSysex()),0,"Main: nothing sent")
    for _,m in ipairs({"Track Mute","Pad Mute"}) do
        w.wire(PING); mock.set(w.mpc.engineMode.CurrentMode,m); w.tick(40)
        eq(#w.callsNamed("pads.LastHitPad"),0,m..": not polled")
        eq(#laneTexts(w.takeSysex()),0,m..": nothing sent")
        mock.set(w.mpc.engineMode.CurrentMode,"Main Mode"); w.tick(10); w.takeSysex()
    end
    mock.set(w.mpc.engineMode.CurrentMode,"Main Mode"); w.tick(10)
    w.wire(PING); mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer"); w.tick(30)
    eq(laneTexts(w.takeSysex())[1],"@Lane A05")
    w.wire(PING); w.tick(30); eq(#laneTexts(w.takeSysex()),0)
    mock.set(w.currentTrack.Name,"Drum 002"); w.tick(30)
    local texts=laneTexts(w.takeSysex())
    eq(texts[#texts],"@Lane A05","same lane re-sent after the track change")
    mock.set(w.mpc.engineMode.CurrentMode,"Main Mode"); w.tick(10); w.clearCalls()
    mock.set(w.currentTrack.Name,"Drum 003"); w.tick(30)
    eq(#w.callsNamed("pads.LastHitPad"),0,"outside Step Seq: not polled")
    eq(#laneTexts(w.takeSysex()),0)
    noErrors(w)
end)

test("lane poll re-sends the lane on leaving and re-entering Step Seq", function()
    local w=load({lanePoll=true}); connect(w)
    w.lastHitPad=8
    enterStepSeq(w); w.tick(30)
    eq(laneTexts(w.takeSysex())[1],"@Lane A08")
    mock.set(w.mpc.engineMode.CurrentMode,"Main Mode"); w.tick(20); w.takeSysex()
    mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer"); w.tick(30)
    local texts=laneTexts(w.takeSysex())
    eq(#texts,1); eq(texts[1],"@Lane A08")
    noErrors(w)
end)

test("lane poll pauses during a Move-pad lane pick and resumes after it", function()
    local w=load({lanePoll=true}); connect(w)
    w.lastHitPad=1
    enterStepSeq(w); w.tick(30); w.takeSysex(); w.clearCalls()
    w.wire({0x9F,1,100}); w.wire({0x8F,1,0})
    local during=0
    for _=1,40 do
        local before=#w.callsNamed("pads.LastHitPad")
        w.tick(1)
        if #w.callsNamed("pads.Press")==0 then during=during+(#w.callsNamed("pads.LastHitPad")-before) end
    end
    eq(#w.callsNamed("pads.Press"),1,"the pick tapped once")
    eq(during,0,"no LastHitPad before the Tap")
    local texts=laneTexts(w.takeSysex())
    -- The press is a hit, so LastHitPad follows it (seventh bench) and the
    -- resumed poll reports the same lane.
    eq(table.concat(texts," "),"Lane A02 @Lane A02","pick, then the poll resumed")
    w.lastHitPad=3; w.clearCalls(); w.tick(30)
    texts=laneTexts(w.takeSysex())
    eq(#texts,1); eq(texts[1],"@Lane A03","poll still running")
    noErrors(w)
end)

test("a Move connecting while the MPC is already in Step Seq gets the lane", function()
    local w=load({lanePoll=true})
    w.lastHitPad=12
    mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer"); w.tick(10)
    local texts=laneTexts(connect(w))
    eq(texts[#texts],"@Lane A12")
    noErrors(w)
end)

test("with LANE_POLL false LastHitPad is never called", function()
    local w=load(); connect(w)
    eq(w.I.cfg.LANE_POLL,false)
    w.lastHitPad=10
    enterStepSeq(w); w.tick(60)
    mock.set(w.currentTrack.Name,"Drum 002"); w.tick(30)
    eq(#w.callsNamed("pads.LastHitPad"),0)
    eq(#laneTexts(w.takeSysex()),0)
    noErrors(w)
end)

test("v4 bank B lane select changes MPC bank before Tap and reads bank B lights", function()
    local w=load(); w.I.cfg.LANE_OTHER_BANK=true; connect(w); w.wire(cc(0x30,2)); w.tick(10)
    mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer"); w.tick(10); w.takeSysex(); w.clearCalls()
    local tapTick
    w.wire({0x9F,5,100}); w.wire({0x8F,5,0})
    for i=1,20 do
        w.tick()
        if #w.callsNamed("pads.SetCurrentBank")>0 and not tapTick then
            eq(#w.callsNamed("pads.Press"),0,"bank switch waits before Tap")
            tapTick=i
        elseif #w.callsNamed("pads.Press")>0 then
            ok(i>tapTick,"Tap occurs on a later tick"); break
        end
    end
    w.tick(20)
    local names={}
    for _,c in ipairs(w.calls) do
        if c.name=="pads.SetCurrentBank" or c.name=="pads.Press" then names[#names+1]=c.name end
    end
    eq(table.concat(names," "),"pads.SetCurrentBank pads.Press")
    eq(w.callsNamed("pads.SetCurrentBank")[1][1],1)
    eq(w.callsNamed("pads.Press")[1][1],2)
    eq(w.pads.CurrentBank.value,1); eq(w.padSel,false)
    w.takeSysex()
    w.pads.virtual=setmetatable({}, {__index=function(_,vp)
        assert(vp>=16 and vp<32,"step lights must read bank B")
        return {Colour={value=w.vpadColour[vp] or 0}}
    end})
    w.vpadColour[16]=0xFF0000; w.vpadColour[17]=0; w.vpadColour[18]=0x00FF00
    w.tick()
    local lights=decodeRuns(w.takeSysex(),0x45)
    ledEq(lights[0],127,0,0,0); ledEq(lights[2],0,127,0,0)
    noErrors(w)
end)

test("v5 lane select waits for the MPC bank to read back before Tap", function()
    local w=load(); w.I.cfg.LANE_OTHER_BANK=true; connect(w); w.wire(cc(0x30,2)); w.tick(10)
    mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer"); w.tick(10); w.takeSysex(); w.clearCalls()
    w.bankDelay=4
    w.wire({0x9F,5,100}); w.wire({0x8F,5,0})
    local due, tapTick
    for _=1,40 do
        w.tick()
        if not due and w.pendingBank then due=w.pendingBank.due end
        if #w.callsNamed("pads.Press")>0 then tapTick=w.tickNo; break end
    end
    ok(due,"bank change requested"); ok(tapTick,"Tap happened")
    ok(tapTick>=due,"Tap waits for the read-back")
    eq(w.pads.CurrentBank.value,1,"bank read back as B")
    w.tick(20)
    eq(#w.callsNamed("pads.SetCurrentBank"),1,"asked once, then only re-read")
    eq(#w.callsNamed("pads.Press"),1)
    eq(w.callsNamed("pads.Press")[1][1],2)
    eq(w.padSel,false); noErrors(w)
end)

test("v5 lane select gives up after 15 reads when the bank never moves", function()
    local w=load(); w.I.cfg.LANE_OTHER_BANK=true; connect(w); w.wire(cc(0x30,2)); w.tick(10)
    mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer"); w.tick(10); w.takeSysex(); w.clearCalls()
    w.bankDelay="never"
    w.wire({0x9F,5,100}); w.wire({0x8F,5,0})
    w.tick(60)
    eq(#w.callsNamed("pads.SetCurrentBank"),1,"asked once")
    eq(#w.callsNamed("pads.Press"),0,"never tapped the wrong bank")
    eq(#w.callsNamed("fKey4.Press"),0)
    local found
    for _,m in ipairs(ofCmd(w.takeSysex(),0x46)) do
        if m:byte(5)==2 and m:sub(6)=="No lane" then found=true end
    end
    ok(found,"TEXT slot 2 says No lane")
    -- the job is cleared: a later pad press starts a new one
    w.bankDelay=nil; w.clearCalls()
    w.wire({0x9F,5,100}); w.wire({0x8F,5,0}); w.tick(30)
    eq(#w.callsNamed("pads.Press"),1,"next press works once the bank moves")
    noErrors(w)
end)

test("STATE available bit 4 (marks): every track but a mixer track; bits 0-3 untouched; aux separate", function()
    local w=load(); connect(w)
    local base
    for _,c in ipairs({{"Drum",true,false},{"Plugin",true,false},{"Keygroup",true,false},{"Audio",true,true},
                       {"Submix",false,true},{"Send",false,true},{"Output",false,true},{"Input",false,true}}) do
        mock.set(w.currentTrack.Type,c[1]); mock.set(w.currentTrack.Name,"T")
        w.wire(cc(0x33,127)); w.tick(10)
        local st=lastOf(w.takeSysex(),0x42)
        eq(st:byte(16)&16,c[2] and 16 or 0,c[1].." marks")
        eq(st:byte(14)&16,c[3] and 16 or 0,c[1].." aux")
        base=base or st:byte(16)&15
        eq(st:byte(16)&15,base,c[1].." bits 0-3 unchanged by marks")
    end
    ok(base>0,"the mock has some of metronome/16 Levels/Full Level/quantise")
    noErrors(w)
end)

-- Step Seq with LANE_OTHER_BANK false: only the MPC's current bank is usable.
local function bankSeqWorld(w)
    for i=0,31 do w.vpadColour[i]=0xFF0000 end
    w.wire(cc(0x30,2)); w.tick(10); w.takeSysex()
    mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer"); w.tick(10)
    return decodeRuns(w.takeSysex(),0x43)
end
local function tickAlive(w,n) -- the Move's PING every 50 ticks (1 s), or the 3.5 s heartbeat ends the session
    while n>0 do local k=math.min(n,50); w.tick(k); n=n-k; w.wire(PING) end
end
local function bankBPad(p) return (p%8)>=4 end
local function noLaneActivity(w)
    for _,n in ipairs({"fKey4.Press","pads.Press","pads.SetCurrentBank","stepSequencer.Tap"}) do
        eq(#w.callsNamed(n),0,"no "..n)
    end
    for _,t in ipairs(laneTexts(w.takeSysex())) do ok(false,"unexpected text: "..t) end
end

test("Step Seq, LANE_OTHER_BANK false, MPC bank A: bank B pads sent off, cached A pads kept", function()
    local w=load(); connect(w)
    eq(w.I.cfg.LANE_OTHER_BANK,false)
    local pads=bankSeqWorld(w)
    for p=0,31 do
        if bankBPad(p) then ledEq(pads[p],0,0,0,0,"B pad "..p) end
    end
    w.wire(cc(0x33,127)); w.tick(10)
    pads=decodeRuns(w.takeSysex(),0x43)
    for p=0,31 do
        if bankBPad(p) then ledEq(pads[p] or {0,0,0,0},0,0,0,0,"B pad (refresh) "..p)
        else ledEq(pads[p],127,0,0,0,"A pad "..p) end
    end
    noErrors(w)
end)

test("Step Seq, LANE_OTHER_BANK false: a bank B press does nothing at all, a bank A press picks the lane", function()
    local w=load(); connect(w)
    bankSeqWorld(w); w.clearCalls()
    eq(w.wire({0x9F,5,100}),"script"); w.wire({0x8F,5,0}); w.tick(40)
    noLaneActivity(w)
    w.lastHitPad=5 -- the lane is elsewhere, so the pick has something to do
    w.wire({0x9F,0,100}); w.wire({0x8F,0,0}); w.tick(40)
    ok(#w.callsNamed("fKey4.Press")>=1,"bank A press starts the Pad Sel flow")
    eq(#w.callsNamed("pads.SetCurrentBank"),0)
    eq(#w.callsNamed("pads.Press"),1); eq(w.callsNamed("pads.Press")[1][1],1)
    noErrors(w)
end)

test("Step Seq, LANE_OTHER_BANK false: the MPC moving to bank B swaps which pads are live within a second", function()
    local w=load(); connect(w)
    bankSeqWorld(w); w.clearCalls()
    mock.set(w.pads.CurrentBank,1)
    tickAlive(w,100)
    local pads=decodeRuns(w.takeSysex(),0x43)
    for p=0,31 do
        if bankBPad(p) then ledEq(pads[p],127,0,0,0,"B pad back "..p)
        else ledEq(pads[p],0,0,0,0,"A pad off "..p) end
    end
    w.clearCalls()
    w.wire({0x9F,0,100}); w.wire({0x8F,0,0}); w.tick(40)
    noLaneActivity(w)
    w.wire({0x9F,5,100}); w.wire({0x8F,5,0}); w.tick(40)
    eq(#w.callsNamed("pads.SetCurrentBank"),0,"already in bank B")
    eq(#w.callsNamed("pads.Press"),1); eq(w.callsNamed("pads.Press")[1][1],2)
    noErrors(w)
end)

test("Step Seq, LANE_OTHER_BANK false: leaving Step Seq restores all 32 pads", function()
    local w=load(); connect(w)
    bankSeqWorld(w)
    for i=0,31 do w.vpadColour[i]=0x00FF00 end
    mock.set(w.mpc.engineMode.CurrentMode,"Main Mode"); w.tick(10)
    local pads=decodeRuns(w.takeSysex(),0x43)
    for p=0,31 do ledEq(pads[p],0,127,0,0,"restored "..p) end
    noErrors(w)
end)

test("Step Seq, LANE_OTHER_BANK false: with the MPC bank unreadable nothing is hidden or ignored", function()
    local w=load(); connect(w)
    for i=0,31 do w.vpadColour[i]=0xFF0000 end
    w.wire(cc(0x30,2)); w.tick(10); w.takeSysex()
    w.pads.CurrentBank=setmetatable({}, {__index=function() error("unreadable") end})
    mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer"); w.tick(10); w.takeSysex()
    eq(w.I.seq and w.I.seq.bank or nil,nil)
    w.wire(cc(0x33,127)); w.tick(10)
    local pads=decodeRuns(w.takeSysex(),0x43)
    for p=0,31 do ledEq(pads[p],127,0,0,0,"visible "..p) end
    w.clearCalls()
    w.wire({0x9F,5,100}); w.wire({0x8F,5,0}); w.tick(10)
    ok(#w.callsNamed("fKey4.Press")+#w.callsNamed("pads.SetCurrentBank")>=1,"a bank B press is still tried")
end)

test("v5 MUTE walks Main -> Track Mute -> Pad Mute (drum) -> Main", function()
    local w=load(); connect(w); w.tick(2); w.clearCalls()
    local function mode() return w.mpc.engineMode.CurrentMode.value end
    press(0x19,w); w.tick(2); eq(mode(),"Track Mute")
    press(0x19,w); w.tick(2); eq(mode(),"Pad Mute")
    press(0x19,w); w.tick(2); eq(mode(),"Main Mode")
    local names={}
    for _,c in ipairs(w.callsNamed("RequestModeChange")) do names[#names+1]=c[1] end
    eq(table.concat(names,","),"Track Mute,Pad Mute,Main Mode")
    noErrors(w)
end)

test("v5 MUTE on a non-drum track goes Track Mute -> Main, release does nothing", function()
    local w=load(); connect(w); mock.set(w.currentTrack.Type,"Synth"); w.tick(2); w.clearCalls()
    local function mode() return w.mpc.engineMode.CurrentMode.value end
    w.wire(cc(0x19,127)); w.tick(2); eq(mode(),"Track Mute")
    w.wire(cc(0x19,0)); w.tick(2); eq(#w.callsNamed("RequestModeChange"),1,"release sends nothing")
    press(0x19,w); w.tick(2); eq(mode(),"Main Mode")
    eq(#w.callsNamed("RequestModeChange"),2)
    noErrors(w)
end)

test("v5 ARRANGE presses the arrange button once, on press only", function()
    local w=load(); connect(w); w.clearCalls()
    w.wire(cc(0x1A,127)); eq(#w.callsNamed("arrange.Press"),1)
    w.wire(cc(0x1A,0)); eq(#w.callsNamed("arrange.Press"),1)
    noErrors(w)
end)

test("v5 AUTOMATION press toggles Read <-> Write, Off goes to Read, Shift is ignored", function()
    local w=load(); connect(w)
    local p=w.mpc.project.GlobalAutomationFilterType
    press(0x16,w); eq(p.value,"Write")
    press(0x16,w); eq(p.value,"Read")
    mock.set(p,"Off"); press(0x16,w); eq(p.value,"Read")
    w.wire(cc(5,127)); press(0x16,w); eq(p.value,"Write"); w.wire(cc(5,0))
    w.wire(cc(0x16,0)); eq(p.value,"Write","release alone changes nothing")
    eq(#w.callsNamed("AdvanceGlobalAutomationFilterType"),0)
    noErrors(w)
end)

test("v4 PADS freeze and full refresh retain cached Main colours, then resume", function()
    local w=load(); w.I.cfg.LANE_OTHER_BANK=true -- about the Main cache, not the bank restriction
    connect(w)
    for i=0,31 do w.vpadColour[i]=0xFF0000 end
    w.wire(cc(0x30,2)); w.tick(10); w.takeSysex()
    mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer")
    for i=0,31 do w.vpadColour[i]=0x00FF00 end
    w.tick(30)
    eq(#ofCmd(w.takeSysex(),0x43),0,"no copied step colours")
    w.wire(cc(0x33,127)); w.tick(10)
    local pads=decodeRuns(w.takeSysex(),0x43)
    for i=0,31 do ledEq(pads[i],127,0,0,0,"cached Main pad "..i) end
    eq(w.wire({0x9F,0,100}),"script","in Step Seq the script takes pad notes (lane select)")
    mock.set(w.mpc.engineMode.CurrentMode,"Main Mode"); w.tick(10)
    eq(w.wire({0x9F,0,100}),"vpad","native pad binding back in Main")
    local msgs=w.takeSysex(); pads=decodeRuns(msgs,0x43)
    for i=0,31 do ledEq(pads[i],0,127,0,0,"resumed "..i) end
    eq(decodeState(lastOf(msgs,0x42)).canMove,2,"normal bank bounds restored")
    for i,led in pairs(decodeRuns(msgs,0x45)) do ledEq(led,0,0,0,0,"normal steps "..i) end
    eq(#ofCmd(msgs,0x45),2,"complete normal STEPS refresh")
    for _, name in ipairs({"Track Mute","Pad Mute","Other"}) do
        mock.set(w.mpc.engineMode.CurrentMode,name)
        for i=0,31 do w.vpadColour[i]=0x0000FF end
        w.wire(cc(0x33,127)); w.tick(10)
        ledEq(decodeRuns(w.takeSysex(),0x43)[0],0,0,127,0,"non-Step modes keep v3 pads")
    end
    noErrors(w)
end)

test("v4 refresh in Step Seq skips pads never read in Main, including bank changes", function()
    local w=load({engineMode="Step Sequencer",noClipWorkflow=true})
    w.I.cfg.LANE_OTHER_BANK=true -- about the Main cache, not the bank restriction
    local msgs=connect(w)
    eq(#ofCmd(msgs,0x43),0,"no Main cache yet")
    w.wire(cc(0x32,6)); w.wire(cc(0x33,127)); w.tick(10)
    eq(#ofCmd(w.takeSysex(),0x43),0,"unread bank stays untouched")
    mock.set(w.mpc.engineMode.CurrentMode,"Main Mode"); w.vpadColour[96]=0xFF0000; w.tick(10)
    ledEq(decodeRuns(w.takeSysex(),0x43)[0],127,0,0,0,"copy resumes")
    mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer"); w.wire(cc(0x32,5)); w.wire(cc(0x33,127)); w.tick(10)
    local pads=decodeRuns(w.takeSysex(),0x43)
    eq(pads[0],nil,"unread left bank omitted")
    ledEq(pads[4],127,0,0,0,"cached right bank survives")
    noErrors(w)
end)

test("v4 leaving Step Seq restores steps, canMove, subtitle and step actions in all modes", function()
    for mode=0,3 do
        local w=load(); connect(w)
        if mode==3 then mock.set(w.currentTrack.Type,"Plugin") end
        w.wire(cc(0x30,mode)); w.tick(10)
        local before=w.takeSysex()
        w.wire(cc(0x33,127)); w.tick(10); before=w.takeSysex()
        mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer"); w.tick(10); w.takeSysex()
        mock.set(w.mpc.engineMode.CurrentMode,"Main Mode"); w.tick(10)
        local after=w.takeSysex()
        eq(decodeState(lastOf(after,0x42)).canMove,decodeState(lastOf(before,0x42)).canMove)
        eq(#ofCmd(after,0x45),2,"full normal STEPS")
        local want,got=decodeRuns(before,0x45),decodeRuns(after,0x45)
        for i=0,15 do ledEq(got[i],table.unpack(want[i])) end
        local normalSubtitle
        for _,m in ipairs(ofCmd(after,0x46)) do if m:byte(5)==1 then normalSubtitle=m:sub(6) end end
        eq(normalSubtitle,nil,"unchanged track description is not resent on mode exit")
        for _, engine in ipairs({"Main Mode","Track Mute","Pad Mute","Other"}) do
            mock.set(w.mpc.engineMode.CurrentMode,engine); w.clearCalls()
            press(0x20,w); press(0x21,w)
            eq(#w.callsNamed("stepSequencer.Tap"),0,"outside Step Seq")
            eq(#w.callsNamed("SelectTrack"),mode==0 and 1 or 0)
            eq(#w.callsNamed("StopClipsOnTrack"),mode==0 and 1 or 0)
            eq(#w.callsNamed("TriggerRow"),mode==1 and 1 or 0,"Transposed: step 1 launches scene 1")
        end
        noErrors(w)
    end
end)

test("v4 missing mode, step and nav APIs stay inside safety wrappers", function()
    local w=load(); w.mpc.engineMode=nil
    local msgs=connect(w)
    eq(decodeState(lastOf(msgs,0x42)).mpcMode,4,"unreadable")
    press(0x18,w); eq(w.I.status().active,true)
    w=load({engineMode="Step Sequencer"}); connect(w)
    w.mpc.controlSurface.stepSequencer=nil
    w.mpc.controlSurface.stepSeqPrev=nil
    w.mpc.controlSurface.stepSeqNext.Press=function() error("missing") end
    press(0x20,w); press(1,w); press(2,w); w.tick(10)
    eq(w.I.status().active,true)
    eq(#w.callsNamed("stepSeqNext.Release"),1,"release attempted even if press fails")
    ok(w.I.errors()["stepSequencer.Tap"])
    ok(w.I.errors()["stepSeqPrev.Press"])
end)

test("DUP_CLIP duplicates in every mode and Shift state, selects on a later tick", function()
    for mode=0,3 do for _,shift in ipairs({false,true}) do
        local w=load(); connect(w)
        if mode==3 then mock.set(w.currentTrack.Type,"Plugin") end
        w.wire(cc(0x30,mode)); eq(w.I.status().mode,mode)
        w.setCell(2,3,0xFF0000,2); w.setCell(2,4,0xFF0000,2)
        w.selectedCol,w.selectedRow=2,3
        if shift then w.wire(cc(5,127)) end
        w.clearCalls(); w.takeSysex()
        w.wire(vector("move_to_mpc","DUP_CLIP release").wire); w.tick()
        eq(#w.callsNamed("CopyClip"),0,"release is inert")
        w.wire(vector("move_to_mpc","DUP_CLIP press").wire)
        eq(#w.callsNamed("CopyClip"),0,"job is asynchronous")
        for _=1,20 do
            w.tick()
            if #w.callsNamed("CopyClip")>0 then break end
        end
        local c=w.callsNamed("CopyClip"); eq(#c,1)
        eq(c[1][1],2); eq(c[1][2],3); eq(c[1][3],2); eq(c[1][4],5,"next empty below")
        eq(#w.callsNamed("clipMatrix.SelectClip"),0,"not on copy tick")
        w.tick(); local selected=w.callsNamed("clipMatrix.SelectClip"); eq(#selected,1); eq(selected[1][1],2); eq(selected[1][2],5)
        w.tick(10)
        local found=false
        for _,m in ipairs(ofCmd(w.takeSysex(),0x46)) do if m:byte(5)==2 and m:sub(6)=="Clip duplicated" then found=true end end
        ok(found,"duplicate feedback"); noErrors(w)
    end end
end)

test("MAIN closes Sixteen Level only, otherwise requests Main, release inert", function()
    for _,popup in ipairs({"No Popup","Sixteen Level","Other"}) do
        for _,shift in ipairs({false,true}) do
            local w=load({engineMode="Step Sequencer"}); connect(w)
            local prop=w.mpc.engineMode.CurrentPopup
            ok(next(prop._lon),"popup uses listenOldNew"); eq(next(prop._l),nil)
            mock.set(prop,popup); if shift then w.wire(cc(5,127)) end
            w.clearCalls(); w.takeSysex(); w.wire(cc(0x33,127)); w.tick(10)
            eq(lastOf(w.takeSysex(),0x42):byte(14)&8,popup=="Sixteen Level" and 8 or 0)
            w.wire(vector("move_to_mpc","MAIN release").wire)
            eq(#w.callsNamed("RequestModeChange"),0); eq(#w.callsNamed("sixteenLevel.Press"),0)
            w.wire(vector("move_to_mpc","MAIN press").wire)
            eq(#w.callsNamed("sixteenLevel.Press"),popup=="Sixteen Level" and 1 or 0)
            local calls=w.callsNamed("RequestModeChange")
            eq(#calls,popup=="Sixteen Level" and 0 or 1)
            if #calls>0 then eq(calls[1][1],"Main Mode") end
            noErrors(w)
        end
    end
end)

test("popup listener emits changed STATE without a refresh request", function()
    local w=load(); connect(w)
    for _,popup in ipairs({"Sixteen Level","Other","Sixteen Level","No Popup"}) do
        mock.set(w.mpc.engineMode.CurrentPopup,popup); w.tick(2)
        local state=lastOf(w.takeSysex(),0x42); ok(state,"listener dirties STATE")
        eq(state:byte(14)&8,popup=="Sixteen Level" and 8 or 0)
    end
    noErrors(w)
end)

test("aux STATE, unnumbered title and 'Return' by track type (device: Submix, Send, Output)", function()
    local w=load(); connect(w)
    for _,c in ipairs({{"Drum",false,"Drum"},{"Submix",true,"Submix"},{"Send",true,"Return"},{"Output",true,"Output"},{"Keygroup",false,"Keygroup"}}) do
        mock.set(w.currentTrack.Type,c[1]); mock.set(w.currentTrack.Index,3); mock.set(w.currentTrack.Name,"Bus")
        w.wire(cc(0x33,127)); w.tick(10); local msgs=w.takeSysex()
        eq(lastOf(msgs,0x42):byte(14)&16,c[2] and 16 or 0,c[1])
        local title,sub
        for _,m in ipairs(ofCmd(msgs,0x46)) do if m:byte(5)==0 then title=m:sub(6) elseif m:byte(5)==1 then sub=m:sub(6) end end
        eq(title,c[2] and "Bus" or "4: Bus",c[1]); eq(sub,c[3],c[1])
    end
    noErrors(w)
end)

test("Step Seq selects either normal Q-Link page before tap and refuses column pages with STATE", function()
    local w=load({engineMode="Step Sequencer"}); connect(w)
    for _,n in ipairs({0,7,8,15,0}) do
        w.clearCalls(); press(0x20+n,w)
        eq(w.I.status().qlinkPage,n<8 and 0 or 1)
        eq(w.callsNamed("stepSequencer.Tap")[1][1],n+1)
        eq(w.calls[#w.calls].name,"stepSequencer.Tap")
        for _,page in ipairs({2,3}) do
            w.tick(10); w.takeSysex(); w.wire(cc(0x31,page)); w.tick(2)
            eq(decodeState(lastOf(w.takeSysex(),0x42)).qlinkPage,n<8 and 0 or 1,"refused page answered")
        end
    end
    noErrors(w)
end)

test("v6 entering Step Seq on a column page falls to page 1", function()
    for _,page in ipairs({2,3}) do
        local w=load(); connect(w); w.wire(cc(0x31,page)); press(0x18,w); w.tick(2)
        eq(w.I.status().qlinkPage,0,"column pages are not offered in Step Seq")
        noErrors(w)
    end
end)

test("track descriptions use plugin preset or type in every view and MPC mode", function()
    for _,case in ipairs({{"Drum","Ignored","Drum"},{"Plugin","Warm Keys","Warm Keys"},{"Plugin","","Plugin"},{"Keygroup","Ignored","Keygroup"}}) do
        local w=load()
        mock.set(w.currentTrack.Type,case[1]); mock.set(w.currentTrack.PluginPresetName,case[2])
        connect(w)
        for mode=0,3 do
            w.wire(cc(0x30,mode))
            for _,engine in ipairs({"Main Mode","Step Sequencer"}) do
                mock.set(w.mpc.engineMode.CurrentMode,engine)
                press(0x33,w); w.tick(15)
                local desc
                for _,m in ipairs(ofCmd(w.takeSysex(),0x46)) do if m:byte(5)==1 then desc=m:sub(6) end end
                eq(desc,case[3],engine.." view "..mode)
            end
        end
        noErrors(w)
    end
end)

test("STATE mute reads current normal track and unreadable mute stays false without errors", function()
    local w=load()
    w.mpc.tracks.normalTracks[0]={Mute=mock.prop(true)}
    local msgs=connect(w)
    eq(lastOf(msgs,0x42):byte(14)&32,32)
    mock.set(w.mpc.tracks.normalTracks[0].Mute,false); w.tick(15)
    eq(lastOf(w.takeSysex(),0x42):byte(14)&32,0,"external mute change emits STATE")
    for _,entry in ipairs({{}, {Mute=setmetatable({}, {__index=function() error("unreadable") end})}}) do
        w.mpc.tracks.normalTracks[0]=entry; press(0x33,w); w.tick(15)
        eq(lastOf(w.takeSysex(),0x42):byte(14)&32,0)
        noErrors(w)
    end
    w.mpc.tracks.normalTracks[1]={Mute=mock.prop(true)}
    mock.set(w.currentTrack.Index,1); w.tick(15)
    eq(lastOf(w.takeSysex(),0x42):byte(14)&32,32,"current index selects mute")
    mock.set(w.currentTrack.Index,65); w.tick(15)
    eq(lastOf(w.takeSysex(),0x42):byte(14)&32,0,"aux missing entry")
    noErrors(w)
end)

test("solo follows named track, polls with arm at one second and contains getter failure", function()
    local w=load(); w.solo["Drum 001"]=true
    eq(lastOf(connect(w),0x42):byte(14)&64,64)
    w.clearCalls(); w.tick(20)
    eq(#w.callsNamed("GetSolo"),0,"no early poll")
    w.solo["Drum 001"]=false; w.tick(40)
    eq(#w.callsNamed("GetSolo"),1)
    eq(#w.callsNamed("GetTrackRecordArmed"),1,"same poll cadence")
    eq(lastOf(w.takeSysex(),0x42):byte(14)&64,0,"solo change emits STATE")
    w.solo.Lead=true; mock.set(w.currentTrack.Name,"Lead"); w.tick(15)
    eq(lastOf(w.takeSysex(),0x42):byte(14)&64,64)
    local calls=w.callsNamed("GetSolo"); eq(calls[#calls][1],"Lead")
    w.mpc.tracks.GetSolo=function() error("unavailable") end
    w.tick(60); noErrors(w)
end)

test("negative device clock sends Step Seq lights before and after lane selection", function()
    local w=load({clockOffset=-1702000000000}); eq(w.now,-2000000000)
    connect(w); w.wire(cc(0x30,2)); w.tick(10)
    mock.set(w.mpc.engineMode.CurrentMode,"Step Sequencer"); w.tick(10); w.takeSysex()
    w.vpadColour[0]=0xFF0000; w.tick(2)
    ok(#ofCmd(w.takeSysex(),0x45)>0,"STEPS before lane selection")
    w.wire({0x9F,1,100}); w.wire({0x8F,1,0}); w.tick(20)
    eq(#w.callsNamed("pads.Press"),1,"lane selected with negative clock")
    w.takeSysex(); w.vpadColour[0]=0x00FF00; w.tick(5)
    ok(#ofCmd(w.takeSysex(),0x45)>0,"STEPS after lane quiet period")
    noErrors(w)
end)

test("clock comparisons never use an or-zero deadline", function()
    local f=assert(io.open(SCRIPT)); local s=f:read("*a"); f:close()
    for line in s:gmatch("[^\n]+") do
        if line:match("or%s+0%s*%)") then
            ok(not line:find("nowMs()",1,true) and not line:match("%f[%a]now%f[%A]"),line)
        end
    end
end)

test("arm getter retries after a transient read failure", function()
    local w=load(); local reads=0
    w.mpc.tracks.GetTrackRecordArmed=function()
        reads=reads+1; if reads==1 then error("temporary") end; return true
    end
    connect(w); w.takeSysex(); w.tick(55)
    ok(reads>=2,"retried getter")
    eq(lastOf(w.takeSysex(),0x42):byte(14)&1,1,"armed reported")
    noErrors(w)
end)

test("mute modes force Pads for every track type and clear aux until exit", function()
    for _,kind in ipairs({"Drum","Plugin","Keygroup","Submix","Send","Output"}) do
        for _,engine in ipairs({"Track Mute","Pad Mute"}) do
            local w=load(); mock.set(w.currentTrack.Type,kind); connect(w)
            w.wire(cc(0x30,2)); w.tick(4)
            local own=kind=="Drum" and 2 or 3
            eq(w.I.status().mode,own)
            mock.set(w.mpc.engineMode.CurrentMode,engine); w.tick(10)
            local state=lastOf(w.takeSysex(),0x42)
            eq(decodeState(state).mode,2,kind); eq(state:byte(14)&16,0,"aux clear")
            mock.set(w.mpc.engineMode.CurrentMode,"Main Mode"); w.tick(10)
            eq(w.I.status().mode,own,"track mode restored")
            noErrors(w)
        end
    end
end)

test("track presses queue, cancel and clamp to 32, drained one per two ticks", function()
    for _,direction in ipairs({0x0A,0x0B}) do
        local w=load(); connect(w); w.clearCalls()
        local name=direction==0x0B and "currentTrack.Next" or "currentTrack.Previous"
        local opposite=direction==0x0B and 0x0A or 0x0B
        for _=1,40 do press(direction,w) end
        eq(#w.callsNamed(name),0,"handler does not call MPC")
        for _=1,5 do press(opposite,w) end
        for pair=1,27 do
            local before=#w.callsNamed(name); w.tick()
            eq(#w.callsNamed(name),before,"odd tick waits")
            w.tick()
            eq(#w.callsNamed(name),before+1,"one per two ticks")
        end
        w.tick(4); eq(#w.callsNamed(name),27,"clamped then cancelled")
        eq(#w.callsNamed(direction==0x0B and "currentTrack.Previous" or "currentTrack.Next"),0)
        press(direction,w); press(opposite,w); w.tick(4)
        eq(#w.callsNamed(name),27,"opposites cancel")
        noErrors(w)
    end
end)

test("DUP_CLIP selects globally then aperture-relative only when in view", function()
    for _,mode in ipairs({0,1}) do for _,inside in ipairs({false,true}) do
        local w=load(); connect(w); w.wire(cc(0x30,mode)); w.tick(4)
        w.ox,w.oy=2,3
        local col=inside and 3 or 12
        w.setCell(col,3,0xFF0000,2); w.selectedCol,w.selectedRow=col,3
        w.clearCalls(); press(0x1B,w)
        for _=1,20 do w.tick(); if #w.callsNamed("CopyClip")>0 then break end end
        eq(#w.callsNamed("SelectClip"),0,"no selection on copy tick")
        w.tick()
        local global=w.callsNamed("clipMatrix.SelectClip"); eq(#global,1)
        eq(global[1][1],col); eq(global[1][2],4)
        local relative=w.callsNamed("SelectClip"); eq(#relative,inside and 1 or 0)
        if inside then eq(relative[1][1],1); eq(relative[1][2],1) end
        local order={}; for _,c in ipairs(w.calls) do
            if c.name=="clipMatrix.SelectClip" or c.name=="SelectClip" then order[#order+1]=c.name end
        end
        eq(order[1],"clipMatrix.SelectClip"); noErrors(w)
    end end
end)

test("DUP_CLIP launches the copy only when the original was playing; Copy never does", function()
    for _,playing in ipairs({false,true}) do
        local w=load(); connect(w); w.wire(cc(0x30,0)); w.tick(4)
        w.setCell(3,3,0xFF0000,2); w.selectedCol,w.selectedRow=3,3
        if playing then w.playingClip={3,3} end
        w.clearCalls(); press(0x1B,w); w.tick(30)
        local t=w.callsNamed("clipMatrix.TriggerClip"); eq(#t,playing and 1 or 0)
        if playing then
            eq(t[1][1],3); eq(t[1][2],4)
            local order={}; for _,c in ipairs(w.calls) do
                if c.name=="CopyClip" or c.name=="clipMatrix.SelectClip" or c.name=="clipMatrix.TriggerClip" then order[#order+1]=c.name end
            end
            eq(table.concat(order," "),"CopyClip clipMatrix.SelectClip clipMatrix.TriggerClip")
        end
        noErrors(w)
    end
    local w=load(); connect(w); w.wire(cc(0x30,0)); w.tick(4)
    w.setCell(3,3,0xFF0000,2); w.selectedCol,w.selectedRow=3,3; w.playingClip={3,3}
    w.clearCalls(); press(0x14,w); w.tick(30)
    eq(#w.callsNamed("CopyClip"),1); eq(#w.callsNamed("clipMatrix.TriggerClip"),0); eq(#w.callsNamed("ClipIsPlaying"),0)
end)


-- Quantise with Timing Correct off (sequencer.quantiser.Enabled).
test("Shift + Step 16 stays a plain press: with Timing Correct off nothing is written", function()
    local w=load{quantiser={value=false}}; connect(w); w.quantLog={}
    w.wire(cc(5,127)); press(0x2F,w); w.wire(cc(5,0)); w.tick(30)
    eq(#w.callsNamed("quantiseApply.Press"),1)
    for _,e in ipairs(w.quantLog) do ok(e[1]=="press","only the press, got "..tostring(e[1])) end
    eq(w.quantiserEnabled.value,false); noErrors(w)
end)

-- CC 1D, QUANTISE_ALWAYS: what the Move sends for Shift + Step 16 with Setup "Quantise: Always".
local function quantNow(w) press(0x1D,w) end
local function quantLog(w, base)
    local out = {}
    for _, e in ipairs(w.quantLog) do
        out[#out+1] = e[1] .. (e[2] ~= nil and (" " .. tostring(e[2])) or "") .. "@" .. (e[3] - base)
    end
    return table.concat(out, ", ")
end

test("quantise, Enabled off: write true, press next tick, write false the tick after; once", function()
    local w=load{quantiser={value=false}}; connect(w); w.quantLog={}
    local t0=w.tickNo
    quantNow(w)
    eq(quantLog(w,t0),"write true@0","on the press tick")
    quantNow(w); quantNow(w) -- a second press in progress is ignored
    w.tick(1); eq(quantLog(w,t0),"write true@0, press@1")
    w.tick(1); eq(quantLog(w,t0),"write true@0, press@1, write false@2")
    w.tick(5); eq(#w.quantLog,3,"nothing more")
    eq(w.quantiserEnabled.value,false,"left off"); eq(#w.callsNamed("quantiseApply.Press"),1)
    noErrors(w)
end)

test("quantise, Enabled off: ignored while in progress, then a later press runs the full sequence again", function()
    local w=load{quantiser={value=false}}; connect(w); w.quantLog={}
    local t0=w.tickNo
    -- Two presses while it runs; a third on the tick it finished would rightly start a new one.
    quantNow(w); quantNow(w); w.tick(1); quantNow(w); w.tick(1)
    eq(quantLog(w,t0),"write true@0, press@1, write false@2","presses during the sequence ignored")
    w.tick(1); w.quantLog={}
    local t1=w.tickNo
    quantNow(w); w.tick(2)
    eq(quantLog(w,t1),"write true@0, press@1, write false@2","second full sequence")
    eq(w.quantiserEnabled.value,false); eq(#w.callsNamed("quantiseApply.Press"),2); noErrors(w)
end)

test("quantise, Enabled already on: one plain press at once, never written", function()
    local w=load{quantiser={value=true}}; connect(w); w.quantLog={}
    local t0=w.tickNo
    quantNow(w); eq(quantLog(w,t0),"press@0")
    w.tick(5); eq(quantLog(w,t0),"press@0"); eq(w.quantiserEnabled.value,true); noErrors(w)
end)

test("quantise, quantiser missing: one plain press at once, nothing written", function()
    local w=load(); connect(w); w.quantLog={}
    eq(w.mpc.sequencer.quantiser,nil,"mock default has no quantiser")
    quantNow(w); eq(#w.quantLog,1); eq(w.quantLog[1][1],"press"); w.tick(5); eq(#w.quantLog,1); noErrors(w)
end)

test("quantise, Enabled unreadable or not a boolean: one plain press, nothing written", function()
    for _, v in ipairs({"nil","number","string"}) do
        local w=load{quantiser={value=(v=="number" and 1) or (v=="string" and "off") or nil}}
        connect(w); w.quantLog={}
        quantNow(w); w.tick(5)
        eq(#w.quantLog,1,v); eq(w.quantLog[1][1],"press",v); noErrors(w)
    end
    local w=load{quantiser={value=false}}; connect(w); w.quantLog={}
    rawset(w.quantiserEnabled,"_onRead",function() error("read failed") end)
    quantNow(w); w.tick(5)
    eq(#w.quantLog,1,"read raises"); eq(w.quantLog[1][1],"press"); noErrors(w)
end)

test("quantise, writing Enabled raises: one plain press at once, no script error", function()
    local w=load{quantiser={value=false,failWrite=true}}; connect(w); w.quantLog={}
    local t0=w.tickNo
    quantNow(w); w.tick(5)
    eq(quantLog(w,t0),"write true@0, press@0","the failed write, then the plain press")
    eq(w.quantiserEnabled.value,false); noErrors(w)
end)

test("quantise, Enabled off: the quantizeApply spelling follows the same sequence", function()
    local w=load{quantiser={value=false}}
    w.mpc.controlSurface.quantiseApply=nil
    w.mpc.controlSurface.quantizeApply={Press=function() w.quantLog[#w.quantLog+1]={"press",nil,w.tickNo} end}
    connect(w); w.quantLog={}; local t0=w.tickNo
    quantNow(w); w.tick(3)
    eq(quantLog(w,t0),"write true@0, press@1, write false@2"); noErrors(w)
end)

test("quantise, button unavailable: bit cleared, no further attempts, as before", function()
    local w=load{quantiser={value=false}}; connect(w)
    w.mpc.controlSurface.quantiseApply.Press=function() error("unavailable") end
    quantNow(w); w.tick(4)
    eq(lastOf(w.takeSysex(),0x42):byte(16) & 8,0,"unavailable bit cleared")
    eq(w.quantiserEnabled.value,false,"left off")
    local count=w.I.errors().quantise; quantNow(w); w.tick(4)
    eq(w.I.errors().quantise,count,"no repeat failures"); eq(w.I.status().active,true)
end)

test("quantise: Move disconnects after Enabled was set true; Enabled must end false", function()
    for _, how in ipairs({"bye","timeout"}) do
        local w=load{quantiser={value=false}}; connect(w); w.quantLog={}
        quantNow(w); eq(w.quantiserEnabled.value,true,how)
        if how=="bye" then w.wire(BYE) else w.tick(175) end
        eq(w.I.status().active,false,how)
        w.tick(5)
        eq(w.quantiserEnabled.value,false,how..": Timing Correct restored after disconnect")
    end
end)

test("perf log: one line per PERF_LOG_MS, no script error, same messages as without it", function()
    local w=load({perfLog=true}); connect(w)
    local lines={}
    local realPrint=print
    _G.print=function(s) if tostring(s):find("^MOVEPADS perf") then lines[#lines+1]=s else realPrint(s) end end
    local okRun,err=pcall(function()
        w.wire(cc(0x30,2))
        for _=1,12 do w.wire(PING); w.tick(50) end -- 12 s of 20 ms ticks
    end)
    _G.print=realPrint
    ok(okRun,tostring(err)); noErrors(w)
    ok(#lines>=1 and #lines<=2,"perf lines: "..#lines)
    ok(lines[1]:find("Timer n=%d+") ~= nil,lines[1]); ok(lines[1]:find("gapMax=") ~= nil,lines[1])
end)

test("Step Seq lane pick presses at velocity 0.001, so the pad does not sound; one retry at 1/127 if that is no hit; no press for the current lane", function()
    for _,ignored in ipairs({false,true}) do
        local w=load(); connect(w); w.zeroVelocityIgnored=ignored
        enterStepSeq(w); w.tick(10); w.clearCalls()
        w.wire({0x9F,1,100}); w.wire({0x8F,1,0})
        for _=1,40 do w.wire(PING); w.tick(1) end
        local presses=w.callsNamed("pads.Press")
        noErrors(w)
        if ignored then
            eq(#presses,2,"retried once"); eq(presses[1][2],0.001); ok(math.abs(presses[2][2]-1/127)<1e-9,"retry at 1/127")
        else
            eq(#presses,1,"one press"); eq(presses[1][1],2); eq(presses[1][2],0.001,"velocity 0.001")
        end
        eq(w.lastHitPad,2,"lane is A02")
        eq(#w.callsNamed("pads.Tap"),0,"never a full-velocity Tap")
        -- the same pad again: it is already the lane, so no press at all
        w.clearCalls(); w.wire({0x9F,1,100}); w.wire({0x8F,1,0})
        for _=1,40 do w.wire(PING); w.tick(1) end
        eq(#w.callsNamed("pads.Press"),0,"no press for the current lane"); noErrors(w)
    end
end)

test("entering Matrix or Transposed shows the current track; left alone when already in view (Ryan, 2026-11-19)", function()
    local w=load({globalCols=16}); connect(w)
    local function to(m, idx) mock.set(w.mpc.tracks.currentTrack.Index, idx); w.wire(cc(0x30, m)); w.tick(5) end
    eq(w.ox, 0)
    to(1, 5);  eq(w.ox, 4, "track 6 in Transposed: T5-8")
    to(2, 5);  eq(w.ox, 4, "the play side does not move it")
    to(0, 12); eq(w.ox, 8, "track 13 in Matrix: T9-16")
    to(2, 9);  to(1, 9); eq(w.ox, 8, "track 10 already in view: not moved")
    to(2, 2);  to(0, 2); eq(w.ox, 0, "back to T1-8")
    noErrors(w)
end)

test("the active track's select button is white with the MPC's animation; other tracks unchanged (Ryan, 2026-11-19)", function()
    local w = load()
    for c = 0, 3 do w.setTrack(c, 0xFFFF0000, 4, false) end   -- four red tracks, all playing
    w.setTrack(1, 0xFF0000FF, 2, false)                        -- track 2 blue, stopped
    mock.set(w.mpc.tracks.currentTrack.Index, 2)
    connect(w); w.tick(20)
    local function steps() return decodeRuns(w.takeSysex(), 0x45) end
    w.wire(cc(0x33, 127)); w.tick(10)
    local s1 = steps()
    ledEq(s1[4], 127, 127, 127, 2, "active track 3: white, pulsing while it plays")
    ledEq(s1[5], 127, 0, 0, 2, "its stop step keeps the track colour")
    ledEq(s1[0], 127, 0, 0, 2, "track 1 red, pulsing (playing)")
    ledEq(s1[2], 0, 0, 127, 1, "track 2 blue, dim (stopped)")
    -- the marker follows the current track
    mock.set(w.mpc.tracks.currentTrack.Index, 1); w.tick(20); w.wire(cc(0x33, 127)); w.tick(10)
    local s2 = steps()
    ledEq(s2[2], 127, 127, 127, 0, "active track 2: white, steady (stopped)")
    ledEq(s2[4], 127, 0, 0, 2, "track 3 back to red, pulsing")
    -- Transposed: the row buttons
    w.wire(cc(0x30, 1)); w.tick(10)
    local r = { lastOf(w.takeSysex(), 0x44):byte(5, 20) }
    eq(table.concat({ r[5], r[6], r[7], r[8] }, ","), "127,127,127,0", "row 1 (track 2) white steady")
    eq(table.concat({ r[1], r[2], r[3], r[4] }, ","), "127,0,0,2", "row 0 (track 1) red pulsing")
    noErrors(w)
end)

test("the window never runs past the last track: 6 of 6 in Transposed shows 3-6, 9 of 9 in Matrix 2-9, 10 of 10 3-10 (Ryan)", function()
    local function enter(n, layout, idx, fromOx)
        local w=load({globalCols=16, numTracks=n}); connect(w)
        if fromOx then w.moveTo(fromOx, 0); w.refresh() end
        mock.set(w.mpc.tracks.currentTrack.Index, idx)
        w.wire(cc(0x30, 2)); w.tick(5); w.wire(cc(0x30, layout)); w.tick(5)
        noErrors(w); return w.ox
    end
    eq(enter(6, 1, 5), 2, "6 of 6, Transposed: 3-6")
    eq(enter(9, 0, 8), 1, "9 of 9, Matrix: 2-9")
    eq(enter(10, 0, 9), 2, "10 of 10, Matrix: 3-10")
    eq(enter(12, 1, 5), 4, "6 of 12, Transposed: the page, 5-8")
    eq(enter(6, 0, 5), 0, "6 of 6, Matrix: 1-8 (fewer tracks than the window)")
    eq(enter(9, 0, 8, 8), 1, "9 of 9, Matrix, window at 9-16 already: slides back to 2-9")
    eq(enter(16, 0, 9, 8), 8, "10 of 16, Matrix at 9-16: in view, not past the end, left alone")
end)

test("Transposed step lights: each scene on the odd step under its column, even steps dark, step 16 stop-all (Ryan)", function()
    local w = load()
    w.setScene(0, 0xFFFF0000, 4, false)   -- scene 1 red, playing
    w.setScene(5, 0xFF0000FF, 2, false)   -- scene 6 blue, stopped
    connect(w); w.wire(cc(0x30, 1)); w.tick(10)
    w.wire(cc(0x33, 127)); w.tick(10)
    local st = decodeRuns(w.takeSysex(), 0x45)
    ledEq(st[0], 127, 0, 0, 2, "scene 1 on step 1, pulsing")
    ledEq(st[10], 0, 0, 127, 1, "scene 6 on step 11, dim")
    for _, i in ipairs({1, 3, 5, 9, 11, 13}) do ledEq(st[i], 0, 0, 0, 0, "even step " .. (i + 1) .. " dark") end
    ledEq(st[15], 127, 0, 0, 1, "step 16 stop all")
    noErrors(w)
end)

print(string.format("\n%d passed, %d failed, %d checks", passed, failed, checks))
if failed > 0 then
    print("failed: " .. table.concat(failures, "; "))
    os.exit(1)
end
