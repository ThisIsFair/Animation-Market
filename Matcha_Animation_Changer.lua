 








 
 
 
 
 
 
 

 
 
 
 
 
 
 
 
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
local PLATFORMSTAND_OFFSET=offsets and offsets.PlatformStand or nil
local ANIMATION_ID_OFFSET=offsets and offsets.AnimationId or nil
local isUIVisible = false
local toggleDebounce = false
local CONFIG_FOLDER = "SpooferConfig"
local CONFIG_FILE = CONFIG_FOLDER .. "\\Settings.json"
if offsets then
    print(string.format("[Spoofer] Pinned Roblox %s | PlatformStand=0x%X | AnimId=0x%X",
        tostring(activeClient),PLATFORMSTAND_OFFSET,ANIMATION_ID_OFFSET))
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
print("[MATCHA LIBRARY] Loaded "..tostring((function()
    local n=0;for _ in guardedPairs(savedMarketPacks,"library total") do n=n+1 end;return n
end)()).." saved bundle mappings; custom Drawing marketplace")
