-- Stance Dev / Marketplace-UGC Emote SERVER Observer
-- ROBLOX STUDIO SERVER Script (ServerScriptService) for a place you own.
-- This does NOT run under Matcha's LuaVM.
-- READ ONLY: observes Animator tracks; does not create/stop/load animations.
-- It cannot be installed into someone else's Roblox game's server.
--
-- Install: Roblox Studio > ServerScriptService > Script; paste this file.
-- Publish and join the actual experience with a normal Roblox client.
-- On the player client, run Stance_Dev_Emote_OneShot_v3.lua and Play().
-- Watch the server's F9 Developer Console logs as place owner, or Studio Output.
-- Compare events against a baseline idle and an official equipped emote.
--
-- IMPORTANT: if the client altered a local AnimationId in memory,
-- track.Animation.AnimationId may report a different ID from the actual
-- motion asset. Log the track ID but independently verify the visible pose
-- from a second client as well.
--
-- Roblox docs:
-- https://create.roblox.com/docs/reference/engine/classes/Animator

local Players = game:GetService("Players")
local VERSION = "server-observer-v1-20261107"
local EXPECTED_ANIMATION_ID = "118644064755644" -- underlying animation clip candidate
local TARGET_USERNAME = "" -- empty => observe all; e.g. "oxnardmatthew"
local PRINT_OTHER_TRACKS = true -- helpful for the baseline; prints one line per track start
local ACTIVE_SNAPSHOT_SECONDS = 90 -- number of seconds to poll active tracks per spawn

local PREFIX = "[Stance/ServerObserver] "
local function log(message)
    print(PREFIX .. tostring(message))
end
local function allowed(player)
    return TARGET_USERNAME == "" or player.Name:lower() == TARGET_USERNAME:lower()
end
local function assetId(track)
    local ok, value = pcall(function()
        return track.Animation and track.Animation.AnimationId
    end)
    if not ok or type(value) ~= "string" then return "unreadable" end
    return value:match("rbxassetid://(%d+)")
        or value:match("[?&]id=(%d+)") or value
end

local function present(player, track, eventType)
    local id = assetId(track)
    if PRINT_OTHER_TRACKS or id == EXPECTED_ANIMATION_ID then
        log(player.Name .. " " .. eventType
            .. " trackId=" .. tostring(id)
            .. (id == EXPECTED_ANIMATION_ID and " *** EXPECTED ID MATCH ***" or ""))
    end
end

local function onCharacter(player, character)
    if not allowed(player) then return end
    local humanoid = character:WaitForChild("Humanoid", 10)
    if not humanoid then
        log(player.Name .. " Humanoid unavailable")
        return
    end
    local animator = humanoid:WaitForChild("Animator", 10)
    if not animator then
        log(player.Name .. " Animator unavailable")
        return
    end
    log("Observing " .. player.Name .. " (server-side Animator created/replicated)")
    local connection = animator.AnimationPlayed:Connect(function(track)
        present(player, track, "AnimationPlayed")
    end)

    task.spawn(function()
        local seen = {}
        local limit = os.clock() + ACTIVE_SNAPSHOT_SECONDS
        while os.clock() < limit and player.Character == character do
            local ok, tracks = pcall(function()
                return animator:GetPlayingAnimationTracks()
            end)
            if ok and type(tracks) == "table" then
                for _, track in ipairs(tracks) do
                    if not seen[track] then
                        seen[track] = true
                        present(player, track, "GetPlayingAnimationTracks")
                    end
                end
            end
            task.wait(0.4)
        end
        connection:Disconnect()
        log("Observer snapshot window ended for " .. player.Name
            .. " (rejoin to start a fresh 90-second observation)")
    end)
end

log("VERSION " .. VERSION)
log("Watching Animator.AnimationPlayed on the SERVER for ID " .. EXPECTED_ANIMATION_ID)
log("This script does not request/play animations or modify the game.")
log("SERVER seeing expected track ID is strong evidence; absent ID is inconclusive")
log("when source AnimationIds were substituted in client memory.")
for _, player in ipairs(Players:GetPlayers()) do
    if allowed(player) then
        if player.Character then task.spawn(onCharacter,player,player.Character) end
        player.CharacterAdded:Connect(function(character)
            task.spawn(onCharacter,player,character)
        end)
    end
end
Players.PlayerAdded:Connect(function(player)
    if not allowed(player) then return end
    player.CharacterAdded:Connect(function(character)
        task.spawn(onCharacter,player,character)
    end)
end)
