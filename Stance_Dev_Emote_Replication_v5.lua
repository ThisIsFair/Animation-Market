-- Stance Dev - Marketplace/UGC Emote V5 (quiet-stage + remote stop investigation)
-- ORIGINAL, UNOBFUSCATED LuaVM experiment. No player names or account IDs.
--
-- V3: emote plays for other players, local movement stop works, remote stop fails.
-- V4: waiting 0.65 seconds before ID restore did not solve remote stop.
-- V5: stage the idle AnimationIds WHILE THE PLAYER IS WALKING, with
--      NO PlatformStand pulse at all. Natural walk->idle should begin clip.
--      On movement stop, keep animation IDs unchanged for the OTHER CLIENT
--      to observe whether track stopping replicates without an ID mutation.
--      Only THEN Finish() to restore normal idle references silently.
--
-- REQUIREMENTS: R15, valid/version-checked Matcha memory engine, second client.
-- SERVER REPLICATION OF THE STOP IS NOT YET CONFIRMED.
-- This is an experimental memory test and can crash Roblox; rejoin if stuck.
--
-- RUN IN A FRESH ROBLOX SESSION:
-- loadstring(httpget("https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Dev_Emote_Replication_v5.lua"))()
-- _G.StanceEmoteV5.Report()
-- _G.StanceEmoteV5.Arm("118644064755644")
-- Follow console: start WALKING; keep walking until "ARMED"; then STOP to play.
-- Walk again to test second-client cancellation. KEEP walking.
-- While still walking, call _G.StanceEmoteV5.Finish() to restore idle.
-- _G.StanceEmoteV5.Check()
-- _G.StanceEmoteV5.Unload()
--
-- IMPORTANT: Leaving the replacement armed and returning to idle can replay
-- the emote. That's intentional for isolating a replication problem; Finish()
-- removes the replacement, preferably while walking.
-- No /e, no deobfuscation, no Matcha Pro, no additional network requests.

local VERSION = "v5-quiet-stage-remote-stop-20261107"
local ENGINE_URL = "https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Dev_Emote_Quiet_Engine_v5.lua?build=b62ada4"
local TAG = "[Stance/EmoteV5] "
local function log(s) print(TAG..tostring(s)) end
local function fail(s)
    log("BLOCKED: "..tostring(s))
    return false,tostring(s)
end

-- Avoid overlapping active animation tests.
local function cleanPrevious(name)
    local old = _G[name]
    if type(old) == "table" and type(old.Unload) == "function" then
        local ok, success = pcall(function() return old.Unload() end)
        if not ok or success ~= true then
            log("Cannot unload "..name.."; rejoin to reset the previous experiment.")
            return false
        end
    end
    return true
end
if not cleanPrevious("StanceOneShotEmote") then return end
if not cleanPrevious("StanceEmoteStopV4") then return end
if not cleanPrevious("StanceDevEmoteSlotProbe") then return end
if not cleanPrevious("StanceEmoteV5") then return end

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local P = {Version = VERSION}
local s = {
    live=false,phase="idle",token=0,id=nil,
    char=nil,engine=nil,ownsEngine=false,initAttempted=false,initError=nil,
    createdAt=0,armAt=0,startedAt=0,stopAt=0,
    stableFrames=0,confirmedWalking=false,localMotion="unavailable",
    last="Not started",duration=45,missingFrames=0,
}
local function ready(e)
    return type(e)=="table"
        and type(e.StageQuietIds)=="function"
        and type(e.RestoreNoRefresh)=="function"
        and type(e.AbandonOneShotOnRespawn)=="function"
        and type(e.Status)=="function"
end

