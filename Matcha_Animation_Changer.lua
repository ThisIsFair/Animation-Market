 








 
 
 
 
 
 
 

 
 
 
 
 
 
 
 
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
                        return nil
                    end
                end
            end
        end
        return "No valid AnimationId string found in Animate memory"
    end)
    if not ok then return false,"Capability read failed: "..tostring(reason) end
    if reason then return false,reason end
    return true,"Version-pinned memory engine available (VISUAL playback unverified)"
end
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
        activeWriteStamp={};retryAfter={}
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
    while true do
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


 
local function startStanceUI()
 
 
 
 
local UI_ROOT = "SpooferConfig/MarketplaceResolved.json"
local UI_SETTINGS = "SpooferConfig/Stance_Settings.json"
local UI_PRESETS = "SpooferConfig/MotionIndex_Presets.json"
local UI_STATES = {"idle","walk","run","jump","fall","climb","swim","swimidle"}
local UI_PAGES = {"Library","Favorites","Mix & Match","Presets","Settings"}
local UI_PLAYBACK = _G.MatchaAnimationChangerPlayback
local UI_Players = game:GetService("Players")
local UI_HTTP = game:GetService("HttpService")
local UI_Workspace = game:GetService("Workspace")
local UI_Mouse = UI_Players.LocalPlayer and UI_Players.LocalPlayer:GetMouse()
if not UI_Mouse then warn("[Stance] Mouse unavailable; Drawing UI not started") return end

if _G.MatchaMarketplaceUI and type(_G.MatchaMarketplaceUI.Stop)=="function" then
    pcall(_G.MatchaMarketplaceUI.Stop)
end

local function co(r,g,b) return Color3.fromRGB(r,g,b) end
 
 
  
local THEME_SETS={
  {name="Nocturne", main={18,22,24},sidebar={24,29,31},panel={30,36,38},panel2={39,47,48},border={65,76,77},active={42,59,57},accent={117,221,192},accent2={84,186,174},text={235,244,241},mute={169,184,180},dim={127,148,146},danger={249,153,143}},
  {name="Porcelain", main={242,239,230},sidebar={228,224,214},panel={251,249,244},panel2={232,229,222},border={192,188,177},active={219,233,224},accent={34,117,101},accent2={78,158,134},text={32,43,43},mute={84,100,96},dim={110,126,122},danger={180,68,63}},
  {name="Velvet", main={28,23,39},sidebar={35,29,49},panel={45,37,58},panel2={58,49,74},border={83,70,99},active={69,51,95},accent={201,161,249},accent2={143,120,217},text={245,238,253},mute={182,166,198},dim={144,127,163},danger={247,134,170}},
  {name="Cobalt", main={13,22,40},sidebar={20,32,54},panel={26,41,64},panel2={36,56,82},border={60,84,111},active={32,65,91},accent={107,191,246},accent2={70,136,224},text={231,243,255},mute={156,182,208},dim={119,148,181},danger={247,146,143}},
  {name="Sienna", main={42,32,28},sidebar={52,40,32},panel={62,49,39},panel2={76,61,49},border={112,89,72},active={83,65,50},accent={245,185,119},accent2={207,134,106},text={255,244,225},mute={207,184,161},dim={164,142,124},danger={250,137,130}}
}
local themeIndex=3  
local C={}
local function applyTheme()
    local t=THEME_SETS[themeIndex] or THEME_SETS[1]
    local function col(arr) return co(arr[1],arr[2],arr[3]) end
    C.main=col(t.main); C.sidebar=col(t.sidebar)
    C.panel=col(t.panel); C.panel2=col(t.panel2)
    C.border=col(t.border); C.active=col(t.active)
    C.accent=col(t.accent); C.heroA=C.accent
    C.heroB=col(t.accent2); C.heroC=C.accent
    C.light=col(t.text); C.text=C.light
    C.mute=col(t.mute); C.dim=col(t.dim)
    C.good=C.accent; C.danger=col(t.danger)
    C.darkAccent=C.active; C.shadow=co(4,5,8)
end
applyTheme()
local FONT = (Drawing.Fonts and Drawing.Fonts.System) or 1
local BOLD = (Drawing.Fonts and Drawing.Fonts.SystemBold) or FONT
local MONO = (Drawing.Fonts and Drawing.Fonts.Monospace) or FONT
local function getDoc(path)
    local ok,yes=pcall(isfile,path)
    if not ok or not yes then return nil end
    local r,data=pcall(readfile,path)
    if not r then return nil end
    local valid,obj=pcall(function() return UI_HTTP:JSONDecode(data) end)
    return valid and type(obj)=="table" and obj or nil
end
local function saveDoc(path,value)
    return pcall(function()
        if not isfolder("SpooferConfig") then makefolder("SpooferConfig") end
        writefile(path,UI_HTTP:JSONEncode(value))
    end)
