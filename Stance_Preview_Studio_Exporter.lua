local animationId = "507766666"
local HttpService = game:GetService("HttpService")
local AnimationClipProvider = game:GetService("AnimationClipProvider")
local ServerStorage = game:GetService("ServerStorage")
local clip = AnimationClipProvider:GetAnimationClipAsync("rbxassetid://" .. animationId)
assert(clip:IsA("KeyframeSequence"), "This clip is not a KeyframeSequence; CurveAnimation export is not implemented")
local tracks = {}
local duration = 0
local supported = {
    LowerTorso=true, UpperTorso=true, Head=true,
    LeftUpperArm=true, LeftLowerArm=true, LeftHand=true,
    RightUpperArm=true, RightLowerArm=true, RightHand=true,
    LeftUpperLeg=true, LeftLowerLeg=true, LeftFoot=true,
    RightUpperLeg=true, RightLowerLeg=true, RightFoot=true,
}
local frames = clip:GetKeyframes()
for _, keyframe in ipairs(frames) do
    local tm = keyframe.Time
    duration = math.max(duration, tm)
    for _, pose in ipairs(keyframe:GetDescendants()) do
        if pose:IsA("Pose") and supported[pose.Name] then
            local components = {pose.CFrame:GetComponents()}
            local track = tracks[pose.Name]
            if not track then track = {}; tracks[pose.Name] = track end
            track[#track + 1] = {tm, components}
        end
    end
end
for _, track in pairs(tracks) do
    table.sort(track, function(a,b) return a[1] < b[1] end)
end
assert(next(tracks) ~= nil, "No supported R15 poses were found in this animation")
local looping = false
pcall(function() looping = clip.Loop == true end)
local payload = HttpService:JSONEncode({
    version = 1,
    animationId = animationId,
    duration = math.max(0.2, duration),
    loop = looping,
    tracks = tracks,
})
local folder = ServerStorage:FindFirstChild("StancePreviewExports")
if not folder then
    folder = Instance.new("Folder")
    folder.Name = "StancePreviewExports"
    folder.Parent = ServerStorage
end
local scriptFile = Instance.new("ModuleScript")
scriptFile.Name = "StancePreview_" .. animationId
scriptFile.Source = payload
scriptFile.Parent = folder
game:GetService("Selection"):Set({scriptFile})
print("Stance preview JSON is in ServerStorage/StancePreviewExports/" .. scriptFile.Name)
print("Open that ModuleScript, copy its full JSON text, then save it as SpooferConfig/StancePreviews/" .. animationId .. ".json" .. " in Matcha's workspace")