local function initEngine()
    local engine=_G.StanceAnimationEngine
    if ready(engine) then s.engine=engine; return engine end
    if engine~=nil then return nil,"A different Stance engine is loaded. Rejoin Roblox and run V5 alone." end
    if s.initAttempted then return nil,s.initError or "Unable to initialize Dev V5 engine" end
    s.initAttempted=true
    if type(httpget)~="function" or type(loadstring)~="function" then
        s.initError="Matcha HTTP/compile functions unavailable"
        return nil,s.initError
    end
    log("Initializing isolated quiet-stage engine (NO PlatformStand pulse during emote)")
    local downloaded,source=pcall(function() return httpget(ENGINE_URL) end)
    if not downloaded or type(source)~="string" or #source<40000 or #source>150000
        or not source:find('20261107-emote-quiet-v5',1,true)
        or not source:find('StanceEngine.StageQuietIds',1,true) then
        s.initError="Quiet-stage engine fetch failed or returned stale content"
        return nil,s.initError
    end
    local ok,chunk=pcall(function() return loadstring(source) end)
    if not ok or type(chunk)~="function" then
        s.initError="Quiet-stage engine compilation failed"
        return nil,s.initError
    end
    local ran,err=pcall(function() chunk() end)
    engine=_G.StanceAnimationEngine
    if not ran or not ready(engine) then
        s.initError="Quiet-stage engine initialization failed: "..tostring(err)
        return nil,s.initError
    end
    s.engine=engine
    s.ownsEngine=true
    log("Quiet-stage engine ready; no animation ID changes have been requested")
    return engine
end

local function getStatus(engine)
    local ok,value=pcall(function() return engine.Status() end)
    if ok and type(value)=="table" then return value end
    return nil
end
local function action(fn)
    local ok,success,detail=pcall(fn)
    if not ok then return false,tostring(success) end
    if success~=true then return false,tostring(detail) end
    return true,detail
end
local function exactClipId(value)
    local id=tostring(value or ""):match("^%s*(%d+)%s*$")
    if not id or #id<6 or #id>17 then return nil end
    return id
end
local function currentChar()
    return player and player.Character
end
local function realMotion(char)
    if not char then return false,"character absent" end
    local root=char:FindFirstChild("HumanoidRootPart")
    if root then
        local ok,v=pcall(function() return root.AssemblyLinearVelocity end)
        if ok and v then
            local pass,mag=pcall(function()
                return math.sqrt(v.X*v.X+v.Z*v.Z)
            end)
            if pass and type(mag)=="number" and mag>2.5 then
                return true,"root speed "..string.format("%.2f",mag)
            end
        end
    end
    local hum=char:FindFirstChild("Humanoid")
    if hum then
        local ok,dir=pcall(function() return hum.MoveDirection end)
        if ok and dir then
            local pass,mag=pcall(function() return dir.Magnitude end)
            if pass and type(mag)=="number" and mag>0.10 then
                return true,"Humanoid.MoveDirection"
            end
        end
    end
    return false,"no physical movement observed"
end

local function restoreOnce()
    local e=s.engine
    if not ready(e) then return false,"Engine not available" end
    -- Do not use the full Restore() path because it triggers the
    -- PlatformStand pulse that caused the visual ground dip.
    for i=1,14 do
        local ok,detail=action(function() return e.RestoreNoRefresh() end)
        if ok then return true,detail end
        if i==14 then return false,detail end
        task.wait(0.14)
    end
    return false,"Restore retries exhausted"
end
local function finishState(message)
    s.live=false
    s.phase="idle"
    s.char=nil
    s.last=message
    log(message)
end
local function endSession(reason)
    if not s.live then return true,"Already inactive" end
    local char=currentChar()
    if char~=s.char then
        local ok,detail=action(function() return s.engine.AbandonOneShotOnRespawn() end)
        if not ok then return fail(detail) end
        finishState("Character changed; abandoned old emote replacements")
        return true,detail
    end
    if s.phase=="await-walking" then
        finishState("Stopped before any writes ("..reason..")")
        return true,"Nothing to restore"
    end
    local ok,detail=restoreOnce()
    if not ok then return fail("Could not restore original idle references: "..tostring(detail)) end
    finishState("Original idle references restored without PlatformStand ("..reason..")")
    return true,detail
