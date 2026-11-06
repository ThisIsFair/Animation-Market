local HttpService = game:GetService("HttpService")
local ClipProvider = game:GetService("AnimationClipProvider")
local HOST = "http://127.0.0.1:8765"
local workerToken = nil
local VERSION = (_G.StancePreviewWorkerVersion or 0) + 1
_G.StancePreviewWorkerVersion = VERSION
local VALID = {
    LowerTorso=true, UpperTorso=true, Head=true,
    LeftUpperArm=true, LeftLowerArm=true, LeftHand=true,
    RightUpperArm=true, RightLowerArm=true, RightHand=true,
    LeftUpperLeg=true, LeftLowerLeg=true, LeftFoot=true,
    RightUpperLeg=true, RightLowerLeg=true, RightFoot=true,
}
local function extract(id)
    local clip = ClipProvider:GetAnimationClipAsync("rbxassetid://" .. id)
    assert(clip:IsA("KeyframeSequence"), "CurveAnimation is not supported yet")
    local tracks = {}
    local duration = 0
    for _, frame in ipairs(clip:GetKeyframes()) do
        local t = frame.Time
        if type(t) == "number" and t >= 0 and t < 240 then
            duration = math.max(duration,t)
            for _, pose in ipairs(frame:GetDescendants()) do
                if pose:IsA("Pose") and VALID[pose.Name] then
                    local ok, components = pcall(function() return {pose.CFrame:GetComponents()} end)
                    if ok and #components == 12 then
                        local track = tracks[pose.Name]
                        if not track then track = {}; tracks[pose.Name] = track end
                        track[#track + 1] = {t, components}
                    end
                end
            end
        end
    end
    assert(next(tracks) ~= nil, "No R15 pose keyframes in animation")
    for _, track in pairs(tracks) do
        table.sort(track, function(a,b) return a[1] < b[1] end)
    end
    local looping = true
    pcall(function() looping = clip.Loop == true end)
    return {version=1, animationId=id, duration=math.max(0.2,duration), loop=looping, tracks=tracks}
end
local function request(url, method, data)
    local response = HttpService:RequestAsync({Url=url, Method=method or "GET",
        Headers={ ["Content-Type"]="application/json" }, Body=data})
    if not response.Success then error("Local bridge HTTP " .. response.StatusCode) end
    return HttpService:JSONDecode(response.Body)
end
local function publish(id, status, payload, message)
    local body = HttpService:JSONEncode({animationId=id, status=status, payload=payload, message=message, workerToken=workerToken})
    local ok, err = pcall(function() request(HOST .. "/v1/result", "POST", body) end)
    if not ok then warn("Stance preview result delivery: " .. tostring(err)) end
end
local ok, health = pcall(function() return request(HOST .. "/v1/health", "GET") end)
if not ok or health.status ~= "ready" then
    warn("Start Stance_Preview_Bridge.py before starting Studio auto preview")
else
    workerToken = health.workerToken
    print("Stance Studio auto-preview worker online")
    task.spawn(function()
        while _G.StancePreviewWorkerVersion == VERSION do
            local fetched, job = pcall(function() return request(HOST .. "/v1/next", "GET") end)
            if fetched and type(job) == "table" and type(job.animationId) == "string" then
                local id = job.animationId
                local success, payload = pcall(extract, id)
                if success then publish(id, "ok", payload) else publish(id, "error", nil, tostring(payload)) end
            elseif not fetched then
                warn("Stance Studio preview bridge disconnected")
                break
            end
            task.wait(.35)
        end
    end)
end
