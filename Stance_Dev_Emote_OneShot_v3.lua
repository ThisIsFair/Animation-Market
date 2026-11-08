-- Stance Dev / Marketplace + UGC Emote One-Shot v3
-- Original, unobfuscated Matcha LuaVM experiment.
-- Requires neither Matcha Pro nor default /e emotes.
-- DO NOT claim server replication: test visibility with another client.
-- Makes R15 idle-slot substitution temporary instead of persistent.
--
-- After the substituted idle animation starts, the original idle references
-- are restored WITHOUT restarting the current animation track.
-- Moving/jumping invokes a guarded refresh to cancel current playback.
-- Stops/auto-restores on timeout, and abandons selection on respawn.
--
-- RUN:
-- loadstring(httpget("https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Dev_Emote_OneShot_v3.lua"))()
-- _G.StanceOneShotEmote.Report()
-- _G.StanceOneShotEmote.Play("118644064755644")
-- _G.StanceOneShotEmote.Check()
-- _G.StanceOneShotEmote.Stop()   -- emergency cancel
-- _G.StanceOneShotEmote.Unload() -- exit/cleanup
--
-- Only *underlying animation clip* IDs work with this idle-slot technique.
-- This is an experimental memory-based animation substitution, not native
-- Humanoid:PlayEmoteAsync, and may not replicate. Test on an R15 disposable session.

local VERSION = "v3-one-shot-20261107"
local ENGINE_URL = "https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Animation_Engine.lua?oneshot=67fd07b-v3"
local PREFIX = "[Stance/OneShot] "

local function log(s) print(PREFIX .. tostring(s)) end
local function fail(s)
    log("BLOCKED: " .. tostring(s))
    return false, tostring(s)
end

-- Clean up the previous experiment if loaded, avoiding two engines competing.
local legacy = _G.StanceDevEmoteSlotProbe
if type(legacy) == "table" and type(legacy.Unload) == "function" then
    local ok, result, detail = pcall(function() return legacy.Unload() end)
    if not ok or result == false then
        log("Previous DevEmoteSlot experiment did not unload: " .. tostring(detail))
        log("Restore it or rejoin Roblox before running v3.")
        return
    end
end
if type(_G.StanceOneShotEmote) == "table" and type(_G.StanceOneShotEmote.Unload) == "function" then
    local ok, result = pcall(function() return _G.StanceOneShotEmote.Unload() end)
    if not ok or result == false then
        log("Existing one-shot test did not unload; restore or rejoin before reloading.")
        return
    end
end

local P = { Version = VERSION }
local state = {
    engine = nil, ownsEngine = false, loadAttempted = false, loadError = nil,
    active = false, phase = "idle", id = nil, token = 0, character = nil,
    began = 0, expires = 18, last = "Not started", refreshOK = nil,
}
local Players = game:GetService("Players")
local Player = Players.LocalPlayer

local function readyEngine(engine)
    return type(engine) == "table"
        and type(engine.ApplyStateIds) == "function"
        and type(engine.Restore) == "function"
        and type(engine.RestoreNoRefresh) == "function"
        and type(engine.RefreshOneShot) == "function"
        and type(engine.AbandonOneShotOnRespawn) == "function"
        and type(engine.Status) == "function"
end

local function engine()
    local existing = _G.StanceAnimationEngine
    if readyEngine(existing) then
        state.engine = existing
        return existing
    end
    if existing ~= nil then
        return nil, "An older Stance engine is already running. Unload it or rejoin Roblox, then load v3 BEFORE the Stance UI."
    end
    if state.loadAttempted then return nil, state.loadError or "Engine initialization failed" end
    state.loadAttempted = true
    if type(httpget) ~= "function" or type(loadstring) ~= "function" then
        state.loadError = "Matcha httpget/loadstring unavailable"
        return nil, state.loadError
    end

    log("Loading the Dev animation engine with one-shot restoration support")
    local downloaded, source = pcall(function() return httpget(ENGINE_URL) end)
    if not downloaded or type(source) ~= "string"
        or #source < 20000 or #source > 500000
        or not source:match("^local STANCE_RELEASE")
        or not source:find("StanceEngine.RestoreNoRefresh", 1, true)
        or not source:find("StanceEngine.RefreshOneShot", 1, true)
        or not source:find("StanceEngine.AbandonOneShotOnRespawn", 1, true) then
        state.loadError = "Dev engine download invalid/stale: required v3 methods not found"
        return nil, state.loadError
    end
    local parsed, fn = pcall(function() return loadstring(source) end)
    if not parsed or type(fn) ~= "function" then
        state.loadError = "Matcha could not compile the updated Dev engine"
        return nil, state.loadError
    end
    local ran, err = pcall(function() fn() end)
    local loaded = _G.StanceAnimationEngine
    if not ran or not readyEngine(loaded) then
        state.loadError = "Dev engine failed to start: " .. (not ran and tostring(err) or "one-shot methods missing")
        return nil, state.loadError
    end
    state.engine, state.ownsEngine = loaded, true
    state.loadError = nil
    log("Updated Dev engine initialized (no Stance UI needed)")
    return loaded
