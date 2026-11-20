-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Ryan Gilmore
-- A mock of the parts of MPC's controller-script API that abletonMoveSchwung.lua uses.
--
-- It records every call (w.calls), every outgoing MIDI message (w.sysex,
-- w.voiceOut), and the live mapping table (w.mapped). Incoming MIDI goes
-- through w.wire(), which routes as MPC does: to the script only if mapped to
-- it, to a native pad/Q-Link if mapped so, otherwise "passthrough".
--
-- Shapes follow docs/MPC-SCRIPT-API.md. Where the real API is unproven the
-- mock simply implements the documented shape; options let a test remove a
-- piece (opts.noLightRGB, opts.noClipWorkflow, opts.noControlSurfaceQLinks).

local M = {}

-----------------------------------------------------------------------------
-- Property objects: .value, :listen, :listenOldNew, :stopListening
-----------------------------------------------------------------------------

local propMethods = {}

function propMethods.listen(self, fn, name)
    rawget(self, "_l")[name or ""] = fn
end

function propMethods.listenOldNew(self, fn, name)
    rawget(self, "_lon")[name or ""] = fn
end

function propMethods.stopListening(self, name)
    rawget(self, "_l")[name or ""] = nil
    rawget(self, "_lon")[name or ""] = nil
end

local propMeta = {
    __index = function(t, k)
        if k == "value" then
            local onRead = rawget(t, "_onRead")
            if onRead then onRead() end
            return rawget(t, "_v")
        end
        return propMethods[k]
    end,
    __newindex = function(t, k, v)
        if k == "value" then
            M.set(t, v)
        else
            rawset(t, k, v)
        end
    end,
}

function M.prop(v)
    return setmetatable({ _v = v, _l = {}, _lon = {} }, propMeta)
end

-- Set a property as MPC would: fires listeners if the value changed.
function M.set(p, v)
    local old = rawget(p, "_v")
    rawset(p, "_v", v)
    if old ~= v then
        for _, fn in pairs(rawget(p, "_l")) do fn(v) end
        for _, fn in pairs(rawget(p, "_lon")) do fn(old, v) end
    end
end

function M.listenerCount(p)
    local n = 0
    for _ in pairs(rawget(p, "_l")) do n = n + 1 end
    for _ in pairs(rawget(p, "_lon")) do n = n + 1 end
    return n
end

-----------------------------------------------------------------------------
-- World
-----------------------------------------------------------------------------

