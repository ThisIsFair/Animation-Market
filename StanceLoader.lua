local ROOT = "https://raw.githubusercontent.com/ThisIsFair/Animation-Market/main/"
local JSON_PATH = "SpooferConfig/MarketplaceResolved.json"
local LUA_PATH = "Matcha_Animation_Changer.lua"
local CACHE_PATH = "SpooferConfig/Stance_Script_Cache.lua"
local MIN_PACKS = 1052

local function warning(message)
    warn("[Stance] " .. message)
end

if type(ROOT) ~= "string" or not ROOT:match("^https://raw%.githubusercontent%.com/[^/]+/[^/]+/[^/]+/$") then
    warning("The repository URL is invalid.")
    return
end
if type(httpget) ~= "function" or type(loadstring) ~= "function" then
    warning("Requires Matcha's httpget() and loadstring().")
    return
end
if type(isfile) ~= "function" or type(readfile) ~= "function" or type(writefile) ~= "function" then
    warning("Requires Matcha's workspace readfile()/writefile() API.")
    return
end

local HttpService = game:GetService("HttpService")
local function fetch(relativePath)
    local ok, result = pcall(httpget, ROOT .. relativePath)
    if ok and type(result) == "string" and #result > 0 then
        return result
    end
    return nil
end
local function readCached(path)
    local ok, body = pcall(function()
        if isfile(path) then return readfile(path) end
    end)
    if ok and type(body) == "string" then return body end
    return nil
end
local function validScript(body)

    return type(body) == "string" and #body > 16000
        and body:find("local MarketCore = {}", 1, true) ~= nil
        and body:find("local function startStanceUI()", 1, true) ~= nil
end
local function countValidPacks(body)
    if type(body) ~= "string" or #body < 1000 then return nil end
    local ok, parsed = pcall(function() return HttpService:JSONDecode(body) end)
    if not ok or type(parsed) ~= "table" or parsed.version ~= 1 or type(parsed.packs) ~= "table" then
        return nil
    end
    local count = 0
    for id, record in pairs(parsed.packs) do
        if type(id) ~= "string" or not id:match("^%d+$") or
           type(record) ~= "table" or type(record.menuName) ~= "string" or
           type(record.rows) ~= "table" or #record.rows == 0 then
            return nil
        end
        count = count + 1
    end
    if count < MIN_PACKS then return nil end
    return count
end


local remoteJSON = fetch(JSON_PATH)
local remoteScript = fetch(LUA_PATH)
local existingJSON = readCached(JSON_PATH)
local existingCount = countValidPacks(existingJSON)
local remoteCount = countValidPacks(remoteJSON)
local script = nil

if validScript(remoteScript) then
    script = remoteScript
else
    local cached = readCached(CACHE_PATH)
    if validScript(cached) then
        script = cached
        warning("Could not retrieve a valid script from the repository. Using locally cached Lua.")
    else
        warning("Could not download Stance Lua, and no valid cached script exists. Nothing was changed.")
        return
    end
end

local loadedCount = nil
if remoteCount and (not existingCount or remoteCount >= existingCount) then
    local ok, err = pcall(writefile, JSON_PATH, remoteJSON)
    if ok then
        loadedCount = remoteCount
    else
        warning("Cannot write the new library: " .. tostring(err))
    end
elseif remoteCount and existingCount and remoteCount < existingCount then
    warning("The repository has " .. remoteCount .. " packs but your local library has " .. existingCount .. ". Keeping the larger local library.")
else
    warning("The remote library was unavailable, invalid, or contains fewer than " .. MIN_PACKS .. " packs.")
end

if not loadedCount then
    if existingCount then
        loadedCount = existingCount
    else
        warning("No valid local library is available. Stance was not started; your files were not overwritten.")
        return
    end
end


if validScript(remoteScript) then
    local cacheOK = pcall(writefile, CACHE_PATH, remoteScript)
    if not cacheOK then
        warning("Could not cache Lua for offline use; starting downloaded script anyway.")
    end
end



local ok, entry = pcall(loadstring, script, "Stance")
if not ok or type(entry) ~= "function" then
    warning("Could not compile the Stance Lua script.")
    return
end
entry()