-- StanceEmotesTEST.lua (Dev only)
-- Single UGC/Marketplace CLIP animation test. No Roblox username or account ID.
-- Tested previously: an idle slot change can play an emote locally and on peers.
-- Prior normal start refresh causes a visible dip into the ground.
-- This version tries a SHORTER PlatformStand pulse for auto start.
-- Live behavior of short pulse and replicated STOP must be verified.
--
-- Load: loadstring(httpget("https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/StanceEmotesTEST.lua"))()
-- Play: _G.StanceEmotesTEST.Play("118644064755644")
-- Cancel: walk normally ~1-2 seconds, or use .Stop() to request a walk
-- Status: _G.StanceEmotesTEST.Check()
-- Emergency restore: _G.StanceEmotesTEST.Restore()
-- Manual fallback: _G.StanceEmotesTEST.SetMode("walk")
-- Return to short pulse mode: _G.StanceEmotesTEST.SetMode("pulse")
-- Tune pulse: _G.StanceEmotesTEST.SetPulse(0.03,0.025)
--
-- WARNING: This requires version-checked low-level animation ID and
-- PlatformStand memory writes. If your character behaves abnormally,
-- call .Restore() or rejoin Roblox. Use in a disposable R15 test session.
-- No /e, Matcha Pro, script deobfuscation, or teleportation is involved.
-- A client-local reset does not prove the peer's track stopped.

local VERSION = "20261107-quickpulse-2"
local TAG = "[StanceEmotesTEST] "
local ENGINE_URL =
    "https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Animation_Engine.lua?emotest=quickpulse-67a312"
local function log(message) print(TAG .. tostring(message)) end
local function deny(message)
    log("BLOCKED: " .. tostring(message))
    return false, tostring(message)
end

local previous = _G.StanceEmotesTEST
if type(previous) == "table" and type(previous.Unload) == "function" then
    local ok, result = pcall(function() return previous.Unload() end)
    if not ok or result ~= true then
        log("Previous emote test could not unload. Rejoin Roblox before using this version.")
        return
    end
end

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local P = {Version = VERSION}
local s = {
    engine=nil, ownsEngine=false, attempted=false, engineError=nil,
    active=false, phase="idle", token=0, clip=nil, char=nil,
    mode="pulse", before=0.03, after=0.025,
    startAt=0, stageAt=0, armedAt=0, last="Not started",
    cancelAt=0, expiry=35, retryAfter=0,
    sawMotion=false, lastReadback="0/0",
}

local function engineReady(e)
    return type(e) == "table"
        and type(e.Status) == "function"
        and type(e.StageQuietIds) == "function"
        and type(e.StageQuickPulseIds) == "function"
        and type(e.RestoreNoRefresh) == "function"
        and type(e.AbandonOneShotOnRespawn) == "function"
end

local function getEngine()
    local e = _G.StanceAnimationEngine
    if engineReady(e) then s.engine=e; return e end
    if e ~= nil then return nil, "Old Stance engine loaded. Rejoin to get the quick-pulse engine." end
    if s.attempted then return nil, s.engineError or "Engine unavailable" end
    s.attempted = true
    if type(httpget) ~= "function" or type(loadstring) ~= "function" then
        s.engineError = "Matcha httpget/loadstring unavailable"
        return nil,s.engineError
    end
    log("Loading existing Stance Dev animation engine (no separate helper files)")
    local ok,source = pcall(function() return httpget(ENGINE_URL) end)
    if not ok or type(source)~="string" or #source<20000 or #source>150000
        or not source:match("^local STANCE_RELEASE")
        or not source:find("StanceEngine.StageQuickPulseIds",1,true)
        or not source:find("StanceEngine.RestoreNoRefresh",1,true) then
        s.engineError="Engine download failed or cache returned an older version"
        return nil,s.engineError
    end
    local compiled,fn=pcall(function() return loadstring(source) end)
    if not compiled or type(fn)~="function" then
        s.engineError="Matcha could not compile the Dev engine"
        return nil,s.engineError
    end
    local launched,detail=pcall(function() fn() end)
    e=_G.StanceAnimationEngine
    if not launched or not engineReady(e) then
        s.engineError="Engine initialization failed: "..tostring(detail)
        return nil,s.engineError
    end
    s.engine=e;s.ownsEngine=true;s.engineError=nil
    log("Engine ready. Pulse is test-only; standard Stance animation packs unchanged.")
    return e
