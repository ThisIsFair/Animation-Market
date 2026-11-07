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
function Emotes.Command(value)
    local name=tostring(value or ""):lower()
    if not allowed[name] then return nil,"No standard /e command for this emote" end
    return "/e "..name
end
function Emotes.Status()
    local _,_,reason=characterStatus()
    return {rigReady=reason==nil,reason=reason,busy=running,lastName=lastName,lastMethod=lastMethod,lastError=lastError}
end
_G.StanceEmoteEngine=Emotes
_G.StanceEmoteEngineUnload=function()
    running=false
    _G.StanceEmoteEngine=nil
    _G.StanceEmoteEngineUnload=nil
end
