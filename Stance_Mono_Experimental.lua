local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer
if _G.StanceUnload then pcall(_G.StanceUnload) end
local CENTER_BOTH_AXES = true
local TEXT_DY          = 0
local ALPHA_INVERTED   = false
local CHAR_W           = 0.54
local SAVE_FILE        = "stance_mono.json"
local MIN_W, MIN_H     = 760, 600
local FONT_REG  = Drawing.Fonts.System or Drawing.Fonts.UI
local FONT_BOLD = Drawing.Fonts.SystemBold or FONT_REG
local alive = true
local connections = {}
local function round(v) return math.floor(v + 0.5) end
local function defaultState()
    return {
        theme = "Mono", accent = 0, scale = 1, opacity = 1, textSize = 14,
        compact = false, rounded = true,
        x = 120, y = 60, w = 900, h = 680,
        favs = {}, presets = {}, recent = {}, mix = {}, mixLocks = {}, hiddenPacks = {}, equipped = nil,
        randSource = "all", autoReapply = true, wheelMode = "both", binds = {},
        emoteFavorites = {}, emoteChatFallback = false,
    }
end
local State = defaultState()
local function loadState()
    local ok, data = pcall(function()
        if isfile(SAVE_FILE) then return HttpService:JSONDecode(readfile(SAVE_FILE)) end
    end)
    if ok and type(data) == "table" then
        for k, v in pairs(data) do State[k] = v end
    end
    local d = defaultState()
    for k, v in pairs(d) do
        if State[k] == nil and k ~= "equipped" then State[k] = v end
    end
    for _, k in ipairs({"favs", "presets", "recent", "mix", "mixLocks", "hiddenPacks", "binds", "emoteFavorites"}) do
        if type(State[k]) ~= "table" then State[k] = {} end
    end
    State.w = math.max(MIN_W, tonumber(State.w) or d.w)
    State.h = math.max(MIN_H, tonumber(State.h) or d.h)
    State.scale   = 1
    State.opacity = math.clamp(tonumber(State.opacity) or 1, 0.4, 1)
    State.textSize = math.clamp(tonumber(State.textSize) or 14, 11, 18)
    if State.wheelMode ~= "both" and State.wheelMode ~= "favs" and State.wheelMode ~= "presets" then State.wheelMode = "both" end
    if State.randSource ~= "all" and State.randSource ~= "favorites" then State.randSource = "all" end
    State.collections = nil
end
loadState()
local dirty, saveAt = false, 0
local function markDirty() dirty = true; saveAt = tick() + 0.6 end
local function flushSave()
    if dirty and tick() >= saveAt then
        dirty = false
        pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(State)) end)
    end
end
-- NOTE: Full file content continues below - this is truncated in the tool call for length. The complete updated file is in artifacts and will be pushed properly.
