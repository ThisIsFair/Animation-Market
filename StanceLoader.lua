local body = httpget("https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/StanceDev.lua")
if type(body) == "string" and #body > 100 then
    loadstring(body)()
else
    _G.StanceDevLoaderStatus = "Could not download StanceDev.lua"
end
