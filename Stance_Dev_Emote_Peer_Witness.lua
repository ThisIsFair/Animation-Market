-- Stance Dev / Marketplace-UGC Emote Peer Witness
-- READ-ONLY; run on a DIFFERENT Roblox account/client than the emote player.
-- Designed for Matcha LuaVM (standard documented Players, Instance,
-- BasePart.Position, task.spawn and task.wait APIs only).
-- DOES NOT decode protected scripts, change memory, send remotes, or play emotes.
--
-- USAGE IN THE OBSERVER CLIENT:
-- loadstring(httpget("https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Dev_Emote_Peer_Witness.lua"))()
-- _G.StancePeerWitness.Watch("oxnardmatthew", 30)
-- (Keep target still for the first 1.5 seconds to capture idle baseline)
-- (Switch to target client: _G.StanceOneShotEmote.Play("118644064755644"))
-- _G.StancePeerWitness.Report()
-- _G.StancePeerWitness.Stop()
--
-- Interpret with care: limb pose movement does not identify the emote asset
-- and cannot independently prove what the server's Animator loaded.
-- A second account VISUALLY seeing the correct emote is the practical check.

if type(_G.StancePeerWitness) == "table"
    and type(_G.StancePeerWitness.Unload) == "function" then
    pcall(_G.StancePeerWitness.Unload)
end

local VERSION = "peer-witness-v1-20261107"
local TAG = "[Stance/PeerWitness] "
local Players = game:GetService("Players")
local P = { Version = VERSION }
local cfg = {
    active = false, token = 0, target = nil, targetName = nil,
    startAt = 0, endAt = 0, frames = 0, valid = 0, missing = 0,
    moved = 0, strong = 0, peak = 0, peakAt = 0,
    baseline = nil, baselineFrames = 0, samples = 0, latest = 0,
    endReason = "Not started"
}
local LIMBS = {"Head","UpperTorso","LeftHand","RightHand","LeftFoot","RightFoot"}

local function log(message) print(TAG .. tostring(message)) end
local function err(message)
    log("BLOCKED: " .. tostring(message))
    return false, tostring(message)
end
local function magnitude3(x,y,z) return math.sqrt(x*x+y*y+z*z) end

local function findPlayer(name)
    if type(name) ~= "string" or name:match("^%s*$") then
        return nil, "Enter the EXACT Roblox username (not display name)"
    end
    local needle = name:lower():match("^%s*(.-)%s*$")
    for _, player in ipairs(Players:GetPlayers()) do
        local ok, value = pcall(function() return player.Name end)
        if ok and type(value) == "string" and value:lower() == needle then
            return player
        end
    end
    return nil, "Player not found in this server: " .. name
end

local function sample(player)
    local character = player and player.Character
    if not character then return nil, "Character not loaded" end
    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then return nil, "Root part unavailable" end
    local gotRoot, rootPos = pcall(function() return root.Position end)
    if not gotRoot or not rootPos then return nil, "Root.Position unavailable" end

    local items, count = {}, 0
    for _, name in ipairs(LIMBS) do
        local part = character:FindFirstChild(name)
        if part then
            local ok, pos = pcall(function() return part.Position end)
            if ok and pos then
                items[name] = {pos.X - rootPos.X,pos.Y - rootPos.Y,pos.Z - rootPos.Z}
                count = count + 1
            end
        end
    end
    if count < 3 then return nil, "Could not read 3 R15 body parts" end
    return {partPositions=items,root={rootPos.X,rootPos.Y,rootPos.Z},count=count}, nil
end

local function baselineFrom(samples)
    local result, counts = {}, {}
    for _, data in ipairs(samples) do
        for name, coords in pairs(data.partPositions) do
            local existing = result[name]
            if not existing then existing = {0,0,0}; result[name] = existing end
            for i=1,3 do existing[i] = existing[i] + coords[i] end
            counts[name] = (counts[name] or 0) + 1
        end
    end
    for name, coords in pairs(result) do
        local count = counts[name]
        for i=1,3 do coords[i] = coords[i] / count end
    end
    return result
end

local function deviation(frame, base)
    local sum, count = 0, 0
    for name, coords in pairs(frame.partPositions) do
        local prior = base[name]
        if prior then
            sum = sum + magnitude3(coords[1]-prior[1],coords[2]-prior[2],coords[3]-prior[3])
            count = count + 1
        end
    end
    if count < 3 then return nil end
    return sum / count
end