end

local function invoke(fn)
    local ok,result,detail=pcall(fn)
    if not ok then return false,tostring(result) end
    if result ~= true then return false,tostring(detail) end
    return true,detail
end
local function status(e)
    local ok,result=pcall(function() return e.Status() end)
    if ok and type(result)=="table" then return result end
    return nil
end
local function currentChar() return player and player.Character end
local function validId(value)
    local id=tostring(value or ""):match("^%s*(%d+)%s*$")
    if not id or #id<6 or #id>17 then return nil end
    return id
end
local function isMoving(char)
    if not char then return false end
    local root=char:FindFirstChild("HumanoidRootPart")
    if root then
        local ok,v=pcall(function() return root.AssemblyLinearVelocity end)
        if ok and v then
            local yes,mag=pcall(function()
                return math.sqrt(v.X*v.X+v.Z*v.Z)
            end)
            if yes and type(mag)=="number" and mag>2.0 then return true,"root speed "..string.format("%.2f",mag) end
        end
    end
    local hum=char:FindFirstChild("Humanoid")
    if hum then
        local ok,dir=pcall(function() return hum.MoveDirection end)
        if ok and dir then
            local yes,mag=pcall(function() return dir.Magnitude end)
            if yes and type(mag)=="number" and mag>0.09 then
                return true,"Humanoid.MoveDirection"
            end
        end
    end
    return false,"no movement"
end

local function readbackReady()
    local r=status(s.engine)
    if r then
        s.lastReadback=tostring(r.synced).."/"..tostring(r.total)
        return type(r.synced)=="number" and type(r.total)=="number"
            and r.total>=2 and r.synced>=2
    end
    return false
end

local function restoreOriginals()
    if not engineReady(s.engine) then return false,"Engine missing; rejoin Roblox" end
    if currentChar()~=s.char then
        return invoke(function() return s.engine.AbandonOneShotOnRespawn() end)
    end
    for _=1,15 do
        local ok,detail=invoke(function() return s.engine.RestoreNoRefresh() end)
        if ok then return true,detail end
        task.wait(0.12)
    end
    return false,"Could not restore animation IDs; rejoin Roblox"
end

local function finish(reason)
    s.active=false;s.phase="idle";s.char=nil
    s.last=reason
    log(reason)
end
local function cleanup(reason)
    if not s.active then return true,"Nothing active" end
    local ok,detail=restoreOriginals()
    if not ok then return deny("Restore failed: "..tostring(detail)) end
    s.token=s.token+1
    finish("Original idle IDs restored ("..reason.."), no extra PlatformStand pulse.")
    return true,detail
end

local function queueQuiet()
    local ok,detail=invoke(function()
        return s.engine.StageQuietIds({idle={tonumber(s.clip),tonumber(s.clip)}})
    end)
    if not ok then return false,detail end
    s.phase="quiet-staging";s.stageAt=tick()
    log("Quiet ID staging queued while walking; normal walk-to-idle will start emote.")
    return true,detail
end

