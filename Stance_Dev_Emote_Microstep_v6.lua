-- Stance Dev / Marketplace-UGC Emote Microstep V6
-- Isolated, unobfuscated Matcha LuaVM experiment. No usernames or account IDs.
--
-- PURPOSE:
-- V5 proved quiet AnimationId staging can start the emote without a
-- PlatformStand-induced drop into the ground. V6 automates a tiny real
-- walk->idle transition with Matcha's documented keypress/keyrelease APIs.
-- It NEVER teleports/repositions the character via CFrame.
--
-- WARNING: Even a 60-100 ms W tap may move the avatar a small distance,
-- potentially more than a screen pixel. Roblox must process a locomotion
-- transition; there is no guaranteed invisible or exact one-pixel walk.
-- REMOTE STOP via a micro-step is EXPERIMENTAL, not yet verified.
-- Test in a disposable R15 session and have a second player observe.
--
-- Load (fresh Roblox session recommended):
-- loadstring(httpget("https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Dev_Emote_Microstep_v6.lua"))()
-- _G.StanceEmoteV6.Report()
-- _G.StanceEmoteV6.Play("118644064755644")
-- _G.StanceEmoteV6.Stop()    -- short automatic micro-step to cancel
-- _G.StanceEmoteV6.Check()
-- _G.StanceEmoteV6.Unload()
--
-- If an injected pulse does not move the character, the script reports that
-- limitation; you can still manually move for a short moment, then Stop().
-- Input requires the Roblox window to be focused, with chat/menus closed.
-- No /e, no protected-code analysis, no Matcha Pro, no user identifiers.

local VERSION = "v6-microstep-20261107"
local TAG = "[Stance/MicroV6] "
local ENGINE_URL = "https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Dev_Emote_Quiet_Engine_v5.lua?microstep=v6-b62ada4"
local VK_W = 0x57
local MOVEMENT_KEYS = {0x57,0x41,0x53,0x44,0x25,0x26,0x27,0x28,0x20}
local function log(m) print(TAG..tostring(m)) end
local function block(m) log("BLOCKED: "..tostring(m));return false,tostring(m) end

local function cleanPrior(name)
    local old=_G[name]
    if type(old)=="table" and type(old.Unload)=="function" then
        local ok,result=pcall(function() return old.Unload() end)
        if not ok or result~=true then
            log("Prior "..name.." not cleanly unloaded. Rejoin before V6.")
            return false
        end
    end
    return true
end
for _,name in ipairs({"StanceDevEmoteSlotProbe","StanceOneShotEmote","StanceEmoteStopV4","StanceEmoteV5","StanceEmoteV6"}) do
    if not cleanPrior(name) then return end
end

local Players=game:GetService("Players")
local player=Players.LocalPlayer
local P={ Version=VERSION }
local s={
    active=false, phase="idle", token=0, candidate=nil, character=nil,
    owned=false, engine=nil, engineAttempted=false, engineError=nil,
    started=0, expiry=25, pulseStart=0.075, pulseStop=0.16,
    heldKey=false, last="Not started", lastPulse="No pulse yet",
    lastPulsePhysical=false, stopConfirmed=false,
}
local function ready(e)
    return type(e)=="table" and type(e.Status)=="function"
        and type(e.StageQuietIds)=="function"
        and type(e.RestoreNoRefresh)=="function"
        and type(e.AbandonOneShotOnRespawn)=="function"
end
local function engine()
    local e=_G.StanceAnimationEngine
    if ready(e) then s.engine=e;return e end
    if e~=nil then return nil,"Incompatible Stance engine loaded; rejoin and load V6 before any Stance UI." end
    if s.engineAttempted then return nil,s.engineError or "Engine failed" end
    s.engineAttempted=true
    if type(httpget)~="function" or type(loadstring)~="function" then
        s.engineError="Matcha httpget/loadstring unavailable";return nil,s.engineError
    end
    log("Loading isolated quiet-stage Dev engine (no PlatformStand input)")
    local ok,source=pcall(function() return httpget(ENGINE_URL) end)
    if not ok or type(source)~="string" or #source<40000 or #source>150000
        or not source:find("StanceEngine.StageQuietIds",1,true)
        or not source:find("20261107-emote-quiet-v5",1,true) then
        s.engineError="Quiet engine download failed or stale";return nil,s.engineError
    end
    local compiled,fn=pcall(function() return loadstring(source) end)
    if not compiled or type(fn)~="function" then
        s.engineError="Matcha engine compilation failed";return nil,s.engineError
    end
    local ran,reason=pcall(function() fn() end)
    e=_G.StanceAnimationEngine
    if not ran or not ready(e) then
        s.engineError="Quiet engine initialization failed: "..tostring(reason)
        return nil,s.engineError
    end
    s.engine=e;s.owned=true
    log("Quiet engine ready; current animation IDs not changed.")
    return e