function M.new(opts)
    opts = opts or {}
    local w = {
        calls = {}, sysex = {}, voiceOut = {}, mapped = {}, routed = {},
        now = 1700000000000 + (opts.clockOffset or 0), timerRunning = false, timerInterval = nil,
        handleSysex = false, tickNo = 0, sysexPerTick = {},
        globalCols = opts.globalCols or 16, globalRows = opts.globalRows or 32,
        cells = {}, tracks = {}, scenes = {}, quantLog = {},
        selectedCol = 0, selectedRow = 0, armed = {}, solo = {}, position = 0, loopStart = 0, loopEnd = 7680,
        ox = 0, oy = 0, cols = 8, rows = 4, shown = false,
    }
    local function log(name, ...)
        w.calls[#w.calls + 1] = { name = name, args = { ... } }
    end
    w.log = log

    function w.callsNamed(name)
        local out = {}
        for _, c in ipairs(w.calls) do
            if c.name == name then out[#out + 1] = c.args end
        end
        return out
    end

    function w.clearCalls() w.calls = {} end

    ------------------------------------------------------------------ device
    local dev = {}
    w.dev = dev

    dev.midiOut = {
        SendMIDISysex = function(bytes, idx)
            assert(type(bytes) == "string", "SendMIDISysex wants a string")
            assert(idx == 0, "output index must be 0")
            w.sysex[#w.sysex + 1] = bytes
            w.sysexPerTick[w.tickNo] = (w.sysexPerTick[w.tickNo] or 0) + 1
            log("SendMIDISysex", bytes, idx)
        end,
        SendMIDINoteOn = function(ch, n, v, idx) w.voiceOut[#w.voiceOut + 1] = { 0x90 | ch, n, v }; log("SendMIDINoteOn", ch, n, v, idx) end,
        SendMIDINoteOff = function(ch, n, v, idx) w.voiceOut[#w.voiceOut + 1] = { 0x80 | ch, n, v }; log("SendMIDINoteOff", ch, n, v, idx) end,
        SendMIDICC = function(ch, cc, v, idx) w.voiceOut[#w.voiceOut + 1] = { 0xB0 | ch, cc, v }; log("SendMIDICC", ch, cc, v, idx) end,
    }

    dev.timer = {
        Start = function(ms) log("timer.Start", ms); w.timerRunning = true; w.timerInterval = ms end,
        Stop = function() log("timer.Stop"); w.timerRunning = false end,
        Now = function() return w.now end,
    }

    local function mapFn(name, fn)
        return function(...)
            log(name, ...)
            return fn(...)
        end
    end

    local qlinkMappings = {
        AddInfiniteCCToQLink = mapFn("AddInfiniteCCToQLink", function(ch, cc, idx) w.mapped["qlink." .. ch .. "." .. cc] = idx end),
        RemoveInfiniteCCToQLink = mapFn("RemoveInfiniteCCToQLink", function(ch, cc) w.mapped["qlink." .. ch .. "." .. cc] = nil end),
        AddAbsoluteCCToQLink = mapFn("AddAbsoluteCCToQLink", function() error("not used") end),
        SetQLinkFineAdjust = mapFn("SetQLinkFineAdjust", function() end),
        SetInfiniteCCMagnitude = mapFn("SetInfiniteCCMagnitude", function() end),
    }

    dev.mappings = {
        script = {
            SetHandleSysex = mapFn("SetHandleSysex", function(v) w.handleSysex = v end),
            AddNoteToScript = mapFn("AddNoteToScript", function(ch, n) w.mapped["script.note." .. ch .. "." .. n] = true end),
            RemoveNoteToScript = mapFn("RemoveNoteToScript", function(ch, n) w.mapped["script.note." .. ch .. "." .. n] = nil end),
            AddCCToScript = mapFn("AddCCToScript", function(ch, cc) w.mapped["script.cc." .. ch .. "." .. cc] = true end),
            RemoveCCToScript = mapFn("RemoveCCToScript", function(ch, cc) w.mapped["script.cc." .. ch .. "." .. cc] = nil end),
        },
        pads = {
            AddNoteToVirtualPad = mapFn("AddNoteToVirtualPad", function(ch, n, vp)
                assert(ch >= 0 and ch <= 15 and n >= 0 and n <= 127 and vp >= 0 and vp <= 127, "AddNoteToVirtualPad range")
                w.mapped["vpad." .. ch .. "." .. n] = vp
            end),
            RemoveNoteToVirtualPad = mapFn("RemoveNoteToVirtualPad", function(ch, n) w.mapped["vpad." .. ch .. "." .. n] = nil end),
        },
        controlSurface = {
            AddCCToControl = mapFn("AddCCToControl", function() end),
            RemoveCCToControl = mapFn("RemoveCCToControl", function() end),
        },
    }
    if opts.noControlSurfaceQLinks then
        dev.mappings.qlinks = qlinkMappings
    else
        dev.mappings.controlSurface.qlinks = qlinkMappings
    end

    ---------------------------------------------------------------- aperture
    local ap = {
        OriginX = M.prop(0), OriginY = M.prop(0),
        CanMoveLeft = M.prop(false), CanMoveRight = M.prop(false),
        CanMoveUp = M.prop(false), CanMoveDown = M.prop(false),
        ActiveMatrix = M.prop("Normal"),
        clipProperties = {}, trackProperties = {}, sceneProperties = {},
    }
    dev.clipMatrixAperture = ap
    w.aperture = ap
    for c = 0, 15 do
        ap.clipProperties[c] = {}
        for r = 0, 15 do
            ap.clipProperties[c][r] = { Colour = M.prop(0), State = M.prop(0), Selected = M.prop(false), Name = M.prop("") }
        end
        ap.trackProperties[c] = { Colour = M.prop(0), State = M.prop(0), Selected = M.prop(false), Name = M.prop(""), Type = M.prop("Drum") }
        ap.sceneProperties[c] = { Colour = M.prop(0), State = M.prop(0), Selected = M.prop(false), Name = M.prop("") }
    end

    local function get(tbl, i, j)
        local col = tbl[i]
        if j == nil then return col end
        return col and col[j]
    end

    -- Copy the global matrix into the aperture-relative properties (rebind).
    function w.refresh()
        for c = 0, 15 do
            for r = 0, 15 do
                local cell = get(w.cells, w.ox + c, w.oy + r) or { 0, 0, false }
                local p = ap.clipProperties[c][r]
                M.set(p.Colour, cell[1]); M.set(p.State, cell[2]); M.set(p.Selected, cell[3])
            end
            local t = w.tracks[w.ox + c] or { 0, 0, false }
            M.set(ap.trackProperties[c].Colour, t[1]); M.set(ap.trackProperties[c].State, t[2]); M.set(ap.trackProperties[c].Selected, t[3])
            local s = w.scenes[w.oy + c] or { 0, 0, false }
            M.set(ap.sceneProperties[c].Colour, s[1]); M.set(ap.sceneProperties[c].State, s[2]); M.set(ap.sceneProperties[c].Selected, s[3])
        end
        M.set(ap.OriginX, w.ox); M.set(ap.OriginY, w.oy)
        M.set(ap.CanMoveLeft, w.ox > 0); M.set(ap.CanMoveRight, w.ox + w.cols < w.globalCols)
        M.set(ap.CanMoveUp, w.oy > 0); M.set(ap.CanMoveDown, w.oy + w.rows < w.globalRows)
    end

    function w.moveTo(x, y)
        x = math.max(0, math.min(x, math.max(0, w.globalCols - w.cols)))
        y = math.max(0, math.min(y, math.max(0, w.globalRows - w.rows)))
        w.ox, w.oy = x, y
        w.refresh()
    end

    function w.setCell(gc, gr, colour, state, selected)
        w.cells[gc] = w.cells[gc] or {}
        w.cells[gc][gr] = { colour, state, selected or false }
        w.refresh()
    end
    function w.setTrack(gc, colour, state, selected) w.tracks[gc] = { colour, state, selected or false }; w.refresh() end
    function w.setScene(gr, colour, state, selected) w.scenes[gr] = { colour, state, selected or false }; w.refresh() end

    ap.GetColumns = function() return w.cols end
    ap.GetRows = function() return w.rows end
    ap.GetGlobalColumns = function() return w.globalCols end
    ap.GetGlobalRows = function() return w.globalRows end
    ap.SetColumns = mapFn("SetColumns", function(n) assert(n >= 1 and n <= 16); w.cols = n; w.moveTo(w.ox, w.oy) end)
    ap.SetRows = mapFn("SetRows", function(n) assert(n >= 1 and n <= 16); w.rows = n; w.moveTo(w.ox, w.oy) end)
    ap.SetLabel = mapFn("SetLabel", function(s) w.label = s end)
    ap.SetFollowsTUI = mapFn("SetFollowsTUI", function(v) w.followsTUI = v end)
    ap.SetFollowsTUIActiveMatrix = mapFn("SetFollowsTUIActiveMatrix", function(v)
        assert(w.followsTUI == false, "SetFollowsTUIActiveMatrix(false) not allowed while following TUI")
    end)
    ap.Show = mapFn("Show", function() w.shown = true end)
    ap.Hide = mapFn("Hide", function() w.shown = false end)
    ap.MoveTo = mapFn("MoveTo", function(x, y) w.moveTo(x, y) end)
    ap.MoveToColumn = mapFn("MoveToColumn", function(x) w.moveTo(x, w.oy) end)
    ap.MoveToRow = mapFn("MoveToRow", function(y) w.moveTo(w.ox, y) end)
    ap.MoveLeft = mapFn("MoveLeft", function(n) w.moveTo(w.ox - n, w.oy) end)
    ap.MoveRight = mapFn("MoveRight", function(n) w.moveTo(w.ox + n, w.oy) end)
    ap.MoveUp = mapFn("MoveUp", function(n) w.moveTo(w.ox, w.oy - n) end)
    ap.MoveDown = mapFn("MoveDown", function(n) w.moveTo(w.ox, w.oy + n) end)
    ap.BankLeft = mapFn("BankLeft", function(n) w.moveTo(w.ox - w.cols * (n or 1), w.oy) end)
    ap.BankRight = mapFn("BankRight", function(n) w.moveTo(w.ox + w.cols * (n or 1), w.oy) end)
    ap.BankUp = mapFn("BankUp", function(n) w.moveTo(w.ox, w.oy - w.rows * (n or 1)) end)
    ap.BankDown = mapFn("BankDown", function(n) w.moveTo(w.ox, w.oy + w.rows * (n or 1)) end)
    ap.TriggerClip = mapFn("TriggerClip", function() end)
    ap.SelectClip = mapFn("SelectClip", function(c,r) w.selectedCol,w.selectedRow=w.ox+c,w.oy+r end)
    ap.TriggerRow = mapFn("TriggerRow", function() end)
    ap.StopClipsOnTrack = mapFn("StopClipsOnTrack", function() end)
    ap.SelectTrack = mapFn("SelectTrack", function() end)

    -------------------------------------------------------------- mpc global
    local qlinks = { GetNumQLinks = function() return 16 end }
    for i = 0, 15 do
        qlinks[i] = { TargetName = M.prop("Target " .. (i + 1)), ValueString = M.prop("0"), IsTouched = M.prop(false) }
    end
    w.qlinkReads = {}
    for i = 0, 15 do
        for _, field in ipairs({ "TargetName", "ValueString" }) do
            qlinks[i][field]._onRead = function()
                w.qlinkReads[#w.qlinkReads + 1] = { tick = w.tickNo, time = w.now, idx = i, field = field }
            end
        end
    end
    w.vpadColour = {} -- [vp] = 0xRRGGBB, served by LightRGBColor
    w.virtualHeld = {}
    local pads = { CurrentBank = M.prop(0) }
    pads.SetCurrentBank = mapFn("pads.SetCurrentBank", function(bank)
        assert(bank >= 0 and bank <= 7, "SetCurrentBank range")
        -- w.bankDelay: nil = at once; N = after N ticks; "never" = ignored.
        if w.bankDelay == "never" then return end
        local function apply()
            M.set(pads.CurrentBank, bank)
            if w.padSel then for i=0,15 do w.vpadColour[bank * 16 + i] = 0xFFFF00 end end
        end
        if w.bankDelay then w.pendingBank = { due = w.tickNo + w.bankDelay, apply = apply }
        else apply() end
    end)
    -- The pad the MPC last hit, 1-based (1 = A01, 17 = B01). Tests set w.lastHitPad
    -- to anything, including nil or a non-number, to see what the script does.
    w.lastHitPad = 1
    pads.LastHitPad = mapFn("pads.LastHitPad", function() return w.lastHitPad end)
    pads.Tap = mapFn("pads.Tap", function(n) assert(n >= 1 and n <= 16) end)
    -- As on the device (seventh bench): a press is a hit, and LastHitPad
    -- follows it, 1-based across banks. w.zeroVelocityIgnored: a velocity-0
    -- press is not a hit, to test the script's retry.
    pads.Press = mapFn("pads.Press", function(n, v)
        assert(n >= 1 and n <= 16, "pads are 1-based"); assert(type(v) == "number" and v >= 0 and v <= 1, "velocity 0-1")
        if v < 0.005 and w.zeroVelocityIgnored then return end -- device: 0 is no hit; 0.001 to be benched
        w.lastHitPad = math.floor(pads.CurrentBank.value) * 16 + n
    end)
    pads.Release = mapFn("pads.Release", function(n) assert(n >= 1 and n <= 16) end)
    pads.ReleaseVirtual = mapFn("ReleaseVirtual", function(vp) w.virtualHeld[vp] = nil end)
    for i = 0, 15 do pads[i] = { Colour = M.prop(0) } end
    if not opts.noLightRGB then
        -- As on the device: 0-based, ARGB, every bank; the same colours.
        pads.virtual = setmetatable({}, { __index = function(_, vp)
            return { Colour = { value = 0xFF000000 | (w.vpadColour[vp] or 0) } }
        end })
        pads.LightRGBColor = function(pad)
            -- As on the device: 1-based, "{rrggbb}", every bank.
            assert(pad >= 1 and pad <= 128, "LightRGBColor range")
            return string.format("{%06x}", w.vpadColour[pad - 1] or 0)
        end
    end

    local currentTrack = {
        Name = M.prop("Drum 001"), Index = M.prop(0), Colour = M.prop(0xFFFF0000), Type = M.prop("Drum"), PluginPresetName = M.prop(""),
    }
    currentTrack.Next = mapFn("currentTrack.Next", function()
        M.set(currentTrack.Index, currentTrack.Index.value + 1)
        M.set(currentTrack.Name, "Track " .. (currentTrack.Index.value + 1))
    end)
    currentTrack.Previous = mapFn("currentTrack.Previous", function()
        M.set(currentTrack.Index, math.max(0, currentTrack.Index.value - 1))
        M.set(currentTrack.Name, "Track " .. (currentTrack.Index.value + 1))
    end)

    w.mpc = {
        IsStandalone = function() return true end,
        engineMode = { CurrentMode = M.prop(opts.engineMode or "Main Mode"), CurrentPopup = M.prop("No Popup") },
        features = { UseClipWorkflow = M.prop(not opts.noClipWorkflow) },
        sequencer = {
            MetronomeEnabled = M.prop(false),
            PlayheadPosition = mapFn("PlayheadPosition", function() return w.position end),
            GetLoopStart = mapFn("GetLoopStart", function() return w.loopStart end),
            GetEndOrLoop = mapFn("GetEndOrLoop", function() return w.loopEnd end),
            SetBPM = mapFn("SetBPM", function(bpm) w.bpm = bpm end),
            Playing = M.prop(false), RecordState = M.prop(0), OverdubState = M.prop(0),
            TogglePlayStart = mapFn("TogglePlayStart", function() end),
            TogglePlay = mapFn("TogglePlay", function() end),
            Record = mapFn("Record", function() end),
            Overdub = mapFn("Overdub", function() end),
        },
        commandManager = {
            Undo = mapFn("Undo", function() end),
            Redo = mapFn("Redo", function() end),
        },
        project = {BPM = M.prop(120), GlobalAutomationFilterType = M.prop("Read")},
        clipMatrix = {
            StopAllClips = mapFn("StopAllClips", function() end),
            SelectClip = mapFn("clipMatrix.SelectClip", function(c, r) w.selectedCol, w.selectedRow = c, r end),
            GetSelectedClipColumn = mapFn("GetSelectedClipColumn", function() return w.selectedCol end),
            GetSelectedClipRow = mapFn("GetSelectedClipRow", function() return w.selectedRow end),
            GetRows = mapFn("GetRows", function() return w.globalRows end),
            HasClip = mapFn("HasClip", function(c, r) return w.cells[c] ~= nil and w.cells[c][r] ~= nil and w.cells[c][r][2] >= 2 end),
            CopyClip = mapFn("CopyClip", function(c, r, dc, dr)
                w.cells[dc] = w.cells[dc] or {}; local src = w.cells[c] and w.cells[c][r] or {0, 2, false}
                w.cells[dc][dr] = {src[1], src[2], false}; w.selectedCol, w.selectedRow = dc, dr; w.refresh()
            end),
            ClipIsPlaying = mapFn("ClipIsPlaying", function(c, r) return w.playingClip ~= nil and w.playingClip[1] == c and w.playingClip[2] == r end),
            TriggerClip = mapFn("clipMatrix.TriggerClip", function() end),
            DeleteClip = mapFn("DeleteClip", function(c, r) if w.cells[c] then w.cells[c][r] = nil end; w.refresh() end),
            InsertRows = mapFn("InsertRows", function(row, count)
                for _, col in pairs(w.cells) do for r = w.globalRows - 1, row, -1 do col[r + count] = col[r] end; for r = row, row + count - 1 do col[r] = nil end end
                w.globalRows = w.globalRows + count; w.refresh()
            end),
            CopyRow = mapFn("CopyRow", function(row, dest)
                for _, col in pairs(w.cells) do local src = col[row]; col[dest] = src and {src[1], src[2], false} or nil end; w.refresh()
            end),
        },
        tracks = { currentTrack = currentTrack, normalTracks = { Count = opts.numTracks and M.prop(opts.numTracks) or nil },
            GetSolo = mapFn("GetSolo", function(name) return w.solo[name] or false end),
            SizeNormalTracks = function() return w.normalTrackCount or 64 end,
            GetTrackRecordArmed = mapFn("GetTrackRecordArmed", function(name) return w.armed[name] or false end),
            SetTrackRecordArmed = mapFn("SetTrackRecordArmed", function(name, armed) assert(type(name)=="string" and type(armed)=="boolean"); w.armed[name] = armed end),
        },
        controlSurface = { qlinks = qlinks, pads = pads,
            stepSequencer = { Tap = mapFn("stepSequencer.Tap", function(n) assert(n >= 1 and n <= 16, "steps are 1-based") end) },
            fKey4 = { Press = mapFn("fKey4.Press", function()
                    -- Pad Sel: the bank's pads go yellow, the current lane's pad
                    -- (w.lanePad, 0-based, default 0; or the list w.lanePads) green;
                    -- leaving restores what was there. Raw read: tests count .value.
                    local base = (rawget(pads.CurrentBank, "_v") or 0) * 16
                    w.padSel = not w.padSel
                    if w.padSel then
                        w.padSelSaved = {}
                        local greens = {}
                        for _, g in ipairs(w.lanePads or { w.lanePad or 0 }) do greens[g] = true end
                        for i = 0, 15 do
                            w.padSelSaved[i] = w.vpadColour[base + i]
                            w.vpadColour[base + i] = greens[i] and 0x00FF00 or 0xFFFF00
                        end
                    else
                        for i = 0, 15 do w.vpadColour[base + i] = (w.padSelSaved or {})[i] end
                        w.padSelSaved = nil
                    end
                end), Release = mapFn("fKey4.Release", function() end) },
            stepSeqNext = { Press = mapFn("stepSeqNext.Press", function() w.stepBar = (w.stepBar or 0) + 1 end), Release = mapFn("stepSeqNext.Release", function() end) },
            stepSeqPrev = { Press = mapFn("stepSeqPrev.Press", function() w.stepBar = (w.stepBar or 0) - 1 end), Release = mapFn("stepSeqPrev.Release", function() end) },
            shift = { Hold = mapFn("shift.Hold", function() end), Release = mapFn("shift.Release", function() end) },
            noteRepeat = { Hold = mapFn("noteRepeat.Hold", function() w.repeatOn = true end), Release = mapFn("noteRepeat.Release", function() w.repeatOn = false end), Press = mapFn("noteRepeat.Press", function() w.repeatOn = not w.repeatOn end) },
            arrange = { Press = mapFn("arrange.Press", function() end) },
            sixteenLevel = { Press = mapFn("sixteenLevel.Press", function() end) },
            fullLevel = { Press = mapFn("fullLevel.Press", function() end) },
            quantiseApply = { Press = mapFn("quantiseApply.Press", function() w.quantLog[#w.quantLog + 1] = { "press", nil, w.tickNo } end) },
            record = { Press = mapFn("record.Press", function() end) } },
        ui = { ShowTUIFeedback = mapFn("ShowTUIFeedback", function() end) },
    }
    w.mpc.engineMode.RequestModeChange = mapFn("RequestModeChange", function(name)
        M.set(w.mpc.engineMode.CurrentMode, name)
    end)
    w.mpc.project.AdvanceGlobalAutomationFilterType = mapFn("AdvanceGlobalAutomationFilterType", function()
        local p = w.mpc.project.GlobalAutomationFilterType
        p.value = p.value == "Read" and "Write" or "Read"
    end)
    -- sequencer.quantiser.Enabled exists only when a test asks for it:
    -- mock.new{quantiser = {value = false}} (value may be nil/number to model an
    -- odd read; failWrite = true makes every write raise). Every write is
    -- appended to w.quantLog as {"write", value, tickNo}, interleaved with the
    -- quantise button's {"press", nil, tickNo}. mock.set(p, v) changes the
    -- value without logging, as the MPC itself would.
    if opts.quantiser then
        local q = M.prop(opts.quantiser.value)
        local inner = getmetatable(q)
        w.quantiserEnabled = setmetatable(q, {
            __index = inner.__index,
            __newindex = function(t, k, v)
                if k ~= "value" then return rawset(t, k, v) end
                w.quantLog[#w.quantLog + 1] = { "write", v, w.tickNo }
                if opts.quantiser.failWrite then error("quantiser write failed") end
                M.set(t, v)
            end,
        })
        w.mpc.sequencer.quantiser = { Enabled = w.quantiserEnabled }
    end
    for i = 0, 31 do w.mpc.tracks.normalTracks[i] = {Name = M.prop("Track " .. (i + 1))} end
    w.qlinks, w.pads, w.currentTrack = qlinks, pads, currentTrack

    ------------------------------------------------------------ MIDI routing
    -- Feed one wire message (array of ints, F0..F7 for SysEx) as MPC would.
    function w.wire(bytes)
        local status = bytes[1]
        if status == 0xF0 then
            local body = {}
            for i = 2, #bytes - 1 do body[#body + 1] = bytes[i] end
            if w.handleSysex then
                dev.HandleMIDISysex(string.char(table.unpack(body)))
                return "script"
            end
            return "passthrough"
        end
        local kind, ch = status & 0xF0, status & 0x0F
        local d1, d2 = bytes[2], bytes[3]
        if kind == 0x90 or kind == 0x80 then
            if w.mapped["script.note." .. ch .. "." .. d1] then
                if kind == 0x90 and d2 > 0 then dev.HandleMIDINoteOn(ch, d1, d2)
                else dev.HandleMIDINoteOff(ch, d1, d2) end
                return "script"
            elseif w.mapped["vpad." .. ch .. "." .. d1] then
                local vp = w.mapped["vpad." .. ch .. "." .. d1]
                w.virtualHeld[vp] = (kind == 0x90 and d2 > 0) or nil
                w.routed[#w.routed + 1] = { "vpad", vp, kind, d2 }
                return "vpad"
            end
            return "passthrough"
        elseif kind == 0xB0 then
            if w.mapped["script.cc." .. ch .. "." .. d1] then
                dev.HandleMIDICC(ch, d1, d2)
                return "script"
            elseif w.mapped["qlink." .. ch .. "." .. d1] then
                w.routed[#w.routed + 1] = { "qlink", w.mapped["qlink." .. ch .. "." .. d1], d2 }
                return "qlink"
            end
            return "passthrough"
        elseif kind == 0xA0 then
            -- poly pressure: no script handler exists; follows a native pad mapping if any
            if w.mapped["vpad." .. ch .. "." .. d1] then return "vpad" end
            return "passthrough"
        end
        return "passthrough"
    end

    function w.tick(n)
        for _ = 1, (n or 1) do
            w.now = w.now + (w.timerInterval or 20)
            w.tickNo = w.tickNo + 1
            if w.pendingBank and w.tickNo >= w.pendingBank.due then
                local pb = w.pendingBank; w.pendingBank = nil; pb.apply()
            end
            if w.timerRunning then dev.HandleTimer() end
        end
    end

    function w.takeSysex()
        local out = w.sysex
        w.sysex = {}
        return out
    end

    function w.countMapped()
        local n = 0
        for _ in pairs(w.mapped) do n = n + 1 end
        return n
    end

    return w
end

return M