function P.Watch(username, seconds)
    if cfg.active then return err("A watch is already running; call .Stop()") end
    local target, reason = findPlayer(username)
    if not target then return err(reason) end
    local selfPlayer = Players.LocalPlayer
    if target == selfPlayer then
        return err("Run this witness on a SECOND client, not the emote player's client")
    end
    local secondsNum = tonumber(seconds) or 30
    if secondsNum < 10 then secondsNum = 10 end
    if secondsNum > 120 then secondsNum = 120 end
    cfg.active = true
    cfg.token = cfg.token + 1
    cfg.target, cfg.targetName = target, username
    cfg.startAt, cfg.endAt = tick(), tick() + secondsNum
    cfg.frames, cfg.valid, cfg.missing, cfg.moved, cfg.strong, cfg.peak = 0,0,0,0,0,0
    cfg.baseline, cfg.baselineFrames, cfg.samples, cfg.latest = nil,0,0,0
    cfg.peakAt = 0
    cfg.endReason = "Running"
    local token = cfg.token
    log("Watching remote R15 player " .. username .. " for " .. secondsNum .. "s")
    log("Keep target still for the first ~1.5s while capturing idle baseline.")
    log("Then play the V3 emote on the OTHER client. Watch the second screen visually.")
    task.spawn(function()
        local success, issue = pcall(function()
            local baselineFrames = {}
            for _=1,12 do
                if not cfg.active or cfg.token ~= token then return end
                local frame = sample(target)
                if frame then baselineFrames[#baselineFrames+1] = frame end
                task.wait(0.12)
            end
            if #baselineFrames < 5 then
                cfg.endReason = "Insufficient remote R15 samples to establish baseline"
                cfg.active = false
                log(cfg.endReason)
                return
            end
            cfg.baselineFrames = #baselineFrames
            cfg.baseline = baselineFrom(baselineFrames)
            local baselineRoot = baselineFrames[#baselineFrames].root
            log("Idle baseline established from " .. cfg.baselineFrames .. " remote frames.")
            local lastPrint = tick()
            while cfg.active and cfg.token == token and tick() < cfg.endAt do
                local frame = sample(target)
                cfg.frames = cfg.frames + 1
                if not frame then
                    cfg.missing = cfg.missing + 1
                else
                    local dx = frame.root[1] - baselineRoot[1]
                    local dy = frame.root[2] - baselineRoot[2]
                    local dz = frame.root[3] - baselineRoot[3]
                    local rootShift = magnitude3(dx,dy,dz)
                    if rootShift > 1.5 then
                        cfg.moved = cfg.moved + 1
                    else
                        local d = deviation(frame, cfg.baseline)
                        if d then
                            cfg.valid = cfg.valid + 1
                            cfg.latest = d
                            if d > cfg.peak then cfg.peak,cfg.peakAt=d,tick()-cfg.startAt end
                            -- Advisory marker only; ordinary idle may also deviate.
                            if d > 0.22 then cfg.strong = cfg.strong + 1 end
                        end
                    end
                end
                if tick() - lastPrint > 5 then
                    lastPrint = tick()
                    log("remote body-pose samples=" .. cfg.valid
                        .. ", peak deviation=" .. string.format("%.3f",cfg.peak)
                        .. " studs, root moved frames=" .. cfg.moved)
                end
                task.wait(0.12)
            end
            if cfg.token == token then
                cfg.active = false
                cfg.endReason = "Completed observation window"
                P.Report()
            end
        end)
        if not success and cfg.token == token then
            cfg.active = false
            cfg.endReason = "Monitor failed: " .. tostring(issue)
            log(cfg.endReason)
        end
    end)
    return true, "Remote witness started"
end

function P.Report()
    log("Version=" .. VERSION .. "; target=" .. tostring(cfg.targetName)
        .. "; active=" .. tostring(cfg.active) .. "; status=" .. cfg.endReason)
    log("Remote samples=" .. cfg.valid .. "; missing=" .. cfg.missing
        .. "; root-motion frames excluded=" .. cfg.moved)
    log("Peak body-pose deviation=" .. string.format("%.3f",cfg.peak)
        .. " studs at t+" .. string.format("%.2f",cfg.peakAt)
        .. "s; above 0.22 stud frames=" .. cfg.strong)
    if cfg.valid == 0 then
        log("No usable remote body-pose observations. Cannot evaluate visibility.")
    elseif cfg.strong == 0 then
        log("No large pose differences detected; still check the other client's SCREEN.")
    else
        log("Remote limb-pose differences detected; does NOT identify the animation asset.")
    end
    log("CONFIRMATION REQUIRES: another account visually seeing the correct UGC emote,")
    log("or a server-controlled experience logging its animation track independently.")
    return true, cfg.endReason
end

function P.Stop()
    if not cfg.active then
        P.Report()
        return true, "No active watch"
    end
    cfg.active = false
    cfg.token = cfg.token + 1
    cfg.endReason = "Stopped manually"
    return P.Report()
end

function P.Unload()
    if cfg.active then P.Stop() end
    if _G.StancePeerWitness == P then _G.StancePeerWitness = nil end
    log("Unloaded")
    return true
end

_G.StancePeerWitness = P
log("VERSION " .. VERSION .. " loaded (read-only, second-client witness)")
log("Call _G.StancePeerWitness.Watch('oxnardmatthew', 30) on OTHER client.")