end
local function call(f)
    local ok,a,b=pcall(f)
    if not ok then return false,tostring(a) end
    if a~=true then return false,tostring(b) end
    return true,b
end
local function currentChar()
    return player and player.Character
end
local function status(e)
    local ok,r=pcall(function() return e.Status() end)
    return ok and type(r)=="table" and r or nil
end
local function motion(char)
    if not char then return false,"No character" end
    local root=char:FindFirstChild("HumanoidRootPart")
    if root then
        local ok,v=pcall(function() return root.AssemblyLinearVelocity end)
        if ok and v then
            local yes,speed=pcall(function() return math.sqrt(v.X*v.X+v.Z*v.Z) end)
            if yes and type(speed)=="number" and speed>2.4 then
                return true,"root velocity "..string.format("%.1f",speed)
            end
        end
    end
    local humanoid=char:FindFirstChild("Humanoid")
    if humanoid then
        local ok,dir=pcall(function() return humanoid.MoveDirection end)
        if ok and dir then
            local yes,size=pcall(function() return dir.Magnitude end)
            if yes and type(size)=="number" and size>0.08 then
                return true,"MoveDirection "..string.format("%.2f",size)
            end
        end
    end
    return false,"No locomotion detected"
end

local function focused()
    if type(isrbxactive)~="function" then return false,"isrbxactive unavailable" end
    local ok,active=pcall(isrbxactive)
    if not ok or active~=true then
        return false,"Roblox must be the foreground window; close Matcha overlays/Roblox chat."
    end
    return true
end
local function movementKeyHeld()
    if type(iskeypressed)~="function" then return false end
    for _,key in ipairs(MOVEMENT_KEYS) do
        local ok,down=pcall(iskeypressed,key)
        if ok and down==true then return true end
    end
    return false
end
local function releaseHeld()
    if not s.heldKey then return true end
    -- Retry key-up even if input was interrupted, preventing stuck movement.
    local ok,value=pcall(keyrelease,VK_W)
    if ok and value~=false then s.heldKey=false;return true end
    log("WARNING: keyrelease failed; release W manually / refocus Roblox.")
    return false
end
local function pulse(seconds,char,token)
    if type(keypress)~="function" or type(keyrelease)~="function" then
        return false,"Matcha keypress/keyrelease unavailable",false
    end
    local ok,why=focused()
    if not ok then return false,why,false end
    if movementKeyHeld() then
        return false,"Movement key is already held; automatic pulse refused",false
    end
    if char~=currentChar() then return false,"Character changed",false end
    local injected,issue=true,nil
    if type(setrobloxinput)=="function" then
        local sent,msg=pcall(setrobloxinput,true)
        if not sent then injected=false;issue="setrobloxinput(true) failed: "..tostring(msg) end
    end
    if not injected then return false,issue,false end
    local started,ret=pcall(keypress,VK_W)
    if not started or ret==false then return false,"keypress(W) failed",false end
    s.heldKey=true
    local start=tick()
    local moved,method=false,nil
    -- Capture physical movement while the button is still down.
    while tick()-start < seconds and s.token==token do
        task.wait(0.015)
        local yes,label=motion(char)
        if yes then moved=true;method=label end
        if currentChar()~=char then break end
    end
    local released=releaseHeld()
    if not released then
        return false,"Cannot verify key release",moved
    end
    if not moved then
        local yes,label=motion(char)
        if yes then moved=true;method=label end
    end
    return true,"W pressed "..string.format("%.0f",seconds*1000)
        .."ms; physical movement="..tostring(moved)
        .."; source="..tostring(method),moved
end
local function restore(e)
    for attempt=1,16 do
        local ok,detail=call(function() return e.RestoreNoRefresh() end)
        if ok then return true,detail end
        task.wait(0.11)
    end
    return false,"Timed out restoring idle animation references; rejoin Roblox."
end
local function clear(message)
    s.active=false;s.phase="idle";s.character=nil;s.last=message
    log(message)
