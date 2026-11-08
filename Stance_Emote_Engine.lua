local Players=game:GetService("Players")
local player=Players.LocalPlayer
local Emotes={}
local allowed={wave=true,point=true,cheer=true,laugh=true,dance=true,dance2=true,dance3=true}
local lastName,lastMethod,lastError=nil,nil,nil
local running=false
local function characterStatus()
    local character=player and player.Character
    if not character then return nil,nil,"Waiting for character" end
    local ok,rig=pcall(function()
        if character:FindFirstChild("LowerTorso") and character:FindFirstChild("UpperTorso") then return "R15" end
        if character:FindFirstChild("Torso") then return "R6" end
        return "Loading"
    end)
    if not ok or rig~="R15" then return nil,nil,rig=="R6" and "R6 rigs are not supported" or "Waiting for R15 rig" end
    local humanoid=character:FindFirstChild("Humanoid")
    if not humanoid then return nil,nil,"Waiting for Humanoid" end
    local healthy,health=pcall(function() return humanoid.Health end)
    if healthy and type(health)=="number" and health<=0 then return nil,nil,"Character is not alive" end
    return character,humanoid,nil
end
local function tap(vk)
    local pressed=keypress(vk)
    if pressed==false then return false end
    task.wait(0.035)
    keyrelease(vk)
    task.wait(0.045)
    return true
end
local function keyboardEmote(name)
    if not allowed[name] then return false,"Only standard /e commands support the keyboard fallback" end
    if type(keypress)~="function" or type(keyrelease)~="function" or type(isrbxactive)~="function" then
        return false,"Keyboard input unavailable in Matcha"
    end
    if not isrbxactive() then return false,"Focus the Roblox window first" end
    if not tap(0xBF) then return false,"Could not open Roblox chat" end
    task.wait(0.22)
    if not isrbxactive() then return false,"Roblox lost focus before typing" end
    keypress(0x11)
    tap(0x41)
    keyrelease(0x11)
    local command="/e "..name
    for i=1,#command do
        local ch=command:sub(i,i)
        local vk=ch=="/" and 0xBF or (ch==" " and 0x20 or string.byte(ch:upper()))
        if not isrbxactive() or not tap(vk) then return false,"Keyboard command was interrupted" end
    end
    task.wait(0.10)
    if not isrbxactive() then return false,"Roblox lost focus before sending" end
    if not tap(0x0D) then return false,"Could not submit emote command" end
    return true,"Keyboard command sent (visual playback not verified)"
end
function Emotes.Play(value,useKeyboard)
    if running then return false,"An emote request is already in progress" end
    if type(value)~="string" then return false,"Enter an emote name" end
    local name=value:lower():match("^%s*(.-)%s*$")
    if #name==0 or #name>40 or not name:match("^[a-z0-9_]+$") then return false,"Invalid emote name" end
    local character,humanoid,reason=characterStatus()
    if not humanoid then lastError=reason;return false,reason end
    running=true
    local ok,played=pcall(function() return humanoid:PlayEmoteAsync(name) end)
    if ok and played==true then
        running=false
        lastName,lastMethod,lastError=name,"Roblox native async",nil
        return true,"Roblox started "..name
    end
    local legacyOk,legacyPlayed=pcall(function() return humanoid:PlayEmote(name) end)
    if legacyOk and legacyPlayed==true then
        running=false
        lastName,lastMethod,lastError=name,"Roblox native legacy",nil
        return true,"Roblox started "..name
    end
    if useKeyboard==true and allowed[name] then
        local sent,detail=keyboardEmote(name)
        running=false
        if sent then
            lastName,lastMethod,lastError=name,"Keyboard /e",nil
            return true,detail
        end
        lastError=detail
        return false,detail
    end
    running=false
    lastError="Native emote method unavailable or emote not equipped; try Copy /e, or enable experimental keyboard fallback"
    return false,lastError
end

local directTrack,directClip,directToken=nil,nil,0
local lastAssetId,lastDetail=nil,nil

local function dropClip(clip)
    if clip then pcall(function() clip:Destroy() end) end
end

function Emotes.Stop()
    directToken=directToken+1
    local track,clip=directTrack,directClip
    directTrack,directClip=nil,nil
    if track then pcall(function() track:Stop(0.12) end) end
    dropClip(clip)
    if track then lastDetail="Stopped Stance's custom animation track" end
    return track~=nil,track and "Stopped custom emote" or "No Stance custom emote is playing"
end

local function locateAnimator(humanoid)
    local ok,animator=pcall(function() return humanoid:FindFirstChildOfClass("Animator") end)
    if ok and animator then return animator end
    ok,animator=pcall(function() return humanoid:FindFirstChild("Animator") end)
    return ok and animator or nil
