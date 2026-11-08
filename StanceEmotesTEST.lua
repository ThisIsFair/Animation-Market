-- StanceEmotesTEST.lua  |  Dev-only Marketplace/UGC emote experiment
-- One test file. No embedded Roblox usernames, user IDs, or protected scripts.
-- The normal Stance UI is not required; this reuses Stance's Dev animation engine.
-- Underlying animation CLIP IDs only. Marketplace listing IDs can differ.
--
-- VERIFIED IN PRIOR LIVE TESTS:
-- * Changing both idle clip references can play a UGC emote locally.
-- * Other clients can see the emote begin.
-- * Staging while already walking, then becoming idle, avoids the
--   PlatformStand ground dip experienced in earlier tests.
-- NOT VERIFIED: Fully replicated STOP on other clients.
--
-- AUTO START: Tries a brief real W-key walk with a generous enough duration
-- to test the game's actual movement. This is NOT a CFrame "one-pixel teleport".
-- Previous 75/130ms input pulses did not move the avatar; even longer injected
-- inputs may fail in Matcha. If this happens, the test STAYS READY for a
-- normal manual walk (the verified V5 fallback) instead of discarding the ID.
-- AUTO STOP: Tries a brief real walk, otherwise asks for manual walking.
-- We log physical/MoveDirection evidence, not just "keypress returned true".
-- Test in a disposable R15 session: version-checked memory writes may crash.
--
-- LOADER:
-- loadstring(httpget("https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/StanceEmotesTEST.lua"))()
-- _G.StanceEmotesTEST.Play("118644064755644")
-- _G.StanceEmotesTEST.Stop()
-- _G.StanceEmotesTEST.Check()
-- _G.StanceEmotesTEST.Restore()
--
-- Leave game chat/menus closed, and keep Roblox focused for automatic input.
-- If the automatic tap does not physically move your character, walk normally
-- until ARMED then stop. That path is the proven quiet-stage technique.
-- Another client must verify whether STOP actually replicates.

local VERSION = "20261107-consolidated-1"
local PREFIX = "[StanceEmotesTEST] "
local ENGINE_URL = "https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Animation_Engine.lua?emotest=consolidated-1"
local VK_W = 0x57
local INPUT_KEYS = {0x57,0x41,0x53,0x44,0x25,0x26,0x27,0x28,0x20}
local function log(message) print(PREFIX .. tostring(message)) end
local function fail(message)
    log("BLOCKED: " .. tostring(message))
    return false,tostring(message)
end

local existing = _G.StanceEmotesTEST
if type(existing)=="table" and type(existing.Unload)=="function" then
    local ok,success=pcall(function() return existing.Unload() end)
    if not ok or success~=true then
        log("Previous TEST failed cleanup. Rejoin Roblox before reloading.")
        return
    end
end

local Players=game:GetService("Players")
local player=Players.LocalPlayer
local P={Version=VERSION}
local s={
    engine=nil,owned=false,initialized=false,initError=nil,
    active=false,phase="idle",id=nil,char=nil,token=0,
    since=0,untilTime=0,stagedAt=0,armedAt=0,stillAt=nil,cancelAt=0,
    last="Not started",startPulse=0.42,stopPulse=0.45,
    auto=true,keyHeld=false,physicalStart=false,physicalStop=false,
    stopVerifiedOnPeer=false, -- deliberately never set automatically
    startupFallback=false,
}

local function validEngine(e)
    return type(e)=="table" and type(e.StageQuietIds)=="function"
        and type(e.RestoreNoRefresh)=="function" and type(e.Status)=="function"
        and type(e.AbandonOneShotOnRespawn)=="function"
end