end
local function cleanup(reason)
    releaseHeld()
    if not s.active then return true,"No active emote" end
    local e=s.engine
    if not ready(e) then return block("Engine missing during cleanup; rejoin to reset Roblox.") end
    if currentChar()~=s.character then
        local ok,err=call(function() return e.AbandonOneShotOnRespawn() end)
        if not ok then return block("Respawn cleanup failed: "..tostring(err)) end
        clear("Respawn cleanup: old selection abandoned.")
        return true,err
    end
    if s.phase=="preparing" then
        -- Reference may already have been substituted, so restore in all
        -- cases unless the action never reached StageQuietIds.
    end
    local ok,details=restore(e)
    if not ok then return block(details) end
    clear("Original idle references restored ("..reason.."), no PlatformStand pulse.")
    return true,details
end

local function waitReadback(e,token,limit)
    local start=tick()
    while s.token==token and s.active and tick()-start<limit do
        local r=status(e)
        if r and type(r.synced)=="number" and r.synced>=2
            and type(r.total)=="number" and r.total>=2 then
            return true
        end
        task.wait(0.055)
    end
    return false
end
local function startRunner(token)
    local e=s.engine
    if not waitReadback(e,token,4) then
        log("2/2 quiet-stage readback not reached; restoring and aborting.")
        cleanup("memory write timeout")
        return
    end
    if not s.active or s.token~=token then return end
    log("2/2 idle animation IDs staged. Trying small W pulse to trigger natural idle reload.")
    s.phase="micro-start"
    local attempts={s.pulseStart,math.min(0.16,s.pulseStart+0.055)}
    local didMove=false
    for i,ms in ipairs(attempts) do
        if not s.active or s.token~=token then return end
        local ok,details,real=pulse(ms,s.character,token)
        s.lastPulse=details
        s.lastPulsePhysical=real
        log("Startup pulse #"..i..": "..details)
        if not ok then
            cleanup("startup input unavailable")
            return
        end
        if real then didMove=true;break end
        task.wait(0.10)
    end
    if not didMove then
        log("No real locomotion detected after small inputs.")
        log("Fallback: manually TAP movement briefly, then stand still; playback may start.")
        s.last="Automatic movement unconfirmed; manual tiny movement may be needed"
    else
        s.last="Automatic physical microstep detected; waiting for return to idle"
    end
    -- Wait for our own injected movement to decay before enabling the
    -- "manual movement stops emote" monitor. Otherwise the startup pulse
    -- might be mistaken for a user trying to cancel the emote.
    local settleStart=tick()
    local quietSince=nil
    while s.active and s.token==token and tick()-settleStart<1.6 do
        task.wait(0.055)
        local moving=motion(s.character)
        if moving then
            quietSince=nil
        else
            quietSince=quietSince or tick()
            if tick()-quietSince>=0.18 then break end
        end
    end
    if not s.active or s.token~=token then return end
    s.phase="playing";s.started=tick()
    log("PLAY PHASE: if animation started, it should be visible to other players.")
    log("To cancel automatically, call .Stop(). Walking manually also triggers cleanup.")
    log("V6 remote stop still requires second-client visual confirmation.")

    while s.active and s.token==token and s.phase=="playing" do
        task.wait(0.075)
        if currentChar()~=s.character then
            cleanup("respawn");break
        end
        local moving,why=motion(s.character)
        if moving then
            s.phase="stopping"
            log("Manual movement detected ("..tostring(why).."); allowing natural transition.")
            task.wait(0.32)
            cleanup("manual movement stop")
            break
        end
        if tick()-s.started>s.expiry then
            log("Safety timeout; cancelling with microstep.")
            P.Stop()
            break
        end
    end
end

function P.Report()
    log("Version="..VERSION.." | automatic small physical step; never a CFrame teleport.")
    local e,why=engine()
    if not e then return block(why) end
    local r=status(e)
    if not r then return block("Engine status unavailable") end
    log("Rig="..tostring(r.rig).."; capability="..tostring(r.available).."; "..tostring(r.reason))
    log("Active states="..tostring(r.requestedStates)
        .."; memory readback="..tostring(r.synced).."/"..tostring(r.total))
    log("Start pulse="..string.format("%.0f",s.pulseStart*1000)
        .."ms, stop pulse="..string.format("%.0f",s.pulseStop*1000).."ms.")
    log("A tiny actual walk can move more than one screen pixel; no invisible movement guaranteed.")
    return true,"Report printed"
end

