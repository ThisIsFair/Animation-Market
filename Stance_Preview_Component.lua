local Preview = {
    current = nil, selectedSlot = "Idle", animationId = nil,
    target = 0, progress = 0, yaw = 0.55, pitch = 0.1, zoom = 1,
    playTime = 0, playing = true, looping = true, speed = 1,
    orbiting = false, orbitX = 0, orbitY = 0, viewport = nil,
    clip = nil, loading = false, message = "Select an animation to preview",
    cache = {}, attempted = {}, generation = 0,
}
local PREVIEW_WIDTH = 336
local PREVIEW_ROOT = "SpooferConfig/StancePreviews/"
local PREVIEW_REMOTE = "https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/SpooferConfig/StancePreviews/"
local PREVIEW_EMPTY = CFrame.new()
local PREVIEW_PARTS = {
    { "LowerTorso", nil, {0, -0.28, 0}, {1.6, 0.8, 0.8}, {0, 0, 0} },
    { "UpperTorso", "LowerTorso", {0, 0.84, 0}, {1.95, 1.05, 0.88}, {0, 0.12, 0} },
    { "Head", "UpperTorso", {0, 1.04, 0}, {0.95, 0.95, 0.95}, {0, 0.35, 0} },
    { "LeftUpperArm", "UpperTorso", {-1.14, 0.42, 0}, {0.52, 0.84, 0.56}, {0, -0.38, 0} },
    { "LeftLowerArm", "LeftUpperArm", {0, -0.87, 0}, {0.48, 0.74, 0.5}, {0, -0.36, 0} },
    { "LeftHand", "LeftLowerArm", {0, -0.75, 0}, {0.42, 0.37, 0.42}, {0, -0.15, 0} },
    { "RightUpperArm", "UpperTorso", {1.14, 0.42, 0}, {0.52, 0.84, 0.56}, {0, -0.38, 0} },
    { "RightLowerArm", "RightUpperArm", {0, -0.87, 0}, {0.48, 0.74, 0.5}, {0, -0.36, 0} },
    { "RightHand", "RightLowerArm", {0, -0.75, 0}, {0.42, 0.37, 0.42}, {0, -0.15, 0} },
    { "LeftUpperLeg", "LowerTorso", {-0.48, -0.69, 0}, {0.72, 1.15, 0.76}, {0, -0.56, 0} },
    { "LeftLowerLeg", "LeftUpperLeg", {0, -1.13, 0}, {0.65, 1.02, 0.68}, {0, -0.49, 0} },
    { "LeftFoot", "LeftLowerLeg", {0, -1.0, -0.17}, {0.68, 0.37, 1.02}, {0, -0.11, -0.15} },
    { "RightUpperLeg", "LowerTorso", {0.48, -0.69, 0}, {0.72, 1.15, 0.76}, {0, -0.56, 0} },
    { "RightLowerLeg", "RightUpperLeg", {0, -1.13, 0}, {0.65, 1.02, 0.68}, {0, -0.49, 0} },
    { "RightFoot", "RightLowerLeg", {0, -1.0, -0.17}, {0.68, 0.37, 1.02}, {0, -0.11, -0.15} },
}
local PREVIEW_FACES = {
    {1, 2, 3, 4, 0.26}, {5, 8, 7, 6, 0.37},
    {1, 5, 6, 2, 0.38}, {2, 6, 7, 3, 0.57},
    {3, 7, 8, 4, 0.7}, {4, 8, 5, 1, 0.45},
}
local function previewFrame(arr)
    if type(arr) ~= "table" or #arr ~= 12 then return nil end
    for i = 1, 12 do
        if type(arr[i]) ~= "number" or arr[i] ~= arr[i] or math.abs(arr[i]) > 10000 then return nil end
    end
    local ok, cf = pcall(function()
        return CFrame.new(arr[1], arr[2], arr[3], arr[4], arr[5], arr[6], arr[7], arr[8], arr[9], arr[10], arr[11], arr[12])
    end)
    if ok then return cf end
    return nil
