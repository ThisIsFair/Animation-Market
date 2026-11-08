-- Stance Dev / Marketplace emote-slot replication experiment
-- Runs with the existing Stance Dev animation engine (not a replacement).
-- Uses its already-tested, version-checked animation-ID memory adapter.
-- This experiment does NOT decode protected scripts, require Matcha Pro,
-- invoke the /e chat commands, or promise server replication.
-- IMPORTANT: Changing an idle clip is NOT equivalent to triggering
-- a native Marketplace emote. Another Roblox client must verify visibility.
--
-- 1. Launch StanceDev.lua in Matcha.
-- 2. Run: loadstring(httpget("https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Dev_Emote_Slot_Probe.lua"))()
-- 3. _G.StanceDevEmoteSlotProbe.Report()
-- 4. _G.StanceDevEmoteSlotProbe.Try("118644064755644")
-- 5. Stand still; briefly move and stop if necessary.
-- 6. _G.StanceDevEmoteSlotProbe.Check()
-- 7. _G.StanceDevEmoteSlotProbe.Restore()
--
-- Test in a disposable R15 session with a second player.
-- A crash can prevent clean restoration; rejoining resets the character.
-- Only *underlying animation clip IDs* are eligible, not necessarily
-- Marketplace emote item IDs.

if _G.StanceDevEmoteSlotProbe and type(_G.StanceDevEmoteSlotProbe.Unload) == "function" then
    pcall(_G.StanceDevEmoteSlotProbe.Unload)
end

local Probe = {}
local PREFIX = "[Stance/DevEmoteSlot] "
local state = { active = false, id = nil }
local function say(message)
    print(PREFIX .. tostring(message))
end
local function deny(message)
    say("BLOCKED: " .. tostring(message))
    return false, tostring(message)
end
local function getEngine()
    local engine = _G.StanceAnimationEngine
    if type(engine) ~= "table"
        or type(engine.ApplyStateIds) ~= "function"
        or type(engine.Status) ~= "function"
        or type(engine.Restore) ~= "function" then
        return nil, "Stance Dev engine missing. Run StanceDev.lua first."
    end
    return engine
end
local function readStatus(engine)
    local ok, snapshot = pcall(function() return engine.Status() end)
    if not ok or type(snapshot) ~= "table" then
        return nil, "Stance engine Status() call failed"
    end
    return snapshot
end
local function scrubId(value)
    local id = tostring(value or ""):match("^%s*(%d+)%s*$")
    if not id or #id < 6 or #id > 17 then return nil end
    return id
end

function Probe.Report()
    say("Marketplace/UGC animation clip test; never a /e emote test")
    say("Technique: reuse Stance Dev's existing memory-ID engine for idle slots")
    local engine, reason = getEngine()
    if not engine then return deny(reason) end
    local status, issue = readStatus(engine)
    if not status then return deny(issue) end
    say("R15 rig=" .. tostring(status.rig))
    say("Memory engine available=" .. tostring(status.available)
        .. "; reason=" .. tostring(status.reason))
    say("Already requested states=" .. tostring(status.requestedStates)
        .. "; slot readback=" .. tostring(status.synced)
        .. "/" .. tostring(status.total))
    if status.requestedStates and status.requestedStates > 0 and not state.active then
        say("A Stance pack/mix is active. Restore it before this test to avoid overriding it.")
    end
    say("No code here can determine server visibility. Have a second player observe.")
    return true, "Diagnostic printed"
end

function Probe.Try(value)
    if state.active then
        return deny("A test is already active. Restore it before trying another ID.")
    end
    local id = scrubId(value)
    if not id then return deny("Enter an animation clip ID with 6-17 digits") end

    local engine, reason = getEngine()
    if not engine then return deny(reason) end
    local snapshot, issue = readStatus(engine)
    if not snapshot then return deny(issue) end
    if snapshot.available ~= true or snapshot.rig ~= "R15" then
        return deny(snapshot.reason or "R15/memory engine unavailable")
    end
    if type(snapshot.requestedStates) == "number" and snapshot.requestedStates > 0 then
        return deny("Stance has active movement animation states. Do not override the current pack/mix.")
    end

    local ok, success, detail = pcall(function()
        return engine.ApplyStateIds({ idle = { tonumber(id), tonumber(id) } })
    end)
    if not ok or success ~= true then
        return deny(ok and (detail or "Stance engine rejected request") or
            "ApplyStateIds raised an error")
    end
    state.active = true
    state.id = id
    say("Queued underlying clip ID " .. id .. " for both R15 idle slots.")
    say("Stand still. If nothing happens, move a step and return to idle.")
    say("This tests slot playback, not the native Marketplace wheel.")
    say("Ask a second player whether they can see the SAME motion.")
    say("Run .Check() for memory readback and .Restore() afterwards.")
    return true, "Candidate queued; visual playback and server replication UNVERIFIED"
end

function Probe.Check()
    local engine, reason = getEngine()
    if not engine then return deny(reason) end
    local snapshot, issue = readStatus(engine)
    if not snapshot then return deny(issue) end
    say("Active test=" .. tostring(state.active) ..
        "; candidate=" .. tostring(state.id))
    say("Requested states=" .. tostring(snapshot.requestedStates) ..
        "; ID slot readback=" .. tostring(snapshot.synced) .. "/" .. tostring(snapshot.total))
    say("Engine last=" .. tostring(snapshot.last))
    say("NOTE: Even 2/2 matching slots would prove only memory readback, NOT playback or replication.")
    return true, "Status printed"
end

function Probe.Restore()
    if not state.active then
        say("No emote-slot test is active; no changes made by this probe")
        return true, "Nothing to restore"
    end
    local engine, reason = getEngine()
    if not engine then return deny(reason) end
    local ok, success, detail = pcall(function()
        return engine.Restore()
    end)
    if not ok or success ~= true then
        return deny(ok and (detail or "Engine restore failed") or
            "Engine Restore() raised an error; rejoin Roblox if needed")
    end
    state.active, state.id = false, nil
    say("Engine restored original animation references: " .. tostring(detail))
    return true, detail
end

function Probe.Unload()
    if state.active then
        local ok, detail = Probe.Restore()
        if not ok then
            return deny("Restore failed; keeping probe loaded so you can retry: " .. tostring(detail))
        end
    end
    if _G.StanceDevEmoteSlotProbe == Probe then
        _G.StanceDevEmoteSlotProbe = nil
    end
    say("Unloaded")
    return true
end

_G.StanceDevEmoteSlotProbe = Probe
say("Loaded from Dev. Use _G.StanceDevEmoteSlotProbe.Report()")
say("Try('118644064755644') to test a provided UGC clip candidate.")