local function getEngine()
    local current=_G.StanceAnimationEngine
    if validEngine(current) then s.engine=current;return current end
    if current~=nil then
        return nil,"An older/incompatible Stance engine is loaded. Rejoin before this test."
    end
    if s.initialized then return nil,s.initError or "Dev engine initialization failed" end
    s.initialized=true
    if type(httpget)~="function" or type(loadstring)~="function" then
        s.initError="Matcha httpget or loadstring is unavailable"
        return nil,s.initError
    end
    log("Initializing existing Dev Stance engine with quiet-stage support")
    local ok,source=pcall(function() return httpget(ENGINE_URL) end)
    if not ok or type(source)~="string" or #source<20000 or #source>150000
        or not source:match("^local STANCE_RELEASE")
        or not source:find("StanceEngine.StageQuietIds",1,true)
        or not source:find("StanceEngine.RestoreNoRefresh",1,true) then
        s.initError="Dev engine download failed or was cached without quiet-stage methods"
        return nil,s.initError
    end
    local compiled,fn=pcall(function() return loadstring(source) end)
    if not compiled or type(fn)~="function" then
        s.initError="Matcha could not compile the Dev engine"
        return nil,s.initError
    end
    local launched,problem=pcall(function() fn() end)
    current=_G.StanceAnimationEngine
    if not launched or not validEngine(current) then
        s.initError="Dev engine did not initialize: "..tostring(problem)
        return nil,s.initError
    end
    s.engine=current;s.owned=true;s.initError=nil
    log("Dev engine ready. Core Stance UI is unchanged.")
    return current
end
local function call(fn)
    local ok,result,detail=pcall(fn)
    if not ok then return false,tostring(result) end
    if result~=true then return false,tostring(detail) end
    return true,detail
end
local function snap(e)
    local ok,result=pcall(function() return e.Status() end)
    if ok and type(result)=="table" then return result end
    return nil
end
local function character()
    return player and player.Character
end
local function findId(value)
    local id=tostring(value or ""):match("^%s*(%d+)%s*$")
    if not id or #id<6 or #id>17 then return nil end
    return id
end
local function realMovement(char)
    if not char then return false,"Character missing" end
    local root=char:FindFirstChild("HumanoidRootPart")
    if root then
        local ok,v=pcall(function() return root.AssemblyLinearVelocity end)
        if ok and v then
            local yes,speed=pcall(function()
                return math.sqrt(v.X*v.X+v.Z*v.Z)
            end)
            if yes and type(speed)=="number" and speed>2.0 then
                return true,"root velocity "..string.format("%.1f",speed)
            end
        end
    end
    local hum=char:FindFirstChild("Humanoid")
    if hum then
        local ok,direction=pcall(function() return hum.MoveDirection end)
        if ok and direction then
            local yes,mag=pcall(function() return direction.Magnitude end)
            if yes and type(mag)=="number" and mag>0.09 then
                return true,"Humanoid.MoveDirection"
            end
        end
    end
    return false,"No locomotion detected"
end
local function focused()
    if type(isrbxactive)~="function" then return false,"isrbxactive unavailable" end
    local ok,value=pcall(isrbxactive)
    if not ok or value~=true then return false,"Roblox is not focused" end
    return true
end
local function alreadyPressingMove()
    if type(iskeypressed)~="function" then return false end
    for _,key in ipairs(INPUT_KEYS) do
        local ok,down=pcall(iskeypressed,key)
        if ok and down==true then return true end
    end
    return false
end
local function keyUp()
    if not s.keyHeld then return true end
    local ok,result=pcall(function() return keyrelease(VK_W) end)
    if ok and result~=false then
        s.keyHeld=false
        return true
    end
    log("WARNING: W release failed. Release W manually, then rejoin if needed.")
    return false
end
local function keyDown()
    if type(keypress)~="function" or type(keyrelease)~="function" then
        return false,"Matcha keypress/keyrelease unavailable"
    end
    local ok,why=focused()
    if not ok then return false,why end
    if alreadyPressingMove() then
        return false,"A movement key is already held; avoiding injected input overlap"
    end
    if type(setrobloxinput)=="function" then
        local sent=pcall(function() setrobloxinput(true) end)
        if not sent then return false,"Could not route input to Roblox" end
    end
    local sent,result=pcall(function() return keypress(VK_W) end)
    if not sent or result==false then return false,"keypress(W) failed" end
    s.keyHeld=true
    return true,"W keydown sent"
end

