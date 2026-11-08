-- Stance Dev - Emote Replication Stop Experiment V4
-- ORIGINAL UNOBFUSCATED MATCHA LUA VM SCRIPT (no embedded usernames)
-- Public Dev-only experiment; does not use /e or protected scripts.
-- Local playback + peer visibility confirmed with V3.
-- V3's local-only PlatformStand refresh did not cancel the animation on peers.
--
-- V4 hypothesis: V3 restored the spoofed AnimationId before walking,
-- so a peer's replicated animation track never received a normal stop.
-- V4 leaves the substituted idle IDs intact until the character moves,
-- lets Roblox's Animate script transition to walking, THEN restores the IDs.
-- No PlatformStand pulse on the walking stop path.
--
-- A remote stop is NOT guaranteed. Have another player watch your avatar.
-- Underlying animation clip IDs only (Marketplace item IDs may differ).
-- Raw-memory experiments can crash Roblox. Test in a disposable R15 session.
--
-- Loader:
-- loadstring(httpget("https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Dev_Emote_MovementStop_v4.lua"))()
-- _G.StanceEmoteStopV4.Report()
-- _G.StanceEmoteStopV4.Play("118644064755644")
-- (start walking for about 1 second; compare observer's screen)
-- _G.StanceEmoteStopV4.Check()
-- _G.StanceEmoteStopV4.Stop() -- emergency cleanup, not remote-stop proof
-- _G.StanceEmoteStopV4.Unload()

local VERSION = "v4-replicated-stop-20261107"
local URL = "https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Animation_Engine.lua?movement-stop-v4"
local TAG = "[Stance/StopV4] "
local function log(message) print(TAG .. tostring(message)) end
local function fail(message)
    log("BLOCKED: " .. tostring(message))
    return false, tostring(message)
end

-- Do not let V3, V4, and a running Stance UI compete for one idle slot.
local function unloadPrevious(reference, label)
    if type(reference) == "table" and type(reference.Unload) == "function" then
        local ok, result, reason = pcall(function() return reference.Unload() end)
        if not ok or result == false then
            log("Could not unload " .. label .. ": " .. tostring(reason))
            return false
        end
    end
    return true
end
if not unloadPrevious(_G.StanceDevEmoteSlotProbe,"old slot probe") then return end
if not unloadPrevious(_G.StanceOneShotEmote,"V3") then return end
if not unloadPrevious(_G.StanceEmoteStopV4,"older V4") then return end

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local P = {Version = VERSION}
local st = {
    active=false,phase="idle",token=0,id=nil,char=nil,began=0,
    engine=nil,owned=false,loadAttempted=false,loadError=nil,
    timeout=25,readbackAt=nil,last="Not started",
    keyDetected=false,confirmedMove=false,peerStop="Not measured",
}

local function ready(e)
    return type(e)=="table" and type(e.ApplyStateIds)=="function"
        and type(e.Restore)=="function" and type(e.RestoreNoRefresh)=="function"
        and type(e.AbandonOneShotOnRespawn)=="function" and type(e.Status)=="function"
end
local function engine()
    local e = _G.StanceAnimationEngine
    if ready(e) then st.engine=e; return e end
    if e ~= nil then return nil,"An incompatible/old engine is already loaded. Unload it or rejoin, then run V4 alone." end
    if st.loadAttempted then return nil,st.loadError or "Dev engine initialization failed" end
    st.loadAttempted=true
    if type(httpget)~="function" or type(loadstring)~="function" then
        st.loadError="Matcha httpget/loadstring unavailable"
        return nil,st.loadError
    end
    log("Loading existing Dev animation engine (V4 reuses its validated memory adapter)")
    local fetched,source=pcall(function() return httpget(URL) end)
    if not fetched or type(source)~="string" or #source<20000 or #source>500000
        or not source:match("^local STANCE_RELEASE")
        or not source:find("StanceEngine.RestoreNoRefresh",1,true) then
        st.loadError="Dev animation engine fetch failed or returned stale/invalid content"
        return nil,st.loadError
    end
    local compiled,fn=pcall(function() return loadstring(source) end)
    if not compiled or type(fn)~="function" then
        st.loadError="Dev animation engine compilation failed"
        return nil,st.loadError
    end
    local ran,problem=pcall(fn)
    e=_G.StanceAnimationEngine
    if not ran or not ready(e) then
        st.loadError="Engine did not initialize: "..(not ran and tostring(problem) or "required API missing")
        return nil,st.loadError
    end
    st.engine=e;st.owned=true
    log("Dev animation engine loaded successfully")
    return e
end
local function status(e)
    local ok,r=pcall(function() return e.Status() end)
    if ok and type(r)=="table" then return r end
    return nil
end
local function call(f)
    local ok,a,b=pcall(f)
    if not ok then return false,"VM/engine error: "..tostring(a) end
    if a~=true then return false,tostring(b) end
    return true,b
end
local function clipId(input)
    local s=tostring(input or ""):match("^%s*(%d+)%s*$")
    if not s or #s<6 or #s>17 then return nil end
    return s
end
local function currentChar()
    return player and player.Character
end

-- Returns independently logged movement signals. Keypress by itself does
-- not prove Roblox entered its real walking animation state.
local function detectMovement(char)
    if not char then return false,false,nil end
    local root=char:FindFirstChild("HumanoidRootPart")
    if root then
        local ok,v=pcall(function() return root.AssemblyLinearVelocity end)
        if ok and v then
            local valid,speed=pcall(function()
                return math.sqrt(v.X*v.X+v.Z*v.Z)
            end)
            if valid and type(speed)=="number" and speed>2.0 then
                return true,true,"horizontal root speed "..string.format("%.1f",speed)
            end
        end
    end
    local hum=char:FindFirstChild("Humanoid")
    if hum then
        local ok,direction=pcall(function() return hum.MoveDirection end)
        if ok and direction then
            local valid,amount=pcall(function() return direction.Magnitude end)
            if valid and type(amount)=="number" and amount>0.09 then
                return true,true,"Humanoid.MoveDirection"
            end
        end
    end
    if type(iskeypressed)=="function" then
        for _,code in ipairs({0x57,0x41,0x53,0x44,0x25,0x26,0x27,0x28,0x20}) do
            local ok,pressed=pcall(iskeypressed,code)
            if ok and pressed==true then
                return true,false,"movement/jump key"
            end
        end
    end
    return false,false,nil
end

local function clearState(message)
    st.active=false
    st.phase="idle"
    st.last=message
    st.char=nil
    log(message)
end

local function cancelUnverified(reason)
    if not st.active then return true,"No active emote" end
    local e=st.engine
    if not ready(e) then return fail("Engine vanished; rejoin to reset animations") end
    if currentChar()~=st.char then
        local ok,err=call(function() return e.AbandonOneShotOnRespawn() end)
        if not ok then return fail(err) end
        clearState("Respawn: cleared prior emote selection")
        return true,"Respawn cleared"
    end
    local ok,err=call(function() return e.Restore() end)
    if not ok then return fail("Original idle restoration failed: "..tostring(err)) end
    clearState("Cleanup ("..tostring(reason).."): originals restored. REMOTE STOP NOT VERIFIED.")
    return true,err
end

local function stopAfterMovement(token,initialSignal)
    local start=tick()
    st.phase="walking-transition"
    log("Motion detected ("..initialSignal.."). KEEP WALKING for at least 1 second.")
    log("Waiting 0.65s for Roblox Animate to naturally stop the spoofed idle track.")

    local confirmed=false
    local signal=initialSignal
    while tick()-start<0.65 do
        if not st.active or st.token~=token then return end
        if currentChar()~=st.char then
            cancelUnverified("respawn")
            return
        end
        local moving,real,why=detectMovement(st.char)
        if moving then signal=why or signal end
        if real then confirmed=true end
        task.wait(0.08)
    end

    st.confirmedMove=confirmed
    if not confirmed then
        log("NOTE: Matcha could not verify physical locomotion; only input was detected.")
        log("Normal Animate track-stop replication may not have happened.")
    else
        log("Movement corroborated by physical/MoveDirection signal: "..tostring(signal))
    end

    -- Original idle AnimationId was still present during the walk transition.
    -- Now disarm without a PlatformStand pulse, which is only a local refresh.
    local e=st.engine
    local restored,reason=false,""
    for _=1,12 do
        if not st.active or st.token~=token then return end
        restored,reason=call(function() return e.RestoreNoRefresh() end)
        if restored then break end
        task.wait(0.12)
    end
    if not restored then
        log("No-refresh restoration failed: "..tostring(reason))
        cancelUnverified("failed delayed restore")
        return
    end
    st.peerStop="Awaiting second-client observation"
    clearState("Delayed restore completed AFTER movement transition, no PlatformStand pulse.")
    log("Check the OTHER player's screen: did the UGC emote stop when you walked?")
    log("If it still plays remotely, V4 cannot claim replicated cancellation.")
end

local function monitor(token)
    local e=st.engine
    local start=st.began
    while st.active and st.token==token do
        task.wait(0.10)
        if not st.active or st.token~=token then break end
        if currentChar()~=st.char then
            cancelUnverified("respawn")
            break
        end
        if st.phase=="arming" then
            local r=status(e)
            if r and type(r.total)=="number" and r.total>=2 and r.synced>=2 then
                if not st.readbackAt then
                    st.readbackAt=tick()
                    log("2/2 UGC idle references applied; waiting for local emote startup")
                end
                if tick()-st.readbackAt>=1.0 then
                    st.phase="playing"
                    st.last="Animation IDs remain spoofed until actual locomotion transition"
                    log("READY: UGC clip active as idle; original references NOT YET restored.")
                    log("Now WALK for ~1 second; V4 will restore originals after a delay.")
                end
            elseif tick()-start>5 then
                cancelUnverified("No 2/2 memory readback")
                break
            end
        elseif st.phase=="playing" then
            local moving,real,reason=detectMovement(st.char)
            if moving then
                st.keyDetected=true
                if real then st.confirmedMove=true end
                stopAfterMovement(token,reason or "movement")
                break
            end
            if tick()-start>st.timeout then
                log("Safety timeout reached. Restoring originals; remote stop may NOT replicate.")
                cancelUnverified("timeout")
                break
            end
        elseif st.phase=="walking-transition" then
            -- transition is managed by stopAfterMovement, not this loop
            break
        else
            cancelUnverified("Unknown phase")
            break
        end
    end
end

function P.Report()
    log("Version="..VERSION.." | TEST: allow natural walking transition before restoring idle IDs")
    local e,why=engine()
    if not e then return fail(why) end
    local r=status(e)
    if not r then return fail("Engine.Status() unavailable") end
    log("Rig="..tostring(r.rig).."; capability="..tostring(r.available).."; reason="..tostring(r.reason))
    log("Selected states="..tostring(r.requestedStates).."; readback="..tostring(r.synced).."/"..tostring(r.total))
    log("Previous V3: local stop worked but remote avatar kept playing")
    log("V4 does not claim success until second client confirms cancellation")
    return true,"Report printed"
end

function P.Play(input,duration)
    if st.active then return fail("Test already active. Wait for movement stop or call .Stop()") end
    local id=clipId(input)
    if not id then return fail("Enter an underlying animation clip ID with 6-17 digits") end
    local e,why=engine()
    if not e then return fail(why) end
    local r=status(e)
    if not r or r.available~=true or r.rig~="R15" then
        return fail(r and r.reason or "R15/engine unavailable")
    end
    if type(r.requestedStates)~="number" or r.requestedStates>0 then
        return fail("Other Stance animation states are active. Restore/unload them before testing.")
    end
    local char=currentChar()
    if not char then return fail("Character unavailable") end
    local moving,_,reason=detectMovement(char)
    if moving then return fail("Stand still to begin ("..tostring(reason)..")") end

    local seconds=tonumber(duration) or 25
    if seconds<10 then seconds=10 end
    if seconds>60 then seconds=60 end
    local applied,reason=call(function()
        return e.ApplyStateIds({ idle={tonumber(id),tonumber(id)} })
    end)
    if not applied then return fail(reason) end

    st.active=true
    st.phase="arming"
    st.char=char
    st.token=st.token+1
    st.id=id
    st.began=tick()
    st.timeout=seconds
    st.readbackAt=nil
    st.keyDetected=false
    st.confirmedMove=false
    st.peerStop="Not measured"
    st.last="Awaiting 2/2 idle readback"
    log("Triggering UGC clip "..id..". IMPORTANT: do NOT move until READY.")
    log("Unlike V3, the custom idle references remain until walking is established.")
    local token=st.token
    task.spawn(function()
        local ok,err=pcall(function() monitor(token) end)
        if not ok and st.active and st.token==token then
            log("Monitor failed: "..tostring(err).."; restoring original idle IDs.")
            cancelUnverified("monitor error")
        end
    end)
    return true,"V4 test started. Remote stop still unverified."
end

function P.Check()
    log("Version="..VERSION.."; active="..tostring(st.active).."; phase="..tostring(st.phase)
        .."; candidate="..tostring(st.id))
    log("Movement input detected="..tostring(st.keyDetected)
        .."; physical/MoveDirection corroborated="..tostring(st.confirmedMove))
    log("Last="..tostring(st.last).."; remote stop="..tostring(st.peerStop))
    if ready(st.engine) then
        local r=status(st.engine)
        if r then log("Engine states="..tostring(r.requestedStates)
            .."; ID readback="..tostring(r.synced).."/"..tostring(r.total)) end
    end
    log("Second client's visual result is required.")
    return true,st.last
end
function P.Stop()
    if not st.active then return true,"No active emote" end
    st.token=st.token+1
    return cancelUnverified("manual Stop; no replicated track stop verified")
end
function P.Unload()
    if st.active then
        local ok,reason=P.Stop()
        if not ok then return fail("Could not restore engine: "..tostring(reason)) end
    end
    st.token=st.token+1
    if st.owned and _G.StanceAnimationEngine==st.engine
        and type(_G.StanceEngineUnload)=="function" then
        local ok=pcall(_G.StanceEngineUnload)
        if not ok then return fail("Engine cleanup failed; rejoin to reset") end
    end
    st.engine=nil;st.owned=false
    if _G.StanceEmoteStopV4==P then _G.StanceEmoteStopV4=nil end
    log("Unloaded")
    return true
end

_G.StanceEmoteStopV4=P
log("VERSION "..VERSION.." loaded. Use .Report() then .Play('118644064755644').")
log("V4 tests whether a natural walking transition can replicate the track stop.")