end

local function loop(token)
    local expiration=s.createdAt+s.duration
    local waitingStart=nil
    local stationary=0
    local logOnce=false
    while s.live and s.token==token do
        task.wait(0.11)
        if not s.live or s.token~=token then break end
        if currentChar()~=s.char then endSession("respawn"); break end
        if tick()>expiration then
            log("Safety timeout. Cleaning up original idle references now.")
            endSession("timeout")
            break
        end
        local moved,details=realMotion(s.char)
        s.localMotion=details
        if s.phase=="await-walking" then
            if moved then
                log("Movement confirmed ("..details.."). Staging clip WITHOUT PlatformStand.")
                local ok,why=action(function()
                    return s.engine.StageQuietIds({idle={tonumber(s.id),tonumber(s.id)}})
                end)
                if not ok then
                    fail("Quiet staging failed: "..tostring(why))
                    endSession("stage failure")
                    break
                end
                s.phase="applying"
                s.armAt=tick()
                s.last="Waiting for guarded memory readback while moving"
                log("Keep walking until the two idle slots report 2/2.")
            end
        elseif s.phase=="applying" then
            local status=getStatus(s.engine)
            if status and status.synced>=2 and status.total>=2 then
                s.phase="armed"
                s.last="2/2 quiet-stage ID readback. Awaiting natural walk-to-idle transition."
                log("ARMED: 2/2 idle IDs substituted; NO PlatformStand pulse issued.")
                log("STOP WALKING to play the emote. Another player should watch.")
            elseif tick()-s.armAt>8 then
                fail("Timed out waiting for 2/2 memory write. Restoring.")
                endSession("memory stage timeout")
                break
            end
        elseif s.phase=="armed" then
            if not moved then
                stationary=stationary+0.11
                if stationary>0.35 then
                    s.phase="playing"
                    s.startedAt=tick()
                    s.last="Walk-to-idle transition observed; NO PlatformStand pulse was used"
                    log("IDLE DETECTED: check whether UGC emote plays without ground dip.")
                    log("When it plays, WALK again. V5 holds ID unchanged for remote-stop test.")
                end
            else
                stationary=0
            end
        elseif s.phase=="playing" then
            if moved then
                s.phase="walking-hold"
                s.stopAt=tick()
                s.confirmedWalking=true
                s.last="Actual movement detected with ID still spoofed: waiting for peer stop"
                log("WALKING CONFIRMED: IDs still unchanged. Do NOT stop walking yet.")
                log("CHECK SECOND DEVICE NOW: did the emote stop there?")
                log("While still walking, run _G.StanceEmoteV5.Finish() to restore IDs.")
            end
        elseif s.phase=="walking-hold" then
            if moved then
                if not logOnce and tick()-s.stopAt>2 then
                    logOnce=true
                    log("2+ seconds of walking without restoring AnimationId.")
                    log("If the other client still sees emote, the cause is NOT early ID restoration alone.")
                    log("Run .Finish() while walking to prevent idle repeat.")
                end
            else
                if not waitingStart then waitingStart=tick() end
                if tick()-waitingStart>0.6 then
                    log("Stopped walking before Finish(); emote MAY replay in idle.")
                    log("Use .Finish() to restore original references.")
                    waitingStart=tick()+30
                end
            end
        else
            fail("Unexpected internal phase")
            endSession("state mismatch")
            break
        end
    end
end

function P.Report()
    log("Version="..VERSION.."; staging avoids the PlatformStand pulse")
    log("This test isolates replicated STOP behavior; remote stop still unverified")
    local engine,why=initEngine()
    if not engine then return fail(why) end
    local status=getStatus(engine)
    if not status then return fail("Cannot obtain engine Status()") end
    log("Rig="..tostring(status.rig).."; memory capability="..tostring(status.available))
    log("Reason="..tostring(status.reason))
    log("Requested states="..tostring(status.requestedStates)
        .."; readback="..tostring(status.synced).."/"..tostring(status.total))
    return true,"Report printed"