local function run(token)
    local stillSince=nil
    while s.active and s.token==token do
        task.wait(0.08)
        if not s.active or s.token~=token then return end
        if currentChar()~=s.char then cleanup("respawn");return end
        if tick()-s.startAt>s.expiry then
            log("Safety timeout; restoring original idle IDs")
            cleanup("timeout")
            return
        end
        local moving,reason=isMoving(s.char)
        if s.phase=="pulse-staging" then
            if readbackReady() then
                s.phase="pulse-starting";s.armedAt=tick()
                log("2/2 IDs applied. Short PlatformStand pulse should have started the emote.")
            elseif tick()-s.stageAt>5 then
                log("Quick pulse never reached 2/2 readback. Restoring IDs.")
                cleanup("pulse staging failed")
                return
            end
        elseif s.phase=="pulse-starting" then
            if tick()-s.armedAt>=0.35 then
                s.phase="playing"
                s.last="Short pulse requested animation start (visual motion unverified)"
                log("PLAYING PHASE: verify emote started and whether the ground dip is reduced.")
                log("Walk normally to stop. Original idle IDs are still staged.")
            end
        elseif s.phase=="await-walk" then
            if moving then
                log("Real walking detected ("..tostring(reason)..")")
                local ok,detail=queueQuiet()
                if not ok then
                    deny("Quiet staging failed: "..tostring(detail))
                    cleanup("quiet staging error")
                    return
                end
            end
        elseif s.phase=="quiet-staging" then
            if readbackReady() then
                s.phase="quiet-armed";s.armedAt=tick()
                log("ARMED (quiet): 2/2 idle IDs. Stop walking to play.")
            elseif tick()-s.stageAt>6 then
                cleanup("quiet staging timeout")
                return
            end
        elseif s.phase=="quiet-armed" then
            if moving then
                stillSince=nil
            else
                stillSince=stillSince or tick()
                if tick()-stillSince>=0.35 then
                    s.phase="playing"
                    s.last="Walk-to-idle emote activation"
                    log("PLAYING PHASE: manual quiet-start expected, no PlatformStand dip.")
                end
            end
        elseif s.phase=="playing" or s.phase=="await-stop" then
            if moving then
                s.sawMotion=true
                s.phase="walking-cancel"
                s.cancelAt=tick()
                log("Actual movement detected; allowing normal Animate track transition.")
                log("Keep walking for about 1.5 seconds while IDs remain unchanged.")
            end
        elseif s.phase=="walking-cancel" then
            if tick()-s.cancelAt>=1.5 then
                cleanup("walking stop")
                return
            end
        else
            deny("Unexpected playback state "..tostring(s.phase))
            cleanup("state error")
            return
        end
    end
end

function P.Report()
    local e,why=getEngine()
    if not e then return deny(why) end
    local r=status(e)
    if not r then return deny("Dev engine Status unavailable") end
    log("Version="..VERSION.."; default start=pulse, manual fallback=walk")
    log("Mode="..s.mode.."; PlatformStand pre-write="..tostring(s.before)
        .."s, post-write="..tostring(s.after).."s")
    log("Rig="..tostring(r.rig).."; available="..tostring(r.available)
        .."; engine reason="..tostring(r.reason))
    log("Requested states="..tostring(r.requestedStates)
        .."; memory readback="..tostring(r.synced).."/"..tostring(r.total))
    log("Replication of stopping remains unverified. Check a second player.")
    return true,"Report printed"
end

function P.Play(value)
    if s.active then return deny("An emote is already active; use .Stop() or .Restore() first") end
    local id=validId(value)
    if not id then return deny("Enter a valid underlying animation CLIP ID") end
    local e,why=getEngine()
    if not e then return deny(why) end
    local r=status(e)
    if not r or r.available~=true or r.rig~="R15" then
        return deny(r and r.reason or "R15 or memory capability unavailable")
    end
    if type(r.requestedStates)~="number" or r.requestedStates>0 then
        return deny("Another Stance selection is active; restore it or rejoin Roblox")
    end
    local char=currentChar()
    if not char then return deny("Character unavailable") end
    local moving=isMoving(char)
    if moving then return deny("Stand still before Play()") end
    s.active=true;s.phase="await-walk";s.clip=id;s.char=char
    s.token=s.token+1;s.startAt=tick();s.last="Starting emote"
    s.sawMotion=false;s.lastReadback="0/0"
    local token=s.token
    if s.mode=="pulse" then
        local ok,detail=invoke(function()
            return e.StageQuickPulseIds({idle={tonumber(id),tonumber(id)}},s.before,s.after)
        end)
        if not ok then
            s.active=false;s.char=nil;s.phase="idle"
            return deny("Quick pulse rejected: "..tostring(detail))
        end
        s.phase="pulse-staging";s.stageAt=tick()
        log("QUICK PULSE queued: "..math.floor((s.before+s.after)*1000+0.5)
            .." ms requested vs original ~240 ms (actual timing depends on Roblox frames).")
        log("This still briefly toggles PlatformStand; check for any ground dip.")
    else
        log("Manual quiet mode: walk until ARMED, then release movement.")
    end
    task.spawn(function()
        local ok,problem=pcall(function() run(token) end)
        if not ok and s.active and s.token==token then
            log("Monitor failed: "..tostring(problem))
            cleanup("monitor error")
        end
    end)
    return true,"Emote queued; playback and remote stop require visual confirmation"