function P.Play(value)
    if s.active then return block("An emote test is already active; call .Stop() first.") end
    local id=tostring(value or ""):match("^%s*(%d+)%s*$")
    if not id or #id<6 or #id>17 then return block("Underlying clip ID must have 6-17 digits.") end
    local inFocus,reason=focused()
    if not inFocus then return block(reason) end
    if movementKeyHeld() then return block("Release movement keys before calling Play.") end
    local e,why=engine()
    if not e then return block(why) end
    local r=status(e)
    if not r or r.available~=true or r.rig~="R15" then
        return block(r and r.reason or "R15/engine unavailable")
    end
    if type(r.requestedStates)~="number" or r.requestedStates>0 then
        return block("Another Stance animation selection is active; rejoin/reset before V6.")
    end
    local character=currentChar()
    if not character then return block("Character unavailable") end
    local inMotion,details=motion(character)
    if inMotion then return block("Stand still before starting: "..tostring(details)) end

    local applied,why=call(function()
        return e.StageQuietIds({idle={tonumber(id),tonumber(id)}})
    end)
    if not applied then return block(why) end
    s.active=true;s.phase="preparing";s.character=character;s.candidate=id
    s.last="Quiet stage requested; waiting for 2/2 ID readback"
    s.token=s.token+1;s.lastPulsePhysical=false;s.stopConfirmed=false
    local token=s.token
    log("Emote ID "..id.." queued. V6 will pulse W briefly once staging completes.")
    task.spawn(function()
        local ok,problem=pcall(function() startRunner(token) end)
        if not ok and s.active and s.token==token then
            log("Monitor error: "..tostring(problem))
            cleanup("monitor error")
        end
    end)
    return true,"V6 microstep emote test started; remote stop unverified."
end

function P.Stop()
    if not s.active then return true,"No active emote" end
    if s.phase=="stopping" then return block("Stop already in progress") end
    if s.phase=="preparing" or s.phase=="micro-start" then
        s.phase="stopping"
        return cleanup("cancelled before startup")
    end
    s.phase="stopping"
    local ok,info,physical=pulse(s.pulseStop,s.character,s.token)
    s.lastPulse=info;s.lastPulsePhysical=physical
    log("Automatic STOP microstep: "..tostring(info))
    if ok then
        -- Let Roblox's ordinary walk transition propagate before ID restore.
        task.wait(0.33)
    else
        log("No automatic movement: original IDs will still be restored.")
        log("If the remote emote persists, walk manually before calling Stop again.")
    end
    local restored,details=cleanup("automatic microstep stop")
    if restored then
        s.stopConfirmed=ok and physical
        log("Stop microstep physical="..tostring(physical).."; peer stop NOT yet proven.")
    end
    return restored,details
end

function P.SetPulse(startSeconds,stopSeconds)
    if s.active then return block("Stop current emote before changing pulse durations") end
    local begin=tonumber(startSeconds)
    local finish=tonumber(stopSeconds)
    if not begin or not finish or begin<0.04 or begin>0.25 or finish<0.06 or finish>0.4 then
        return block("Start pulse must be 0.04-0.25 sec, stop pulse 0.06-0.40 sec.")
    end
    s.pulseStart,s.pulseStop=begin,finish
    log("Pulse durations set: start="..tostring(begin).."s stop="..tostring(finish).."s")
    return true
end

function P.Check()
    log("Version="..VERSION.."; active="..tostring(s.active)
        .."; phase="..tostring(s.phase).."; clip ID="..tostring(s.candidate))
    log("Last="..tostring(s.last))
    log("Last pulse="..tostring(s.lastPulse)
        .."; actual movement="..tostring(s.lastPulsePhysical))
    log("Stop microstep detected physical movement="..tostring(s.stopConfirmed)
        .." (remote stop NOT proven)")
    if ready(s.engine) then
        local r=status(s.engine)
        if r then
            log("Engine selected states="..tostring(r.requestedStates)
                .."; ID readback="..tostring(r.synced).."/"..tostring(r.total))
        end
    end
    return true,s.last
end

function P.Unload()
    if s.active then
        local ok,why=P.Stop()
        if not ok then return block("Cleanup failed: "..tostring(why)) end
    end
    releaseHeld()
    s.token=s.token+1
    if s.owned and _G.StanceAnimationEngine==s.engine
        and type(_G.StanceEngineUnload)=="function" then
        local ok=pcall(_G.StanceEngineUnload)
        if not ok then return block("Engine unload failed; rejoin Roblox") end
    end
    s.engine=nil;s.owned=false
    if _G.StanceEmoteV6==P then _G.StanceEmoteV6=nil end
    log("Unloaded")
    return true
end

_G.StanceEmoteV6=P
log("VERSION "..VERSION.." loaded; standalone Dev microstep test.")
log("Call .Report() then .Play('118644064755644') while Roblox is focused.")
log("Close chat/menus. Do not press movement keys during the automatic pulse.")