end

local function snapshot(e)
    local ok, info = pcall(function() return e.Status() end)
    if not ok or type(info) ~= "table" then return nil end
    return info
end
local function currentCharacter()
    return Player and Player.Character
end
local function validId(value)
    local id = tostring(value or ""):match("^%s*(%d+)%s*$")
    if not id or #id < 6 or #id > 17 then return nil end
    return id
end
local function motion(character)
    if not character then return "No character" end
    local humanoid = character:FindFirstChild("Humanoid")
    if humanoid then
        local ok, direction = pcall(function() return humanoid.MoveDirection end)
        if ok and direction then
            local checked, amount = pcall(function() return direction.Magnitude end)
            if checked and type(amount) == "number" and amount > 0.07 then
                return "MoveDirection"
            end
        end
        local jumpOK, jumping = pcall(function() return humanoid.Jump end)
        if jumpOK and jumping == true then return "Jump" end
    end
    local root = character:FindFirstChild("HumanoidRootPart")
    if root then
        local ok, velocity = pcall(function() return root.AssemblyLinearVelocity end)
        if ok and velocity then
            local read, horizontal = pcall(function()
                return math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
            end)
            if read and type(horizontal) == "number" and horizontal > 2.0 then
                return "Horizontal speed"
            end
        end
    end
    if type(iskeypressed) == "function" then
        local focused = true
        if type(isrbxactive) == "function" then
            local ok, active = pcall(isrbxactive)
            if ok then focused = active end
        end
        if focused then
            -- W/A/S/D, arrows and Space. Root velocity covers controller movement.
            for _, vk in ipairs({0x57,0x41,0x53,0x44,0x25,0x26,0x27,0x28,0x20}) do
                local ok, pressed = pcall(iskeypressed, vk)
                if ok and pressed == true then return "Movement/jump key" end
            end
        end
    end
    return nil
end

local function applyCall(fn)
    local ok, success, detail = pcall(fn)
    if not ok then return false, "Engine call raised an error" end
    if success ~= true then return false, tostring(detail or "Engine declined operation") end
    return true, detail
end

local function finish(message, result)
    state.active = false
    state.phase = "idle"
    state.character = nil
    state.last = message
    state.refreshOK = result
    log(message)
end

local function stopInternal(reason)
    if not state.active then return true, "No one-shot emote active" end
    local e = state.engine
    if not readyEngine(e) then return fail("Engine missing during cleanup; rejoin Roblox") end
    if currentCharacter() ~= state.character then
        -- No references to restore on the freshly spawned character.
        local ok, detail = applyCall(function() return e.AbandonOneShotOnRespawn() end)
        if not ok then return fail("Respawn cleanup failed: " .. tostring(detail)) end
        finish("Character changed; cleared pending emote replacement", true)
        return true, "Respawn cleanup complete"
    end
    if state.phase == "arming" then
        local restored, detail = applyCall(function() return e.Restore() end)
        if not restored then return fail("Could not restore pending idle slots: " .. tostring(detail)) end
        finish("Stopped before one-shot disarm (" .. tostring(reason) .. ")", true)
        return true, detail
    end
    -- Once the original references are back, we never re-apply the UGC ID.
    -- Deliberate refresh asks Roblox to transition away from the old idle track.
    local refreshed, detail = applyCall(function() return e.RefreshOneShot() end)
    if not refreshed then
        finish("Idle slots already restored, but stop refresh failed: " .. tostring(detail), false)
        return false, tostring(detail)
    end
    finish("One-shot emote ended (" .. tostring(reason) .. "); original idle retained", true)
    return true, detail
end

local function monitor(token)
    local e = state.engine
    local char = state.character
    local start = state.began
    local readyAt = nil
    local retrySince = nil
    while state.active and state.token == token do
        task.wait(0.1)
        if not state.active or state.token ~= token then break end

        if currentCharacter() ~= char then
            stopInternal("respawn")
            break
        end
        local moveReason = motion(char)
        if moveReason then
            stopInternal("movement: " .. moveReason)
            break
        end

        if state.phase == "arming" then
            local report = snapshot(e)
            if report and report.total >= 2 and report.synced >= 2 then
                if not readyAt then
                    readyAt = tick()
                    log("2/2 idle references applied; allowing idle track to start")
                end
            end
            if readyAt and tick() - readyAt >= 1.0 then
                local ok, detail = applyCall(function() return e.RestoreNoRefresh() end)
                if ok then
                    state.phase = "playing"
                    state.last = "Original idle references restored WITHOUT interrupting current track"
                    log("ONE-SHOT ARMED: originals restored; emote should continue until movement")
                    log("Walk/jump to cancel; it should NOT restart when you stop.")
                    retrySince = nil
                else
                    retrySince = retrySince or tick()
                    if tick() - retrySince > 2.5 then
                        log("Disarm failed: " .. tostring(detail) .. " - cleaning up normally")
                        stopInternal("disarm timeout")
                        break
                    end
                end
            end
            if tick() - start >= 5 and not readyAt then
                log("Animation never appeared in both idle slots. Restoring.")
                stopInternal("no slot readback")
                break
            end
        elseif state.phase == "playing" then
            if tick() - start >= state.expires then
                stopInternal("safety time limit")
                break
            end
        else
            stopInternal("unexpected phase")
            break
        end
    end