end
local function previewDecode(raw, id)
    local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(data) ~= "table" or tonumber(data.version) ~= 1
        or tostring(data.animationId) ~= id or type(data.tracks) ~= "table" then return nil end
    local duration = tonumber(data.duration)
    if not duration or duration <= 0 or duration > 240 then return nil end
    local tracks, valid = {}, 0
    for _, spec in ipairs(PREVIEW_PARTS) do
        local source = data.tracks[spec[1]]
        if type(source) == "table" then
            local track = {}
            for _, key in ipairs(source) do
                if #track >= 1000 then break end
                if type(key) == "table" and tonumber(key[1]) then
                    local tm = tonumber(key[1])
                    local cf = previewFrame(key[2])
                    if cf and tm >= 0 and tm <= duration + 0.001 then
                        track[#track + 1] = {t = tm, cf = cf}
                    end
                end
            end
            table.sort(track, function(a, b) return a.t < b.t end)
            if #track > 0 then tracks[spec[1]] = track; valid = valid + 1 end
        end
    end
    if valid == 0 then return nil end
    return {animationId = id, duration = duration, tracks = tracks, loop = data.loop ~= false}
end
local function previewNative(id)
    local ok, obj = pcall(function()
        return game:GetService("AnimationClipProvider"):GetAnimationClipAsync("rbxassetid://" .. id)
    end)
    if not ok or not obj then return nil end
    local seqOk, isSeq = pcall(function() return obj:IsA("KeyframeSequence") end)
    if not seqOk or not isSeq then return nil end
    local keyOk, keys = pcall(function() return obj:GetKeyframes() end)
    if not keyOk or type(keys) ~= "table" then return nil end
    local wanted = {}
    for _, spec in ipairs(PREVIEW_PARTS) do wanted[spec[1]] = true end
    local tracks, duration = {}, 0
    for _, frame in ipairs(keys) do
        local tm = tonumber(frame.Time)
        if tm and tm >= 0 and tm < 240 then
            duration = math.max(duration, tm)
            local got, descendants = pcall(function() return frame:GetDescendants() end)
            if got and type(descendants) == "table" then
                for _, pose in ipairs(descendants) do
                    if wanted[pose.Name] and pose:IsA("Pose") then
                        local cfOK, components = pcall(function() return {pose.CFrame:GetComponents()} end)
                        if cfOK and #components == 12 then
                            local track = tracks[pose.Name]
                            if not track then track = {}; tracks[pose.Name] = track end
                            track[#track + 1] = {tm, components}
                        end
                    end
                end
            end
        end
    end
    if next(tracks) == nil then return nil end
    for _, track in pairs(tracks) do
        table.sort(track, function(a, b) return a[1] < b[1] end)
    end
    local looping = true
    pcall(function() looping = obj.Loop == true end)
    local okJson, json = pcall(function()
        return HttpService:JSONEncode({version = 1, animationId = id, duration = math.max(duration, 0.2),
            loop = looping, tracks = tracks})
    end)
    if not okJson or type(json) ~= "string" then return nil end
    return previewDecode(json, id), json
end
function Preview.load(id)
    if not id or not tostring(id):match("^%d+$") then
        Preview.clip = nil; Preview.animationId = nil; Preview.message = "No animation ID in this state"; return
    end
    id = tostring(id)
    if Preview.animationId == id and (Preview.clip or Preview.loading) then return end
    Preview.generation = Preview.generation + 1
    local gen = Preview.generation
    Preview.animationId, Preview.clip, Preview.playTime = id, nil, 0
    Preview.playing, Preview.loading = true, false
    if Preview.cache[id] then
        Preview.clip = Preview.cache[id]
        Preview.looping = Preview.clip.loop
        Preview.message = ""
        return
    end
    if Preview.attempted[id] then
        Preview.message = "Keyframes unavailable for #" .. id
        return
    end
    Preview.attempted[id] = true
    Preview.loading = true
    Preview.message = "Loading keyframes for #" .. id
    task.spawn(function()
        local raw
        local path = PREVIEW_ROOT .. id .. ".json"
        pcall(function() if isfile(path) then raw = readfile(path) end end)
        local clip = raw and previewDecode(raw, id)
        if not clip then
            local native, encoded = previewNative(id)
            if native then
                clip = native
                pcall(function() writefile(path, encoded) end)
            end
        end
        if not clip then
            local ok, remote = pcall(httpget, PREVIEW_REMOTE .. id .. ".json")
            if ok and type(remote) == "string" and #remote > 0 and #remote < 1800000 then
                clip = previewDecode(remote, id)
                if clip then pcall(function() writefile(path, remote) end) end
            end
        end
        if Preview.generation ~= gen then return end
        Preview.loading = false
        if clip then
            Preview.cache[id] = clip
            Preview.clip, Preview.looping, Preview.message = clip, clip.loop, ""
        else
            Preview.message = "No exported keyframes for #" .. id
        end
    end)
end
function Preview.selectPack(pack)
    if not pack then return end
    Preview.current = pack
    if not pack.anims[Preview.selectedSlot] then
        for _, slot in ipairs(SLOTS) do
            if pack.anims[slot] then Preview.selectedSlot = slot; break end
        end
    end
    Preview.target = 1
    Preview.load(pack.anims[Preview.selectedSlot])
end
function Preview.chooseSlot(slot)
    Preview.selectedSlot = slot
    if Preview.current then Preview.load(Preview.current.anims[slot]) end
end
function Preview.toggle()
    Preview.target = Preview.target > 0 and 0 or 1
    if Preview.target > 0 and not Preview.current and State.equipped ~= "mix" then
        Preview.selectPack(State.equipped and PACK_BY_ID[State.equipped] or PACKS[1])
    end
end
function Preview.step(dt)
    Preview.progress = Preview.progress + (Preview.target - Preview.progress) * math.min(1, dt * 14)
    if math.abs(Preview.target - Preview.progress) < 0.004 then Preview.progress = Preview.target end
    if Preview.clip and Preview.playing and Preview.progress > 0.01 then
        Preview.playTime = Preview.playTime + dt * Preview.speed
        if Preview.playTime >= Preview.clip.duration then
            if Preview.looping then Preview.playTime = Preview.playTime % Preview.clip.duration
            else Preview.playTime = Preview.clip.duration; Preview.playing = false end
        end
    end
end
local function previewPose(name)
    local track = Preview.clip and Preview.clip.tracks[name]
    if not track or #track == 0 then return PREVIEW_EMPTY end
    if #track == 1 or Preview.playTime <= track[1].t then return track[1].cf end
    local tail = track[#track]
    if Preview.playTime >= tail.t then return tail.cf end
    local lo, hi = 1, #track
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if track[mid].t <= Preview.playTime then lo = mid else hi = mid end
    end
    local a, b = track[lo], track[hi]
    local span = b.t - a.t
    if span <= 0 then return a.cf end
    return a.cf:Lerp(b.cf, math.clamp((Preview.playTime - a.t) / span, 0, 1))
end
function Preview.model(vx, vy, vw, vh)
    local yaw, pitch = Preview.yaw, Preview.pitch
    local sy, cy = math.sin(yaw), math.cos(yaw)
    local sp, cp = math.sin(pitch), math.cos(pitch)
    local scale = math.min(vw / 4.8, vh / 6.5) * Preview.zoom
    local mx, my = vx + vw / 2, vy + vh / 2
    local function project(p)
        local px, py, pz = p.X, p.Y - 2.6, p.Z
        local x = px * cy + pz * sy
        local z = pz * cy - px * sy
        local y = py * cp - z * sp
        local depth = z * cp + py * sp
        local f = 1 / math.max(0.65, 1 + depth / 17)
        return mx + x * scale * f, my - y * scale * f, depth
    end
    local frames = {Root = CFrame.new(0, 3.0, 0)}
    local triangles = {}
    for _, spec in ipairs(PREVIEW_PARTS) do
        local name, parent, offset, size, center = spec[1], spec[2], spec[3], spec[4], spec[5]
        local parentCf = parent and frames[parent] or frames.Root
        local cf = parentCf * CFrame.new(offset[1], offset[2], offset[3]) * previewPose(name)
        frames[name] = cf
        local partCf = cf * CFrame.new(center[1], center[2], center[3])
        local xh, yh, zh = size[1] / 2, size[2] / 2, size[3] / 2
        local corners = {
            {-xh,-yh,-zh}, {xh,-yh,-zh}, {xh,yh,-zh}, {-xh,yh,-zh},
            {-xh,-yh,zh}, {xh,-yh,zh}, {xh,yh,zh}, {-xh,yh,zh},
        }
        local projected = {}
        for i, p in ipairs(corners) do
            local wp = partCf * Vector3.new(p[1],p[2],p[3])
            local x,y,z = project(wp)
            projected[i] = {x,y,z}
        end
        for _, face in ipairs(PREVIEW_FACES) do
            local a,b,c,d = projected[face[1]],projected[face[2]],projected[face[3]],projected[face[4]]
            local area = (b[1]-a[1])*(c[2]-a[2]) - (b[2]-a[2])*(c[1]-a[1])
            if area < -0.01 then
                local brightness = face[5]
                if name == "Head" then brightness = brightness * 1.12 end
                if name:find("Foot",1,true) then brightness = brightness * 0.77 end
                local tone = mix(TH.bg, TH.text, math.min(0.92, brightness))
                triangles[#triangles+1] = {z = (a[3]+b[3]+c[3]+d[3])*0.25,
                    a = a,b = b,c = c,d = d,col = tone}
            end
        end
    end
    table.sort(triangles,function(a,b) return a.z > b.z end)
    for _, t in ipairs(triangles) do
        tri(t.a[1],t.a[2],t.b[1],t.b[2],t.c[1],t.c[2],t.col,41)
        tri(t.a[1],t.a[2],t.c[1],t.c[2],t.d[1],t.d[2],t.col,41)
    end
end
function Preview.viewportHit(lx, ly)
    local vp = Preview.viewport
    return Preview.target > 0 and vp ~= nil and lx >= vp.x and ly >= vp.y
        and lx <= vp.x + vp.w and ly <= vp.y + vp.h
end
function Preview.drawPanel(px, py, pw, ph)
    card(px, py, pw, ph, 26, 10)
    if Preview.progress < 0.92 then return end
    local ix, iw = px + 14, pw - 28
    txt("ANIMATION PREVIEW", ix, py + 25, FS - 2, TH.sub, 14, false, true)
    button(px + pw - 40, py + 12, 26, 26, "x", "pvclose", function() Preview.target = 0 end,
        "ghost", 20, "Close preview")
    txt(fit(Preview.current and Preview.current.name or "R15 Mannequin", iw, FS + 2),
        ix, py + 51, FS + 2, TH.text, 14, false, true)
    local slotY = py + 65
    button(ix, slotY, iw, 28, "State: " .. (SLOT_LABEL[Preview.selectedSlot] or "Idle"), "pvslot", function()
        local i = 0
        for idx, slot in ipairs(SLOTS) do if slot == Preview.selectedSlot then i = idx; break end end
        Preview.chooseSlot(SLOTS[i + 1] or SLOTS[1])
    end, "soft", 20, "Cycle animation states")
    local vx, vy, vw = ix, py + 104, iw
    local vh = math.max(160, ph - 273)
    card(vx, vy, vw, vh, 16, 30, nil, TH.ctl)
    Preview.viewport = {x=vx,y=vy,w=vw,h=vh}
    Preview.model(vx + 2, vy + 2, vw - 4, vh - 4)
    if Preview.loading then
        txt("Loading keyframes...", vx + vw / 2, vy + 24, FS - 1, TH.sub, 46, true)
    elseif not Preview.clip then
        txt("NO ANIMATION DATA", vx + vw / 2, vy + 24, FS - 1, TH.warn, 46, true, true)
        txt(fit(Preview.message, vw - 18, FS - 3), vx + vw / 2, vy + 44,
            FS - 3, TH.sub, 46, true)
    end
    txt("Drag to orbit", vx + 12, vy + vh - 16, FS - 3, TH.mute, 46)
    local py2 = vy + vh + 10
    local third = math.floor((iw - 12) / 3)
    button(ix, py2, third, 29, Preview.playing and "Pause" or "Play", "pvplay", function()
        Preview.playing = not Preview.playing
    end, Preview.clip and "primary" or "soft", 20)
    button(ix + third + 6, py2, third, 29, "Restart", "pvrestart", function()
        Preview.playTime = 0; Preview.playing = true
        if Preview.animationId and not Preview.clip then
            Preview.attempted[Preview.animationId] = nil
            Preview.load(Preview.animationId)
        end
    end, "soft", 20)
    button(ix + 2*(third + 6), py2, third, 29, "Zoom " .. round(Preview.zoom*100) .. "%", "pvzoom", function()
        Preview.zoom = Preview.zoom >= 1.25 and 0.75 or (Preview.zoom + 0.25)
    end, "soft", 20)
    local py3 = py2 + 36
    button(ix, py3, third, 28, "Speed " .. Preview.speed .. "x", "pvspeed", function()
        if Preview.speed == 0.5 then Preview.speed = 1
        elseif Preview.speed == 1 then Preview.speed = 1.5
        else Preview.speed = 0.5 end
    end, "soft", 20)
    button(ix + third + 6, py3, third, 28, Preview.looping and "Loop On" or "Loop Off", "pvloop", function()
        Preview.looping = not Preview.looping
    end, "soft", 20)
    button(ix + 2*(third + 6), py3, third, 28, "Reset view", "pvreset", function()
        Preview.yaw, Preview.pitch, Preview.zoom = 0.55, 0.1, 1
    end, "soft", 20)
    local progress = Preview.clip and math.clamp(Preview.playTime / Preview.clip.duration, 0, 1) or 0
    rect(ix, py3 + 37, iw, 4, TH.line, 40, 2)
    rect(ix, py3 + 37, math.max(1, iw * progress), 4, TH.accent, 41, 2)
    local position = Preview.clip and string.format("%.1f / %.1f s", Preview.playTime, Preview.clip.duration)
        or "Export keyframes to enable playback"
    txt(position, ix, py3 + 56, FS - 3, TH.sub, 42)
end