end

local function findClipTemplate(character)
    local ok,items=pcall(function() return character:GetDescendants() end)
    if not ok or type(items)~="table" then return nil end
    for _,item in ipairs(items) do
        local valid,yes=pcall(function()
            return item:IsA("Animation")
        end)
        if valid and yes then return item end
    end
    return nil
end

function Emotes.PlayId(value)
    if running then return false,"Another emote request is already running" end
    local id=tostring(value or ""):match("^%s*(%d+)%s*$")
    if not id or #id<6 or #id>17 then
        lastError="Enter a numeric animation asset ID (6-17 digits)"
        return false,lastError
    end
    local character,humanoid,reason=characterStatus()
    if not humanoid then lastError=reason;return false,reason end
    local animator=locateAnimator(humanoid)
    if not animator then
        lastError="No Animator found under your character's Humanoid"
        return false,lastError
    end
    running=true
    local uri="rbxassetid://"..id
    local track,clip,method=nil,nil,nil
    local existingOK,existing=pcall(function() return animator:GetTrackByAnimationId(uri) end)
    if existingOK and existing then
        track,method=existing,"Animator existing track"
    end
    if not track then
        local template=findClipTemplate(character)
        if not template then
            running=false
            lastError="No Animation template in character. Matcha cannot use Instance.new; cannot safely load this ID."
            return false,lastError
        end
        local cloned,copy=pcall(function() return template:Clone() end)
        if not cloned or not copy then
            running=false
            lastError="Matcha does not allow cloning an Animation template"
            return false,lastError
        end
        clip=copy
        local changed=pcall(function() clip.AnimationId=uri end)
        if not changed then
            dropClip(clip)
            running=false
            lastError="Matcha cannot set AnimationId on the cloned animation"
            return false,lastError
        end
        local loaded,loadedTrack=pcall(function() return animator:LoadAnimation(clip) end)
        if not loaded or not loadedTrack then
            dropClip(clip)
            running=false
            lastError="Animator:LoadAnimation unavailable or Roblox rejected the asset (may be an emote item ID, not a playable clip)"
            return false,lastError
        end
        track,method=loadedTrack,"Animator:LoadAnimation"
    end
    pcall(function() track.Priority=Enum.AnimationPriority.Action end)
    local started,startReason=pcall(function() track:Play(0.1) end)
    if not started then
        dropClip(clip)
        running=false
        lastError="AnimationTrack:Play unavailable or rejected: "..tostring(startReason)
        return false,lastError
    end
    Emotes.Stop()
    directTrack,directClip=track,clip
    lastAssetId,lastName,lastMethod,lastError=id,"Cute Wave (asset test)",method,nil
    lastDetail="Play request sent; visual playback/replication not verified"
    local token=directToken
    running=false
    task.spawn(function()
        local begun=tick()
        while directToken==token and directTrack==track do
            task.wait(0.13)
            local currentChar=player and player.Character
            if currentChar~=character then
                Emotes.Stop()
                lastDetail="Character changed; emote stopped"
                break
            end
            local moved,moveAmount=pcall(function() return humanoid.MoveDirection.Magnitude end)
            if moved and type(moveAmount)=="number" and moveAmount>0.08 then
                Emotes.Stop()
                lastDetail="Movement detected; emote stopped"
                break
            end
            local healthy,health=pcall(function() return humanoid.Health end)
            if healthy and type(health)=="number" and health<=0 then
                Emotes.Stop()
                lastDetail="Character died; emote stopped"
                break
            end
            if tick()-begun>0.8 then
                local ok,playing=pcall(function() return track.IsPlaying end)
                if ok and playing==false then
                    Emotes.Stop()
                    lastDetail="Animation finished or stopped"
                    break
                end
            end
        end
    end)
    return true,"Play request sent for "..id.."; check whether it moves your character"
end

function Emotes.Command(value)
    local name=tostring(value or ""):lower()
    if not allowed[name] then return nil,"No standard /e command for this emote" end
    return "/e "..name
end
function Emotes.Status()
    local _,_,reason=characterStatus()
    return {rigReady=reason==nil,reason=reason,busy=running,lastName=lastName,lastMethod=lastMethod,lastError=lastError,lastAssetId=lastAssetId,active=directTrack~=nil,detail=lastDetail}
end
_G.StanceEmoteEngine=Emotes
_G.StanceEmoteEngineUnload=function()
    Emotes.Stop()
    running=false
    _G.StanceEmoteEngine=nil
    _G.StanceEmoteEngineUnload=nil
end