end

function P.Stop()
    if not s.active then return true,"No active emote" end
    if s.phase=="playing" or s.phase=="await-stop" then
        s.phase="await-stop"
        s.last="Stop requested; waiting for genuine movement"
        log("Please walk briefly (~1.5 seconds) to cancel on other clients.")
        log("The short PlatformStand pulse alone is not a confirmed remote-track stop.")
        return true,"Awaiting actual walking; no fake stop reported"
    end
    return cleanup("cancelled before playback")
end

function P.Restore()
    if not s.active then return true,"No active emote to restore" end
    log("Emergency restore does not guarantee other players' tracks stop.")
    return cleanup("manual emergency restore")
end

function P.SetMode(mode)
    if s.active then return deny("Stop/restore the active emote first") end
    if mode~="pulse" and mode~="walk" then
        return deny("SetMode must be 'pulse' or 'walk'")
    end
    s.mode=mode
    log("Start mode set to "..mode)
    return true,mode
end
function P.SetPulse(beforeSeconds,afterSeconds)
    if s.active then return deny("Restore the active test first") end
    local a,b=tonumber(beforeSeconds),tonumber(afterSeconds)
    if not a or not b or a<0.02 or a>0.12 or b<0.02 or b>0.12 then
        return deny("SetPulse(before,after): each must be 0.02 to 0.12 seconds")
    end
    s.before,s.after=a,b
    log("Quick pulse: "..tostring(a).."s before ID write, "..tostring(b).."s after")
    return true
end

function P.Check()
    log("Version="..VERSION.."; active="..tostring(s.active)
        .."; phase="..tostring(s.phase).."; clip="..tostring(s.clip))
    log("Mode="..tostring(s.mode).."; pulse="..tostring(s.before)
        .."+"..tostring(s.after).." seconds")
    log("Last="..tostring(s.last).."; memory readback="..tostring(s.lastReadback)
        .."; walking observed="..tostring(s.sawMotion))
    if engineReady(s.engine) then
        local r=status(s.engine)
        if r then log("Engine requested="..tostring(r.requestedStates)
            .."; ID readback="..tostring(r.synced).."/"..tostring(r.total)
            .."; last="..tostring(r.last)) end
    end
    log("Other-player stop is not detectable from this VM.")
    return true,s.last
end

function P.Unload()
    if s.active then
        local ok,detail=cleanup("unload")
        if not ok then return deny("Cannot unload: "..tostring(detail)) end
    end
    s.token=s.token+1
    if s.ownsEngine and _G.StanceAnimationEngine==s.engine
        and type(_G.StanceEngineUnload)=="function" then
        local ok=pcall(_G.StanceEngineUnload)
        if not ok then return deny("Dev engine unload failed; rejoin Roblox") end
    end
    s.engine=nil;s.ownsEngine=false
    if _G.StanceEmotesTEST==P then _G.StanceEmotesTEST=nil end
    log("Unloaded")
    return true
end

_G.StanceEmotesTEST=P
log("VERSION "..VERSION.." loaded. Use .Play('118644064755644').")
log("Default is shortened PlatformStand pulse; use .SetMode('walk') for the proven manual method.")