end
local prefs=getDoc(UI_SETTINGS) or getDoc("SpooferConfig/PrismMarket_Settings.json") or getDoc("SpooferConfig/MotionIndex_Settings.json") or getDoc("SpooferConfig/Kinetic_Settings.json") or {}
themeIndex=math.max(1,math.min(#THEME_SETS,tonumber(prefs.theme) or 3))
 
 
local velvetMigration=prefs.stanceThemeRevision~="velvet-default-1"
if velvetMigration then themeIndex=3 end
applyTheme()
local savedPresets=getDoc(UI_PRESETS) or {}
local favorites=type(prefs.favorites)=="table" and prefs.favorites or {}
local presets=type(savedPresets.presets)=="table" and savedPresets.presets or {}
local screenW,screenH=1280,720
local function getScreen()
    local ok,vp=pcall(function() return UI_Workspace.CurrentCamera.ViewportSize end)
    if ok and vp then screenW,screenH=vp.X,vp.Y end
end
getScreen()
local W={x=tonumber(prefs.x),y=tonumber(prefs.y),w=tonumber(prefs.w) or 825,
         h=tonumber(prefs.h) or 618,show=true}
W.w=math.max(math.min(760,screenW-20),math.min(screenW-20,W.w))
W.h=math.max(math.min(520,screenH-20),math.min(screenH-20,W.h))
W.x=math.max(0,math.min(screenW-W.w,W.x or math.floor((screenW-W.w)/2)))
W.y=math.max(0,math.min(screenH-W.h,W.y or math.floor((screenH-W.h)/2)))
local function savePrefs()
    prefs.x,prefs.y,prefs.w,prefs.h=W.x,W.y,W.w,W.h
    prefs.favorites=favorites
    prefs.theme=themeIndex
    prefs.columns=nil  
    prefs.stanceThemeRevision="velvet-default-1"
    saveDoc(UI_SETTINGS,prefs)
end
if velvetMigration then savePrefs() end
local function savePresets() saveDoc(UI_PRESETS,{presets=presets}) end

local packs,lookup={},{}
local function loadPacks()
    local doc=getDoc(UI_ROOT)
    if not doc or type(doc.packs)~="table" then return false end
    local nextP,nextL={},{}
    for bundle,rec in pairs(doc.packs) do
        if type(rec)=="table" and type(rec.rows)=="table" then
            local states,n={},0
            for _,row in ipairs(rec.rows) do
                if type(row)=="table" then
                    local st=tostring(row[1] or ""):lower()
                    local id=tostring(row[3] or "")
                    if id:match("^%d+$") then
                        for _,valid in ipairs(UI_STATES) do
                            if st==valid then
                                states[st]=states[st] or {}
                                states[st][#states[st]+1]=id
                                break
                            end
                        end
                    end
                end
            end
            for _,st in ipairs(UI_STATES) do if states[st] then n=n+1 end end
            if n>0 then
                local obj={id=tostring(bundle),name=tostring(rec.name or rec.menuName or bundle),
                    creator=tostring(rec.creator or "UGC creator"),states=states,count=n}
                nextP[#nextP+1]=obj;nextL[obj.id]=obj
            end
        end
    end
    table.sort(nextP,function(a,b) return a.name:lower()<b.name:lower() end)
    if #nextP==0 then return false end
    packs,lookup=nextP,nextL
    return true
end
loadPacks()

local alive=true
local page="Library"
local search=""
local queryCursor=0
local searchSelectAll=false
local pageNo=1
local selected=nil
local edit=nil  
local presetName=""
local mix={}
local mixState="run"
local status="Ready"
local expandedPreset=nil  
local deleteConfirm=nil  
local captureState="not attempted"
local mouseWasDown=false
local drag=nil
local keysDown={}
local render, draw, blur

 
local pool={}
local used=0
local hits={}
local hasBounds=false
local measure=Drawing.new("Text")
measure.Visible=false
pcall(function() measure.Font=FONT end)
local function prop(obj,k,v)
    local success=pcall(function() obj[k]=v end)
    return success
end
local function measureW(str,size,font)
    local ok,val=pcall(function()
        measure.Font=font or FONT
        measure.Size=size
        measure.Text=tostring(str)
        return measure.TextBounds.X
    end)
    if ok and type(val)=="number" and val>0 then hasBounds=true;return val end
    return #tostring(str)*(size or 13)*0.53
end
local function fit(str,width,size,font)
    str=tostring(str or "")
    if width<=2 then return "" end
    if measureW(str,size,font)<=width then return str end
    local dot="..."
    while #str>0 and measureW(str..dot,size,font)>width do str=str:sub(1,-2) end
    return str..dot
end
local function take(kind,x,y)
    used=used+1
    local p=pool[used]
    if not p or p.kind~=kind then
        if p then pcall(function() p.o:Remove() end) end
        p={kind=kind,o=Drawing.new(kind)}
        pool[used]=p
    end
    p.x=x;p.y=y
    prop(p.o,"Position",Vector2.new(W.x+x,W.y+y))
    prop(p.o,"Visible",true)
    return p.o
end
local function box(x,y,w,h,color,round,z,outline,alpha)
    local o=take("Square",x,y)
    prop(o,"Size",Vector2.new(math.max(1,w),math.max(1,h)))
    prop(o,"Color",color)
    prop(o,"Filled",not outline)
    prop(o,"Transparency",alpha or 1)
    prop(o,"ZIndex",z or 1)
    if round then prop(o,"Corner",round) end
    return o
end
local function label(s,x,y,size,color,strong,z,maxWidth)
    local font=strong and BOLD or FONT
    if maxWidth then s=fit(s,maxWidth,size,font) end
    local o=take("Text",x,y)
    prop(o,"Text",tostring(s))
    prop(o,"Size",size or 14)
    prop(o,"Font",font)
    prop(o,"Color",color or C.text)
    prop(o,"Transparency",1)
    prop(o,"Center",false)
    prop(o,"Outline",false)
    prop(o,"ZIndex",z or 10)
    return o
end
local function middle(s,x,y,w,h,size,color,strong)
    local font=strong and BOLD or FONT
    local fs=size or 13
    s=fit(s,w-8,fs,font)
     
    local th=fs
    pcall(function()
        measure.Font=font;measure.Size=fs;measure.Text=s
        local bounds=measure.TextBounds
        if bounds and type(bounds.Y)=="number" and bounds.Y>0 then th=bounds.Y end
    end)
    local ytext=math.floor(y+(h-th)/2+0.5)
    local o=label(s,math.floor(x+w/2+0.5),ytext,fs,color,strong)
    prop(o,"Center",true)
    return o
end
local function hit(x,y,w,h,func,role)
    hits[#hits+1]={x=x,y=y,w=w,h=h,func=func,role=role}
end
local function action(s,x,y,w,h,callback,kind)
    local bg,fg=C.panel2,C.text
    if kind=="primary" then bg,fg=C.accent,C.main
    elseif kind=="selected" then bg,fg=C.darkAccent,C.accent
    elseif kind=="danger" then bg,fg=C.panel2,C.danger end
    box(x,y,w,h,bg,3,7)
    middle(s,x,y,w,h,13,fg,kind=="primary")
    hit(x,y,w,h,callback)
end
local function drawFrame()
    used=0;hits={}
    if W.show then render() end
    for i=used+1,#pool do prop(pool[i].o,"Visible",false) end
end
local function shiftFrame()
    for i=1,used do
        local p=pool[i]
        if p then prop(p.o,"Position",Vector2.new(W.x+p.x,W.y+p.y)) end
    end
end
local function packCurrent()return selected and lookup[selected] end
local function countMix()local n=0 for _,st in ipairs(UI_STATES) do if mix[st] then n=n+1 end end return n end
local function selection(method,...)
    if not UI_PLAYBACK or type(UI_PLAYBACK[method])~="function" then
        status="Playback adapter unavailable";return false end
    local ok,result,reason=pcall(UI_PLAYBACK[method],...)
    if not ok or not result then status="Equip failed: "..tostring(reason or result or "unknown") return false end
    status="Selection sent to working R15 playback engine";return true
end
local function equipPack()
    local p=packCurrent()
    if p then selection("EquipBundle",p.id,p.states,p) end
    drawFrame()
end
local function choosePage(name)
    blur()
    page=name;pageNo=1;search="";queryCursor=0;selected=nil
    deleteConfirm=nil
    drawFrame()
end
local function listFiltered()
    local out={}
    local q=search:lower()
    for _,p in ipairs(packs) do
        if (page~="Favorites" or favorites[p.id]) and
           (page~="Mix & Match" or p.states[mixState]) and
           (page=="Mix & Match" or p.count>=7) and
           (q=="" or p.name:lower():find(q,1,true) or (p.creator~="UGC creator" and p.creator:lower():find(q,1,true))) then
            out[#out+1]=p
        end
    end
    return out
end
local function repeatDown(vk)
    local ok,down=pcall(iskeypressed,vk)
    return ok and down==true
end
local function caps()return repeatDown(0x14) end  
local function shift()return repeatDown(16) or repeatDown(160) or repeatDown(161) end
local function ctrl()return repeatDown(17) or repeatDown(162) or repeatDown(163) end

 
 
 
local gameInputBlocked=false
 
 
 
local hoveringTextField=false
 
 
local hoverArmed=true
 
 
local releaseReassert=0
local gateCalls=0
local gateFailures=0
local casBound=false
local function sinkTextAction()
    local ok,value=pcall(function() return Enum.ContextActionResult.Sink end)
    return ok and value or nil
end
local function setActionSink(enabled)
    local ok,svc=pcall(function() return game:GetService("ContextActionService") end)
    if not ok or not svc then return false end
    if enabled and not casBound then
        local okBind=pcall(function()
            svc:BindActionAtPriority("StanceTypingInput",function()
                return sinkTextAction()
            end,false,1000000,
            Enum.KeyCode.W,Enum.KeyCode.A,Enum.KeyCode.S,Enum.KeyCode.D,
            Enum.KeyCode.Space,Enum.KeyCode.Up,Enum.KeyCode.Down,
            Enum.KeyCode.Left,Enum.KeyCode.Right)
        end)
        casBound=okBind
    elseif not enabled and casBound then
        local didUnbind=pcall(function() svc:UnbindAction("StanceTypingInput") end)
        if didUnbind then casBound=false end
    end
    return casBound
end
local function setGameInputEnabled(enabled)
    local ok=false
    if type(setrobloxinput)=="function" then
        ok=pcall(setrobloxinput,enabled)
    end
    if not ok then gateFailures=gateFailures+1 end
    local sunk=setActionSink(not enabled)
    gameInputBlocked=not enabled
    gateCalls=gateCalls+1
    captureState=enabled and "Game input released" or (sunk and "Typing: game controls captured" or
      (ok and "Typing: Matcha forwarding blocked (physical keys not guaranteed)" or "Input suppression unavailable"))
    return ok or sunk
end
local function maintainInputGate(force)
     
     
    local shouldBlock=W.show and (edit~=nil or hoveringTextField)
    if shouldBlock then
        releaseReassert=0
        if force or not gameInputBlocked then return setGameInputEnabled(false) end
    elseif force or gameInputBlocked or releaseReassert>0 then
        if releaseReassert>0 then releaseReassert=releaseReassert-1 end
        return setGameInputEnabled(true)
    end
    return true
end
local function releaseGameInput()
     
     
    releaseReassert=5
    local ok=false
    for i=1,3 do
        if setGameInputEnabled(true) then ok=true end
    end
    return ok
end
blur=function()
    local wasEditing=edit~=nil
    edit=nil
    searchSelectAll=false
     
     
    hoveringTextField=false
    hoverArmed=false
    for vk in pairs(keysDown) do keysDown[vk]=nil end
    if wasEditing or gameInputBlocked then releaseGameInput() end
end
local function focus(where)
    if not W.show then return end
    if edit==where then
         
        releaseReassert=0
        setGameInputEnabled(false)
        return
    end
     
     
    edit=where
    searchSelectAll=false
    for vk in pairs(keysDown) do keysDown[vk]=nil end
    if where=="search" then queryCursor=#search else queryCursor=#presetName end
    setGameInputEnabled(false)
    drawFrame()
end
local function editValue()
    return edit=="search" and search or presetName
end
local function updateEdit(v,cursor)
    if edit=="search" then
        search=v:sub(1,74);pageNo=1;selected=nil;queryCursor=math.min(cursor,#search)
    else
        presetName=v:sub(1,40);queryCursor=math.min(cursor,#presetName)
    end
    drawFrame()
end
local function handleEdit(vk)
    if not edit then return end
    local value=editValue()
    local pos=math.min(#value,queryCursor)
    local selectedAll=searchSelectAll
    if vk==13 or vk==27 then blur();drawFrame();return end
    if ctrl() and vk==65 then searchSelectAll=true;queryCursor=#value;drawFrame();return end
    if ctrl() and vk==86 then
        local good,data=pcall(function() return getclipboard() end)
        if good and type(data)=="string" then
            data=data:gsub("[%c]", " ")
            if selectedAll then value="";pos=0 end
            value=value:sub(1,pos)..data..value:sub(pos+1)
            pos=pos+#data
            searchSelectAll=false;updateEdit(value,pos)
        else status="Clipboard read is unavailable in this Matcha build";drawFrame() end
        return
    end
    if vk==36 then queryCursor=0;searchSelectAll=false;drawFrame();return end
    if vk==35 then queryCursor=#value;searchSelectAll=false;drawFrame();return end
    if vk==37 then queryCursor=math.max(0,pos-1);searchSelectAll=false;drawFrame();return end
    if vk==39 then queryCursor=math.min(#value,pos+1);searchSelectAll=false;drawFrame();return end
    if vk==8 then
        if selectedAll then value="";pos=0
        elseif pos>0 then
            if ctrl() then
                local left=value:sub(1,pos)
                local new=left:gsub("%s+$",""):gsub("%S+$","")
                value=new..value:sub(pos+1);pos=#new
            else value=value:sub(1,pos-1)..value:sub(pos+1);pos=pos-1 end
        end
        searchSelectAll=false;updateEdit(value,pos);return
    end
    if vk==46 then
        if selectedAll then value="";pos=0
        else value=value:sub(1,pos)..value:sub(pos+2) end
        searchSelectAll=false;updateEdit(value,pos);return
    end
    if ctrl() or repeatDown(18) then return end
    local ch
    if vk>=65 and vk<=90 then
        local uppercase=shift()  
        ch=uppercase and string.char(vk) or string.char(vk+32)
    elseif vk>=48 and vk<=57 then ch=string.char(vk)
    elseif vk==32 then ch=" "
    elseif vk==189 then ch=shift() and "_" or "-"
    elseif vk==190 then ch="."
    elseif vk==191 then ch="/" end
    if ch then
        if selectedAll then value="";pos=0 end
        value=value:sub(1,pos)..ch..value:sub(pos+1)
        searchSelectAll=false;updateEdit(value,pos+#ch)
    end
end
local watched={8,13,27,32,35,36,37,39,46,189,190,191}
for i=48,57 do watched[#watched+1]=i end
for i=65,90 do watched[#watched+1]=i end
local nextRepeat={}
local function pollKeys(now)
    if not edit then return end
    for _,vk in ipairs(watched) do
        local down=repeatDown(vk)
        if down then
            if not keysDown[vk] then
                keysDown[vk]=true
                nextRepeat[vk]=now+0.36
                handleEdit(vk)
            elseif now>=(nextRepeat[vk] or math.huge) then
                nextRepeat[vk]=now+0.052
                 
                if vk~=13 and vk~=27 then handleEdit(vk) end
            end
        else
            keysDown[vk]=false
            nextRepeat[vk]=nil
        end
        if not edit then break end
    end
end
local function savePreset()
    local name=presetName:gsub("^%s+",""):gsub("%s+$","")
    if name=="" then status="Enter a preset name first";drawFrame();return end
    if countMix()==0 then status="Choose Mix & Match states first";drawFrame();return end
    if #presets>=80 then status="Preset limit (80) reached";drawFrame();return end
    local copy={}
    for _,st in ipairs(UI_STATES) do
        if mix[st] then copy[st]={packId=mix[st].packId,packName=mix[st].packName,ids=mix[st].ids} end
    end
    presets[#presets+1]={name=name,mix=copy}
    savePresets();presetName="";blur();status="Saved preset: "..name;drawFrame()
end
local function loadPreset(index)
    local preset=presets[index]
    if not preset then return end
    mix={}
    for _,st in ipairs(UI_STATES) do
        local sel=preset.mix and preset.mix[st]
        local real=sel and lookup[tostring(sel.packId)]
        if real and real.states[st] then
            mix[st]={packId=real.id,packName=real.name,ids=real.states[st]}
        end
    end
    choosePage("Mix & Match")
    status="Loaded preset: "..tostring(preset.name);drawFrame()
end
local function favor()
    if not selected then return end
    favorites[selected]=not favorites[selected] or nil
    savePrefs();drawFrame()
end
local function onMix()
    local p=packCurrent()
    if not p or not p.states[mixState] then status="This state is unavailable";drawFrame();return end
    mix[mixState]={packId=p.id,packName=p.name,ids=p.states[mixState]}
    status="Added "..mixState.." from "..p.name;drawFrame()
end
 
local function blend(c1,c2,t)
    return co(math.floor((c1.R+(c2.R-c1.R)*t)*255+0.5),
              math.floor((c1.G+(c2.G-c1.G)*t)*255+0.5),
              math.floor((c1.B+(c2.B-c1.B)*t)*255+0.5))
end
local function fineRule(x,y,w,color,alpha)
    box(x,y,w,1,color or C.border,0,5,false,alpha or 0.68)
end
local function gradRule(x,y,w)
    for i=0,19 do
       local x1=math.floor(x+w*i/20)
       local x2=math.floor(x+w*(i+1)/20)
       box(x1,y,math.max(1,x2-x1),2,blend(C.heroA,C.heroB,i/19),0,7)
    end
end
local function titleLine(text,x,y,size)
    label(text,x,y,size or 24,C.light,true)
end
local function textFit(text,x,y,w,size,color,strong)
    label(fit(tostring(text),math.max(1,w),size,strong and BOLD or FONT),x,y,size,color,strong)
end
local function plainButton(txt,x,y,w,h,fn,mode)
    local active=mode=="active"
    local primary=mode=="primary"
    box(x,y,w,h,primary and C.heroA or (active and C.active or C.panel2),7,7)
    if active then box(x,y,w,h,C.heroA,7,8,true,0.75) end
    middle(txt,x,y,w,h,h<=29 and 11 or (h<=35 and 12 or 13),primary and C.main or (active and C.heroA or C.text),primary or active)
    hit(x,y,w,h,fn)
end
local SIDEBAR=132
local MARGIN=22
local function contentX() return SIDEBAR+MARGIN end
local function contentW() return W.w-SIDEBAR-MARGIN*2 end
local function nav()
     
    box(-2,-2,W.w+4,W.h+4,C.shadow,15,0,false,0.27)
    box(0,0,W.w,W.h,C.main,12,1)
    box(0,0,SIDEBAR,W.h,C.sidebar,12,2)
    box(SIDEBAR-16,0,16,W.h,C.sidebar,0,2)
    box(SIDEBAR,0,1,W.h,C.border,0,4,false,0.72)
     
    label("stance",16,17,24,C.light,true)
    local links={{"Library","Browse"},{"Favorites","Favorites"},{"Mix & Match","Mix & Match"},{"Presets","Presets"},{"Settings","Appearance"}}
    for i,item in ipairs(links) do
        local tab,title=item[1],item[2]
        local y=67+(i-1)*44
        local active=page==tab
        if active then
            box(7,y,SIDEBAR-14,35,C.active,6,4)
            box(7,y+6,3,23,C.accent,1,5)
        end
        label(title,17,y+9,13,active and C.light or C.mute,active)
        hit(7,y,SIDEBAR-14,36,function()choosePage(tab)end)
    end
end
local function topLine(section, count)
    local x=contentX()
    local w=contentW()
    titleLine(section,x,27,21)
    if count then
        local str=type(count)=="string" and count or (tostring(count).." bundles")
        label(str,x+w-measureW(str,13,FONT),36,13,C.dim)
    end
end
 
 
local function drawSearch(x,y,w)
    local active=edit=="search"
    box(x,y,w,44,C.panel,8,5)
    box(x,y,w,44,active and C.heroA or C.border,8,6,true,active and 0.78 or 0.55)
    local textX=x+15
    local room=math.max(18,w-88)
    local value=search
    local fontSize=15
    local charAdvance=9  
    local maxChars=math.max(1,math.floor((room-3)/charAdvance))
    local start=0
    if #value>maxChars then
       start=math.max(0,math.min(queryCursor-maxChars+1,#value-maxChars))
    end
    local shown=value:sub(start+1,start+maxChars)
    if value=="" then
        label("Search animations",textX,y+13,15,C.dim)
    else
        for i=1,#shown do
           local o=label(shown:sub(i,i),textX+(i-1)*charAdvance,y+13,fontSize,C.light)
           prop(o,"Font",MONO)
        end
    end
    if active then
        if searchSelectAll and #shown>0 then
            box(textX,y+34,math.min(room,#shown*charAdvance),2,C.heroA,1,8)
        end
        if os.clock()%1<0.52 then
            local caretCell=math.max(0,math.min(queryCursor-start,maxChars))
            box(textX+caretCell*charAdvance,y+11,1,22,C.light,0,9)
        end
    end
    if value~="" then
        label("Clear",x+w-50,y+14,13,C.mute)
        hit(x+w-62,y+3,60,38,function()
            blur();search="";queryCursor=0;selected=nil;pageNo=1;drawFrame()
        end)
    end
    hit(x,y,w-(value~="" and 70 or 0),44,function()focus("search")end,"search")
end
local function pageControls(total,per,y)
    local cnt=math.max(1,math.ceil(total/per))
    pageNo=math.min(cnt,math.max(1,pageNo))
    local x=contentX();local w=contentW()
     
    local right=x+w
     
    plainButton("<",right-126,y,28,29,function()pageNo=math.max(1,pageNo-1);selected=nil;drawFrame()end)
    middle(pageNo.." / "..cnt,right-92,y,61,29,12,C.dim)
    plainButton(">",right-27,y,27,29,function()pageNo=math.min(cnt,pageNo+1);selected=nil;drawFrame()end)
end
local toastAt=0
local toastText=""
local function toast(text)
   toastAt=os.clock()+2.6
   toastText=text
end
local function row(p,index,x,y,w,h,ismix)
    local chosen=(selected==p.id)
    if chosen then box(x,y,w,h,C.active,5,4) end
    if chosen then box(x,y+5,3,h-10,C.accent,1,6) end
    label(string.format("%02d",index%100),x+9,y+(h-13)/2-1,11,C.dim,true)
    local bodyX=x+43
    local titleY=y+(h<=36 and 5 or 9)
    textFit(p.name,bodyX,titleY,w-223,h<=36 and 13 or 15,chosen and C.light or C.text,true)
    if h>36 then
        local creator=(p.creator=="UGC creator") and "Community animation" or p.creator
        textFit(creator,bodyX,y+31,w-230,11,C.dim,false)
    end
    middle(p.count.."/8",x+w-155,y,35,h,12,p.count>=7 and C.accent or C.mute,true)
    local favoriteText=favorites[p.id] and "Saved" or "Save"
    middle(favoriteText,x+w-116,y,47,h,11,favorites[p.id] and C.accent or C.mute,false)
    hit(x+w-118,y,50,h,function()
        favorites[p.id]=not favorites[p.id] or nil
        savePrefs();drawFrame()
    end)
    local bw=60;local bh=math.min(28,h-6)
    plainButton(ismix and "Add" or "Wear",x+w-bw-2,y+(h-bh)/2,bw,bh,function()
        selected=p.id
        if ismix then onMix();toast("Added "..mixState.." from "..p.name)
        else
           local success=selection("EquipBundle",p.id,p.states,p)
           toast(success and ("Equipped "..p.name) or status)
        end
        drawFrame()
    end,"primary")
    hit(x,y,w-161,h,function()selected=p.id;drawFrame()end)
    fineRule(x,y+h,w,C.border,0.45)
end
local function emptyState(y,h)
    local x=contentX();local w=contentW()
    fineRule(x,y,w,C.border,0.55)
    middle("No results",x,y+math.min(50,h*0.18),w,33,18,C.text,true)
    middle(search~="" and "Try a different search." or "Nothing saved here yet.",x,y+math.min(92,h*0.32),w,25,13,C.dim)
    if search~="" then
       plainButton("Clear search",x+(w-120)/2,y+math.min(142,h*0.45),120,31,function()
         blur();search="";queryCursor=0;pageNo=1;selected=nil;drawFrame()
       end)
    end
end
local function drawCatalogue(ismix)
    local x=contentX();local w=contentW()
    if page=="Favorites" then topLine("Favorites") else topLine("Animations",#packs) end
    drawSearch(x,83,w)
    label("Full Set",x,149,14,C.accent,true)
    local top=201
    local bottom=W.h-49
    local height=55  
    local pitch=height+3
    local per=math.max(2,math.floor((bottom-top)/pitch))
    local results=listFiltered()
    local maxPage=math.max(1,math.ceil(#results/per))
    pageNo=math.min(pageNo,maxPage)
     
    if selected then
       local visible=false
       for _,p in ipairs(results) do if p.id==selected then visible=true;break end end
       if not visible then selected=nil end
    end
    fineRule(x,191,w,C.border,0.63)
    label("ANIMATION",x+47,174,10,C.dim,true)
    label("STATES",x+w-174,174,10,C.dim,true)
    if #results==0 then emptyState(top,bottom-top)
    else
        for i=1,per do
            local idx=(pageNo-1)*per+i
            local p=results[idx]
            if p then row(p,idx,x,top+(i-1)*pitch,w,height,false) end
        end
    end
    pageControls(#results,per,W.h-38)
end
local function drawMixer()
    local x=contentX();local w=contentW()
    topLine("Mix & Match",countMix().." / 8 selected")
     
    local gap=9;local cols=4;local cw=(w-3*gap)/cols
    for i,st in ipairs(UI_STATES) do
       local cc=(i-1)%cols;local rr=math.floor((i-1)/cols)
       local xx=x+cc*(cw+gap);local yy=79+rr*51
       local active=(mixState==st)
       local mapped=mix[st]
       box(xx,yy,cw,44,active and C.active or C.panel,6,5)
       box(xx,yy,cw,44,active and C.accent or C.border,6,6,true,active and 0.83 or 0.38)
       local stateName=st=="swimidle" and "Swim idle" or (st:sub(1,1):upper()..st:sub(2))
       middle(stateName,xx+4,yy+3,cw-8,18,12,active and C.accent or C.light,true)
       local packName=mapped and (mapped.packName or "Selected") or "Not assigned"
       middle(packName,xx+5,yy+22,cw-10,17,11,mapped and C.mute or C.dim)
       hit(xx,yy,cw,44,function()
           mixState=st;selected=nil;search="";pageNo=1;blur();drawFrame()
       end)
    end
    drawSearch(x,186,w)
    local results=listFiltered()
    local height=53  
    local pitch=height+2
    local top=253
    local bottom=W.h-93
    local per=math.max(1,math.floor((bottom-top)/pitch))
    pageNo=math.min(pageNo,math.max(1,math.ceil(#results/per)))
    if #results==0 then emptyState(top,bottom-top)
    else
       for i=1,per do
           local idx=(pageNo-1)*per+i
           local p=results[idx]
           if p then row(p,idx,x,top+(i-1)*pitch,w,height,true) end
       end
    end
    pageControls(#results,per,W.h-88)
    fineRule(x,W.h-55,w,C.border,0.6)
    label(countMix().." / 8 assigned",x,W.h-42,12,C.mute)
    plainButton("Apply mix",x+w-112,W.h-51,112,32,function()
         if countMix()==0 then toast("Choose states first")
         else selection("EquipMix",mix);toast(status) end
         drawFrame()
    end,"primary")
end
local function drawPresets()
    local x=contentX();local w=contentW()
    topLine("Presets",#presets.." saved")
    label("Save the current mix",x,79,14,C.light,true)
    local iy=105
    box(x,iy,w-115,35,C.panel,6,5)
    box(x,iy,w-115,35,edit=="preset" and C.accent or C.border,6,6,true,0.65)
    local title=presetName=="" and (edit=="preset" and "" or "Preset name") or presetName
    textFit(title,x+12,iy+10,w-144,13,presetName=="" and C.dim or C.light)
    if edit=="preset" and os.clock()%1<0.55 then
       box(math.min(x+w-146,x+12+measureW(presetName:sub(1,queryCursor),13,FONT)),iy+7,1,21,C.accent,0,8)
    end
    hit(x,iy,w-115,35,function()focus("preset")end,"preset")
    plainButton("Save mix",x+w-106,iy,106,35,savePreset,"primary")
    label("Saved animation sets",x,157,14,C.light,true)
    fineRule(x,182,w,C.border,0.62)
    local top=192
    local bottom=W.h-46
    if #presets==0 then
        emptyState(top,bottom-top)
        return
    end

    pageNo=math.min(math.max(1,pageNo),#presets)
    local idx=pageNo
    local yy=top
    local shown=0
    while idx<=#presets do
        local p=presets[idx]
        local expanded=expandedPreset==idx
        local asking=deleteConfirm==idx
        local rh=expanded and 232 or 48
        if yy+rh>bottom then break end
         
        box(x,yy,w,rh,C.panel,6,3)
        box(x,yy,w,rh,expanded and C.accent or C.border,6,4,true,expanded and 0.70 or 0.35)
        local arrow=expanded and "v" or ">"
        middle(arrow,x+8,yy+9,24,29,15,C.accent,true)
        textFit(p.name,x+42,yy+13,w-252,14,C.light,true)
         
        if asking then
            plainButton("Cancel",x+w-155,yy+8,65,31,function()deleteConfirm=nil;drawFrame()end)
            box(x+w-84,yy+8,80,31,C.danger,5,7)
            middle("Confirm",x+w-84,yy+8,80,31,11,C.main,true)
            local deletionIndex=idx
            hit(x+w-84,yy+8,80,31,function()
                table.remove(presets,deletionIndex)
                savePresets()
                deleteConfirm=nil
                if expandedPreset then
                    if expandedPreset==deletionIndex then expandedPreset=nil
                    elseif expandedPreset>deletionIndex then expandedPreset=expandedPreset-1 end
                end
                pageNo=math.min(pageNo,math.max(1,#presets))
                toast("Preset deleted")
                drawFrame()
            end)
        else
            local loadIndex=idx
            plainButton("Load",x+w-139,yy+8,62,31,function()deleteConfirm=nil;loadPreset(loadIndex)end,"primary")
            plainButton("Delete",x+w-70,yy+8,66,31,function()
                deleteConfirm=loadIndex;drawFrame()
            end)
        end
        local expandIndex=idx
        hit(x+3,yy+2,w-164,43,function()
            if expandedPreset==expandIndex then expandedPreset=nil else expandedPreset=expandIndex end
            deleteConfirm=nil
             
            if expandedPreset then pageNo=expandIndex end
            drawFrame()
        end)
        if expanded then
            fineRule(x+12,yy+48,w-24,C.border,0.55)
            local gap=18
            local colw=(w-42-gap)/2
            for i,st in ipairs(UI_STATES) do
                local cc=(i-1)%2;local rr=math.floor((i-1)/2)
                local xx=x+15+cc*(colw+gap)
                local sy=yy+59+rr*42
                local sel=p.mix and p.mix[st]
                local stateName=st=="swimidle" and "Swim idle" or (st:sub(1,1):upper()..st:sub(2))
                label(stateName,xx,sy,11,sel and C.accent or C.dim,true)
                local bundleName=sel and (sel.packName or (lookup[tostring(sel.packId)] and lookup[tostring(sel.packId)].name) or "Unknown animation") or "Not assigned"
                textFit(bundleName,xx,sy+14,colw-3,12,sel and C.light or C.mute,sel~=nil)
                if sel and type(sel.ids)=="table" and sel.ids[1] then
                    textFit("ID "..tostring(sel.ids[1]),xx+colw-125,sy,125,10,C.dim)
                end
            end
        end
        shown=shown+1
        yy=yy+rh+8
        idx=idx+1
    end
     
    local footer=W.h-37
    local desc=tostring(pageNo).." - "..tostring(pageNo+shown-1).." of "..tostring(#presets)
    label(desc,x,footer+8,11,C.dim)
    plainButton("<",x+w-85,footer,29,28,function()
        pageNo=math.max(1,pageNo-math.max(1,shown));deleteConfirm=nil;drawFrame()
    end)
    plainButton(">",x+w-29,footer,29,28,function()
        pageNo=math.min(#presets,pageNo+math.max(1,shown));deleteConfirm=nil;drawFrame()
    end)
end
local function drawSettings()
    local x=contentX();local w=contentW()
    topLine("Appearance")
    label("Interface themes",x,81,15,C.light,true)
    label("Changes the entire palette: background, panels, text and highlights.",x,102,12,C.mute)
    for i,t in ipairs(THEME_SETS) do
       local col=(i-1)%2;local rr=math.floor((i-1)/2)
       local cw=(w-10)/2;local xx=x+col*(cw+10);local yy=129+rr*79
       local function rgb(r) return co(r[1],r[2],r[3]) end
       box(xx,yy,cw,70,rgb(t.panel),7,4)
       if themeIndex==i then box(xx,yy,cw,70,C.accent,7,6,true,0.8)
       else box(xx,yy,cw,70,C.border,7,6,true,0.6) end
       box(xx+11,yy+11,60,22,rgb(t.sidebar),4,5)
       box(xx+12,yy+44,cw-24,6,rgb(t.accent),3,6)
       box(xx+79,yy+13,15,16,rgb(t.accent2),4,5)
       label(t.name,xx+102,yy+12,14,rgb(t.text),themeIndex==i)
       if themeIndex==i then label("Active",xx+102,yy+31,11,rgb(t.accent),true) end
       hit(xx,yy,cw,70,function()themeIndex=i;applyTheme();savePrefs();drawFrame()end)
    end
     

end
render=function()
    nav()
    if page=="Library" or page=="Favorites" then drawCatalogue(false)
    elseif page=="Mix & Match" then drawMixer()
    elseif page=="Presets" then drawPresets()
    else drawSettings() end
    if toastAt>os.clock() and toastText~="" then
       local w=math.min(340,math.max(150,measureW(toastText,12,FONT)+24))
       box(W.w-w-24,12,w,32,C.panel2,8,20)
       label(fit(toastText,w-24,12,FONT),W.w-w-12,21,12,C.light,false,21)
    end
end
local function contains(mx,my,item)
    return mx>=W.x+item.x and my>=W.y+item.y
       and mx<W.x+item.x+item.w and my<W.y+item.y+item.h
end
local HEADER_DRAG_HEIGHT=64   
local function mouseDown(mx,my)
    for i=#hits,1,-1 do
        local item=hits[i]
        if contains(mx,my,item) then
             
             
             
            if item.role=="search" or item.role=="preset" then
                setGameInputEnabled(false)
            end
             
             
            if edit and item.role~=edit and item.role~="search" and item.role~="preset" then blur() end
            item.func()
            return
        end
    end
    if edit then blur();drawFrame() end
     
     
    if mx>=W.x and mx<W.x+W.w and my>=W.y and my<W.y+HEADER_DRAG_HEIGHT then
        drag={type="move",dx=mx-W.x,dy=my-W.y};return
    end
    if mx>=W.x+W.w-24 and my>=W.y+W.h-24 and mx<W.x+W.w and my<W.y+W.h then
        drag={type="resize",x=mx,y=my,w=W.w,h=W.h};return
    end
end
local function updateMouse()
    local ok,mx,my=pcall(function() return UI_Mouse.X,UI_Mouse.Y end)
    if not ok then return end
     
     
     
    local inField=false
    local insideUI=W.show and mx>=W.x and mx<W.x+W.w and my>=W.y and my<W.y+W.h
    if insideUI then
        for i=#hits,1,-1 do
            local item=hits[i]
            if (item.role=="search" or item.role=="preset") and contains(mx,my,item) then
                inField=true
                break
            end
        end
    end
    if not inField then hoverArmed=true end
     
     
    if edit and not insideUI then
        blur()
        drawFrame()
    end
    local wantHover=inField and hoverArmed
    if hoveringTextField~=wantHover then
        hoveringTextField=wantHover
        maintainInputGate(false)
    end
    local now=repeatDown(1)
     
    local mo,md=pcall(ismouse1pressed)
    if mo then now=md==true end
    if now and not mouseWasDown then mouseDown(mx,my) end
    if drag and now then
        if drag.type=="move" then
            local nx=math.max(0,math.min(screenW-W.w,math.floor(mx-drag.dx)))
            local ny=math.max(0,math.min(screenH-W.h,math.floor(my-drag.dy)))
            if W.x~=nx or W.y~=ny then W.x,W.y=nx,ny;shiftFrame() end
        end
    elseif drag and not now then
        if drag.type=="resize" then
            W.w=math.max(math.min(760,screenW-W.x),math.min(screenW-W.x,drag.w+mx-drag.x))
            W.h=math.max(math.min(520,screenH-W.y),math.min(screenH-W.y,drag.h+my-drag.y))
            drawFrame()
        end
        drag=nil;savePrefs()
    end
    mouseWasDown=now
end
local f4was=false
local homeWas=false
local ctrlFWas=false
local function toggle()
    W.show=not W.show
    if not W.show then blur();drag=nil;hoveringTextField=false end
    maintainInputGate(true)
    drawFrame()
end
_G.MatchaMarketplaceUI={
    Stop=function()
        alive=false;blur();hoveringTextField=false
         
        releaseGameInput()
        for _,p in ipairs(pool) do pcall(function()p.o:Remove()end) end
        pcall(function()measure:Remove()end)
        pool={}
        _G.MatchaMarketplaceUI=nil
    end,
    Open=function() W.show=true;maintainInputGate(true);drawFrame() end,
    Close=function() W.show=false;blur();hoveringTextField=false;maintainInputGate(true);drawFrame() end,
    SetSearch=function(s) search=tostring(s or ""):sub(1,74);queryCursor=#search;pageNo=1;drawFrame()end,
    GoTo=function(p)
        if p=="Discover" then p="Library" end
        for _,v in ipairs(UI_PAGES) do if p==v then choosePage(p);return end end
    end,
    Refresh=function()
        local ok=loadPacks()
        if not lookup[selected] then selected=nil end
        drawFrame();return ok
    end,
    Status=function()return {count=#packs,page=page,visible=W.show,selected=selected,
        search=search,inputCapture=captureState,inputGateCalls=gateCalls,inputGateFailures=gateFailures}end,
    FocusSearch=function() focus("search") end,
    HandleKey=function(vk) handleEdit(vk) end,
}
drawFrame()
maintainInputGate(true)  
task.spawn(function()
    while alive do
        maintainInputGate(false)  
        local okLoop,loopError=pcall(function()
            local focused=true
            local ok,val=pcall(isrbxactive)
            if ok then focused=val end
            local f4=repeatDown(115)
            if f4 and not f4was and focused then toggle() end
            f4was=f4
            if W.show and focused then
                updateMouse()
                if edit then pollKeys(os.clock()) end
                local home=repeatDown(36)
                if home and not homeWas and not edit then
                    getScreen()
                    W.x=math.max(0,math.floor((screenW-W.w)/2))
                    W.y=math.max(0,math.floor((screenH-W.h)/2))
                    savePrefs();drawFrame()
                end
                homeWas=home
                local quick=ctrl() and repeatDown(70)
                if quick and not ctrlFWas and page~="Settings" and page~="Presets" then focus("search") end
                ctrlFWas=quick
            end
        end)
        if not okLoop then
            warn("[Stance] UI loop error; restoring Roblox keyboard input: "..tostring(loopError))
            blur()
            releaseGameInput()
            alive=false
            break
        end
        task.wait(0.017)
    end
end)

end
startStanceUI()

 
task.spawn(function()
    task.wait(0.1)
    while market.enabled do
        local bridgeOK,bridgeError=pcall(marketBridgePoll)
        if not bridgeOK then warn("[AnimationMarketplace] Dumper feed sync: "..tostring(bridgeError)) end
        local job=table.remove(market.queue,1)
        if job then
            local ok,result=pcall(function()
                if job.kind=="refresh" then marketStartScan(false)
                elseif job.kind=="import" then marketBridgePoll(true)
                elseif job.kind=="more" then marketStartScan(true)
                elseif job.kind=="resolve" then marketResolve(job.pack)
                elseif job.kind=="apply" then marketApply(job.pack,job.category)
                elseif job.kind=="variant" then marketCycleIdleAlternative(job.pack,job.category)
                elseif job.kind=="qa" then marketMarkQA(job.pack,job.category.category,job.category.result) end
            end)
            if not ok then warn("[AnimationMarketplace] "..tostring(result)) end
        elseif market.scanning and tick()>=market.nextPage then
            local ok,result=pcall(marketScanPage)
            if not ok then warn("[AnimationMarketplace] "..tostring(result)) end
        end
        task.wait(0.1)
    end
end)
while true do task.wait() end