end

function P.Arm(value,timeoutSeconds)
    if s.live then return fail("A test is active. Use .Finish() or .Stop() first") end
    local id=exactClipId(value)
    if not id then return fail("Need an underlying animation clip ID (6-17 digits)") end
    local engine,why=initEngine()
    if not engine then return fail(why) end
    local stat=getStatus(engine)
    if not stat or stat.available~=true or stat.rig~="R15" then
        return fail(stat and stat.reason or "R15/engine unavailable")
    end
    if type(stat.requestedStates)~="number" or stat.requestedStates>0 then
        return fail("Existing Stance animations selected; rejoin/unload before test")
    end
    local char=currentChar()
    if not char then return fail("Character not loaded") end
    local duration=tonumber(timeoutSeconds) or 45
    if duration<15 then duration=15 end
    if duration>90 then duration=90 end
    s.live=true
    s.phase="await-walking"
    s.id=id
    s.char=char
    s.token=s.token+1
    s.createdAt=tick()
    s.duration=duration
    s.confirmedWalking=false
    s.last="Waiting for real character movement, no memory writes yet"
    log("ARM REQUESTED: clip "..id.." - begin WALKING now (WASD or controller).")
    log("No memory writes will happen until physical motion is confirmed.")
    local token=s.token
    task.spawn(function()
        local ok,problem=pcall(function() loop(token) end)
        if not ok and s.live and s.token==token then
            log("Monitor error: "..tostring(problem))
            endSession("monitor failure")
        end
    end)
    return true,"Arming queued; start walking now"
end

-- Disarm after enough walking; this is not proof of replicated stop.
function P.Finish()
    if not s.live then return true,"No active emote" end
    if s.phase=="walking-hold" then
        local moved,why=realMotion(s.char)
        if not moved then
            log("WARN: finishing while stationary can retrigger a cached idle track.")
            log("Best practice: keep walking while Finish restores the IDs.")
        else
            log("Finishing during movement ("..tostring(why)..")")
        end
    else
        log("Finish called in phase "..tostring(s.phase).."; will restore if needed")
    end
    s.token=s.token+1
    return endSession("Finish")
end

function P.Stop()
    s.token=s.token+1
    return endSession("manual emergency Stop")
end

function P.Check()
    log("Version="..VERSION.."; active="..tostring(s.live)
        .."; phase="..tostring(s.phase).."; ID="..tostring(s.id))
    log("Character movement="..tostring(s.localMotion)
        .."; confirmed walking="..tostring(s.confirmedWalking))
    log("Last="..tostring(s.last))
    if ready(s.engine) then
        local status=getStatus(s.engine)
        if status then
            log("Engine selected states="..tostring(status.requestedStates)
                .."; readback="..tostring(status.synced).."/"..tostring(status.total))
        end
    end
    log("Check the remote screen directly; this VM cannot read the replicated AnimationTrack.")
    return true,s.last
end

function P.Unload()
    if s.live then
        local ok,why=P.Stop()
        if not ok then return fail("Cannot clean up: "..tostring(why)) end
    end
    s.token=s.token+1
    if s.ownsEngine and _G.StanceAnimationEngine==s.engine
        and type(_G.StanceEngineUnload)=="function" then
        local ok=pcall(_G.StanceEngineUnload)
        if not ok then return fail("Engine cleanup failed; rejoin Roblox") end
    end
    s.engine=nil;s.ownsEngine=false
    if _G.StanceEmoteV5==P then _G.StanceEmoteV5=nil end
    log("Unloaded")
    return true
end

_G.StanceEmoteV5=P
log("VERSION "..VERSION.." loaded. Use .Report() then .Arm('118644064755644').")
log("All player identifiers are supplied at runtime; no username is embedded.")