local function restoreQuiet()
    if not validEngine(s.engine) then return false,"Stance engine unavailable" end
    if character()~=s.char then
        return call(function() return s.engine.AbandonOneShotOnRespawn() end)
    end
    for _=1,18 do
        local ok,why=call(function() return s.engine.RestoreNoRefresh() end)
        if ok then return true,why end
        task.wait(0.12)
    end
    return false,"Couldn't restore original idle references; rejoin Roblox"
end
local function finish(message)
    keyUp()
    s.active=false;s.phase="idle";s.char=nil
    s.last=message
    log(message)
end
local function cleanup(reason)
    keyUp()
    if not s.active then return true,"No active emote test" end
    local ok,detail=restoreQuiet()
    if not ok then return fail(detail) end
    s.token=s.token+1
    finish("Original idle IDs restored quietly ("..reason..")")
    return true,detail
end

local function stageNow(token)
    if not s.active or s.token~=token then return false,"Test changed" end
    local ok,detail=call(function()
        return s.engine.StageQuietIds({idle={tonumber(s.id),tonumber(s.id)}})
    end)
    if not ok then return false,detail end
    s.phase="staging";s.stagedAt=tick()
    log("Quiet staging queued while walking; NO PlatformStand pulse.")
    return true,"Queued"
end
local function readbackReady()
    local info=snap(s.engine)
    return info and type(info.synced)=="number" and info.synced>=2
        and type(info.total)=="number" and info.total>=2
end

-- The input is held while staging so the normal walk->idle transition can
-- occur only AFTER both replacement animation IDs are in place.
local function autoStart(token)
    local ok,why=keyDown()
    if not ok then return false,why end
    local first=tick(),0
    local physical=false
    local stageIssued=false
    local readyAt=nil
    local maxHold=math.max(0.38,s.startPulse)+1.25
    while s.active and s.token==token and tick()-first<maxHold do
        task.wait(0.035)
        if character()~=s.char then break end
        local moving,reason=realMovement(s.char)
        if moving and not physical then
            physical=true
            s.physicalStart=true
            log("Automatic movement CONFIRMED: "..tostring(reason))
        end
        if physical and not stageIssued then
            local staged,issue=stageNow(token)
            if not staged then
                keyUp()
                return false,"Quiet staging failed: "..tostring(issue)
            end
            stageIssued=true
        end
        if stageIssued and readbackReady() then
            readyAt=readyAt or tick()
            if tick()-readyAt>=0.14 then break end
        end
        if not physical and tick()-first>=s.startPulse then break end
    end
    local released=keyUp()
    if not released then return false,"Injected W-key release failed" end
    if not physical then
        return false,"W input accepted, but NO physical movement detected"
    end
    if not stageIssued then return false,"Physical movement occurred but staging failed" end
    return true,"Automatic real movement and quiet stage queued"
end

local function stopAfterWalk(reason)
    local ok,detail=restoreQuiet()
    if not ok then
        fail("Stop restoration failed: "..tostring(detail))
        return false
    end
    finish("Stopped after actual movement ("..reason.."); original idle restored.")
    return true
end

