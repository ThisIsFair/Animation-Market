local SOURCE = "https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Mono_Experimental.lua"
if type(httpget) ~= "function" or type(loadstring) ~= "function" then
    _G.StanceDevLoaderStatus = "Matcha httpget/loadstring unavailable"
    return
end
local body = httpget(SOURCE)
if type(body) ~= "string" or #body < 1000 then
    _G.StanceDevLoaderStatus = "Stance Dev download failed"
    return
end
_G.StanceDevLoaderStatus = "Starting Stance Dev"
loadstring(body)()
_G.StanceDevLoaderStatus = "Stance Dev launched"