end

function P.Report()
    log("Version=" .. VERSION .. "; one-shot Marketplace/UGC ID test")
    local e, why = engine()
    if not e then return fail(why) end
    local report = snapshot(e)
    if not report then return fail("Engine status API failed") end
    log("Rig=" .. tostring(report.rig) .. "; memory capability=" .. tostring(report.available))
    log("Reason=" .. tostring(report.reason))
    log("Requested states=" .. tostring(report.requestedStates)
        .. "; slot readback=" .. tostring(report.synced) .. "/" .. tostring(report.total))
    log("Stage=" .. tostring(state.phase) .. "; current ID=" .. tostring(state.id))
    log("No server replication can be verified inside Matcha. Use a second player.")
    return true, "Diagnostic printed"
end

function P.Play(value, maxSeconds)
    if state.active then return fail("An emote is already active. Move or call .Stop() first.") end
    local id = validId(value)
    if not id then return fail("Enter an underlying animation ID with 6-17 digits") end
    local e, why = engine()
    if not e then return fail(why) end
    local report = snapshot(e)
    if not report or report.available ~= true or report.rig ~= "R15" then
        return fail(report and report.reason or "R15 rig/memory engine unavailable")
    end
    if type(report.requestedStates) ~= "number" or report.requestedStates > 0 then
        return fail("Existing Stance animation selection active; restore it before testing")
    end
    local char = currentCharacter()
    if not char then return fail("Character unavailable") end
    local moving = motion(char)
    if moving then return fail("Stand still before starting emote (" .. moving .. ")") end
    local duration = tonumber(maxSeconds) or 18
    if duration < 6 then duration = 6 end
    if duration > 60 then duration = 60 end
    local applied, detail = applyCall(function()
        return e.ApplyStateIds({ idle = { tonumber(id), tonumber(id) } })
    end)
    if not applied then return fail(detail) end
    state.active = true
    state.phase = "arming"
    state.id = id
    state.token = state.token + 1
    state.character = char
    state.began = tick()
    state.expires = duration
    state.last = "Waiting to confirm idle substitution"
    log("Triggered UGC clip " .. id .. " as a temporary R15 idle animation")
    log("Expected: start once, restore original idle IDs automatically, cancel on movement")
    log("Safety timeout: " .. tostring(duration) .. " seconds; manual .Stop() available")
    local token = state.token
    task.spawn(function() monitor(token) end)
    return true, "One-shot emote experiment started; visual and server replication UNVERIFIED"
end

function P.Stop()
    return stopInternal("manual Stop")
end

function P.Check()
    log("Version=" .. VERSION .. "; active=" .. tostring(state.active)
        .. "; phase=" .. tostring(state.phase) .. "; clip=" .. tostring(state.id))
    log("Last: " .. tostring(state.last)
        .. "; refresh success=" .. tostring(state.refreshOK))
    local e = state.engine
    if readyEngine(e) then
        local report = snapshot(e)
        if report then
            log("Engine requested states=" .. tostring(report.requestedStates)
                .. "; readback=" .. tostring(report.synced) .. "/" .. tostring(report.total))
            log("Engine last=" .. tostring(report.last))
        end
    end
    return true, state.last
end

function P.Unload()
    if state.active then
        local ok, detail = P.Stop()
        if not ok then return fail("Cleanup failed: " .. tostring(detail)) end
    end
    state.token = state.token + 1
    if state.ownsEngine and _G.StanceAnimationEngine == state.engine
        and type(_G.StanceEngineUnload) == "function" then
        local ok = pcall(_G.StanceEngineUnload)
        if not ok then return fail("Engine unload failed; rejoin to reset") end
    end
    state.engine, state.ownsEngine = nil, false
    if _G.StanceOneShotEmote == P then _G.StanceOneShotEmote = nil end
    log("Unloaded cleanly")
    return true, "Unloaded"
end

_G.StanceOneShotEmote = P
log("VERSION " .. VERSION .. " loaded. Call .Report() then .Play('118644064755644')")
log("This test targets one-shot lifecycle only; another client must verify replication.")