local function mainLoop(token)
    local stillFrom=nil
    local noMoveWarning=false
    task.wait(0.22) -- give Roblox foreground input a chance to settle
    if s.auto then
        log("Trying automatic walk trigger. Previous tiny pulses did NOT move the character.")
        local worked,details=autoStart(token)
        if not s.active or s.token~=token then return end
        if not worked then
            log("AUTO START UNAVAILABLE: "..tostring(details))
            log("FALLBACK: Walk normally until ARMED, then stop to start the emote.")
            s.startupFallback=true
            s.phase="await-walk"
        else
            log("Auto startup movement detected. Waiting for 2/2 ID readback and return to idle.")
        end
    else
        log("Manual fallback mode. Walk briefly until ARMED, then stop.")
    end

    while s.active and s.token==token do
        task.wait(0.09)
        if not s.active or s.token~=token then return end
        if character()~=s.char then cleanup("respawn");return end
        if tick()>s.untilTime then
            log("Safety timeout. Restoring original idle IDs.")
            cleanup("timeout")
            return
        end
        local moving,moveReason=realMovement(s.char)

        if s.phase=="await-walk" then
            if moving then
                log("Real manual movement detected ("..moveReason..")")
                local ok,reason=stageNow(token)
                if not ok then
                    fail("Stage failed: "..tostring(reason))
                    cleanup("stage error")
                    return
                end
            end
        elseif s.phase=="staging" then
            if readbackReady() then
                s.phase="armed";s.armedAt=tick()
                stillFrom=nil
                log("ARMED: Both UGC idle IDs staged. Now RELEASE movement to start.")
            elseif tick()-s.stagedAt>6 then
                cleanup("staging timeout")
                return
            end
        elseif s.phase=="armed" then
            if moving then
                stillFrom=nil
            else
                stillFrom=stillFrom or tick()
                if tick()-stillFrom>=0.32 then
                    s.phase="playing";s.last="Walk-to-idle emote activation"
                    log("PLAYING PHASE: Emote should start now, without ground dip.")
                    log("Move normally to cancel, or call .Stop() to TRY an automatic stop.")
                end
            end
        elseif s.phase=="playing" then
            if moving then
                s.phase="walking-cancel"
                s.cancelAt=tick()
                log("Real movement detected; letting normal walk transition occur before restoring.")
            end
        elseif s.phase=="walking-cancel" then
            if tick()-s.cancelAt>=1.0 then
                stopAfterWalk("normal walking")
                return
            end
        elseif s.phase=="stop-await-manual" then
            if moving then
                s.phase="walking-cancel";s.cancelAt=tick()
                log("Manual stop movement detected; restoring after natural walking transition.")
            elseif not noMoveWarning and tick()-s.armedAt>3 then
                noMoveWarning=true
                log("Still awaiting movement. Walk briefly to finish stopping on both clients.")
            end
        elseif s.phase=="stop-injected" then
            -- P.Stop owns this transition; avoid concurrent monitor action.
        elseif s.phase=="idle" then
            return
        end
    end
end

function P.Report()
    log("Version="..VERSION.." | consolidated Dev emote test")
    local e,why=getEngine()
    if not e then return fail(why) end
    local r=snap(e)
    if not r then return fail("Dev engine.Status failed") end
    log("Rig="..tostring(r.rig).." | memory capability="..tostring(r.available))
    log("Capability reason="..tostring(r.reason))
    log("Selected states="..tostring(r.requestedStates)
        .."; readback="..tostring(r.synced).."/"..tostring(r.total))
    log("Auto movement="..tostring(s.auto)
        .."; start="..tostring(s.startPulse).."s; stop="..tostring(s.stopPulse).."s.")
    log("Auto move remains unverified. A real movement-to-idle transition is required.")
    return true,"Report printed"
end

function P.Play(input)
    if s.active then return fail("Another emote is active; call .Stop() or .Restore()") end
    local id=findId(input)
    if not id then return fail("Provide an underlying animation clip ID with 6-17 digits") end
    local e,why=getEngine()
    if not e then return fail(why) end
    local r=snap(e)
    if not r or r.available~=true or r.rig~="R15" then
        return fail(r and r.reason or "R15/engine unavailable")
    end
    if type(r.requestedStates)~="number" or r.requestedStates>0 then
        return fail("Other Stance animation states are active. Rejoin/reset before testing.")
    end
    local char=character()
    if not char then return fail("Character is not ready") end
    local moving=realMovement(char)
    if moving then return fail("Stand still before Play()") end
    s.active=true;s.phase="await-walk";s.id=id;s.char=char
    s.token=s.token+1;s.since=tick();s.untilTime=tick()+35
    s.last="Waiting for physical movement to stage UGC clip"
    s.physicalStart=false;s.physicalStop=false
    s.startupFallback=false;s.armedAt=tick();s.stopVerifiedOnPeer=false
    local token=s.token
    log("Play("..id..") started. Auto="..tostring(s.auto).." (will fall back to walking).")
    task.spawn(function()
        local ok,err=pcall(function() mainLoop(token) end)
        if not ok and s.active and s.token==token then
            log("Monitor error: "..tostring(err))
            cleanup("monitor error")
        end
    end)
    return true,"Attempting quiet-staged playback; remote stop not yet confirmed."
