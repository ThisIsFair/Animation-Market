local STANCE_RELEASE = "20261030-pagination-r2"

local nativePairs = pairs
local EMPTY_TABLE = {}
local reportedMissingTables = {}
local function guardedPairs(value, context)
    if type(value) == "table" then
        return nativePairs(value)
    end
    local label = tostring(context or "unknown")
    if not reportedMissingTables[label] then
        reportedMissingTables[label] = true
        warn("[AnimationMarketplace] Missing/invalid table at " .. label ..
            " (received " .. type(value) .. "); skipping safely")
    end
    return next, EMPTY_TABLE, nil
end

local MarketCore = {}
local MAX_BYTES = 4 * 1024 * 1024
local STATES = { idle=true, walk=true, run=true, jump=true, fall=true, climb=true, swim=true, swimidle=true }
local TYPE_STATE = { [48]="climb", [50]="fall", [51]="idle", [52]="jump", [53]="run", [54]="swim", [55]="walk" }

function MarketCore.id(value)
    local n = tonumber(value)
    if n and n > 0 and n < 9007199254740992 and n == math.floor(n) then
        return string.format("%.0f", n)
    end
    return nil
end

function MarketCore.encode(value)
    return (tostring(value):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function MarketCore.state(name)
    local s = tostring(name or ""):lower():gsub("[^%a%d]", "")
    if STATES[s] then return s end
    if s == "animation1" or s == "animation2" or s == "idleanimation" then return "idle" end
    if s == "swimidle" or s == "swimidleanimation" then return "swimidle" end
    for _, v in ipairs({"walk", "run", "jump", "fall", "climb", "swim"}) do
        if s == v .. "anim" or s == v .. "animation" then return v end
    end
    return nil
end

function MarketCore.contentId(value)
    if type(value) ~= "string" then return nil end
    local id = value:match("^rbxassetid://(%d+)$") or value:match("[?&]id=(%d+)")
    return id and tonumber(MarketCore.id(id)) or nil
end

local function reader(data)
    local r = { data=data, p=1 }
    function r:take(n)
        assert(n >= 0 and self.p + n - 1 <= #self.data, "Truncated asset data")
        local s = self.data:sub(self.p, self.p+n-1)
        self.p = self.p+n
        return s
    end
    function r:byte() return string.byte(self:take(1)) end
    function r:u32()
        local a,b,c,d = string.byte(self:take(4),1,4)
        return a + b*256 + c*65536 + d*16777216
    end
    function r:str()
        local n = self:u32()
        assert(n <= MAX_BYTES, "Asset string too large")
        return self:take(n)
    end
    function r:ints(n, refs)
        assert(n <= 4096, "Too many model instances")
        local s, out, last = self:take(n*4), {}, 0
        for i=1,n do
            local v = string.byte(s,i)*16777216 + string.byte(s,i+n)*65536
                + string.byte(s,i+2*n)*256 + string.byte(s,i+3*n)
            if refs then
                v = v%2 == 0 and v/2 or -(v+1)/2
                last = last+v
                v = last
            end
            out[i] = v
        end
        return out
    end
    return r
end

function MarketCore.lz4(data, expected)
    assert(expected <= MAX_BYTES, "Asset chunk too large")
    assert(data:sub(1,4) ~= string.char(40,181,47,253), "ZSTD-compressed asset is not supported by this LuaVM decoder")
    local r, out, count = reader(data), {}, 0
    local function length(n)
        if n == 15 then
            local b = 255
            while b == 255 do b=r:byte(); n=n+b end
        end
        return n
    end
    while r.p <= #data do
        local token = r:byte()
        local literals = length(math.floor(token/16))
        assert(count+literals <= expected, "Invalid LZ4 literal size")
        local s = r:take(literals)
        for i=1,#s do count=count+1; out[count]=s:sub(i,i) end
        if r.p > #data then break end
        local lo, hi = r:byte(), r:byte()
        local offset = lo+hi*256
        assert(offset > 0 and offset <= count, "Invalid LZ4 back-reference")
        local matchLength = length(token%16)+4
        assert(count+matchLength <= expected, "Invalid LZ4 match size")
        for _=1,matchLength do count=count+1; out[count]=out[count-offset] end
    end
    assert(count == expected, "Wrong decompressed asset length")
    return table.concat(out)
end

function MarketCore.binary(data)
    local r = reader(data)
    assert(r:take(14) == "<roblox!" .. string.char(137,255,13,10,26,10), "Invalid RBXM header")
    assert(r:take(2) == string.char(0,0), "Unsupported RBXM version")
    local classCount, instanceCount = r:u32(), r:u32()
    assert(classCount <= 4096 and instanceCount <= 4096, "Asset model too large")
    r:take(8)
    local classes, nodes, total, ended = {}, {}, 0, false
    while r.p <= #data do
        local kind, compressed, expanded = r:take(4), r:u32(), r:u32()
        r:take(4)
        total = total+expanded
        assert(total <= MAX_BYTES*2 and expanded <= MAX_BYTES, "Expanded model too large")
        local payload = r:take(compressed > 0 and compressed or expanded)

        if kind == "INST" or kind == "PROP" or kind == "PRNT" then
            if compressed > 0 then payload=MarketCore.lz4(payload,expanded) end
            local c = reader(payload)
            if kind == "INST" then
                local index, className = c:u32(), c:str()
                c:byte()
                local n = c:u32()
                local refs = c:ints(n,true)
                classes[index] = { refs=refs, count=n }
                for _,ref in ipairs(refs) do nodes[ref]={class=className, name="", parent=-1} end
            elseif kind == "PROP" then
                local index, name, typeId = c:u32(), c:str(), c:byte()
                local class = classes[index]
                assert(class, "Unknown property class")
                if name == "Name" or name == "AnimationId" then
                    assert(typeId == 1, "Unsupported animation string encoding")
                    for _,ref in ipairs(class.refs) do
                        nodes[ref][name == "Name" and "name" or "animationId"] = c:str()
                    end
                elseif name == "AnimationContent" and typeId == 34 then
                    local types, uris = c:ints(class.count,false), {}
                    local uriCount = c:u32()
                    assert(uriCount <= class.count, "Invalid URI count")
                    for i=1,uriCount do uris[i]=c:str() end
                    local cursor = 1
                    for i,ref in ipairs(class.refs) do
                        if types[i] == 1 then
                            nodes[ref].animationId=uris[cursor]; cursor=cursor+1
                        end
                    end
                end
            else
                assert(c:byte() == 0, "Unsupported parent format")
                local n = c:u32()
                local children, parents = c:ints(n,true), c:ints(n,true)
                for i,ref in ipairs(children) do
                    if nodes[ref] then nodes[ref].parent=parents[i] end
                end
            end
        elseif kind:sub(1,3) == "END" then ended=true; break end
    end
    assert(ended, "Missing RBXM end chunk")
    return nodes
end

local function unxml(s)
    return (s:gsub("<!%[CDATA%[(.-)%]%]>", "%1"):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&apos;", "'"))
end

function MarketCore.xml(data)
    local nodes, stack, nextId, p = {}, {}, 0, 1
    while true do
        local a,b,closing,attrs = data:find("<(/?)Item([^>]*)>",p)
        if not a then break end
        if closing == "/" then
            assert(#stack > 0, "Invalid XML item nesting")
            stack[#stack]=nil
        else
            nextId=nextId+1
            assert(nextId <= 4096, "XML model too large")
            local head = data:sub(b+1)
            local props = head:match("^%s*<Properties>(.-)</Properties>") or ""
            local name = props:match([=[<string[^>]-name%s*=%s*["']Name["'][^>]*>(.-)</string>]=]) or ""
            local content = props:match([=[<Content[^>]-name%s*=%s*["']AnimationId["'][^>]*>(.-)</Content>]=]) or ""
            local url = content:match("<url>(.-)</url>") or ""
            nodes[nextId] = { class=attrs:match([=[class%s*=%s*["']([^"']+)["']]=]) or "",
                name=unxml(name), animationId=unxml(url), parent=stack[#stack] or -1 }
            stack[#stack+1]=nextId
        end
        p=b+1
    end
    assert(#stack == 0 and nextId > 0, "Invalid XML asset")
    return nodes
end

function MarketCore.rows(data, assetType)
    assert(type(data)=="string", "Asset decoder received no model data (non-string response)")
    assert(#data>0, "Asset decoder received an empty model")
    assert(#data<=MAX_BYTES, "Asset model exceeds 4 MiB decoder limit")
    local nodes
    if data:sub(1,8) == "<roblox!" then nodes=MarketCore.binary(data)
    elseif data:find("<roblox",1,true) then nodes=MarketCore.xml(data)
    else assert(false, "Asset data unavailable (authentication, permissions, or unsupported format)") end
    local rows, seen = {}, {}
    for _,node in guardedPairs(nodes, 'asset parser nodes') do
        local id = node.class == "Animation" and MarketCore.contentId(node.animationId) or nil
        if id then
            local folder, parent, depth, excluded = MarketCore.state(node.name), node.parent, 0, false

            while nodes[parent] and depth < 32 do
                if nodes[parent].name:lower()=="pose" then excluded=true; break end
                local state = MarketCore.state(nodes[parent].name)
                if state then folder=state; break end
                parent=nodes[parent].parent; depth=depth+1
            end
            folder=folder or TYPE_STATE[tonumber(assetType)]
            if folder and not excluded then
                local key=folder .. ":" .. (node.name or "") .. ":" .. tostring(id)
                if not seen[key] then
                    seen[key]=true; rows[#rows+1]={folder,node.name ~= "" and node.name or "Animation1",id}
                end
            end
        end
    end
    table.sort(rows,function(a,b)
        if a[1] ~= b[1] then return a[1]<b[1] end
        if a[2] ~= b[2] then return a[2]<b[2] end
        return a[3]<b[3]
    end)
    assert(#rows > 0, "No playable locomotion animation IDs in this asset")
    return rows
end

local CATALOG_ANIMATION_TYPES = {
    climbanimation=48, fallanimation=50, idleanimation=51,
    jumpanimation=52, runanimation=53, swimanimation=54,
    walkanimation=55,
}
function MarketCore.catalogAnimationType(value)
    local number=tonumber(value)
    if number and TYPE_STATE[number] then return number end
    if type(value)=="string" then
        local cleaned=value:lower():gsub("[^%a]","")
        return CATALOG_ANIMATION_TYPES[cleaned]
    end
    return nil
end

local function marketEligibleCandidate(item)
    if type(item)~="table" then return false end
    local name=tostring(item.name or ""):lower()
    local creator=tostring(item.creatorName or ""):lower()
    local words=" "..name:gsub("[^%w]+"," ").." "
    if words:find(" r6 ",1,true) or words:find(" r6converter ",1,true)
        or name:find("r6converter",1,true) then return false end
    if (name.." "..creator):find("content deleted",1,true)
        or (name.." "..creator):find("content_deleted",1,true)
        or name:find("deleted item",1,true) or name:find("moderated",1,true)
        or name:find("broken",1,true) or name:find("bugged",1,true)
        or name:find("failed",1,true) then return false end
    local normalized=name:gsub("^%s+",""):gsub("%s+$","")
    if normalized=="" or normalized=="r" or normalized=="a"
        or normalized=="n/a" or normalized=="test" or normalized=="unknown"
        or normalized:match("^[%p%s]+$") then return false end
    local price=tonumber(item.price or item.priceRobux or item.lowestPrice or item.currentPrice)
    if not price or price < 300 then return false end
    local ps=tostring(item.priceStatus or item.saleStatus or ""):lower()
    if ps:find("off sale",1,true) or ps:find("offsale",1,true)
        or ps:find("unavailable",1,true) or ps:find("deleted",1,true) then return false end
    if item.isForSale==false or item.isOnSale==false then return false end
    return true
end
function MarketCore.pack(item)
    if not marketEligibleCandidate(item) then return nil end
    local id=MarketCore.id(item.id)
    local itemType, bundleType=tostring(item.itemType),tostring(item.bundleType)
    if not id or (itemType~="Bundle" and itemType~="2") then return nil end
    if bundleType~="2" and bundleType~="Animations" and bundleType~="AvatarAnimations" then return nil end
    return { id=id,key="bundle:"..id,name=tostring(item.name),
        creator=tostring(item.creatorName or "Unknown creator"),creatorId=MarketCore.id(item.creatorTargetId),
        creatorType=tostring(item.creatorType or ""),price=tonumber(item.price or item.priceRobux or item.lowestPrice or item.currentPrice),
        items=item.bundledItems or {},status="Unverified R15 candidate" }
end

function MarketCore.group(rows)
    local grouped={}
    for _,row in ipairs(rows or {}) do
        if type(row)=="table" and STATES[row[1]] and MarketCore.id(row[3]) then
            grouped[row[1]]=grouped[row[1]] or {}
            table.insert(grouped[row[1]],tonumber(row[3]))
        end
    end

    if grouped.idle and #grouped.idle == 1 then grouped.idle[2]=grouped.idle[1] end
    return grouped
end

function MarketCore.catalogUrl(cursor, apiVersion)

    local url
    if apiVersion == 2 then
        url = "https://catalog.roblox.com/v2/search/items/details?model.bundleTypeIds=2&model.sortType=3&limit=30"
        if cursor and cursor ~= "" then url=url.."&cursor="..MarketCore.encode(cursor) end
    else
        url = "https://catalog.roblox.com/v1/search/items/details?Category=12&Subcategory=38&SortType=3&Limit=30"
        if cursor and cursor ~= "" then url=url.."&Cursor="..MarketCore.encode(cursor) end
    end
    return url
end

local HttpService = game:GetService("HttpService")

local SUB_MENU_MAX_ROWS = 22       
local SUB_MENU_COL_WIDTH = 175     
local TOGGLE_KEYCODE = 115         

local PINNED_OFFSETS = {
    ["version-5a21b87bbc2641cf"]={PlatformStand=0x1D2,AnimationId=0xA8},
}
local okVersion, activeClient = pcall(function() return getrbxversion() end)
if not okVersion then activeClient = nil end
local offsets=PINNED_OFFSETS[activeClient or ""]
local offsetSource=offsets and "pinned" or nil
if not offsets and type(activeClient)=="string" and activeClient:match("^version%-%x+$") and type(httpget)=="function" then
    local fetched,body=pcall(httpget,"https://offsets.imtheo.lol/Offsets.json")
    if fetched and type(body)=="string" and #body>=100 and #body<=250000 then
        local parsed,data=pcall(function() return HttpService:JSONDecode(body) end)
        if parsed and type(data)=="table" and data["Roblox Version"]==activeClient and type(data.Offsets)=="table" then
            local misc=data.Offsets.Misc
            local humanoid=data.Offsets.Humanoid
            local anim=type(misc)=="table" and misc.AnimationId or nil
            local stand=type(humanoid)=="table" and humanoid.PlatformStand or nil
            if type(anim)=="number" and anim%8==0 and anim>=0x80 and anim<=0x400
                and type(stand)=="number" and stand%1==0 and stand>=0x100 and stand<=0x800 then
                offsets={PlatformStand=stand,AnimationId=anim}
                offsetSource="theo"
            end
        end
    end
end
local PLATFORMSTAND_OFFSET=offsets and offsets.PlatformStand or nil
local ANIMATION_ID_OFFSET=offsets and offsets.AnimationId or nil
local isUIVisible = false
local toggleDebounce = false
local CONFIG_FOLDER = "SpooferConfig"
local CONFIG_FILE = CONFIG_FOLDER .. "\\Settings.json"
if offsets then
    print(string.format("[Spoofer] %s Roblox %s | PlatformStand=0x%X | AnimId=0x%X",
        offsetSource=="theo" and "Auto-resolved" or "Pinned",tostring(activeClient),PLATFORMSTAND_OFFSET,ANIMATION_ID_OFFSET))
else
    warn("[Spoofer] Unsupported Roblox build "..tostring(activeClient)..
        "; memory writes disabled until offsets are verified for this build")
end

local function read_std_string(addr)
    if type(addr)~="number" or addr<=0 then return nil end
    local size = memory_read("uintptr_t", addr + 0x10)
    local cap = memory_read("uintptr_t", addr + 0x18)
    if type(size)~="number" or type(cap)~="number" or
        size<0 or size>512 or cap<0 or cap>4096 or size>cap then return nil end
    if size==0 then return "" end
    local ptr = (cap>=16) and memory_read("uintptr_t",addr) or addr
    if type(ptr)~="number" or ptr<=0 then return nil end
    local bytes={}
    for i=0,size-1 do
        local byte=memory_read("byte",ptr+i)
        if type(byte)~="number" then return nil end
        bytes[#bytes+1]=string.char(byte)
    end
    return table.concat(bytes)
end
local function write_std_string(addr,value)
    if type(addr)~="number" or addr<=0 or type(value)~="string" then return false end
    local oldSize=memory_read("uintptr_t",addr+0x10)
    local cap=memory_read("uintptr_t",addr+0x18)
    if type(oldSize)~="number" or type(cap)~="number" or
        oldSize<0 or oldSize>512 or cap<0 or cap>4096 or oldSize>cap or

        #value>cap then return false end
    local ptr=(cap>=16) and memory_read("uintptr_t",addr) or addr
    if type(ptr)~="number" or ptr<=0 then return false end
    for i=1,#value do memory_write("byte",ptr+i-1,string.byte(value,i)) end
    memory_write("byte",ptr+#value,0)
    memory_write("uintptr_t",addr+0x10,#value)
    return read_std_string(addr)==value
end

local rawPacks = {
	["2014"] = {
		{"idle", "Animation1", 79230074465081},
		{"idle", "Animation2", 108128190588873},
		{"walk", "WalkAnim", 129176008736462},
		{"run", "RunAnim", 109490732869533},
		{"jump", "JumpAnim", 82537739274282},
		{"fall", "FallAnim", 115218010785890},
		{"climb", "ClimbAnim", 86309925713925},
		{"swimidle", "SwimIdle", 92452074550508},
		{"swim", "Swim", 125096636102405},
	},

	["Adidas Aura"] = {
		{"idle", "Animation1", 110211186840347},
		{"idle", "Animation2", 114191137265065},
		{"walk", "WalkAnim", 83842218823011},
		{"run", "RunAnim", 118320322718866},
		{"jump", "JumpAnim", 109996626521204},
		{"fall", "FallAnim", 95603166884636},
		{"climb", "ClimbAnim", 97824616490448},
		{"swimidle", "SwimIdle", 94922130551805},
		{"swim", "Swim", 134530128383903},
	},

	["Adidas Community"] = {
		{"idle", "Animation1", 122257458498464},
		{"idle", "Animation2", 102357151005774},
		{"walk", "WalkAnim", 122150855457006},
		{"run", "RunAnim", 82598234841035},
		{"jump", "JumpAnim", 75290611992385},
		{"fall", "FallAnim", 98600215928904},
		{"climb", "ClimbAnim", 88763136693023},
		{"swimidle", "SwimIdle", 109346520324160},
		{"swim", "Swim", 133308483266208},
	},

	["Adidas Sports"] = {
		{"idle", "Animation1", 18537376492},
		{"idle", "Animation2", 18537371272},
		{"walk", "WalkAnim", 18537392113},
		{"run", "RunAnim", 18537384940},
		{"jump", "JumpAnim", 18537380791},
		{"fall", "FallAnim", 18537367238},
		{"climb", "ClimbAnim", 18537363391},
		{"swimidle", "SwimIdle", 18537387180},
		{"swim", "Swim", 18537389531},
	},

	["Amazon Unboxed"] = {
		{"idle", "Animation1", 98281136301627},
		{"idle", "Animation2", 138183121662404},
		{"walk", "WalkAnim", 90478085024465},
		{"run", "RunAnim", 134824450619865},
		{"jump", "JumpAnim", 121454505477205},
		{"fall", "FallAnim", 94788218468396},
		{"climb", "ClimbAnim", 121145883950231},
		{"swimidle", "SwimIdle", 129126268464847},
		{"swim", "Swim", 105962919001086},
	},

	["Billie Eilish"] = {
		{"idle", "Animation1", 102934602884410},
		{"idle", "Animation2", 92151291669373},
		{"walk", "WalkAnim", 81877886552514},
		{"run", "RunAnim", 100920560634123},
		{"jump", "JumpAnim", 117602630922781},
		{"fall", "FallAnim", 81072141180299},
		{"climb", "ClimbAnim", 117873469361430},
		{"swimidle", "SwimIdle", 78535650384589},
		{"swim", "Swim", 121824746242877},
	},

	["Bold"] = {
		{"idle", "Animation1", 16738333868},
		{"idle", "Animation2", 16738334710},
		{"walk", "WalkAnim", 16738340646},
		{"run", "RunAnim", 16738337225},
		{"jump", "JumpAnim", 16738336650},
		{"fall", "FallAnim", 16738333171},
		{"climb", "ClimbAnim", 16738332169},
		{"swimidle", "SwimIdle", 16738339817},
		{"swim", "Swim", 16738339158},
	},

	["Borock"] = {
		{"idle", "Animation1", 3293641938},
		{"idle", "Animation2", 3293642554},
	},

	["Bubbly"] = {
		{"idle", "Animation1", 10921054344},
		{"idle", "Animation2", 10921055107},
		{"walk", "WalkAnim", 10980888364},
		{"run", "RunAnim", 10921057244},
		{"jump", "JumpAnim", 10921062673},
		{"fall", "FallAnim", 10921061530},
		{"climb", "ClimbAnim", 10921053544},
		{"swimidle", "SwimIdle", 10922582160},
		{"swim", "Swim", 10921063569},
	},

	["Cartoony"] = {
		{"idle", "Animation1", 10921071918},
		{"idle", "Animation2", 10921072875},
		{"walk", "WalkAnim", 10921082452},
		{"run", "RunAnim", 10921076136},
		{"jump", "JumpAnim", 10921078135},
		{"fall", "FallAnim", 10921077030},
		{"climb", "ClimbAnim", 10921070953},
		{"swimidle", "SwimIdle", 10921081059},
		{"swim", "Swim", 10921079380},
	},

	["Catwalk Glam"] = {
		{"idle", "Animation1", 133806214992291},
		{"idle", "Animation2", 94970088341563},
		{"walk", "WalkAnim", 109168724482748},
		{"run", "RunAnim", 81024476153754},
		{"jump", "JumpAnim", 116936326516985},
		{"fall", "FallAnim", 92294537340807},
		{"climb", "ClimbAnim", 119377220967554},
		{"swimidle", "SwimIdle", 98854111361360},
		{"swim", "Swim", 134591743181628},
	},

	["Cowboy"] = {
		{"idle", "Animation1", 1014390418},
		{"idle", "Animation2", 1014398616},
		{"walk", "WalkAnim", 1014421541},
		{"run", "RunAnim", 1014401683},
		{"jump", "JumpAnim", 1014394726},
		{"fall", "FallAnim", 1014384571},
		{"climb", "ClimbAnim", 1014380606},
		{"swimidle", "SwimIdle", 1014411816},
		{"swim", "Swim", 1014406523},
	},

	["Default"] = {
		{"idle", "Animation1", 507766388},
		{"idle", "Animation2", 507766666},
		{"walk", "WalkAnim", 913402848},
		{"run", "RunAnim", 913376220},
		{"jump", "JumpAnim", 507765000},
		{"fall", "FallAnim", 507767968},
		{"climb", "ClimbAnim", 507765644},
		{"swimidle", "SwimIdle", 913389285},
		{"swim", "Swim", 913384386},
	},

	["Default Retarget"] = {
		{"idle", "Animation1", 101210804817434},
		{"idle", "Animation2", 95884606664820},
		{"walk", "WalkAnim", 115825677624788},
		{"run", "RunAnim", 102294264237491},
		{"jump", "JumpAnim", 117150377950987},
		{"fall", "FallAnim", 110205622518029},
		{"climb", "ClimbAnim", 110967007211137},
		{"swimidle", "SwimIdle", 70573966249880},
		{"swim", "Swim", 135296543654863},
	},

	["Elder"] = {
		{"idle", "Animation1", 10921101664},
		{"idle", "Animation2", 10921102574},
		{"walk", "WalkAnim", 10921111375},
		{"run", "RunAnim", 10921104374},
		{"jump", "JumpAnim", 10921107367},
		{"fall", "FallAnim", 10921105765},
		{"climb", "ClimbAnim", 10921100400},
		{"swimidle", "SwimIdle", 10921110146},
		{"swim", "Swim", 10921108971},
	},

	["Fallback"] = {
		{"idle", "Animation1", 507766388},
		{"idle", "Animation2", 507766951},
		{"walk", "WalkAnim", 507777826},
		{"run", "RunAnim", 507767714},
		{"jump", "JumpAnim", 507765000},
		{"fall", "FallAnim", 507767968},
		{"climb", "ClimbAnim", 10921100400},
		{"swimidle", "SwimIdle", 507785072},
		{"swim", "Swim", 507784897},
	},

	["Glow Motion"] = {
		{"idle", "Animation1", 137764781910579},
		{"idle", "Animation2", 96439737641086},
		{"walk", "WalkAnim", 85809016093530},
		{"run", "RunAnim", 101925097435036},
		{"jump", "JumpAnim", 74159004634379},
		{"fall", "FallAnim", 98070939608691},
		{"climb", "ClimbAnim", 108236155509584},
		{"swimidle", "SwimIdle", 112946194103503},
		{"swim", "Swim", 83003487432457},
	},

	["KATSEYE"] = {
		{"idle", "Animation1", 108187809145790},
		{"idle", "Animation2", 72329200359275},
		{"walk", "WalkAnim", 99182913548783},
		{"run", "RunAnim", 73117360545482},
		{"jump", "JumpAnim", 103632305262747},
		{"fall", "FallAnim", 127802717128367},
		{"climb", "ClimbAnim", 106213237973858},
		{"swimidle", "SwimIdle", 138619485942849},
		{"swim", "Swim", 134148268480210},
	},

	["Knight"] = {
		{"idle", "Animation1", 10921117521},
		{"idle", "Animation2", 10921118894},
		{"walk", "WalkAnim", 10921121197},
		{"run", "RunAnim", 10921121197},
		{"jump", "JumpAnim", 10921123517},
		{"fall", "FallAnim", 10921116196},
		{"climb", "ClimbAnim", 106213237973858},
		{"swimidle", "SwimIdle", 10921125935},
		{"swim", "Swim", 10921125160},
	},

	["Levitation"] = {
		{"idle", "Animation1", 10921132962},
		{"idle", "Animation2", 10921133721},
		{"walk", "WalkAnim", 10921140719},
		{"run", "RunAnim", 10921135644},
		{"jump", "JumpAnim", 10921137402},
		{"fall", "FallAnim", 10921136539},
		{"climb", "ClimbAnim", 10921132092},
		{"swimidle", "SwimIdle", 10921139478},
		{"swim", "Swim", 10921138209},
	},

	["Mr. Toilet"] = {
		{"idle", "Animation1", 4417977954},
		{"idle", "Animation2", 4417978624},
		{"run", "RunAnim", 4417979645},
	},

	["NFL"] = {
		{"idle", "Animation1", 92080889861410},
		{"idle", "Animation2", 74451233229259},
		{"walk", "WalkAnim", 110358958299415},
		{"run", "RunAnim", 117333533048078},
		{"jump", "JumpAnim", 119846112151352},
		{"fall", "FallAnim", 129773241321032},
		{"climb", "ClimbAnim", 134630013742019},
		{"swimidle", "SwimIdle", 79090109939093},
		{"swim", "Swim", 132697394189921},
	},

	["Ninja"] = {
		{"idle", "Animation1", 10921155160},
		{"idle", "Animation2", 10921155867},
		{"walk", "WalkAnim", 10921162768},
		{"run", "RunAnim", 10921157929},
		{"jump", "JumpAnim", 10921160088},
		{"fall", "FallAnim", 10921159222},
		{"climb", "ClimbAnim", 10921154678},
		{"swimidle", "SwimIdle", 10922757002},
		{"swim", "Swim", 10921161002},
	},

	["No Boundaries"] = {
		{"idle", "Animation1", 18747067405},
		{"idle", "Animation2", 18747063918},
		{"walk", "WalkAnim", 18747074203},
		{"run", "RunAnim", 18747070484},
		{"jump", "JumpAnim", 18747069148},
		{"fall", "FallAnim", 18747062535},
		{"climb", "ClimbAnim", 18747060903},
		{"swimidle", "SwimIdle", 18747071682},
		{"swim", "Swim", 18747073181},
	},

	["Oldschool"] = {
		{"idle", "Animation1", 10921230744},
		{"idle", "Animation2", 10921232093},
		{"walk", "WalkAnim", 10921244891},
		{"run", "RunAnim", 10921240218},
		{"jump", "JumpAnim", 10921242013},
		{"fall", "FallAnim", 10921241244},
		{"climb", "ClimbAnim", 10921229866},
		{"swimidle", "SwimIdle", 10921244018},
		{"swim", "Swim", 10921243048},
	},

	["Patrol"] = {
		{"idle", "Animation1", 1149612882},
		{"idle", "Animation2", 1150842221},
		{"walk", "WalkAnim", 1151231493},
		{"run", "RunAnim", 1150967949},
		{"jump", "JumpAnim", 1150944216},
		{"fall", "FallAnim", 1148863382},
		{"climb", "ClimbAnim", 1148811837},
		{"swimidle", "SwimIdle", 1151221899},
		{"swim", "Swim", 1151204998},
	},

	["Pirate"] = {
		{"idle", "Animation1", 750781874},
		{"idle", "Animation2", 750782770},
		{"walk", "WalkAnim", 750785693},
		{"run", "RunAnim", 750783738},
		{"jump", "JumpAnim", 750782230},
		{"fall", "FallAnim", 750780242},
		{"climb", "ClimbAnim", 750779899},
		{"swimidle", "SwimIdle", 750785176},
		{"swim", "Swim", 750784579},
	},

	["Popstar"] = {
		{"idle", "Animation1", 1212900985},
		{"idle", "Animation2", 1212954651},
		{"walk", "WalkAnim", 1212980338},
		{"run", "RunAnim", 1212980348},
		{"jump", "JumpAnim", 1212954642},
		{"fall", "FallAnim", 1212900995},
		{"climb", "ClimbAnim", 1213044953},
		{"swimidle", "SwimIdle", 1212998578},
		{"swim", "Swim", 1212852603},
	},

	["Princess"] = {
		{"idle", "Animation1", 941003647},
		{"idle", "Animation2", 941013098},
		{"walk", "WalkAnim", 941028902},
		{"run", "RunAnim", 941015281},
		{"jump", "JumpAnim", 941008832},
		{"fall", "FallAnim", 941000007},
		{"climb", "ClimbAnim", 940996062},
		{"swimidle", "SwimIdle", 941025398},
		{"swim", "Swim", 941018893},
	},

	["R6"] = {
		{"idle", "Animation2", 110291203484752},
		{"idle", "Animation1", 131260802088656},
		{"walk", "WalkAnim", 81275475859584},
		{"run", "RunAnim", 86501760984532},
		{"jump", "JumpAnim", 109853826438411},
		{"fall", "FallAnim", 110640511139183},
		{"climb", "ClimbAnim", 81319122881778},
		{"swimidle", "SwimIdle", 114255213893452},
		{"swim", "Swim", 75467827271831},
	},

	["Realistic"] = {
		{"idle", "Animation2", 17173014241},
		{"idle", "Animation1", 17172918855},
		{"walk", "WalkAnim", 11600249883},
		{"run", "RunAnim", 11600211410},
		{"jump", "JumpAnim", 11600210487},
		{"fall", "FallAnim", 11600206437},
		{"climb", "ClimbAnim", 11600205519},
		{"swimidle", "SwimIdle", 11600213505},
		{"swim", "Swim", 11600212676},
	},

	["Robot"] = {
		{"idle", "Animation1", 10921248039},
		{"idle", "Animation2", 10921248831},
		{"walk", "WalkAnim", 10921255446},
		{"run", "RunAnim", 10921250460},
		{"jump", "JumpAnim", 10921252123},
		{"fall", "FallAnim", 10921251156},
		{"climb", "ClimbAnim", 10921247141},
		{"swimidle", "SwimIdle", 10921253767},
		{"swim", "Swim", 10921253142},
	},

	["Rthro"] = {
		{"idle", "Animation2", 10921258489},
		{"idle", "Animation1", 10921259953},
		{"walk", "WalkAnim", 10921269718},
		{"run", "RunAnim", 10921261968},
		{"jump", "JumpAnim", 10921263860},
		{"fall", "FallAnim", 10921262864},
		{"climb", "ClimbAnim", 10921257536},
		{"swimidle", "SwimIdle", 10921265698},
		{"swim", "Swim", 10921264784},
	},

	["Rthro Heavy"] = {
		{"run", "RunAnim", 3236836670},
	},

	["Sneaky"] = {
		{"idle", "Animation2", 1132473842},
		{"idle", "Animation1", 1132477671},
		{"walk", "WalkAnim", 1132510133},
		{"run", "RunAnim", 1132494274},
		{"jump", "JumpAnim", 1132489853},
		{"fall", "FallAnim", 1132469004},
		{"climb", "ClimbAnim", 1132461372},
		{"swimidle", "SwimIdle", 11132506407},
		{"swim", "Swim", 1132500520},
	},

	["Superhero"] = {
		{"idle", "Animation1", 10921288909},
		{"idle", "Animation2", 10921290167},
		{"walk", "RunAnim", 10921298616},
		{"run", "RunAnim", 10921291831},
		{"jump", "JumpAnim", 10921294559},
		{"fall", "FallAnim", 10921293373},
		{"climb", "ClimbAnim", 10921286911},
		{"swimidle", "SwimIdle", 10921297391},
		{"swim", "Swim", 10921295495},
	},

	["Steven"] = {
		{"idle", "Animation1", 105514975554898},
		{"idle", "Animation2", 80873549026270},
		{"walk", "WalkAnim", 73935678087300},
		{"run", "RunAnim", 86028285109536},
		{"jump", "JumpAnim", 128193557442109},
		{"fall", "FallAnim", 105844133916862},
		{"climb", "ClimbAnim", 119233460706851},
		{"swimidle", "SwimIdle", 85254089135641},
		{"swim", "Swim", 105514975554898},
	},

	["Stylish"] = {
		{"idle", "Animation1", 10921272275},
		{"idle", "Animation2", 10921273958},
		{"walk", "WalkAnim", 10921283326},
		{"run", "RunAnim", 10921276116},
		{"jump", "JumpAnim", 10921279832},
		{"fall", "FallAnim", 10921278648},
		{"climb", "ClimbAnim", 10921271391},
		{"swimidle", "SwimIdle", 10921281964},
		{"swim", "Swim", 10921281000},
	},

	["Stylized Female"] = {
		{"idle", "Animation1", 4708191566},
		{"idle", "Animation2", 4708192150},
		{"walk", "WalkAnim", 4708193840},
		{"run", "RunAnim", 4708192705},
		{"jump", "JumpAnim", 4708188025},
		{"fall", "FallAnim", 4708186162},
		{"climb", "ClimbAnim", 4708184253},
		{"swimidle", "SwimIdle", 4708190607},
		{"swim", "Swim", 4708189360},
	},

	["Toy"] = {
		{"idle", "Animation1", 10921301576},
		{"idle", "Animation2", 10921302207},
		{"walk", "WalkAnim", 10921312010},
		{"run", "RunAnim", 10921306285},
		{"jump", "JumpAnim", 10921308158},
		{"fall", "FallAnim", 10921307241},
		{"climb", "ClimbAnim", 10921300839},
		{"swimidle", "SwimIdle", 10921310341},
		{"swim", "Swim", 10921309319},
	},

	["Ud-zal"] = {
		{"idle", "Animation1", 3303162274},
		{"idle", "Animation2", 3303162549},
	},

	["Vampire"] = {
		{"idle", "Animation1", 10921315373},
		{"idle", "Animation2", 10921316709},
		{"walk", "WalkAnim", 10921326949},
		{"run", "RunAnim", 10921320299},
		{"jump", "JumpAnim", 10921322186},
		{"fall", "FallAnim", 10921321317},
		{"climb", "ClimbAnim", 10921314188},
		{"swimidle", "SwimIdle", 10921325443},
		{"swim", "Swim", 10921324408},
	},

	["Werewolf"] = {
		{"idle", "Animation1", 10921330408},
		{"idle", "Animation2", 10921333667},
		{"walk", "WalkAnim", 10921342074},
		{"run", "RunAnim", 10921336997},
		{"jump", "JumpAnim", 1083218792},
		{"fall", "FallAnim", 10921337907},
		{"climb", "ClimbAnim", 10921329322},
		{"swimidle", "SwimIdle", 10921341319},
		{"swim", "Swim", 10921340419},
	},

	["Wicked DTS"] = {
		{"idle", "Animation1", 92849173543269},
		{"idle", "Animation2", 132238900951109},
		{"walk", "WalkAnim", 73718308412641},
		{"run", "RunAnim", 135515454877967},
		{"jump", "JumpAnim", 78508480717326},
		{"fall", "FallAnim", 78147885297412},
		{"climb", "ClimbAnim", 129447497744818},
		{"swimidle", "SwimIdle", 129183123083281},
		{"swim", "Swim", 110657013921774},
	},

	["Wicked Popular"] = {
		{"idle", "Animation1", 118832222982049},
		{"idle", "Animation2", 76049494037641},
		{"walk", "WalkAnim", 92072849924640},
		{"run", "RunAnim", 72301599441680},
		{"jump", "JumpAnim", 104325245285198},
		{"fall", "FallAnim", 121152442762481},
		{"climb", "ClimbAnim", 131326830509784},
		{"swimidle", "SwimIdle", 113199415118199},
		{"swim", "Swim", 99384245425157},
	},

	["Zombie"] = {
		{"idle", "Animation1", 10921344533},
		{"idle", "Animation2", 10921345304},
		{"walk", "WalkAnim", 10921355261},
		{"run", "RunAnim", 616163682},
		{"jump", "JumpAnim", 10921351278},
		{"fall", "FallAnim", 10921350320},
		{"climb", "ClimbAnim", 10921343576},
		{"swimidle", "SwimIdle", 10921353442},
		{"swim", "Swim", 10921352344},
	},
}

local MARKET_RESOLVED_FILE = CONFIG_FOLDER .. "/MarketplaceResolved.json"
local savedMarketPacks = {}
do
    local ok, data = pcall(function()
        if isfile(MARKET_RESOLVED_FILE) then
            return HttpService:JSONDecode(readfile(MARKET_RESOLVED_FILE))
        end
    end)
    if ok and type(data)=="table" and data.version==1 and type(data.packs)=="table" then
        for id,record in guardedPairs(data.packs, 'saved pack cache records') do
            if MarketCore.id(id) and type(record)=="table" and type(record.menuName)=="string"
                and type(record.rows)=="table" and next(MarketCore.group(record.rows)) then

                savedMarketPacks[tostring(id)]=record
            end
        end
    end
end

do
    local ok, previous=pcall(function()
        if isfile(CONFIG_FILE) then return HttpService:JSONDecode(readfile(CONFIG_FILE)) end
    end)
    if ok and type(previous)=="table" then
        local wanted={}
        for _,name in guardedPairs(previous,"previous category selections") do
            if type(name)=="string" then wanted[name]=true end
        end
        for _,record in guardedPairs(savedMarketPacks,"saved menu selections") do
            if wanted[record.menuName] and type(record.rows)=="table" then
                rawPacks[record.menuName]=record.rows
            end
        end
    end
end

local categoryConfig = {
    { name = "Idle",  folders = {"idle"} },
    { name = "Walk",  folders = {"walk"} },
    { name = "Run",   folders = {"run"} },
    { name = "Jump",  folders = {"jump"} },
    { name = "Fall",  folders = {"fall"} },
    { name = "Climb", folders = {"climb"} },
    { name = "Swim",  folders = {"swim", "swimidle"} },
}

local categoryOptions = {}
for _, cat in ipairs(categoryConfig) do 
    categoryOptions[cat.name] = {} 
end

for packName, animList in guardedPairs(rawPacks, 'initial category construction') do
    local catDataMap = {} 

    for _, animData in ipairs(animList) do
        local folder = animData[1]
        local id = animData[3]

        local catName = nil
        if folder == "idle" then catName = "Idle"
        elseif folder == "walk" then catName = "Walk"
        elseif folder == "run" then catName = "Run"
        elseif folder == "jump" then catName = "Jump"
        elseif folder == "fall" then catName = "Fall"
        elseif folder == "climb" then catName = "Climb"
        elseif folder == "swim" or folder == "swimidle" then catName = "Swim"
        end

        if catName then
            if not catDataMap[catName] then catDataMap[catName] = {} end
            if not catDataMap[catName][folder] then catDataMap[catName][folder] = {} end
            table.insert(catDataMap[catName][folder], id)
        end
    end

    for catName, foldersMap in guardedPairs(catDataMap, 'category folders') do
        table.insert(categoryOptions[catName], { name = packName, foldersData = foldersMap })
    end
end

for _, cat in ipairs(categoryConfig) do
    table.sort(categoryOptions[cat.name], function(a, b) 
        return a.name:lower() < b.name:lower() 
    end)
end

local activeSpoofs={}
local activeWriteStamp={}
local retryAfter={}
local appliedCharacterAddress=nil
local reportedAnimationIssue={}
local playbackStats={wrote=0,failed=0,pulses=0,last="No animation selection submitted",recentResults={}}
local applyBusy=false

local function logAnimationIssue(key,message)
    if not reportedAnimationIssue[key] then
        reportedAnimationIssue[key]=true
        warn("[Spoofer/PLAYBACK] "..message)
    end
end
local function animationIdFromText(value)
    if type(value)~="string" then return nil end
    return value:match("[?&]id=(%d+)") or value:match("rbxassetid://(%d+)")
end
local function findAnimationChildren(folder)
    local result={}
    for _,child in ipairs(folder:GetChildren()) do
        if child:IsA("Animation") then result[#result+1]=child end
    end

    table.sort(result,function(a,b) return tostring(a.Name)<tostring(b.Name) end)
    return result
end
local function probeNativeId(anim)
    local ok,uri=pcall(function() return anim.AnimationId end)
    if ok then return animationIdFromText(uri) end
    return nil
end
local function tryNativeWrite(anim,id)
    local uri="rbxassetid://"..tostring(id)
    local ok=pcall(function() anim.AnimationId=uri end)
    return ok and probeNativeId(anim)==tostring(id)
end
local function memoryStringAddress(anim)
    if not ANIMATION_ID_OFFSET or type(anim.Address)~="number" or anim.Address<65536 then return nil end
    return anim.Address+ANIMATION_ID_OFFSET
end
local function validateAnimationMemory(anim)
    local addr=memoryStringAddress(anim)
    if not addr then return nil,"No verified AnimationId offset or Animation.Address" end
    local ok,existing=pcall(read_std_string,addr)
    if not ok or not animationIdFromText(existing) then
        return nil,"Animation memory did not contain a recognizable asset URI"
    end
    return addr,existing
end
local function tryReferenceMemoryWrite(anim,id)
    local addr,existing=validateAnimationMemory(anim)
    if not addr then return false,existing end
    local target="http://www.roblox.com/asset/?id="..tostring(id)

    if existing==target then return true,"already" end
    local ok,capacity=pcall(function() return memory_read("uintptr_t",addr+0x18) end)
    if not ok or type(capacity)~="number" or capacity<0 or capacity>4096 then
        return false,"Invalid C++ string capacity" end
    if #target>capacity then

        if tryNativeWrite(anim,id) then return true,"native" end
        return false,"New AnimationId exceeds allocated capacity; unsafe buffer takeover disabled"
    end
    local wrote,succeeded=pcall(write_std_string,addr,target)
    if not wrote or not succeeded then

        local recovered,current=pcall(read_std_string,addr)
        if not recovered or current~=existing then
            local restored,result=pcall(write_std_string,addr,existing)
            if not restored or not result then
                logAnimationIssue("rollback_"..tostring(addr),
                    "CRITICAL: original AnimationId could not be restored; rejoin Roblox")
            end
        end
        return false,"String write/readback failed (rollback attempted)"
    end
    return true,"memory"
end
local function capability()
    if not offsets then return false,"Roblox client "..tostring(activeClient).." is not pinned; writes disabled" end
    if type(memory_read)~="function" or type(memory_write)~="function" then
        return false,"Matcha unsafe-memory APIs are not enabled" end
    local ok,reason=pcall(function()
        local player=game:GetService("Players").LocalPlayer
        local c=player and player.Character
        local hum=c and c:FindFirstChild("Humanoid")
        local animate=c and c:FindFirstChild("Animate")
        if not hum or not animate then return "Character Humanoid/Animate missing" end
        if type(hum.Address)~="number" then return "Humanoid.Address missing" end
        for _,name in ipairs({"run","walk","idle"}) do
            local folder=animate:FindFirstChild(name)
            if folder then
                local anims=findAnimationChildren(folder)
                for _,anim in ipairs(anims) do
                    local addr,old=validateAnimationMemory(anim)
                    if addr then
                        local value=memory_read("byte",hum.Address+PLATFORMSTAND_OFFSET)
                        if value~=0 and value~=1 then return "PlatformStand memory is not boolean (0/1)" end
                        if offsetSource=="theo" then
                            local nativeId=probeNativeId(anim)
                            if not nativeId or nativeId~=animationIdFromText(old) then
                                return "Auto-resolved AnimationId offset did not match Roblox's read-only AnimationId property"
                            end
                            local okStand,nativeStand=pcall(function() return hum.PlatformStand end)
                            if not okStand or type(nativeStand)~="boolean" or value~=(nativeStand and 1 or 0) then
                                return "Auto-resolved PlatformStand offset failed read-only validation"
                            end
                        end
                        return nil
                    end
                end
            end
        end
        return "No valid AnimationId string found in Animate memory"
    end)
    if not ok then return false,"Capability read failed: "..tostring(reason) end
    if reason then return false,reason end
    return true,(offsetSource=="theo" and "Auto-resolved offsets validated" or "Version-pinned memory engine available").." (VISUAL playback unverified)"
end
local stanceOriginals = {}
local stanceEngineAlive = true
local function applyActiveAnimations()
    if applyBusy or not next(activeSpoofs) then return end
    local can,why=capability()
    if not can then logAnimationIssue("capability",tostring(why));return end
    applyBusy=true

    local player=game:GetService("Players").LocalPlayer
    local character=player and player.Character
    local hum=character and character:FindFirstChild("Humanoid")
    local animate=character and character:FindFirstChild("Animate")
    if not hum or not animate then applyBusy=false;return end
    if character.Address~=appliedCharacterAddress then
        appliedCharacterAddress=character.Address
        activeWriteStamp={};retryAfter={};stanceOriginals={}
    end
    local pending={}
    local now=tick()
    for folderName,ids in guardedPairs(activeSpoofs,"active selected animations") do
        local folder=animate:FindFirstChild(folderName)
        if folder and type(ids)=="table" then
            local anims=findAnimationChildren(folder)
            for i,id in ipairs(ids) do
                local anim=anims[i]
                if anim then
                    local idText=MarketCore.id(id)
                    if idText then
                        local addr,existing=validateAnimationMemory(anim)
                        if addr then
                            local animKey=tostring(anim.Address)
                            if stanceOriginals[animKey]==nil then
                                stanceOriginals[animKey]={anim=anim,uri=existing,character=character.Address,state=folderName}
                            end
                            local expected="http://www.roblox.com/asset/?id="..idText
                            local key=folderName..":"..tostring(anim.Address)..":"..idText

                            if existing~=expected and not activeWriteStamp[key] and not retryAfter[key] then
                                pending[#pending+1]={anim=anim,id=idText,key=key,state=folderName}
                            end
                        else
                            logAnimationIssue("invalid_"..folderName,"Cannot safely access "..folderName.." animation: "..tostring(existing))
                        end
                    end
                end
            end
        end
    end
    if #pending==0 then applyBusy=false;return end
    local originalPS=nil
    local pulseStarted=false
    local ok,errorMessage=pcall(function()
        originalPS=memory_read("byte",hum.Address+PLATFORMSTAND_OFFSET)
        if originalPS~=0 and originalPS~=1 then
            assert(false,"PlatformStand value invalid; refusing pulse")
        end

        if originalPS==0 then
            memory_write("byte",hum.Address+PLATFORMSTAND_OFFSET,1)
            pulseStarted=true
            task.wait(0.16)
        end
        for _,item in ipairs(pending) do
            local worked,mode=tryReferenceMemoryWrite(item.anim,item.id)
            local resultLine
            if worked then
                playbackStats.wrote=playbackStats.wrote+1
                activeWriteStamp[item.key]=true
                resultLine=tostring(item.state).." "..item.id.." = "..tostring(mode).." (memory only)"
                playbackStats.last="Applied "..item.id.." via "..tostring(mode).."; visual motion unverified"
            else
                playbackStats.failed=playbackStats.failed+1
                retryAfter[item.key]=true   
                resultLine=tostring(item.state).." "..item.id.." FAILED: "..tostring(mode)
                logAnimationIssue(item.key,resultLine)
                playbackStats.last="Skipped "..item.id..": "..tostring(mode)
            end
            playbackStats.recentResults[#playbackStats.recentResults+1]=resultLine
            if #playbackStats.recentResults>15 then table.remove(playbackStats.recentResults,1) end
        end
        if pulseStarted then task.wait(0.08) end
    end)

    if pulseStarted and originalPS~=nil then
        local restored,err=pcall(function()
            memory_write("byte",hum.Address+PLATFORMSTAND_OFFSET,originalPS)
            assert(memory_read("byte",hum.Address+PLATFORMSTAND_OFFSET)==originalPS,
                "PlatformStand restoration did not verify")
        end)
        if not restored then
            logAnimationIssue("restore","URGENT: failed to verify PlatformStand restored: "..tostring(err))
        else
            playbackStats.pulses=playbackStats.pulses+1
        end
    end
    if not ok then
        playbackStats.failed=playbackStats.failed+1
        logAnimationIssue("apply","Animation application failed: "..tostring(errorMessage))
    end
    applyBusy=false
end

task.spawn(function()
    while stanceEngineAlive do
        task.wait(0.5)
        local ok,message=pcall(applyActiveAnimations)
        if not ok then logAnimationIssue("loop",tostring(message)) end
    end
end)

local market, marketQueue
local ugcIdsOnly=true
local function ugcShort(value,n) return tostring(value or ""):sub(1,n or 100) end
local function updateContentLayout() end  
local function saveConfig() end  
local dropdowns={}  

local MARKET_TAB = "Animation Marketplace"
local MARKET_CACHE = CONFIG_FOLDER .. "/MarketplaceCatalog.json"
local MARKET_SETTINGS = CONFIG_FOLDER .. "/MarketplaceSettings.json"
local MARKET_PLAYBACK_QA = CONFIG_FOLDER .. "/MarketplacePlaybackQA.json"
local MARKET_KEY = CONFIG_FOLDER .. "/AssetDeliveryKey.txt"
market = { packs={}, ordered={}, filtered={}, selected=nil, queue={}, page=1,
    filter=0, search="", dirty=true, status="Browse saved ID mappings; in-game playback not verified", nextPage=0,
    cursor=nil, cursors={}, scanning=false, scanRemaining=0, scanRank=0, failures=0,
    favorites={}, refreshAt=math.huge, saveAt=0, apiVersion=1,
    enabled=true, lastError="", qa={}, lastApplied=nil }

local function marketRead(path)
    local ok,value=pcall(function()
        if isfile(path) then return HttpService:JSONDecode(readfile(path)) end
    end)
    return ok and type(value)=="table" and value or nil
end

local function marketWrite(path,value)
    local ok=pcall(function() writefile(path,HttpService:JSONEncode(value)) end)
    if not ok then market.lastError="Could not save "..path end
end

local function marketGet(url,headers)

    assert(type(httpget)=="function","Matcha global httpget() is unavailable")
    local body=httpget(url,headers)
    assert(type(body)=="string" and #body>0,"Empty HTTP response for "..url:match("^https?://([^/]+)"))
    return body
end

local function marketJSON(url,headers)
    local raw=marketGet(url,headers)
    assert(type(raw)=="string" and #raw>0,"Empty HTTP response; check your connection")
    local ok,value=pcall(function() return HttpService:JSONDecode(raw) end)
    assert(ok and type(value)=="table","Expected a JSON API response")
    if value.errors then

        local message=value.errors[1] and value.errors[1].message or "Request rejected"
        assert(false,"Roblox API: "..tostring(message):sub(1,180))
    end
    return value
end

local previousQA=marketRead(MARKET_PLAYBACK_QA)
if previousQA and previousQA.version==1 and type(previousQA.packs)=="table" then
    market.qa=previousQA.packs
end
local function marketMarkQA(pack,category,result)

    if not pack or not pack.id or not category or (result~="works" and result~="fails") then return end
    local bundle=tostring(pack.id)
    market.qa[bundle]=market.qa[bundle] or {}
    market.qa[bundle][category]={result=result,source="manual",recordedAt=(os and os.time and os.time()) or 0}
    marketWrite(MARKET_PLAYBACK_QA,{version=1,packs=market.qa})
    market.status="Manual playback QA: "..pack.name.." / "..category.." = "..result
end

local function marketRemember(pack)
    if not market.packs[pack.key] then
        market.packs[pack.key]=pack
        table.insert(market.ordered,pack)
    else
        local old=market.packs[pack.key]
        for _,field in ipairs({"name","creator","creatorId","creatorType","price","items","rank"}) do
            if pack[field]~=nil then old[field]=pack[field] end
        end

        if not old.rows and pack.rows then old.rows=pack.rows end
        if not old.menuName and pack.menuName then old.menuName=pack.menuName end
        if old.rows and old.status=="Unverified R15 candidate" then
            old.status="BTR AnimationId mapping loaded (playback unverified)"
        end
    end
    market.dirty=true
end

local function marketSaveSettings()
    marketWrite(MARKET_SETTINGS,{favorites=market.favorites,filter=market.filter,search=market.search})
end

local function marketSaveCatalog()
    local items={}
    for _,pack in ipairs(market.ordered) do
        if pack.id then
            items[#items+1]={id=pack.id,itemType="Bundle",bundleType=2,name=pack.name,
                creatorName=pack.creator,creatorTargetId=pack.creatorId,creatorType=pack.creatorType,
                price=pack.price,bundledItems=pack.items}
        end
    end
    marketWrite(MARKET_CACHE,{version=1,data=items})
end

local function marketRegister(pack,rows)
    if pack.legacy then return pack.name end
    local id=tostring(pack.id)
    local previous=savedMarketPacks[id]
    local menuName=(previous and previous.menuName) or (pack.name.." ["..id.."]")
    local changed=(previous==nil) or previous.rows~=rows
    local record=previous or {}
    record.menuName=menuName;record.rows=rows;record.name=pack.name;record.creator=pack.creator
    savedMarketPacks[id]=record
    rawPacks[menuName]=rows
    pack.menuName=menuName

    if changed then marketWrite(MARKET_RESOLVED_FILE,{version=1,packs=savedMarketPacks}) end
    return menuName
end

local function marketAssetError(raw)
    if type(raw)~="string" then return nil end
    local ok, parsed = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(parsed)~="table" then return nil end
    local errors=parsed.errors or parsed.Errors
    if type(errors)=="table" and errors[1] then
        local message=tostring(errors[1].message or errors[1].Message or "Request rejected")

        local lower=message:lower()
        if lower:find("authentication required",1,true) or lower:find("unauthorized",1,true) then
            return "Authentication required (401): "..message:sub(1,125)
        end
        if lower:find("permission",1,true) or lower:find("forbidden",1,true) or lower:find("not authorized",1,true) then
            return "Asset permission denied (403): "..message:sub(1,125)
        end
        return "Roblox Asset Delivery: "..message:sub(1,150)
    end
    return nil
end

local function marketCDNLocation(json)
    local location=json.location
    if not location and type(json.locations)=="table" and json.locations[1] then
        location=json.locations[1].location
    end
    assert(type(location)=="string", "Asset Delivery returned no asset location")
    local host=location:match("^https://([^/:?#]+)")
    assert(host and (host=="rbxcdn.com" or host:sub(-11)==".rbxcdn.com"), "Asset Delivery returned an unexpected download host")

    return marketGet(location)
end

local function marketFetchAsset(id)
    local ok,key=pcall(function()
        if isfile(MARKET_KEY) then return readfile(MARKET_KEY):match("^%s*(.-)%s*$") end
    end)
    local hasKey=ok and type(key)=="string" and key~=""
    if hasKey then

        local data=marketJSON("https://apis.roblox.com/asset-delivery-api/v1/assetId/"..id,{["x-api-key"]=key})
        return marketCDNLocation(data)
    end

    local body=marketGet("https://assetdelivery.roblox.com/v1/asset/?id="..id)
    if body:sub(1,8)=="<roblox!" or body:find("<roblox",1,true) then return body end
    local issue=marketAssetError(body)

    if issue then assert(false,issue) end

    local valid, json=pcall(function() return HttpService:JSONDecode(body) end)
    if valid and type(json)=="table" and (json.location or json.locations) then
        return marketCDNLocation(json)
    end
    assert(false,"Asset Delivery did not return a Roblox model (login/access or unsupported format)")
end

local function marketFailureCategory(message)
    local lower=tostring(message or ""):lower()
    if lower:find("authentication required",1,true) or lower:find("unauthorized",1,true) then return "auth_required" end
    if lower:find("permission",1,true) or lower:find("forbidden",1,true) or lower:find("not authorized",1,true) then return "no_permission" end
    if lower:find("unsupported",1,true) or lower:find("zstd",1,true) or lower:find("invalid xml",1,true) then return "format_unsupported" end
    if lower:find("no playable locomotion",1,true) then return "no_playable_id" end
    if lower:find("exceeds 4 mib",1,true) or lower:find("too large",1,true) then return "oversized" end
    if lower:find("did not return a roblox model",1,true) or lower:find("empty http",1,true)
        or lower:find("received no model data",1,true) or lower:find("empty model",1,true) then return "not_model_data" end
    return "other"
end

local function marketResolve(pack)
    if pack.rows and next(MarketCore.group(pack.rows)) then return true end

    local id=MarketCore.id(pack.id) or tostring(pack.key or ""):match("^bundle:(%d+)$")
    local stored=id and savedMarketPacks[id]
    if stored and type(stored.rows)=="table" and next(MarketCore.group(stored.rows)) then
        pack.id=id
        pack.rows=stored.rows
        pack.menuName=stored.menuName
        pack.status="Imported AnimationId mapping (playback not verified)"
        return true
    end
    pack.status="No imported AnimationId mapping for bundle "..tostring(id or "unknown")..
        ". Run the BTR importer for this specific bundle; catalog IDs are not playable IDs."
    return false
end

local function marketApply(pack,category)
    if not marketResolve(pack) then
        market.status=pack.status
        market.lastError=pack.status
        warn("[AnimationMarketplace] "..pack.status)
        return false
    end
    local grouped=MarketCore.group(pack.rows)
    local changed=0
    local requested=nil
    if category then
        for _,cat in ipairs(categoryConfig) do
            if cat.name==category then requested=cat.folders;break end
        end
        if not requested then return false end
    end
    for _,folder in ipairs(requested or {"idle","walk","run","jump","fall","climb","swim","swimidle"}) do
        if grouped[folder] then

            activeSpoofs[folder]=grouped[folder]
            changed=changed+1
        end
    end
    if changed==0 then
        market.status="No mapped animation states for "..tostring(category or "bundle")
        return false
    end

    activeWriteStamp={}
    market.lastApplied={bundleId=tostring(pack.id or ""),category=category}
    market.selected=pack
    market.status="Queued "..changed.." mapped states: "..pack.name.." (verify playback visually)"
    return true
end

local function marketCycleIdleAlternative(pack,slot)
    if not pack or not slot or slot.state~="idle" or type(slot.ids)~="table" or #slot.ids<2 then return end
    local rec=savedMarketPacks[tostring(pack.id)]
    if not rec or type(rec.rows)~="table" then return end
    for _,row in ipairs(rec.rows) do
        if row[1]=="idle" and row[2]==slot.name then
            local index=0
            for j,id in ipairs(slot.ids) do
                if tostring(id)==tostring(row[3]) then index=j; break end
            end
            local nextId=slot.ids[(index % #slot.ids)+1]
            row[3]=tostring(nextId)
            slot.selected=tostring(nextId)
            pack.rows=rec.rows
            marketWrite(MARKET_RESOLVED_FILE,{version=1,packs=savedMarketPacks})
            marketApply(pack,"Idle")
            market.status="Switched Idle "..slot.name.." to ID "..tostring(nextId).." (playback unverified)"
            return
        end
    end
end

marketQueue = function(kind,pack,category)
    if #market.queue>=16 then market.lastError="Please wait for current requests"; return end
    table.insert(market.queue,{kind=kind,pack=pack,category=category})
end

local function marketStartScan(loadMore)
    if loadMore and (not market.cursor or market.cursor=="") then
        market.status="No more catalog pages. Use Pull to refresh."
        return
    end
    if not loadMore then
        market.cursor=nil; market.cursors={}; market.scanRank=0
        market.apiVersion=1
    end
    market.scanning=true
    market.scanRemaining=3  
    market.nextPage=tick()
    market.failures=0
    market.lastError=""
    market.status=loadMore and "Loading more UGC packs..." or "Fetching Roblox UGC catalog..."
    updateContentLayout()
end

local function marketScanPage()
    local ok,page=pcall(function()
        return marketJSON(MarketCore.catalogUrl(market.cursor,market.apiVersion))
    end)
    if (not ok or type(page)~="table" or type(page.data)~="table") and market.apiVersion==1 then

        market.apiVersion=2
        page=marketJSON(MarketCore.catalogUrl(market.cursor,2))
        ok=true
    end
    assert(ok and type(page)=="table" and type(page.data)=="table", "Catalog response has no result list")
    local added=0
    for _,item in ipairs(page.data) do
        local pack=MarketCore.pack(item)
        if pack then
            market.scanRank=market.scanRank+1
            added=added+1
            pack.rank=market.scanRank
            marketRemember(pack)
        end
    end
    if added==0 and market.scanRank==0 and market.apiVersion==1 then
        market.apiVersion=2
        market.status="Trying alternate Roblox catalog format..."
        market.nextPage=tick()+0.5
        return
    end
    local cursor=page.nextPageCursor
    market.scanRemaining=market.scanRemaining-1
    if type(cursor)=="string" and cursor~="" then
        assert(not market.cursors[cursor],"Catalog repeated a pagination cursor; refresh to retry")
        market.cursors[cursor]=true
        market.cursor=cursor
        market.nextPage=tick()+0.8
        if market.scanRemaining<=0 then
            market.scanning=false
            market.status="Pulled "..market.scanRank.." packs. Click Load More to continue."
            marketSaveCatalog()
        else
            market.status="Found "..market.scanRank.." packs; fetching next page..."
        end
    else
        market.scanning=false
        market.cursor=nil
        market.status="Catalog complete: "..market.scanRank.." packs found."
        marketSaveCatalog()
    end
    market.failures=0
    if tick()>=market.saveAt then marketSaveCatalog(); market.saveAt=tick()+15 end
    updateContentLayout()
end

local function marketFilter()
    if not market.dirty then return end
    market.filtered={}
    local query=market.search:lower()
    for _,pack in ipairs(market.ordered) do
        local roblox=pack.creatorId=="1" and (pack.creatorType=="User" or pack.creatorType=="1")
        local include=market.filter==0 or (market.filter==1 and not pack.legacy and not roblox)
            or (market.filter==2 and not pack.legacy and roblox)
            or (market.filter==3 and market.favorites[pack.key])
            or (market.filter==4 and pack.legacy)
        if include and (not ugcIdsOnly or pack.rows) and (query=="" or (pack.name.." "..pack.creator):lower():find(query,1,true)) then
            table.insert(market.filtered,pack)
        end
    end
    table.sort(market.filtered,function(a,b)
        if a.legacy~=b.legacy then return not a.legacy end
        if (a.rank or 1000000)~=(b.rank or 1000000) then return (a.rank or 1000000)<(b.rank or 1000000) end
        if a.name~=b.name then return a.name:lower()<b.name:lower() end
        return a.key<b.key
    end)
    market.page=math.max(1,math.min(market.page,math.ceil(#market.filtered/8)))
    market.dirty=false
end

local MARKET_BRIDGE_REVISION = CONFIG_FOLDER .. "/MarketplaceBridgeRevision.json"
local MARKET_BRIDGE_FEED = CONFIG_FOLDER .. "/MarketplaceBridgeFeed.json"
local marketBridgeLastRevision = nil
local marketBridgeNextCheck = 0
local function marketBridgePoll(force)
    if tick() < marketBridgeNextCheck then return end
    marketBridgeNextCheck = tick() + 2
    local marker = marketRead(MARKET_BRIDGE_REVISION)
    if not marker or type(marker.revision) ~= "string" or (not force and marker.revision == marketBridgeLastRevision) then return end
    local feed = marketRead(MARKET_BRIDGE_FEED)
    if not feed or feed.version ~= 1 or feed.revision ~= marker.revision
        or type(feed.packs) ~= "table" then return end
    local added = 0
    for _,record in ipairs(feed.packs) do
        if type(record)=="table" and type(record.name)=="string"
            and type(record.rows)=="table" and MarketCore.id(record.bundleId) then
            local rows = {}
            for _,row in ipairs(record.rows) do
                if type(row)=="table" and MarketCore.state(row[1]) and MarketCore.id(row[3]) then
                    rows[#rows+1] = {row[1],tostring(row[2] or "Animation1"),tonumber(row[3])}
                end
            end
            if #rows > 0 then
                local id = MarketCore.id(record.bundleId)
                local pack = market.packs["bundle:"..id]
                if not pack then
                    pack = {key="bundle:"..id,id=id,name=record.name,
                        creator=tostring(record.creator or "Unknown"),legacy=false}
                    marketRemember(pack)
                end
                if not pack.rows then
                    pack.rows=rows
                    pack.status="Dumped references imported (playback not verified)"
                    marketRegister(pack,rows)
                    added=added+1
                end
            end
        end
    end
    marketBridgeLastRevision = marker.revision
    if added>0 then
        market.status="Dumper imported "..added.." ID-reference pack(s). Select states to apply."
        market.lastError=""
        marketSaveCatalog()
        updateContentLayout()
    end
end

local savedCount=0
for id,record in guardedPairs(savedMarketPacks,'saved BTR maps') do
    if type(record)=="table" and type(record.rows)=="table" and
        next(MarketCore.group(record.rows)) then
        local pack={id=id,key="bundle:"..id,name=record.name or record.menuName,
            menuName=record.menuName,creator=record.creator or "BTRoblox Explorer",
            legacy=false,rows=record.rows,
            status="Imported AnimationId properties (playback unverified)"}
        marketRemember(pack)
        savedCount=savedCount+1
    end
end

for name,rows in guardedPairs(rawPacks, 'marketplace initial pack registration') do
    local fromSaved=false
    for _,record in guardedPairs(savedMarketPacks, 'marketplace saved pack registration') do if record.menuName==name then fromSaved=true; break end end
    if not fromSaved then
        marketRemember({key="legacy:"..name,name=name,creator="Included in your original script",
            legacy=true,rows=rows,status="Ready"})
    end
end
local settings=marketRead(MARKET_SETTINGS)
if settings then
    if type(settings.favorites)=="table" then market.favorites=settings.favorites end
    if type(settings.search)=="string" then market.search=settings.search end
    if type(settings.filter)=="number" and settings.filter>=0 and settings.filter<=4 then market.filter=math.floor(settings.filter) end
end
local cached=marketRead(MARKET_CACHE)
if cached and type(cached.data)=="table" then
    for _,item in ipairs(cached.data) do
        local pack=MarketCore.pack(item)
        if pack then
            local saved=savedMarketPacks[pack.id]
            if saved and type(saved.rows)=="table" then
                pack.rows=saved.rows
                pack.status="Ready (saved IDs)"
            end
            marketRemember(pack)
        end
    end
    market.status="Curated on-sale R15 candidates loaded; playable IDs not guaranteed."
end

updateContentLayout()

local function playbackCapability()
    return capability()
end
_G.MatchaAnimationChangerPlayback = {
    CanEquip = playbackCapability,
    Diagnose = function()
        local can,why=playbackCapability()
        local lines={
            "MATCHA ANIMATION CHANGER / REFERENCE ENGINE REPORT",
            "Roblox client="..tostring(activeClient),
            "Executor="..tostring((function() local ok,n,v=pcall(identifyexecutor);return ok and (tostring(n).." "..tostring(v)) or "unavailable" end)()),
            "Pinned offsets="..tostring(offsets~=nil),
            "AnimId offset="..tostring(ANIMATION_ID_OFFSET),
            "PlatformStand offset="..tostring(PLATFORMSTAND_OFFSET),
            "Reference engine available="..tostring(can),
            "Reason="..tostring(why),
            "Readback ID writes="..tostring(playbackStats.wrote),
            "Skipped/failed writes="..tostring(playbackStats.failed),
            "Restored refresh pulses="..tostring(playbackStats.pulses),
            "Last operation="..playbackStats.last,
            "Recent per-state results="..table.concat(playbackStats.recentResults," | "),
            "Playback visually verified=false",
            "Caution=Version-pinned raw client memory; may crash or fail to reload animation tracks"
        }
        local report=table.concat(lines,"\n")
        print(report)
        return report
    end,
    SyncLibrary = function()
        local data=marketRead(MARKET_RESOLVED_FILE)
        if not data or type(data.packs)~="table" then return false end
        local count=0
        for id,record in pairs(data.packs) do
            if MarketCore.id(id) and type(record)=="table" and type(record.rows)=="table"
                and next(MarketCore.group(record.rows)) then
                id=tostring(id)
                savedMarketPacks[id]=record
                local p=market.packs["bundle:"..id]
                if p then p.rows=record.rows;p.name=record.name or p.name
                else marketRemember({id=id,key="bundle:"..id,name=record.name or id,
                     creator=record.creator or "BTRoblox Explorer",rows=record.rows,legacy=false,
                     status="Imported R15 references (playback unverified)"}) end
                count=count+1
            end
        end
        return true
    end,
    EquipBundle = function(bundleId,states,entry)
        local can,reason=playbackCapability()
        if not can then warn("[MATCHA PLAYBACK BLOCKED] "..tostring(reason));return false,reason end
        local pack=market.packs["bundle:"..tostring(bundleId)]
        if not pack or not pack.rows then return false,"No resolved animation ID map for this bundle" end
        local applied=marketApply(pack,nil)
        if applied then task.spawn(applyActiveAnimations) end
        return applied
    end,
    EquipMix = function(mixByState)
        local can,reason=playbackCapability()
        if not can then warn("[MATCHA PLAYBACK BLOCKED] "..tostring(reason));return false,reason end
        if type(mixByState)~="table" then return false,"No mix specified" end
        local staged={}
        local count=0
        for state,slot in pairs(mixByState) do
            if STATES[state] and type(slot)=="table" and type(slot.ids)=="table" then
                local pack=market.packs["bundle:"..tostring(slot.packId)]
                if pack and pack.rows then
                    local verifiedIds=MarketCore.group(pack.rows)[state]
                    if verifiedIds then
                        staged[state]=verifiedIds
                        if state=="idle" and #staged[state]==1 then staged[state][2]=staged[state][1] end
                        count=count+1
                    end
                end
            end
        end
        if count==0 then return false end
        for state,ids in pairs(staged) do activeSpoofs[state]=ids end
        activeWriteStamp={}
        market.status="Queued Mix & Match: "..count.." state(s); playback unverified"
        task.spawn(applyActiveAnimations)
        return true
    end,
}


local StanceEngine = _G.MatchaAnimationChangerPlayback
local function stanceCopy(selection)
    local result = {}
    for name, ids in pairs(selection or {}) do
        if type(ids) == "table" then
            result[name] = {}
            for i, id in ipairs(ids) do result[name][i] = id end
        end
    end
    return result
end
local function stanceRestoreTracked()
    local previous = stanceCopy(activeSpoofs)
    activeSpoofs = {}
    activeWriteStamp = {}
    retryAfter = {}
    local can, reason = capability()
    if not can then
        activeSpoofs = previous
        return false, reason
    end
    local player = game:GetService("Players").LocalPlayer
    local character = player and player.Character
    local currentAddress = character and character.Address
    local failures, restored = 0, 0
    for _, record in pairs(stanceOriginals) do
        if record.character == currentAddress then
            local addr = memoryStringAddress(record.anim)
            if addr then
                local ok, current = pcall(read_std_string, addr)
                if ok and current and current ~= record.uri then
                    local worked, wrote = pcall(write_std_string, addr, record.uri)
                    if worked and wrote then restored = restored + 1 else failures = failures + 1 end
                end
            end
        end
    end
    if failures > 0 then
        return false, "Failed to restore " .. tostring(failures) .. " animation references"
    end
    if restored > 0 then
        local hum = character and character:FindFirstChild("Humanoid")
        if hum and PLATFORMSTAND_OFFSET then
            task.spawn(function()
                local ok, old = pcall(function() return memory_read("byte", hum.Address + PLATFORMSTAND_OFFSET) end)
                if ok and old == 0 then
                    pcall(function() memory_write("byte", hum.Address + PLATFORMSTAND_OFFSET, 1) end)
                    task.wait(0.16)
                    pcall(function() memory_write("byte", hum.Address + PLATFORMSTAND_OFFSET, 0) end)
                end
            end)
        end
    end
    return true, "Restored " .. tostring(restored) .. " animation references"
end
local function stanceApplyIds(idsByState)
    local can, reason = capability()
    if not can then return false, reason end
    if type(idsByState) ~= "table" then return false, "No animation state map supplied" end
    local staged, count = {}, 0
    for state, ids in pairs(idsByState) do
        if STATES[state] and type(ids) == "table" then
            local values = {}
            for _, id in ipairs(ids) do
                local clean = MarketCore.id(id)
                if clean then values[#values + 1] = tonumber(clean) end
            end
            if #values > 0 then
                if state == "idle" and #values == 1 then values[2] = values[1] end
                staged[state] = values
                count = count + 1
            end
        end
    end
    if count == 0 then return false, "No valid animation state IDs supplied" end
    for state in pairs(activeSpoofs) do
        if staged[state] == nil then
            for _, record in pairs(stanceOriginals) do
                if record.state == state then
                    local addr = memoryStringAddress(record.anim)
                    if addr then pcall(write_std_string, addr, record.uri) end
                end
            end
        end
    end
    activeSpoofs = staged
    activeWriteStamp = {}
    retryAfter = {}
    task.spawn(applyActiveAnimations)
    return true, "Queued " .. tostring(count) .. " animation states"
end
StanceEngine.ApplyStateIds = function(ids)
    return stanceApplyIds(ids)
end
StanceEngine.ApplyRows = function(rows)
    return stanceApplyIds(MarketCore.group(rows))
end
StanceEngine.Restore = function()
    return stanceRestoreTracked()
end
StanceEngine.Library = function()
    return market.ordered
end
StanceEngine.Status = function()
    local ok, reason = capability()
    return {available=ok,reason=reason,written=playbackStats.wrote,failed=playbackStats.failed}
end
_G.StanceAnimationEngine = StanceEngine
_G.StanceEngineUnload = function()
    stanceEngineAlive = false
    pcall(stanceRestoreTracked)
    if _G.StanceAnimationEngine == StanceEngine then _G.StanceAnimationEngine = nil end
end