end

function P.Stop()
    if not s.active then return true,"Nothing to stop" end
    if s.phase=="stop-injected" then return fail("Automatic stop already in progress") end
    if s.phase~="playing" and s.phase~="armed" then
        return cleanup("early cancellation")
    end
    s.phase="stop-injected"
    local token=s.token
    task.spawn(function()
        local ok,err=pcall(function()
            local started,why=keyDown()
            if not started then
                log("Auto stop not available: "..tostring(why))
                s.phase="stop-await-manual"
                log("Walk normally to stop and restore the emote.")
                return
            end
            local startedAt=tick()
            local physical=false
            while s.active and s.token==token and tick()-startedAt<s.stopPulse do
                task.wait(0.035)
                local moving=realMovement(s.char)
                if moving then physical=true end
            end
            keyUp()
            if not s.active or s.token~=token then return end
            s.physicalStop=physical
            if not physical then
                log("Automatic W stop pulse did not cause physical locomotion.")
                s.phase="stop-await-manual"
                log("Walk briefly to cancel. Original IDs remain in place for now.")
                return
            end
            log("Physical stop movement confirmed. Waiting for natural walking transition.")
            task.wait(1.0)
            if s.active and s.token==token then stopAfterWalk("automatic W movement") end
        end)
        if not ok then
            keyUp()
            log("Automatic stop failed: "..tostring(err))
            if s.active and s.token==token then s.phase="stop-await-manual" end
        end
    end)
    return true,"Stop requested; checking for real movement"
end

function P.Restore()
    if not s.active then return true,"Nothing to restore" end
    log("Emergency restore does not guarantee the remote animation track stops.")
    return cleanup("manual restore")
end

function P.SetAuto(value)
    if s.active then return fail("Finish current test before changing Auto") end
    s.auto=value~=false
    log("Automatic movement attempt="..tostring(s.auto))
    return true,s.auto
end
function P.SetPulse(startSeconds,stopSeconds)
    if s.active then return fail("Finish current test first") end
    local a,b=tonumber(startSeconds),tonumber(stopSeconds)
    if not a or not b or a<0.20 or a>0.80 or b<0.20 or b>0.80 then
        return fail("SetPulse(start, stop): both durations must be 0.20-0.80 seconds")
    end
    s.startPulse=a;s.stopPulse=b
    log("Pulses set: startup "..tostring(a).."s, stop "..tostring(b).."s")
    return true
end

function P.Check()
    log("Version="..VERSION.." | active="..tostring(s.active)
        .." | phase="..tostring(s.phase).." | clip="..tostring(s.id))
    log("Last="..tostring(s.last)
        .." | auto fallback="..tostring(s.startupFallback))
    log("Physical startup="..tostring(s.physicalStart)
        .." | physical auto-stop="..tostring(s.physicalStop))
    log("Peer stop verified by script=false (always requires another client)")
    if validEngine(s.engine) then
        local r=snap(s.engine)
        if r then
            log("Engine selected="..tostring(r.requestedStates)
                .." | memory readback="..tostring(r.synced).."/"..tostring(r.total))
        end
    end
    return true,s.last
end

function P.Unload()
    if s.active then
        local ok,why=cleanup("unload")
        if not ok then return fail("Unable to clean up: "..tostring(why)) end
    end
    keyUp()
    s.token=s.token+1
    if s.owned and _G.StanceAnimationEngine==s.engine
        and type(_G.StanceEngineUnload)=="function" then
        local ok=pcall(_G.StanceEngineUnload)
        if not ok then return fail("Dev engine unload failed; rejoin Roblox") end
    end
    s.engine=nil;s.owned=false
    if _G.StanceEmotesTEST==P then _G.StanceEmotesTEST=nil end
    log("Unloaded")
    return true
end

_G.StanceEmotesTEST=P
log("VERSION "..VERSION.." loaded. .Play('118644064755644'), .Stop(), .Restore()")
log("No private usernames or account identifiers are included in this file.")
