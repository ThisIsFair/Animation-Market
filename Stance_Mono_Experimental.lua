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
        favs = {}, presets = {}, recent = {}, mix = {}, equipped = nil,
        autoReapply = true, wheelMode = "both", binds = {},
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
    for _, k in ipairs({"favs", "presets", "recent", "mix", "binds"}) do
        if type(State[k]) ~= "table" then State[k] = {} end
    end
    State.w = math.max(MIN_W, tonumber(State.w) or d.w)
    State.h = math.max(MIN_H, tonumber(State.h) or d.h)
    State.scale   = 1
    State.opacity = math.clamp(tonumber(State.opacity) or 1, 0.4, 1)
    State.textSize = math.clamp(tonumber(State.textSize) or 14, 11, 18)
    if State.wheelMode ~= "both" and State.wheelMode ~= "favs" and State.wheelMode ~= "presets" then State.wheelMode = "both" end
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
local WHITE = {255, 255, 255}
local GOOD  = {82, 210, 140}
local WARN  = {250, 190, 70}
local BAD   = {244, 104, 116}
local THEMES = {
    Mono = {
        bg = {0, 0, 0},      side = {0, 0, 0},    card = {0, 0, 0},    ctl = {20, 20, 20},  ctlHi = {34, 34, 34},
        line = {44, 44, 44}, input = {0, 0, 0},   accent = {255, 255, 255},
        text = {244, 244, 244}, sub = {158, 158, 158}, mute = {98, 98, 98},
    },
    Purple = {
        bg = {14, 11, 22},  side = {19, 15, 31}, card = {25, 20, 40}, ctl = {37, 30, 60}, ctlHi = {49, 41, 80},
        line = {54, 45, 84}, input = {16, 12, 27}, accent = {139, 92, 246},
        text = {236, 232, 248}, sub = {166, 156, 196}, mute = {104, 96, 134},
    },
    Dark = {
        bg = {13, 13, 14},  side = {19, 19, 21}, card = {25, 25, 28}, ctl = {37, 37, 41}, ctlHi = {49, 49, 55},
        line = {46, 46, 52}, input = {15, 15, 17}, accent = {96, 156, 248},
        text = {232, 232, 236}, sub = {152, 152, 162}, mute = {92, 92, 102},
    },
    Midnight = {
        bg = {8, 11, 20},   side = {12, 16, 29}, card = {17, 22, 38}, ctl = {27, 35, 58}, ctlHi = {37, 47, 76},
        line = {36, 46, 70}, input = {10, 13, 24}, accent = {45, 190, 220},
        text = {218, 230, 242}, sub = {132, 150, 172}, mute = {70, 86, 110},
    },
}
local ACCENTS = {
    {139, 92, 246}, {96, 156, 248}, {45, 190, 220}, {82, 210, 140}, {250, 150, 70}, {240, 96, 146},
}
local c3 = {}
local function C(c)
    local k = c[1] * 65536 + c[2] * 256 + c[3]
    local v = c3[k]
    if not v then v = Color3.fromRGB(c[1], c[2], c[3]); c3[k] = v end
    return v
end
local function mix(a, b, t)
    return {
        math.floor(a[1] + (b[1] - a[1]) * t + 0.5),
        math.floor(a[2] + (b[2] - a[2]) * t + 0.5),
        math.floor(a[3] + (b[3] - a[3]) * t + 0.5),
    }
end
local TH = {}
local function buildTheme()
    local base = THEMES[State.theme] or THEMES.Mono
    local t = {}
    for k, v in pairs(base) do t[k] = v end
    if State.accent and State.accent > 0 and ACCENTS[State.accent] then t.accent = ACCENTS[State.accent] end
    t.accentHi   = mix(t.accent, WHITE, 0.2)
    t.accentTint = mix(t.side, t.accent, 0.26)
    local lum = (0.299 * t.accent[1] + 0.587 * t.accent[2] + 0.114 * t.accent[3]) / 255
    t.onAccent   = (lum > 0.6) and { 0, 0, 0 } or WHITE
    t.goodLine   = mix(t.line, GOOD, 0.55)
    t.good, t.warn, t.bad = GOOD, WARN, BAD
    t.goodTint = mix(t.card, GOOD, 0.18)
    t.warnTint = mix(t.card, WARN, 0.18)
    t.badTint  = mix(t.card, BAD, 0.2)
    t.badHi    = mix(BAD, WHITE, 0.15)
    t.rowHover = mix(t.card, t.ctl, 0.55)
    t.rowIn    = mix(t.card, t.ctl, 0.45)
    t.lineHi   = mix(t.line, t.text, 0.25)
    t.onSeg    = mix(t.ctl, GOOD, 0.3)
    TH = t
end
buildTheme()
local OX, OY, S = 0, 0, 1
local FS = 14
local Pool = { sq = {}, tx = {}, ln = {}, tr = {} }
local Idx  = { sq = 0, tx = 0, ln = 0, tr = 0 }
local HAS_CORNER, HAS_FONTSIZE = nil, nil
local function alphaOf(a)
    local t = State.opacity * (a or 1)
    if ALPHA_INVERTED then t = 1 - t end
    return t
end
local function nextSquare()
    Idx.sq = Idx.sq + 1
    local e = Pool.sq[Idx.sq]
    if not e then
        local o = Drawing.new("Square")
        o.Filled = true
        o.Visible = false
        if HAS_CORNER == nil then HAS_CORNER = pcall(function() o.Corner = 0 end) end
        e = { o = o }
        Pool.sq[Idx.sq] = e
    end
    return e
end
local function nextText()
    Idx.tx = Idx.tx + 1
    local e = Pool.tx[Idx.tx]
    if not e then
        local o = Drawing.new("Text")
        o.Outline = false
        o.Visible = false
        if HAS_FONTSIZE == nil then HAS_FONTSIZE = pcall(function() o.FontSize = 14 end) end
        e = { o = o }
        Pool.tx[Idx.tx] = e
    end
    return e
end
local function rect(x, y, w, h, col, z, r, a, force)
    local e = nextSquare()
    local o = e.o
    local px = round(OX + x * S)
    local py = round(OY + y * S)
    local pw = math.max(1, round(OX + (x + w) * S) - px)
    local ph = math.max(1, round(OY + (y + h) * S) - py)
    if e.px ~= px or e.py ~= py then o.Position = Vector2.new(px, py); e.px = px; e.py = py end
    if e.pw ~= pw or e.ph ~= ph then o.Size = Vector2.new(pw, ph); e.pw = pw; e.ph = ph end
    local c = C(col)
    if e.c ~= c then o.Color = c; e.c = c end
    local zz = z or 1
    if e.z ~= zz then o.ZIndex = zz; e.z = zz end
    local tr = alphaOf(a)
    if e.a ~= tr then o.Transparency = tr; e.a = tr end
    if HAS_CORNER then
        local cr = 0
        if (State.rounded or force) and r and r > 0 then
            cr = math.min(round(r * S), math.floor(math.min(pw, ph) / 2))
        end
        if e.r ~= cr then o.Corner = cr; e.r = cr end
    end
    if not e.v then o.Visible = true; e.v = true end
end
local function txt(str, x, y, size, col, z, center, bold, a)
    str = tostring(str)
    local e = nextText()
    local o = e.o
    local fs = math.max(8, round(size * S))
    local px = round(OX + x * S)
    local cy = OY + y * S + TEXT_DY
    local py
    if center and CENTER_BOTH_AXES then py = round(cy) else py = round(cy - fs * 0.5) end
    if e.t ~= str then o.Text = str; e.t = str end
    if e.px ~= px or e.py ~= py then o.Position = Vector2.new(px, py); e.px = px; e.py = py end
    if e.fs ~= fs then
        o.Size = fs
        if HAS_FONTSIZE then o.FontSize = fs end
        e.fs = fs
    end
    local f = bold and FONT_BOLD or FONT_REG
    if e.f ~= f then o.Font = f; e.f = f end
    local cen = center and true or false
    if e.cen ~= cen then o.Center = cen; e.cen = cen end
    local c = C(col)
    if e.c ~= c then o.Color = c; e.c = c end
    local zz = z or 14
    if e.z ~= zz then o.ZIndex = zz; e.z = zz end
    local tr = alphaOf(a)
    if e.a ~= tr then o.Transparency = tr; e.a = tr end
    if not e.v then o.Visible = true; e.v = true end
end
local function nextLine()
    Idx.ln = Idx.ln + 1
    local e = Pool.ln[Idx.ln]
    if not e then
        local o = Drawing.new("Line")
        o.Visible = false
        e = { o = o }
        Pool.ln[Idx.ln] = e
    end
    return e
end
local function line(x1, y1, x2, y2, thick, col, z, a)
    local e = nextLine()
    local o = e.o
    local ax, ay = round(OX + x1 * S), round(OY + y1 * S)
    local bx, by = round(OX + x2 * S), round(OY + y2 * S)
    if e.ax ~= ax or e.ay ~= ay then o.From = Vector2.new(ax, ay); e.ax = ax; e.ay = ay end
    if e.bx ~= bx or e.by ~= by then o.To = Vector2.new(bx, by); e.bx = bx; e.by = by end
    local th = math.max(1, round(thick * S))
    if e.th ~= th then o.Thickness = th; e.th = th end
    local c = C(col)
    if e.c ~= c then o.Color = c; e.c = c end
    local zz = z or 1
    if e.z ~= zz then o.ZIndex = zz; e.z = zz end
    local tr = alphaOf(a)
    if e.a ~= tr then o.Transparency = tr; e.a = tr end
    if not e.v then o.Visible = true; e.v = true end
end
local function nextTri()
    Idx.tr = Idx.tr + 1
    local e = Pool.tr[Idx.tr]
    if not e then
        local o = Drawing.new("Triangle")
        o.Filled = true
        o.Visible = false
        e = { o = o }
        Pool.tr[Idx.tr] = e
    end
    return e
end
local function tri(ax, ay, bx, by, cx, cy, col, z, a)
    local e = nextTri()
    local o = e.o
    local x1, y1 = round(OX + ax * S), round(OY + ay * S)
    local x2, y2 = round(OX + bx * S), round(OY + by * S)
    local x3, y3 = round(OX + cx * S), round(OY + cy * S)
    if e.x1 ~= x1 or e.y1 ~= y1 then o.PointA = Vector2.new(x1, y1); e.x1 = x1; e.y1 = y1 end
    if e.x2 ~= x2 or e.y2 ~= y2 then o.PointB = Vector2.new(x2, y2); e.x2 = x2; e.y2 = y2 end
    if e.x3 ~= x3 or e.y3 ~= y3 then o.PointC = Vector2.new(x3, y3); e.x3 = x3; e.y3 = y3 end
    local c = C(col)
    if e.c ~= c then o.Color = c; e.c = c end
    local zz = z or 1
    if e.z ~= zz then o.ZIndex = zz; e.z = zz end
    local tr = alphaOf(a)
    if e.a ~= tr then o.Transparency = tr; e.a = tr end
    if not e.v then o.Visible = true; e.v = true end
end
local function beginFrame()
    Idx.sq = 0
    Idx.tx = 0
    Idx.ln = 0
    Idx.tr = 0
end
local function endFrame()
    for i = Idx.sq + 1, #Pool.sq do
        local e = Pool.sq[i]
        if e.v then e.o.Visible = false; e.v = false end
    end
    for i = Idx.tx + 1, #Pool.tx do
        local e = Pool.tx[i]
        if e.v then e.o.Visible = false; e.v = false end
    end
    for i = Idx.ln + 1, #Pool.ln do
        local e = Pool.ln[i]
        if e.v then e.o.Visible = false; e.v = false end
    end
    for i = Idx.tr + 1, #Pool.tr do
        local e = Pool.tr[i]
        if e.v then e.o.Visible = false; e.v = false end
    end
end
local function tw(s, size) return #s * size * CHAR_W end
local function fit(s, maxW, size)
    if maxW <= 0 then return "" end
    if tw(s, size) <= maxW then return s end
    local n = math.max(1, math.floor(maxW / (size * CHAR_W)) - 2)
    return s:sub(1, n) .. ".."
end
local function tail(s, maxW, size)
    if tw(s, size) <= maxW then return s end
    local n = math.max(1, math.floor(maxW / (size * CHAR_W)))
    return s:sub(-n)
end
local Mouse = { x = 0, y = 0, lx = 0, ly = 0, down = false, clicked = false }
local UI = {
    visible = true, page = "Home",
    bSearch = "", bPage = 1, bSort = "name",
    fSearch = "", fPage = 1,
    mixSel = "Idle", mSearch = "", mPage = 1,
    pSearch = "", pName = "", pRename = "", pSel = nil, pRenaming = false, pPage = 1,
    delConfirm = nil, jump = "",
    focus = nil, focusGrace = 0,
    toasts = {}, buttons = {}, inputs = {}, prevInputs = {}, prevButtons = {},
    dragging = false, resizing = false, dx = 0, dy = 0, rx = 0, ry = 0,
    busyUntil = 0, tipId = nil, tipSince = 0, tipText = nil,
    caches = {}, favVer = 0, recentVer = 0,
    W = 740, H = 540, W0 = 740,
    binding = nil, bindGuard = 0,
}
local function toast(msg, kind)
    UI.toasts[#UI.toasts + 1] = { msg = msg, kind = kind or "info", life = 2.6 }
    if #UI.toasts > 3 then table.remove(UI.toasts, 1) end
end
local CAS_NAME = "StanceTypingSink"
local casBound = false
local casRetryAt = 0
local casEvents = 0
local casWarned = false
local function casSet(on)
    if not on then
        if casBound then
            pcall(function() game:GetService("ContextActionService"):UnbindAction(CAS_NAME) end)
            casBound = false
        end
        casRetryAt = 0
        casWarned = false
        return
    end
    if casBound or tick() < casRetryAt then return end
    casRetryAt = tick() + 0.6
    local ok = pcall(function()
        local cas = game:GetService("ContextActionService")
        local K = Enum.KeyCode
        cas:BindActionAtPriority(CAS_NAME, function()
            casEvents = casEvents + 1
            return Enum.ContextActionResult.Sink
        end, false, 1000000, K.W, K.A, K.S, K.D, K.Space, K.Up, K.Down, K.Left, K.Right)
    end)
    casBound = ok
end
local inputBlocked = false
local inputChanged = 0
local inputSent = nil
local inputSetErrors = 0
local inputSetCalls = 0
local inputHover = false
local function syncInput(force)
    local hovered = UI.visible and Mouse.x >= OX and Mouse.x <= OX + UI.W * S
        and Mouse.y >= OY and Mouse.y <= OY + UI.H * S
    local focused = UI.visible and (UI.focus ~= nil or UI.binding ~= nil)
    local captured = focused or hovered or UI.wheelOpen == true
    local toGame = not captured
    inputHover = hovered
    if force or inputSent ~= toGame then
        if type(setrobloxinput) == "function" then
            local ok, reason = pcall(setrobloxinput, toGame)
            inputSetCalls = inputSetCalls + 1
            if ok then
                inputSent = toGame
                inputBlocked = captured
                inputChanged = tick()
            else
                inputSetErrors = inputSetErrors + 1
                if inputSetErrors <= 3 then warn("[Stance Dev] Input forwarding: " .. tostring(reason)) end
            end
        elseif inputSetErrors == 0 then
            inputSetErrors = 1
            warn("[Stance Dev] Matcha setrobloxinput unavailable; typing may move the character")
        end
    end
    casSet(focused)
end
local function blur()
    UI.focus = nil
    UI.focusGrace = 0
    syncInput(true)
end
local function focusInput(id)
    if UI.focus == id then
        blur()
        return
    end
    UI.focus = id
    UI.focusGrace = 2
    syncInput(true)
end
local SLOTS = {"Idle", "Walk", "Run", "Jump", "Fall", "Climb", "Swim", "SwimIdle"}
local SLOT_LABEL = {
    Idle = "Idle", Walk = "Walk", Run = "Run", Jump = "Jump",
    Fall = "Fall", Climb = "Climb", Swim = "Swim", SwimIdle = "Swim Idle",
}
local PACKS, PACK_BY_ID = {}, {}
local CATALOG_FILE = "SpooferConfig/MarketplaceResolved.json"
local CATALOG_URL = "https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/SpooferConfig/MarketplaceResolved.json"
local ENGINE_URL = "https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Animation_Engine.lua"
local catalogError = nil
local engineError = nil
local engine = nil
local function catalogRead(raw)
    local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok and type(data) == "table" and type(data.packs) == "table" then return data end
    return nil
end
local catalogData = nil
pcall(function()
    if isfile(CATALOG_FILE) then catalogData = catalogRead(readfile(CATALOG_FILE)) end
end)
if not catalogData then
    local ok, body = pcall(httpget, CATALOG_URL)
    if ok and type(body) == "string" and #body > 0 then
        catalogData = catalogRead(body)
        if catalogData then pcall(function() writefile(CATALOG_FILE, body) end) end
    end
end
if catalogData then
    for bundle, record in pairs(catalogData.packs) do
        if type(record) == "table" and type(record.rows) == "table" then
            local anims = {}
            local count = 0
            for _, row in ipairs(record.rows) do
                if type(row) == "table" then
                    local slot = tostring(row[1] or ""):lower():gsub("[^%a%d]", "")
                    local id = tostring(row[3] or "")
                    for _, name in ipairs(SLOTS) do
                        if slot == name:lower() and id:match("^%d+$") then
                            if anims[name] == nil then anims[name] = id; count = count + 1 end
                            break
                        end
                    end
                end
            end
            if count > 0 then
                local id = tostring(record.bundleId or bundle)
                local p = { id = id, name = tostring(record.name or record.menuName or ("Bundle " .. id)),
                    states = count, maxStates = 8, anims = anims, rows = record.rows }
                p._ln = p.name:lower()
                PACKS[#PACKS + 1] = p
                PACK_BY_ID[p.id] = p
            end
        end
    end
    table.sort(PACKS, function(a, b) if a._ln == b._ln then return a.id < b.id end return a._ln < b._ln end)
else
    catalogError = "Animation catalog unavailable; place MarketplaceResolved.json in SpooferConfig"
end
if type(_G.StanceEngineUnload) == "function" then pcall(_G.StanceEngineUnload) end
if type(httpget) == "function" and type(loadstring) == "function" then
    local ok, reason = pcall(function()
        local body = httpget(ENGINE_URL)
        assert(type(body) == "string" and #body > 1000, "Engine download failed")
        loadstring(body)()
        engine = _G.StanceAnimationEngine
        assert(type(engine) == "table" and type(engine.ApplyRows) == "function", "Engine failed to initialize")
    end)
    if not ok then engineError = tostring(reason) end
else
    engineError = "Matcha HTTP/loadstring is unavailable"
end
local function invokeEngine(method, payload)
    assert(engine and type(engine[method]) == "function", engineError or "Animation engine unavailable")
    local ok, reason = engine[method](payload)
    assert(ok, tostring(reason or "Animation engine rejected the operation"))
    return true
end
local function applyToGame(kind, payload)
    if kind == "pack" then
        assert(type(payload) == "table" and type(payload.rows) == "table", "Pack mapping unavailable")
        return invokeEngine("ApplyRows", payload.rows)
    elseif kind == "mix" then
        local states = {}
        for slot, packId in pairs(payload or {}) do
            local p = PACK_BY_ID[tostring(packId)]
            if p and type(p.rows) == "table" then
                local target = slot:lower()
                local ids = {}
                for _, row in ipairs(p.rows) do
                    if type(row) == "table" and tostring(row[1]):lower() == target then
                        ids[#ids + 1] = row[3]
                    end
                end
                if #ids > 0 then states[target] = ids end
            end
        end
        return invokeEngine("ApplyStateIds", states)
    elseif kind == "restore" then
        return invokeEngine("Restore")
    end
    assert(false, "Unknown animation operation")
end
local function missingOf(p)
    local m = {}
    for _, slot in ipairs(SLOTS) do
        if not p.anims[slot] then m[#m + 1] = SLOT_LABEL[slot] end
    end
    return m
end
local function mixCount()
    local n = 0
    for _, slot in ipairs(SLOTS) do if State.mix[slot] then n = n + 1 end end
    return n
end
local function isFav(id)
    for _, f in ipairs(State.favs) do if f == id then return true end end
    return false
end
local function toggleFav(id)
    UI.favVer = UI.favVer + 1
    markDirty()
    for i, f in ipairs(State.favs) do
        if f == id then table.remove(State.favs, i); return false end
    end
    table.insert(State.favs, 1, id)
    return true
end
local function newId() return tostring(math.floor(tick() * 1000)) .. tostring(math.random(100, 999)) end
local function copySlots(src)
    local t = {}
    for _, slot in ipairs(SLOTS) do t[slot] = src[slot] end
    return t
end
local function equippedLabel()
    if State.equipped == "mix" then return "Custom mix " .. mixCount() .. "/8" end
    local p = State.equipped and PACK_BY_ID[State.equipped]
    return p and p.name or nil
end
local function currentSnap()
    local m = nil
    if State.equipped == "mix" and State.appliedMix then m = copySlots(State.appliedMix) end
    return { eq = State.equipped, mix = m }
end
local function sameSnap(a, b)
    if a.eq ~= b.eq then return false end
    if a.eq == "mix" then
        for _, slot in ipairs(SLOTS) do
            if (a.mix and a.mix[slot]) ~= (b.mix and b.mix[slot]) then return false end
        end
    end
    return true
end
local function snapLabel(snap)
    if snap.eq == nil then return "default animations" end
    if snap.eq == "mix" then return "your mix" end
    local p = PACK_BY_ID[snap.eq]
    return p and p.name or "previous animation"
end
local function applySnap(snap)
    local ok, err
    if snap.eq == nil then
        ok, err = pcall(applyToGame, "restore", nil)
        if ok then State.equipped = nil; State.appliedMix = nil end
    elseif snap.eq == "mix" then
        local m = snap.mix or State.mix
        ok, err = pcall(applyToGame, "mix", m)
        if ok then State.equipped = "mix"; State.appliedMix = copySlots(m) end
    else
        local p = PACK_BY_ID[snap.eq]
        if not p then return false end
        ok, err = pcall(applyToGame, "pack", p)
        if ok then State.equipped = p.id; State.appliedMix = nil end
    end
    if not ok then toast("Could not apply: " .. tostring(err), "bad"); return false end
    markDirty()
    return true
end
local function equipPack(p)
    if tick() < UI.busyUntil then return false end
    UI.busyUntil = tick() + 0.35
    local before = currentSnap()
    local ok, err = pcall(applyToGame, "pack", p)
    if not ok then toast("Could not apply: " .. tostring(err), "bad"); return false end
    State.equipped = p.id
    State.appliedMix = nil
    if not sameSnap(before, currentSnap()) then State.undo = before end
    for i = #State.recent, 1, -1 do
        if State.recent[i] == p.id then table.remove(State.recent, i) end
    end
    table.insert(State.recent, 1, p.id)
    if #State.recent > 12 then table.remove(State.recent) end
    UI.recentVer = UI.recentVer + 1
    markDirty()
    local miss = missingOf(p)
    if #miss > 0 then toast("Equipped " .. p.name .. " (missing " .. table.concat(miss, ", ") .. ")", "warn")
    else toast("Equipped " .. p.name, "good") end
    return true
end
local function applyMix()
    local n = mixCount()
    if n == 0 then toast("Assign at least one state first", "bad"); return false end
    if tick() < UI.busyUntil then return false end
    UI.busyUntil = tick() + 0.35
    local before = currentSnap()
    local ok, err = pcall(applyToGame, "mix", State.mix)
    if not ok then toast("Could not apply: " .. tostring(err), "bad"); return false end
    State.equipped = "mix"
    State.appliedMix = copySlots(State.mix)
    if not sameSnap(before, currentSnap()) then State.undo = before end
    markDirty()
    toast("Mix applied (" .. n .. "/8 states)", "good")
    return true
end
local function restoreDefaults()
    local before = currentSnap()
    local ok, err = pcall(applyToGame, "restore", nil)
    if not ok then toast("Restore failed: " .. tostring(err), "bad"); return false end
    State.equipped = nil
    State.appliedMix = nil
    if before.eq ~= nil then State.undo = before end
    markDirty()
    toast("Default animations restored", "info")
    return true
end
local function reapply(silent)
    if State.equipped == nil then
        if not silent then toast("Nothing equipped to reapply", "info") end
        return false
    end
    local ok = applySnap(currentSnap())
    if ok and not silent then toast("Reapplied " .. (equippedLabel() or ""), "good") end
    return ok
end
local function undoLast()
    if tick() < UI.busyUntil then return end
    local target = State.undo
    if not target then toast("Nothing to undo", "info"); return end
    UI.busyUntil = tick() + 0.35
    local cur = currentSnap()
    if applySnap(target) then
        State.undo = cur
        toast("Back to " .. snapLabel(target), "good")
    end
end
local function cycleFavorite(dir)
    local list = {}
    for _, id in ipairs(State.favs) do
        local p = PACK_BY_ID[id]
        if p then list[#list + 1] = p end
    end
    if #list == 0 then toast("No favorites saved yet", "info"); return end
    local idx = 0
    for i, p in ipairs(list) do
        if p.id == State.equipped then idx = i; break end
    end
    local nxt
    if idx == 0 then nxt = (dir > 0) and 1 or #list
    else nxt = ((idx - 1 + dir) % #list) + 1 end
    equipPack(list[nxt])
end
local function getList(kind)
    local search = (kind == "b") and UI.bSearch or UI.fSearch
    local sort = (kind == "b") and UI.bSort or "saved"
    local key = search .. "|" .. sort .. "|" .. UI.favVer .. "|" .. UI.recentVer
    local c = UI.caches[kind]
    if c and c.key == key then return c.list end
    local s = search:lower()
    local src
    if kind == "b" then
        src = PACKS
    else
        src = {}
        for _, id in ipairs(State.favs) do
            local p = PACK_BY_ID[id]
            if p then src[#src + 1] = p end
        end
    end
    local list = {}
    for _, p in ipairs(src) do
        if s == "" or p._ln:find(s, 1, true) then list[#list + 1] = p end
    end
    if sort == "name" then
        table.sort(list, function(a, b) if a._ln == b._ln then return a.id < b.id end return a._ln < b._ln end)
    elseif sort == "recent" then
        local rm = {}
        for i, id in ipairs(State.recent) do rm[id] = i end
        table.sort(list, function(a, b)
            local ra, rb = rm[a.id] or 9999, rm[b.id] or 9999
            if ra == rb then return a._ln < b._ln end
            return ra < rb
        end)
    end
    UI.caches[kind] = { key = key, list = list }
    return list
end
local function getMixList()
    local key = UI.mixSel .. "|" .. UI.mSearch
    local c = UI.caches.m
    if c and c.key == key then return c.list end
    local s = UI.mSearch:lower()
    local list = {}
    for _, p in ipairs(PACKS) do
        if p.anims[UI.mixSel] and (s == "" or p._ln:find(s, 1, true)) then
            list[#list + 1] = p
        end
    end
    table.sort(list, function(a, b) return a._ln < b._ln end)
    UI.caches.m = { key = key, list = list }
    return list
end
local function circle(cx, cy, r, col, z, a)
    rect(cx - r, cy - r, r * 2, r * 2, col, z, r, a, true)
end
local function pill(x, y, w, h, border, fill, z, a)
    rect(x, y, w, h, border, z, h / 2, a)
    rect(x + 1, y + 1, w - 2, h - 2, fill, z + 1, h / 2 - 1, a)
end
local function card(x, y, w, h, r, z, state, fill)
    local border, f = TH.line, fill or TH.card
    if state == "hov" then border = TH.lineHi; f = TH.rowHover
    elseif state == "sel" then border = TH.text; f = TH.rowHover end
    rect(x, y, w, h, border, z, r)
    rect(x + 1, y + 1, w - 2, h - 2, f, z + 1, math.max(0, r - 1))
end
local function icon(name, cx, cy, col, z)
    local T = 1.6
    local function ln(x1, y1, x2, y2) line(cx + x1, cy + y1, cx + x2, cy + y2, T, col, z) end
    local function dot(x, y, r) circle(cx + x, cy + y, r, col, z) end
    if name == "home" then
        ln(-9, 0, 0, -9); ln(0, -9, 9, 0); ln(-6, -3, -6, 8); ln(6, -3, 6, 8); ln(-6, 8, 6, 8)
        ln(-2, 8, -2, 3); ln(2, 8, 2, 3); ln(-2, 3, 2, 3)
    elseif name == "list" then
        ln(-3, -6, 9, -6); ln(-3, 0, 9, 0); ln(-3, 6, 9, 6)
        dot(-8, -6, 1.6); dot(-8, 0, 1.6); dot(-8, 6, 1.6)
    elseif name == "star" then
        local pts = {}
        for i = 0, 9 do
            local r = (i % 2 == 0) and 10 or 4.3
            local a = -math.pi / 2 + i * math.pi / 5
            pts[#pts + 1] = { r * math.cos(a), r * math.sin(a) + 1 }
        end
        for i = 1, 10 do
            local p, q = pts[i], pts[i % 10 + 1]
            ln(p[1], p[2], q[1], q[2])
        end
    elseif name == "layers" then
        ln(0, -10, 10, -5); ln(10, -5, 0, 0); ln(0, 0, -10, -5); ln(-10, -5, 0, -10)
        ln(-10, 0, 0, 5); ln(0, 5, 10, 0); ln(-10, 5, 0, 10); ln(0, 10, 10, 5)
    elseif name == "bookmark" then
        ln(-6, -9, 6, -9); ln(-6, -9, -6, 9); ln(6, -9, 6, 9); ln(-6, 9, 0, 4); ln(0, 4, 6, 9)
    elseif name == "keys" then
        ln(-10, -6, 10, -6); ln(10, -6, 10, 6); ln(10, 6, -10, 6); ln(-10, 6, -10, -6)
        dot(-5, -2, 1.3); dot(0, -2, 1.3); dot(5, -2, 1.3); ln(-5, 3, 5, 3)
    elseif name == "sliders" then
        ln(-10, -4, 10, -4); ln(-10, 4, 10, 4)
        circle(cx - 3, cy - 4, 3.6, col, z); circle(cx - 3, cy - 4, 2, TH.bg, z + 1)
        circle(cx + 4, cy + 4, 3.6, col, z); circle(cx + 4, cy + 4, 2, TH.bg, z + 1)
    elseif name == "close" then
        ln(-5, -5, 5, 5); ln(-5, 5, 5, -5)
    elseif name == "panel" then
        ln(-7, -5, 7, -5); ln(7, -5, 7, 5); ln(7, 5, -7, 5); ln(-7, 5, -7, -5); ln(1, -5, 1, 5)
    end
end
local function hit(x, y, w, h)
    if UI.dragging or UI.resizing then return false end
    local mx, my = Mouse.lx, Mouse.ly
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end
local function reg(x, y, w, h, id, fn, tip, isInput)
    UI.buttons[#UI.buttons + 1] = { x = x, y = y, w = w, h = h, id = id, fn = fn, tip = tip, isInput = isInput }
end
local function button(x, y, w, h, label, id, fn, style, z, tip, size)
    style = style or "soft"
    z = z or 20
    local hov = fn ~= nil and hit(x, y, w, h)
    local tcol = TH.text
    if style == "primary" then
        rect(x, y, w, h, hov and TH.accentHi or TH.accent, z + 1, h / 2); tcol = TH.onAccent
    elseif style == "soft" then
        pill(x, y, w, h, hov and TH.lineHi or TH.line, hov and TH.ctl or TH.bg, z)
    elseif style == "ghost" then
        if hov then rect(x, y, w, h, TH.ctl, z + 1, h / 2) end
        tcol = hov and TH.text or TH.sub
    elseif style == "danger" then
        if hov then rect(x, y, w, h, TH.badTint, z + 1, h / 2) end
        tcol = TH.bad
    elseif style == "dangerSolid" then
        rect(x, y, w, h, hov and TH.badHi or TH.bad, z + 1, h / 2); tcol = WHITE
    elseif style == "good" then
        pill(x, y, w, h, TH.goodLine, TH.bg, z); tcol = TH.good
    elseif style == "accent" then
        pill(x, y, w, h, hov and TH.text or TH.sub, hov and TH.ctl or TH.bg, z)
    else
        tcol = TH.mute
    end
    txt(label, x + w / 2, y + h / 2, size or (FS - 1), tcol, z + 3, true, false)
    if fn or tip then reg(x, y, w, h, id, fn, tip) end
end
local function input(x, y, w, h, tbl, key, id, placeholder, z, onChange, onEnter)
    z = z or 20
    local focused = UI.focus == id
    local hov = hit(x, y, w, h)
    pill(x, y, w, h, focused and TH.text or (hov and TH.lineHi or TH.line), TH.input, z)
    local val = tbl[key]
    local hasClear = val ~= ""
    local maxW = w - 36 - (hasClear and 24 or 0)
    if val == "" and not focused then
        txt(placeholder, x + 16, y + h / 2, FS - 1, TH.mute, z + 3)
    else
        local shown = tail(val, maxW, FS - 1)
        if focused and (tick() % 1.1) < 0.55 then shown = shown .. "|" end
        txt(shown, x + 16, y + h / 2, FS - 1, TH.text, z + 3)
    end
    UI.inputs[#UI.inputs + 1] = { id = id, t = tbl, k = key, onChange = onChange, onEnter = onEnter }
    reg(x, y, w, h, id, function() focusInput(id) end, nil, true)
    if hasClear then
        button(x + w - 28, y + (h - 22) / 2, 22, 22, "x", id .. "_clr", function()
            tbl[key] = ""
            if onChange then onChange() end
        end, "ghost", z + 4, "Clear", FS - 2)
    end
end
local function segmented(x, y, w, h, opts, sel, fn, z, id)
    z = z or 20
    pill(x, y, w, h, TH.line, TH.input, z)
    local n = #opts
    local inset = 3
    local sw = (w - inset * 2) / n
    local sh = h - inset * 2
    for i, o in ipairs(opts) do
        local sx = x + inset + (i - 1) * sw
        local on
        if type(sel) == "number" and type(o[1]) == "number" then on = math.abs(sel - o[1]) < 0.001
        else on = (o[1] == sel) end
        local hov = hit(sx, y + inset, sw, sh)
        if on then rect(sx, y + inset, sw, sh, TH.accent, z + 2, sh / 2)
        elseif hov then rect(sx, y + inset, sw, sh, TH.ctl, z + 2, sh / 2) end
        txt(o[2], sx + sw / 2, y + h / 2, FS - 1, on and TH.onAccent or (hov and TH.text or TH.sub), z + 4, true, false)
        reg(sx, y + inset, sw, sh, id .. tostring(o[1]), function() fn(o[1]) end)
    end
end
local function footer(x, y, w, pageKey, pages, total, from, to, idp, jump)
    local h = 28
    if w >= 420 then
        txt(total > 0 and ("Showing " .. from .. "-" .. to .. " of " .. total) or "Nothing to show",
            x + 2, y + h / 2, FS - 2, TH.mute, 14)
    end
    local page = UI[pageKey]
    local rx = x + w
    local function nav(label, target, nid)
        rx = rx - 30
        local ok = target ~= page
        button(rx, y, 30, h, label, idp .. nid, ok and function() UI[pageKey] = target end or nil,
            ok and "soft" or "disabled", 20)
        rx = rx - 4
    end
    nav(">>", pages, "last")
    nav(">", math.min(page + 1, pages), "next")
    local lw = 88
    txt("Page " .. page .. " / " .. pages, rx - lw / 2, y + h / 2, FS - 1, TH.sub, 14, true)
    rx = rx - lw - 4
    nav("<", math.max(page - 1, 1), "prev")
    nav("<<", 1, "first")
    if jump and w >= 520 then
        local function doJump()
            local n = tonumber(UI.jump)
            if n then UI[pageKey] = math.clamp(math.floor(n), 1, pages) end
            UI.jump = ""
            blur()
        end
        rx = rx - 10
        rx = rx - 36
        button(rx, y, 36, h, "Go", idp .. "go", doJump, "soft", 20)
        rx = rx - 6
        rx = rx - 56
        input(rx, y, 56, h, UI, "jump", idp .. "jump", "Page", 20, nil, doJump)
    end
end
local function emptyState(x, y, w, h, title, sub)
    txt(title, x + w / 2, y + h / 2 - 10, FS + 1, TH.sub, 14, true, true)
    txt(sub, x + w / 2, y + h / 2 + 12, FS - 1, TH.mute, 14, true)
end
local function btnW(label, size) return round(tw(label, size or (FS - 1)) + 30) end
local function renderPackList(x, y, w, h, kind)
    local isB = kind == "b"
    local searchKey = isB and "bSearch" or "fSearch"
    local pageKey = isB and "bPage" or "fPage"
    local tb = 32
    local sortW = isB and 150 or 0
    local sw = w - (isB and (sortW + 8) or 0)
    input(x, y, sw, tb, UI, searchKey, kind .. "search",
        isB and "Search packs" or "Search favorites", 20,
        function() UI[pageKey] = 1 end)
    if isB then
        segmented(x + sw + 8, y, sortW, tb, { {"name", "Name"}, {"recent", "Recent"} },
            UI.bSort, function(k) UI.bSort = k; UI.bPage = 1 end, 20, "sort")
    end
    local top = y + tb + 10
    local footH = 28
    local bottom = y + h - footH - 10
    local rowH = State.compact and 34 or 42
    local gap = 6
    local per = math.max(1, math.floor((bottom - top + gap) / (rowH + gap)))
    local list = getList(kind)
    local total = #list
    local pages = math.max(1, math.ceil(total / per))
    UI[pageKey] = math.clamp(UI[pageKey], 1, pages)
    local i0 = (UI[pageKey] - 1) * per
    for n = 1, per do
        local idx = i0 + n
        local p = list[idx]
        if not p then break end
        local ry = top + (n - 1) * (rowH + gap)
        local cy = ry + rowH / 2
        local hov = hit(x, ry, w, rowH)
        local isEq = State.equipped == p.id
        card(x, ry, w, rowH, 16, 10, isEq and "sel" or (hov and "hov" or nil))
        reg(x, ry, w, rowH, "row" .. kind .. p.id, function() equipPack(p) end, "Click to equip")
        if isEq then circle(x + 14, cy, 3, TH.good, 12) end
        txt(tostring(idx), x + 28, cy, FS - 2, TH.mute, 14)
        local rEdge = x + w - 10
        local wearW = 80
        local wearX = rEdge - wearW
        if isEq then
            button(wearX, cy - 14, wearW, 28, "Equipped", "w" .. p.id, nil, "good", 20)
        else
            button(wearX, cy - 14, wearW, 28, "Wear", "w" .. p.id, function() equipPack(p) end, "primary", 20)
        end
        local fav = isFav(p.id)
        local saveW = 66
        local saveX = wearX - 6 - saveW
        button(saveX, cy - 14, saveW, 28, fav and "Saved" or "Save", "s" .. p.id, function()
            local added = toggleFav(p.id)
            toast(added and "Saved to Favorites" or "Removed from Favorites", "info")
        end, fav and "accent" or "soft", 20)
        local badgeW = 44
        local badgeX = saveX - 10 - badgeW
        local full = p.states == p.maxStates
        pill(badgeX, cy - 10, badgeW, 20, TH.line, TH.bg, 14)
        txt(p.states .. "/" .. p.maxStates, badgeX + badgeW / 2, cy, FS - 2, full and TH.sub or TH.warn, 17, true)
        if not full then
            reg(badgeX, cy - 10, badgeW, 20, "b" .. p.id, nil, "Missing: " .. table.concat(missingOf(p), ", "))
        end
        local nameX = x + 56
        local nameMax = badgeX - 12 - nameX
        txt(fit(p.name, nameMax, FS), nameX, cy, FS, isEq and TH.good or TH.text, 14)
    end
    if total == 0 then
        if isB then
            emptyState(x, top, w, bottom - top, "No packs found", "Try a different name.")
        elseif UI.fSearch ~= "" then
            emptyState(x, top, w, bottom - top, "No favorites match", "Try a different search.")
        else
            emptyState(x, top, w, bottom - top, "No favorites yet", "Press Save on a pack in Browse to keep it here.")
        end
    end
    footer(x, y + h - footH, w, pageKey, pages, total, total > 0 and (i0 + 1) or 0, math.min(i0 + per, total), kind, true)
end
local function renderMix(x, y, w, h)
    local n = mixCount()
    txt(n .. "/8 states assigned", x + 2, y + 16, FS, TH.sub, 14)
    local bx = x + w
    bx = bx - 100; button(bx, y, 100, 32, "Apply mix", "apply", applyMix, "primary", 20)
    local sw2 = btnW("Save as preset")
    bx = bx - 8 - sw2
    button(bx, y, sw2, 32, "Save as preset", "tosave", function()
        UI.page = "Presets"; UI.pName = ""; focusInput("pname")
    end, "soft", 20, "Create a preset from this mix")
    local cw = btnW("Clear all")
    bx = bx - 8 - cw
    button(bx, y, cw, 32, "Clear all", "clrall", function()
        State.mix = {}; markDirty(); toast("Mix cleared", "info")
    end, "danger", 20)
    local top = y + 44
    local bodyH = h - 44
    local gap = 6
    local lw = math.max(250, math.floor(w * 0.44))
    local rh = math.max(30, math.min(42, math.floor((bodyH - 7 * gap) / 8)))
    for i, slot in ipairs(SLOTS) do
        local ry = top + (i - 1) * (rh + gap)
        local sel = UI.mixSel == slot
        local hov = hit(x, ry, lw, rh)
        card(x, ry, lw, rh, 16, 10, sel and "sel" or (hov and "hov" or nil))
        local pid = State.mix[slot]
        local p = pid and PACK_BY_ID[pid]
        local cy = ry + rh / 2
        txt(SLOT_LABEL[slot], x + 14, cy, FS - 1, sel and TH.text or TH.sub, 14, false, true)
        local maxW = lw - 96 - 14 - (p and 30 or 0)
        txt(p and fit(p.name, maxW, FS - 1) or "Not set", x + 96, cy, FS - 1, p and TH.text or TH.mute, 14)
        reg(x, ry, lw, rh, "slot" .. slot, function() UI.mixSel = slot; UI.mSearch = ""; UI.mPage = 1 end)
        if p then
            button(x + lw - 32, cy - 11, 24, 22, "x", "clr" .. slot, function()
                State.mix[slot] = nil; markDirty()
            end, "ghost", 20, "Reset this slot", FS - 2)
        end
    end
    local px, pw = x + lw + 12, w - lw - 12
    card(px, top, pw, bodyH, 22, 10)
    txt("Choose " .. SLOT_LABEL[UI.mixSel], px + 16, top + 20, FS, TH.text, 14, false, true)
    input(px + 12, top + 38, pw - 24, 30, UI, "mSearch", "msearch", "Search compatible packs", 20,
        function() UI.mPage = 1 end)
    local ltop = top + 78
    local footH = 28
    local lbottom = top + bodyH - footH - 14
    local prh, pgap = 34, 4
    local per = math.max(1, math.floor((lbottom - ltop + pgap) / (prh + pgap)))
    local list = getMixList()
    local total = #list
    local pages = math.max(1, math.ceil(total / per))
    UI.mPage = math.clamp(UI.mPage, 1, pages)
    local i0 = (UI.mPage - 1) * per
    local cur = State.mix[UI.mixSel]
    for k = 1, per do
        local p = list[i0 + k]
        if not p then break end
        local ry = ltop + (k - 1) * (prh + pgap)
        local isSel = cur == p.id
        local hov = hit(px + 12, ry, pw - 24, prh)
        rect(px + 12, ry, pw - 24, prh, hov and TH.ctl or TH.rowIn, 12, 8)
        local bw2 = 78
        local bX = px + pw - 12 - 8 - bw2
        local nameMax = bX - (px + 24) - 8
        txt(fit(p.name, nameMax, FS - 1), px + 24, ry + prh / 2, FS - 1, isSel and TH.good or TH.text, 15)
        if isSel then
            button(bX, ry + 4, bw2, prh - 8, "Selected", "set" .. p.id, nil, "good", 20)
        else
            button(bX, ry + 4, bw2, prh - 8, "Set", "set" .. p.id, function()
                State.mix[UI.mixSel] = p.id; markDirty()
                toast(SLOT_LABEL[UI.mixSel] .. " set to " .. p.name, "good")
            end, "primary", 20)
        end
    end
    if total == 0 then
        emptyState(px, ltop, pw, lbottom - ltop, "No compatible packs", "Try a different search.")
    end
    footer(px + 12, top + bodyH - footH - 10, pw - 24, "mPage", pages, total,
        total > 0 and (i0 + 1) or 0, math.min(i0 + per, total), "mix", false)
end
local function findPreset(id)
    for i, p in ipairs(State.presets) do if p.id == id then return p, i end end
    return nil
end
local function createFromMix()
    local name = UI.pName:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = "Preset " .. (#State.presets + 1) end
    local pr = { id = newId(), name = name, slots = copySlots(State.mix) }
    State.presets[#State.presets + 1] = pr
    UI.pSel = pr.id
    UI.pName = ""
    blur()
    markDirty()
    toast("Preset created", "good")
end
local function renderPresets(x, y, w, h)
    local cw = btnW("Save current mix")
    input(x, y, w - cw - 8, 32, UI, "pName", "pname", "Name a new preset", 20, nil, createFromMix)
    button(x + w - cw, y, cw, 32, "Save current mix", "pcreate", createFromMix, "primary", 20,
        "Create a preset from Mix & Match")
    input(x, y + 42, w, 32, UI, "pSearch", "psearch", "Search presets", 20, function() UI.pPage = 1 end)
    local top = y + 86
    local bodyH = h - 86
    local lw = math.max(220, math.floor(w * 0.46))
    local s = UI.pSearch:lower()
    local list = {}
    for _, p in ipairs(State.presets) do
        if s == "" or p.name:lower():find(s, 1, true) then list[#list + 1] = p end
    end
    local rowH, gap, footH = 40, 6, 28
    local per = math.max(1, math.floor((bodyH - footH - 10 + gap) / (rowH + gap)))
    local pages = math.max(1, math.ceil(#list / per))
    UI.pPage = math.clamp(UI.pPage, 1, pages)
    local i0 = (UI.pPage - 1) * per
    if not (UI.pSel and findPreset(UI.pSel)) then UI.pSel = list[1] and list[1].id or nil end
    for k = 1, per do
        local p = list[i0 + k]
        if not p then break end
        local ry = top + (k - 1) * (rowH + gap)
        local sel = UI.pSel == p.id
        local hov = hit(x, ry, lw, rowH)
        card(x, ry, lw, rowH, 16, 10, sel and "sel" or (hov and "hov" or nil))
        local cnt = 0
        for _, slot in ipairs(SLOTS) do if p.slots[slot] then cnt = cnt + 1 end end
        txt(fit(p.name, lw - 80, FS), x + 14, ry + rowH / 2, FS, TH.text, 14)
        txt(cnt .. "/8", x + lw - 30, ry + rowH / 2, FS - 2, TH.sub, 14, true)
        reg(x, ry, lw, rowH, "pr" .. p.id, function()
            UI.pSel = p.id; UI.pRenaming = false; UI.delConfirm = nil
        end)
    end
    if #list == 0 then
        if #State.presets == 0 then
            emptyState(x, top, lw, bodyH - footH, "No presets yet", "Build a mix, then save it here.")
        else
            emptyState(x, top, lw, bodyH - footH, "No presets match", "Try a different search.")
        end
    end
    if pages > 1 then
        footer(x, top + bodyH - footH, lw, "pPage", pages, #list, i0 + 1, math.min(i0 + per, #list), "pp", false)
    end
    local px, pw = x + lw + 12, w - lw - 12
    card(px, top, pw, bodyH, 22, 10)
    local pr = UI.pSel and findPreset(UI.pSel)
    if not pr then
        emptyState(px, top, pw, bodyH, "Select a preset", "Its states and actions show up here.")
        return
    end
    local ix, iw = px + 16, pw - 32
    if UI.pRenaming then
        local function commitRename()
            local nm = UI.pRename:gsub("^%s+", ""):gsub("%s+$", "")
            if nm ~= "" then pr.name = nm; markDirty(); toast("Preset renamed", "good") end
            UI.pRenaming = false; blur()
        end
        input(ix, top + 14, iw - 148, 30, UI, "pRename", "prename", "Preset name", 20, nil, commitRename)
        button(ix + iw - 140, top + 14, 66, 30, "Save", "rensave", commitRename, "primary", 20)
        button(ix + iw - 68, top + 14, 68, 30, "Cancel", "rencancel", function()
            UI.pRenaming = false; blur()
        end, "soft", 20)
    else
        txt(fit(pr.name, iw, FS + 3), ix, top + 28, FS + 3, TH.text, 14, false, true)
    end
    local gap2 = 6
    local bw3 = math.floor((iw - gap2 * 2) / 3)
    local by1 = top + 54
    local by2 = by1 + 34
    button(ix, by1, bw3, 28, "Apply", "papply", function()
        State.mix = copySlots(pr.slots); markDirty(); applyMix()
    end, "primary", 20)
    button(ix + bw3 + gap2, by1, bw3, 28, "Rename", "prenm", function()
        UI.pRenaming = true; UI.pRename = pr.name; focusInput("prename")
    end, "soft", 20)
    button(ix + (bw3 + gap2) * 2, by1, bw3, 28, "Duplicate", "pdup", function()
        local d2 = { id = newId(), name = pr.name .. " copy", slots = copySlots(pr.slots) }
        State.presets[#State.presets + 1] = d2
        UI.pSel = d2.id; markDirty(); toast("Preset duplicated", "info")
    end, "soft", 20)
    button(ix, by2, bw3, 28, "Overwrite", "pover", function()
        pr.slots = copySlots(State.mix); markDirty(); toast("Preset updated from current mix", "good")
    end, "soft", 20, "Replace this preset with your current mix")
    button(ix + bw3 + gap2, by2, bw3, 28, "Export", "pexp", function()
        local ok = pcall(function()
            setclipboard(HttpService:JSONEncode({ name = pr.name, slots = pr.slots }))
        end)
        toast(ok and "Preset JSON copied to clipboard" or "Could not copy", ok and "good" or "bad")
    end, "soft", 20, "Copy as JSON")
    local confirming = UI.delConfirm and UI.delConfirm.id == pr.id and tick() < UI.delConfirm.t
    button(ix + (bw3 + gap2) * 2, by2, bw3, 28, confirming and "Confirm" or "Delete", "pdel", function()
        if confirming then
            local _, i = findPreset(pr.id)
            if i then table.remove(State.presets, i) end
            UI.delConfirm = nil; UI.pSel = nil; markDirty(); toast("Preset deleted", "info")
        else
            UI.delConfirm = { id = pr.id, t = tick() + 3 }
        end
    end, confirming and "dangerSolid" or "danger", 20)
    local ly = by2 + 44
    local lineH = math.max(16, math.min(26, math.floor((top + bodyH - 10 - ly) / 8)))
    for _, slot in ipairs(SLOTS) do
        local pid = pr.slots[slot]
        local p = pid and PACK_BY_ID[pid]
        txt(SLOT_LABEL[slot], ix, ly + lineH / 2, FS - 2, TH.sub, 14, false, true)
        txt(p and fit(p.name, iw - 90, FS - 1) or "Not set", ix + 90, ly + lineH / 2, FS - 1,
            p and TH.text or TH.mute, 14)
        ly = ly + lineH
    end
end
local VK_NAMES = {
    [0x04] = "Mouse 3", [0x05] = "Mouse 4", [0x06] = "Mouse 5", [0x09] = "Tab", [0x0D] = "Enter",
    [0x10] = "Shift", [0x11] = "Ctrl", [0x12] = "Alt", [0x14] = "Caps Lock", [0x20] = "Space",
    [0x21] = "Page Up", [0x22] = "Page Down", [0x23] = "End", [0x24] = "Home",
    [0x25] = "Left", [0x26] = "Up", [0x27] = "Right", [0x28] = "Down", [0x2D] = "Insert",
    [0xBA] = ";", [0xBB] = "=", [0xBC] = ",", [0xBD] = "-", [0xBE] = ".", [0xBF] = "/",
    [0xC0] = "`", [0xDB] = "[", [0xDC] = "\\", [0xDD] = "]", [0xDE] = "'",
    [0xA0] = "L Shift", [0xA1] = "R Shift", [0xA2] = "L Ctrl", [0xA3] = "R Ctrl",
    [0xA4] = "L Alt", [0xA5] = "R Alt",
}
for i = 0x30, 0x39 do VK_NAMES[i] = string.char(i) end
for i = 0x41, 0x5A do VK_NAMES[i] = string.char(i) end
for i = 0, 9 do VK_NAMES[0x60 + i] = "Num " .. i end
for i = 1, 12 do VK_NAMES[0x6F + i] = "F" .. i end
local function vkName(vk)
    return VK_NAMES[vk] or string.format("Key 0x%02X", vk)
end
local BIND_DEFS = {
    { "wheel",   "Swap wheel (hold)", "Hold to open, aim with the mouse, release to apply" },
    { "next",    "Next favorite",     "Cycle forward through your favorites" },
    { "prev",    "Previous favorite", "Cycle backward through your favorites" },
    { "undo",    "Undo",              "Swap back to the previous animation" },
    { "restore", "Restore default",   "Back to your normal animations" },
}
local function renderControls(x, y, w, h)
    local rowH = 46
    local ch = (2 + #BIND_DEFS) * rowH + 16
    card(x, y, w, ch, 22, 10)
    local ry = y + 8
    local function row(label, desc, build)
        txt(label, x + 18, ry + 15, FS, TH.text, 14, false, true)
        txt(desc, x + 18, ry + 32, FS - 2, TH.mute, 14)
        build(x + w - 18, ry + (rowH - 30) / 2)
        ry = ry + rowH
    end
    row("Auto-reapply on respawn", "Re-equips your animation when you respawn or rejoin", function(rE, ty)
        segmented(rE - 124, ty, 124, 30, { {true, "On"}, {false, "Off"} }, State.autoReapply,
            function(v) State.autoReapply = v; markDirty() end, 20, "autore")
    end)
    row("Swap wheel shows", "What the wheel offers", function(rE, ty)
        segmented(rE - 244, ty, 244, 30, { {"both", "Both"}, {"favs", "Favorites"}, {"presets", "Presets"} },
            State.wheelMode, function(v) State.wheelMode = v; markDirty() end, 20, "wmode")
    end)
    for _, d in ipairs(BIND_DEFS) do
        local id = d[1]
        row(d[2], d[3], function(rE, ty)
            local capturing = UI.binding == id
            local vk = State.binds[id] or 0
            local bw = 128
            local bx = rE - bw
            if vk ~= 0 then
                button(rE - 26, ty, 26, 30, "x", "unbind" .. id, function()
                    State.binds[id] = 0; markDirty()
                end, "ghost", 20, "Clear this bind", FS - 2)
                bx = rE - 26 - 6 - bw
            end
            button(bx, ty, bw, 30, capturing and "Press a key..." or (vk ~= 0 and vkName(vk) or "Not set"),
                "bind" .. id, function()
                    if UI.binding == id then UI.binding = nil else UI.binding = id end
                    UI.bindGuard = tick() + 0.2
                    blur()
                end, capturing and "primary" or "soft", 20, "Click, then press a key")
        end)
    end
    local hint = UI.binding and "Press the key you want. Esc cancels, Backspace clears."
        or "Hotkeys work with the window closed. They pause while a text box is focused."
    txt(hint, x + 4, y + ch + 16, FS - 2, UI.binding and TH.accentHi or TH.mute, 14)
end
local function renderAppearance(x, y, w, h)
    local rowH = 46
    local rows = 6
    local ch = rows * rowH + 16
    card(x, y, w, ch, 22, 10)
    local ry = y + 8
    local function row(label, desc, build)
        txt(label, x + 18, ry + 15, FS, TH.text, 14, false, true)
        txt(desc, x + 18, ry + 32, FS - 2, TH.mute, 14)
        build(x + w - 18, ry + (rowH - 30) / 2)
        ry = ry + rowH
    end
    local function seg(rEdge, ty, opts, per, sel, fn, id)
        local sw2 = per * #opts + 4
        segmented(rEdge - sw2, ty, sw2, 30, opts, sel, fn, 20, id)
    end
    row("Theme", "Base colors", function(rE, ty)
        seg(rE, ty, { {"Mono", "Mono"}, {"Purple", "Purple"}, {"Dark", "Dark"}, {"Midnight", "Midnight"} }, 84, State.theme,
            function(v) State.theme = v; buildTheme(); markDirty() end, "theme")
    end)
    row("Accent", "Highlight color", function(rE, ty)
        local total = 7 * 26 + 6 * 8
        local sx = rE - total
        for i = 0, 6 do
            local col = (i == 0) and THEMES[State.theme].accent or ACCENTS[i]
            local px = sx + i * 34
            local py = ty + 2
            local sel = State.accent == i
            local hov = hit(px, py, 26, 26)
            if sel then
                rect(px - 3, py - 3, 32, 32, TH.text, 20, 16)
                rect(px - 1, py - 1, 28, 28, TH.card, 21, 14)
            elseif hov then
                rect(px - 2, py - 2, 30, 30, TH.lineHi, 20, 15)
            end
            rect(px, py, 26, 26, col, 22, 13)
            reg(px, py, 26, 26, "acc" .. i, function() State.accent = i; buildTheme(); markDirty() end,
                i == 0 and "Theme default" or nil)
        end
    end)
    row("Text size", "Applies to every label", function(rE, ty)
        seg(rE, ty, { {13, "S"}, {14, "M"}, {15, "L"}, {16, "XL"} }, 56, State.textSize,
            function(v) State.textSize = v; markDirty() end, "tsz")
    end)
    row("Window opacity", "See the game through Stance", function(rE, ty)
        seg(rE, ty, { {0.6, "60%"}, {0.7, "70%"}, {0.8, "80%"}, {0.9, "90%"}, {1, "100%"} }, 56, State.opacity,
            function(v) State.opacity = v; markDirty() end, "opac")
    end)
    row("Row spacing", "List density", function(rE, ty)
        seg(rE, ty, { {false, "Comfortable"}, {true, "Compact"} }, 100, State.compact,
            function(v) State.compact = v; markDirty() end, "compact")
    end)
    row("Corners", "Shape of panels and buttons", function(rE, ty)
        seg(rE, ty, { {true, "Rounded"}, {false, "Square"} }, 90, State.rounded,
            function(v) State.rounded = v; markDirty() end, "round")
    end)
    button(x, y + ch + 12, 170, 32, "Reset appearance", "resetapp", function()
        local d = defaultState()
        State.theme, State.accent, State.scale, State.opacity = d.theme, d.accent, d.scale, d.opacity
        State.textSize, State.compact, State.rounded = d.textSize, d.compact, d.rounded
        buildTheme(); markDirty(); toast("Appearance reset", "info")
    end, "danger", 20)
end
local PAGES = {
    { "Home", "Home" }, { "Browse", "Browse" }, { "Favorites", "Favorites" }, { "MixMatch", "Mix" },
    { "Presets", "Presets" }, { "Controls", "Controls" },
}
local PAGE_TITLE = { Home = "Your workspace", Browse = "Browse", Favorites = "Favorites", MixMatch = "Mix & Match",
    Presets = "Presets", Controls = "Controls", Appearance = "Settings" }
local PAGE_SUB = {
    Home = "A clear view of your setup. Pick an animation, fine-tune it, swap fast.",
    Browse = "Browse real animation packs. Select Wear to equip one.",
    Favorites = "Your saved packs, one click away.",
    MixMatch = "Mix and match animations for each movement state.",
    Presets = "Save a mix and switch back to it any time.",
    Controls = "Hotkeys, the swap wheel and respawn behavior.",
    Appearance = "Theme, text size and layout.",
}
local PAGE_ICON = { Home = "home", Browse = "list", Favorites = "star", MixMatch = "layers",
    Presets = "bookmark", Controls = "keys", Appearance = "sliders" }
local SB_X, SB_W = 14, 78
local PANEL_X = SB_X + SB_W + 10
local CX = PANEL_X + 26
local CT = 176
local function renderHome(x, y, w, h)
    local gap = 12
    local cardW = math.floor((w - gap * 2) / 3)
    local cardH = 164
    local eq = equippedLabel()
    local sub1
    if State.equipped == "mix" then sub1 = "Custom mix"
    elseif State.equipped and PACK_BY_ID[State.equipped] then sub1 = PACK_BY_ID[State.equipped].states .. "/8 states"
    else sub1 = "Your normal animations" end
    local assigned = {}
    for _, slot in ipairs(SLOTS) do
        if State.mix[slot] then assigned[#assigned + 1] = SLOT_LABEL[slot] end
    end
    local sub2 = (#assigned == 0) and "Nothing assigned yet" or table.concat(assigned, ", ")
    local wk = State.binds.wheel or 0
    local cards = {
        { "01", "Animation", "What your character plays", eq or "Default", sub1, "Browse packs", "Browse" },
        { "02", "Mix", "Per-state overrides", mixCount() .. "/8 states", sub2, "Configure mix", "MixMatch" },
        { "03", "Controls", "How you swap quickly", wk ~= 0 and (vkName(wk) .. " wheel") or "No wheel key",
          "Auto-reapply " .. (State.autoReapply and "on" or "off"), "Configure controls", "Controls" },
    }
    for i, c in ipairs(cards) do
        local x0 = x + (i - 1) * (cardW + gap)
        card(x0, y, cardW, cardH, 22, 10)
        txt(c[1], x0 + 20, y + 26, FS, TH.mute, 14)
        txt(c[2], x0 + 48, y + 26, FS, TH.text, 14)
        txt(fit(c[3], cardW - 40, FS - 3), x0 + 20, y + 47, FS - 3, TH.mute, 14)
        txt(fit(c[4], cardW - 40, FS + 5), x0 + 20, y + 78, FS + 5, TH.text, 14)
        txt(fit(c[5], cardW - 40, FS - 2), x0 + 20, y + 101, FS - 2, TH.sub, 14)
        local target = c[7]
        button(x0 + 18, y + cardH - 18 - 32, cardW - 36, 32, c[6], "home" .. i,
            function() UI.page = target; blur() end, "soft", 20)
    end
    local py = y + cardH + gap
    local ph = h - cardH - gap
    card(x, py, w, ph, 22, 10)
    txt("Your library", x + 22, py + 28, FS + 1, TH.text, 14, false, true)
    txt(tostring(#PACKS) .. " animation packs  |  " .. tostring(#State.favs) .. " favorites  |  "
        .. tostring(#State.presets) .. " presets", x + 22, py + 50, FS - 2, TH.sub, 14)
    button(x + 20, py + 66, 140, 30, "Browse packs", "quickbrowse", function() UI.page = "Browse" end, "primary", 20)
    button(x + 168, py + 66, 124, 30, "Favorites", "quickfav", function() UI.page = "Favorites" end, "soft", 20)
    local recentY = py + 112
    if #State.recent > 0 and recentY + 30 < py + ph then
        txt("RECENTLY EQUIPPED", x + 22, recentY, FS - 3, TH.mute, 14, false, true)
        local maxRows = math.min(2, math.floor((py + ph - recentY - 24) / 33))
        for i = 1, maxRows do
            local p = PACK_BY_ID[State.recent[i]]
            if p then
                local ry = recentY + 18 + (i - 1) * 32
                txt(fit(p.name, w - 146, FS - 1), x + 22, ry, FS - 1, TH.text, 14)
                button(x + w - 90, ry - 14, 68, 27, "Wear", "recent" .. i, function() equipPack(p) end, "soft", 20)
            end
        end
    end
end
local function renderWindow()
    local W, H, W0 = UI.W, UI.H, UI.W0
    local cw = (W0 - 14 - 26) - CX
    local ch = (H - 14 - 82 - 14) - CT
    rect(0, 0, W, H, TH.bg, 2, 30)
    card(SB_X, 14, SB_W, H - 28, SB_W / 2, 4, nil, TH.side)
    card(PANEL_X, 14, W0 - 14 - PANEL_X, H - 28, 28, 4)
    local ncx = SB_X + SB_W / 2
    local function nav(key, label, cy)
        local active = UI.page == key
        local hov = hit(ncx - 32, cy - 26, 64, 66)
        if active then
            circle(ncx, cy, 28, TH.text, 6)
            circle(ncx, cy, 27, TH.bg, 7)
            circle(ncx, cy, 22, TH.text, 8)
            icon(PAGE_ICON[key], ncx, cy, TH.bg, 24)
        else
            circle(ncx, cy, 22, hov and TH.lineHi or TH.line, 6)
            circle(ncx, cy, 21, hov and TH.ctl or TH.bg, 7)
            icon(PAGE_ICON[key], ncx, cy, hov and TH.text or TH.sub, 24)
        end
        txt(label, ncx, cy + 36, FS - 3, active and TH.text or TH.mute, 24, true)
        reg(ncx - 32, cy - 26, 64, 66, "nav" .. key, function()
            UI.page = key; UI.jump = ""; UI.binding = nil; blur()
        end)
    end
    for i, pg in ipairs(PAGES) do nav(pg[1], pg[2], 66 + (i - 1) * 72) end
    nav("Appearance", "Settings", H - 14 - 58)
    local hy = 46
    local rE = CX + cw
    local function circBtn(cxc, id, fn, tip, iconName, active)
        local hov = hit(cxc - 15, hy - 15, 30, 30)
        circle(cxc, hy, 15, active and TH.text or (hov and TH.lineHi or TH.line), 20)
        circle(cxc, hy, 14, active and TH.text or (hov and TH.ctl or TH.bg), 21)
        icon(iconName, cxc, hy, active and TH.bg or (hov and TH.text or TH.sub), 24)
        reg(cxc - 15, hy - 15, 30, 30, id, fn, tip)
    end
    circBtn(rE - 15, "close", function() UI.visible = false; blur() end, "Close (F4)", "close", false)
    local sx = rE - 15 - 12 - 78
    button(sx, hy - 15, 78, 30, "Search", "gsearch", function()
        UI.page = "Browse"; focusInput("bsearch")
    end, "soft", 20, "Search animation packs")
    local st = State.equipped and "Applied" or "Default"
    local stw = tw(st, FS - 3)
    txt(st, sx - 18 - stw, hy, FS - 3, TH.sub, 14)
    circle(sx - 18 - stw - 12, hy, 3, State.equipped and TH.good or TH.mute, 14)
    txt("S T A N C E", CX, hy, FS - 3, TH.text, 14)
    txt(PAGE_TITLE[UI.page], CX, 112, FS + 20, TH.text, 14)
    txt(PAGE_SUB[UI.page], CX, 146, FS - 2, TH.mute, 14)
    if     UI.page == "Home"       then renderHome(CX, CT, cw, ch)
    elseif UI.page == "Browse"     then renderPackList(CX, CT, cw, ch, "b")
    elseif UI.page == "Favorites"  then renderPackList(CX, CT, cw, ch, "f")
    elseif UI.page == "MixMatch"   then renderMix(CX, CT, cw, ch)
    elseif UI.page == "Presets"    then renderPresets(CX, CT, cw, ch)
    elseif UI.page == "Controls"   then renderControls(CX, CT, cw, ch)
    elseif UI.page == "Appearance" then renderAppearance(CX, CT, cw, ch)
    end
    local fy0 = H - 14 - 82
    rect(CX, fy0, cw, 1, TH.line, 5)
    local eqL = equippedLabel()
    circle(CX + 4, fy0 + 24, 3, eqL and TH.good or TH.mute, 8)
    txt(eqL or "Default animations", CX + 16, fy0 + 24, FS - 2, TH.text, 14)
    txt("Auto-reapply " .. (State.autoReapply and "on" or "off") .. "  -  " .. #State.favs .. " favorites  -  "
        .. #State.presets .. " presets", CX, fy0 + 44, FS - 3, TH.mute, 14)
    local wk = State.binds.wheel or 0
    txt(wk ~= 0 and ("Hold " .. vkName(wk) .. " for the swap wheel") or "Set a swap wheel key in Controls",
        CX, fy0 + 62, FS - 3, TH.mute, 14)
    local fr, fcy = CX + cw, fy0 + 41
    button(fr - 112, fcy - 17, 112, 34, "Reapply", "reapply", State.equipped and function() reapply(false) end or nil,
        State.equipped and "primary" or "disabled", 20, "Apply the current animation again")
    button(fr - 112 - 8 - 84, fcy - 17, 84, 34, "Undo", "undo", State.undo and undoLast or nil,
        State.undo and "soft" or "disabled", 20, "Swap back to the previous animation")
    local rw = btnW("Restore default")
    button(fr - 112 - 8 - 84 - 8 - rw, fcy - 17, rw, 34, "Restore default", "restore", restoreDefaults,
        "ghost", 20, "Go back to your normal animations")
    rect(W - 26, H - 26, 3, 3, TH.mute, 30, 1, nil, true)
    rect(W - 32, H - 26, 3, 3, TH.mute, 30, 1, nil, true)
    rect(W - 26, H - 32, 3, 3, TH.mute, 30, 1, nil, true)
    local ty = fy0 - 46
    local mid = CX + cw / 2
    for i = #UI.toasts, 1, -1 do
        local t = UI.toasts[i]
        local a = math.min(1, t.life / 0.35)
        local tw2 = math.max(180, tw(t.msg, FS - 1) + 56)
        local tx = mid - tw2 / 2
        local dot = (t.kind == "good" and TH.good) or (t.kind == "bad" and TH.bad)
            or (t.kind == "warn" and TH.warn) or TH.text
        pill(tx, ty, tw2, 34, TH.lineHi, TH.ctl, 50, a)
        rect(tx + 14, ty + 13, 8, 8, dot, 53, 4, a, true)
        txt(t.msg, tx + 30, ty + 17, FS - 1, TH.text, 54, false, false, a)
        ty = ty - 40
    end
    if UI.tipText and (tick() - UI.tipSince) > 0.45 then
        local tw2 = tw(UI.tipText, FS - 2) + 24
        local tx = math.min(Mouse.lx + 12, W - tw2 - 6)
        local tyy = Mouse.ly + 20
        pill(tx, tyy, tw2, 26, TH.lineHi, TH.ctl, 60)
        txt(UI.tipText, tx + 12, tyy + 13, FS - 2, TH.text, 64)
    end
end
local renderOverlay
local paintedX, paintedY = nil, nil
local lastPaint = 0
local PAINT_INTERVAL = 1 / 60
local IDLE_PAINT_INTERVAL = 1 / 24
local DRAG_INTERVAL = 1 / 120
local lastDragPaint = 0
local dragDuration, dragPeak, dragMoves = 0, 0, 0
local function translateDrawings()
    if paintedX == nil or paintedY == nil then return false end
    local dx, dy = round(OX - paintedX), round(OY - paintedY)
    if dx == 0 and dy == 0 then return true end
    local started = os.clock()
    for i = 1, Idx.sq do
        local e = Pool.sq[i]
        if e and e.v then
            e.px, e.py = e.px + dx, e.py + dy
            e.o.Position = Vector2.new(e.px, e.py)
        end
    end
    for i = 1, Idx.tx do
        local e = Pool.tx[i]
        if e and e.v then
            e.px, e.py = e.px + dx, e.py + dy
            e.o.Position = Vector2.new(e.px, e.py)
        end
    end
    for i = 1, Idx.ln do
        local e = Pool.ln[i]
        if e and e.v then
            e.ax, e.ay, e.bx, e.by = e.ax + dx, e.ay + dy, e.bx + dx, e.by + dy
            e.o.From = Vector2.new(e.ax, e.ay)
            e.o.To = Vector2.new(e.bx, e.by)
        end
    end
    for i = 1, Idx.tr do
        local e = Pool.tr[i]
        if e and e.v then
            e.x1, e.y1 = e.x1 + dx, e.y1 + dy
            e.x2, e.y2 = e.x2 + dx, e.y2 + dy
            e.x3, e.y3 = e.x3 + dx, e.y3 + dy
            e.o.PointA = Vector2.new(e.x1, e.y1)
            e.o.PointB = Vector2.new(e.x2, e.y2)
            e.o.PointC = Vector2.new(e.x3, e.y3)
        end
    end
    paintedX, paintedY = OX, OY
    dragDuration = (os.clock() - started) * 1000
    dragPeak = math.max(dragPeak * 0.98, dragDuration)
    dragMoves = dragMoves + 1
    return true
end
local lastMouseX, lastMouseY = nil, nil
local lastVisible, lastPage = nil, nil
local lastFocused, lastWheel = nil, nil
local renderDuration, renderPeak, renderFrames = 0, 0, 0
local function render()
    local started = os.clock()
    beginFrame()
    UI.prevInputs = UI.inputs
    UI.prevButtons = UI.buttons
    UI.inputs = {}
    UI.buttons = {}
    local tip, tid = nil, nil
    for i = #UI.prevButtons, 1, -1 do
        local b = UI.prevButtons[i]
        if not UI.dragging and not UI.resizing and Mouse.lx >= b.x and Mouse.lx <= b.x + b.w
            and Mouse.ly >= b.y and Mouse.ly <= b.y + b.h then
            if b.tip then tip, tid = b.tip, b.id end
            break
        end
    end
    if tid ~= UI.tipId then UI.tipId = tid; UI.tipSince = tick() end
    UI.tipText = tip
    if UI.visible then renderWindow() end
    renderOverlay()
    endFrame()
    paintedX, paintedY = OX, OY
    lastPaint = os.clock()
    renderDuration = (lastPaint - started) * 1000
    renderPeak = math.max(renderPeak * 0.98, renderDuration)
    renderFrames = renderFrames + 1
end
local CHAR_MAP, SHIFT_MAP = {}, {}
for i = 0x30, 0x39 do CHAR_MAP[i] = string.char(i) end
for i = 0x41, 0x5A do CHAR_MAP[i] = string.char(i + 32) end
CHAR_MAP[0x20] = " "; CHAR_MAP[0xBC] = ","; CHAR_MAP[0xBE] = "."; CHAR_MAP[0xBD] = "-"; CHAR_MAP[0xDE] = "'"
local shiftDigits = { ")", "!", "@", "#", "$", "%", "^", "&", "*", "(" }
for i = 0, 9 do SHIFT_MAP[0x30 + i] = shiftDigits[i + 1] end
SHIFT_MAP[0xBD] = "_"; SHIFT_MAP[0xBC] = "<"; SHIFT_MAP[0xBE] = ">"; SHIFT_MAP[0xDE] = '"'
local typingVK, holdT = nil, 0
local escHeld, enterHeld = false, false
local function rbxActive()
    if not isrbxactive then return true end
    local ok, v = pcall(isrbxactive)
    if ok then return v end
    return true
end
local function handleKeys(dt)
    if not UI.visible then
        if UI.focus then blur() end
        UI.binding = nil
        typingVK = nil
        return
    end
    if not UI.focus then typingVK = nil; escHeld = false; enterHeld = false; return end
    local e
    for _, inp in ipairs(UI.inputs) do
        if inp.id == UI.focus then e = inp; break end
    end
    if not e then
        if UI.focusGrace > 0 then UI.focusGrace = UI.focusGrace - 1 else blur() end
        return
    end
    UI.focusGrace = 0
    if not rbxActive() then typingVK = nil; return end
    local esc = iskeypressed(0x1B)
    if esc and not escHeld then escHeld = true; blur(); return end
    escHeld = esc
    local ent = iskeypressed(0x0D)
    if ent and not enterHeld and e.onEnter then pcall(e.onEnter) end
    enterHeld = ent
    if not UI.focus then return end
    local function edit(fn)
        local s = e.t[e.k]
        local ns = fn(s)
        if ns ~= s then
            e.t[e.k] = ns
            if e.onChange then e.onChange() end
        end
    end
    if iskeypressed(0x08) then
        if typingVK ~= 0x08 then
            typingVK = 0x08; holdT = 0.35
            edit(function(s) return s:sub(1, -2) end)
        else
            holdT = holdT - dt
            if holdT <= 0 then holdT = 0.045; edit(function(s) return s:sub(1, -2) end) end
        end
        return
    end
    local shift = iskeypressed(0x10)
    for vk, ch in pairs(CHAR_MAP) do
        if iskeypressed(vk) then
            local c = ch
            if shift then c = SHIFT_MAP[vk] or ch:upper() end
            if typingVK ~= vk then
                typingVK = vk; holdT = 0.35
                edit(function(s) if #s < 40 then return s .. c end return s end)
            else
                holdT = holdT - dt
                if holdT <= 0 then
                    holdT = 0.045
                    edit(function(s) if #s < 40 then return s .. c end return s end)
                end
            end
            return
        end
    end
    typingVK = nil
end
local keyPrev = {}
local SKIP_VK = { [0x01] = true, [0x02] = true, [0x03] = true, [0x08] = true, [0x0A] = true, [0x0B] = true,
    [0x0E] = true, [0x0F] = true, [0x1B] = true, [0x2E] = true, [0x5B] = true, [0x5C] = true,
    [0x5D] = true, [0x5F] = true }
local RESERVED_VK = { [0x73] = "F4", [0x24] = "Home" }
local function captureBind()
    local id = UI.binding
    if not id or not rbxActive() then return end
    if iskeypressed(0x1B) then
        UI.binding = nil; UI.bindGuard = tick() + 0.3
        toast("Binding cancelled", "info")
        return
    end
    if iskeypressed(0x08) or iskeypressed(0x2E) then
        State.binds[id] = 0; UI.binding = nil; UI.bindGuard = tick() + 0.3
        markDirty(); toast("Bind cleared", "info")
        return
    end
    for vk = 0x04, 0xFE do
        if not SKIP_VK[vk] and iskeypressed(vk) then
            if RESERVED_VK[vk] then
                toast(RESERVED_VK[vk] .. " is reserved for Stance", "bad")
                UI.binding = nil; UI.bindGuard = tick() + 0.3
                return
            end
            for _, d in ipairs(BIND_DEFS) do
                if d[1] ~= id and State.binds[d[1]] == vk then State.binds[d[1]] = 0 end
            end
            State.binds[id] = vk
            keyPrev[vk] = true
            UI.binding = nil; UI.bindGuard = tick() + 0.3
            markDirty()
            toast("Bound to " .. vkName(vk), "good")
            return
        end
    end
end
local wheel = { open = false, cx = 0, cy = 0, rings = nil, sel = nil }
local function presetApplied(pr)
    if State.equipped ~= "mix" or not State.appliedMix then return false end
    for _, slot in ipairs(SLOTS) do
        if State.appliedMix[slot] ~= pr.slots[slot] then return false end
    end
    return true
end
local function buildWheel()
    local favs, pres = {}, {}
    for _, id in ipairs(State.favs) do
        local p = PACK_BY_ID[id]
        if p and #favs < 12 then
            favs[#favs + 1] = { name = p.name, kind = "Favorite", on = State.equipped == p.id,
                fn = function() equipPack(p) end }
        end
    end
    for _, pr in ipairs(State.presets) do
        if #pres < 8 then
            local ref = pr
            pres[#pres + 1] = { name = pr.name, kind = "Preset", on = presetApplied(pr),
                fn = function() State.mix = copySlots(ref.slots); markDirty(); applyMix() end }
        end
    end
    local useF = State.wheelMode ~= "presets" and #favs > 0
    local useP = State.wheelMode ~= "favs" and #pres > 0
    if not useF and not useP then
        if #favs > 0 then useF = true elseif #pres > 0 then useP = true end
    end
    if not useF and not useP then
        toast("Save a favorite or a preset to use the wheel", "info")
        return nil
    end
    if useF and useP then
        return { { r0 = 52, r1 = 120, items = pres }, { r0 = 126, r1 = 206, items = favs } }
    elseif useF then
        return { { r0 = 62, r1 = 190, items = favs } }
    end
    return { { r0 = 62, r1 = 190, items = pres } }
end
local function buildWheelGeom(rings, cx, cy)
    for _, ring in ipairs(rings) do
        local n = #ring.items
        local d = 2 * math.pi / n
        local rm = (ring.r0 + ring.r1) / 2
        ring.step = d
        for i, it in ipairs(ring.items) do
            local angle = (i - 1) * d
            it.dirx, it.diry = math.sin(angle), -math.cos(angle)
            it.lx, it.ly = cx + rm * it.dirx, cy + rm * it.diry
            it.segW = math.min(116, rm * d * 0.84)
            it.ex, it.ey = cx + (ring.r1 - 10) * it.dirx, cy + (ring.r1 - 10) * it.diry
        end
    end
end
local function wheelOpen()
    local rings = buildWheel()
    if not rings then return end
    local vp = workspace.CurrentCamera.ViewportSize
    local R = rings[#rings].r1
    wheel.cx = math.clamp(Mouse.x, R + 14, math.max(R + 14, vp.X - R - 14))
    wheel.cy = math.clamp(Mouse.y, R + 14, math.max(R + 14, vp.Y - R - 14))
    wheel.rings = rings
    wheel.sel = nil
    buildWheelGeom(rings, wheel.cx, wheel.cy)
    wheel.open = true
    UI.wheelOpen = true
    syncInput(true)
end
local atan2 = math.atan2 or math.atan
local function wheelSelect()
    wheel.sel = nil
    local dx, dy = Mouse.x - wheel.cx, Mouse.y - wheel.cy
    local r = math.sqrt(dx * dx + dy * dy)
    if r < 48 then return end
    local rings = wheel.rings
    if r > rings[#rings].r1 + 26 then return end
    local ring
    if #rings == 1 then ring = rings[1]
    else ring = (r <= (rings[1].r1 + rings[2].r0) / 2) and rings[1] or rings[2] end
    local n = #ring.items
    local th = atan2(dx, -dy)
    if th < 0 then th = th + 2 * math.pi end
    local d = 2 * math.pi / n
    local idx = math.floor(((th + d / 2) % (2 * math.pi)) / d) + 1
    if idx > n then idx = n end
    wheel.sel = { item = ring.items[idx] }
end
local function wheelClose(apply)
    local sel = wheel.sel
    wheel.open = false
    UI.wheelOpen = false
    wheel.rings = nil
    wheel.sel = nil
    syncInput(true)
    if apply and sel and sel.item and sel.item.fn then pcall(sel.item.fn) end
end
local function processHotkeys()
    local active = rbxActive()
    local live = active and UI.focus == nil and UI.binding == nil and tick() >= UI.bindGuard
    local wvk = State.binds.wheel or 0
    if wvk ~= 0 then
        local down = active and iskeypressed(wvk) or false
        local edge = down and not keyPrev[wvk]
        keyPrev[wvk] = down
        if wheel.open then
            if not active then wheelClose(false)
            elseif not down then wheelClose(true) end
        elseif edge and live then
            wheelOpen()
        end
    elseif wheel.open then
        wheelClose(false)
    end
    local actions = {
        next = function() cycleFavorite(1) end,
        prev = function() cycleFavorite(-1) end,
        undo = undoLast,
        restore = restoreDefaults,
    }
    for _, id in ipairs({ "next", "prev", "undo", "restore" }) do
        local vk = State.binds[id] or 0
        if vk ~= 0 then
            local down = active and iskeypressed(vk) or false
            local edge = down and not keyPrev[vk]
            keyPrev[vk] = down
            if edge and live and not wheel.open then actions[id]() end
        end
    end
end
local respawn = { char = nil, pending = false, at = 0, giveUp = 0, nextPoll = 0 }
local function watchRespawn()
    local now = tick()
    if now >= respawn.nextPoll then
        respawn.nextPoll = now + 0.25
        local ok, ch = pcall(function() return LocalPlayer.Character end)
        if ok and ch and ch ~= respawn.char then
            respawn.char = ch
            respawn.pending = true
            respawn.at = now + 1.0
            respawn.giveUp = now + 6
        end
    end
    if respawn.pending and now >= respawn.at then
        local ready = false
        pcall(function() ready = respawn.char:FindFirstChild("Humanoid") ~= nil end)
        if ready or now >= respawn.giveUp then
            respawn.pending = false
            if State.autoReapply and State.equipped ~= nil then
                if reapply(true) then toast("Reapplied after respawn: " .. (equippedLabel() or ""), "info") end
            end
        end
    end
end
local function drawWheel()
    wheelSelect()
    local cx, cy = wheel.cx, wheel.cy
    local rings = wheel.rings
    local R = rings[#rings].r1
    local op = 1 / State.opacity
    circle(cx, cy, R + 10, TH.line, 98, op)
    circle(cx, cy, R + 9, TH.bg, 99, op)
    for j = #rings, 1, -1 do
        local ring = rings[j]
        local z = 100 + (#rings - j) * 2
        circle(cx, cy, ring.r1 + 1, TH.line, z, op)
        circle(cx, cy, ring.r1, TH.ctl, z + 1, op)
        circle(cx, cy, ring.r0 + 1, TH.line, z + 2, op)
        circle(cx, cy, ring.r0, TH.bg, z + 3, op)
    end
    for _, ring in ipairs(rings) do
        local d = ring.step or (2 * math.pi / math.max(1, #ring.items))
        local r0, r1 = ring.r0 + 2, ring.r1 - 2
        for i = 1, #ring.items do
            local angle = (i - 1.5) * d
            local sx, sy = math.sin(angle), -math.cos(angle)
            line(cx + r0 * sx, cy + r0 * sy, cx + r1 * sx, cy + r1 * sy,
                1, TH.lineHi, 104, op)
        end
    end
    local sel = wheel.sel
    for _, ring in ipairs(rings) do
        for _, it in ipairs(ring.items) do
            local selected = sel ~= nil and sel.item == it
            local labelWidth = math.max(26, it.segW - 5)
            if selected then
                rect(it.lx - labelWidth / 2, it.ly - 13, labelWidth, 26,
                    TH.accent, 106, 13, op, true)
            end
            if it.segW >= 32 then
                txt(fit(it.name, labelWidth - 8, FS - 2), it.lx, it.ly,
                    FS - 2, selected and TH.onAccent or TH.text, 107, true, selected, op)
            end
            if it.on then
                rect(it.ex - 3, it.ey - 3, 6, 6, TH.good, 108, 3, op, true)
            end
        end
    end
    circle(cx, cy, 47, TH.lineHi, 110, op)
    circle(cx, cy, 46, TH.bg, 111, op)
    if sel then
        txt(fit(sel.item.name, 86, FS - 1), cx, cy - 7,
            FS - 1, TH.text, 112, true, true, op)
        txt(sel.item.kind, cx, cy + 10, FS - 3, TH.sub, 112, true, false, op)
    else
        txt("QUICK SWAP", cx, cy - 7, FS - 2, TH.text, 112, true, true, op)
        txt("aim to select", cx, cy + 10, FS - 4, TH.mute, 112, true, false, op)
    end
end
function renderOverlay()
    local sS, sX, sY = S, OX, OY
    S, OX, OY = 1, 0, 0
    if wheel.open then drawWheel() end
    if not UI.visible and #UI.toasts > 0 then
        local vp = workspace.CurrentCamera.ViewportSize
        local ty = 28
        for i = #UI.toasts, 1, -1 do
            local t = UI.toasts[i]
            local a = math.min(1, t.life / 0.35)
            local tw2 = math.max(180, tw(t.msg, FS - 1) + 50)
            local tx = (vp.X - tw2) / 2
            local dot = (t.kind == "good" and TH.good) or (t.kind == "bad" and TH.bad)
                or (t.kind == "warn" and TH.warn) or TH.accent
            pill(tx, ty, tw2, 34, TH.lineHi, TH.ctl, 50, a)
            rect(tx + 14, ty + 13, 8, 8, dot, 53, 4, a, true)
            txt(t.msg, tx + 28, ty + 17, FS - 1, TH.text, 54, false, false, a)
            ty = ty + 40
        end
    end
    S, OX, OY = sS, sX, sY
end
local prevDown, f4Held, homeHeld = false, false, false
local stepMs, stepPeakMs, stepFrames = 0, 0, 0
local Scheduler = {
    uiHz = 0, uiCount = 0, uiWindow = os.clock(),
    rates = { RenderStepped = 0, Heartbeat = 0, Task = 0 },
    counts = { RenderStepped = 0, Heartbeat = 0, Task = 0 },
    active = "RenderStepped", window = os.clock(),
    lastStep = os.clock(), changes = 0,
    taskWait = 1 / 240,
}
local lastErr = nil
local function step(dt)
    local stepStart = os.clock()
    FS = State.textSize
    S = State.scale
    local vp = workspace.CurrentCamera.ViewportSize
    local baseW = State.w
    UI.W0, UI.W, UI.H = baseW, baseW, State.h
    OX, OY = State.x, State.y
    local m = LocalPlayer:GetMouse()
    Mouse.x, Mouse.y = m.X, m.Y
    Mouse.lx, Mouse.ly = (Mouse.x - OX) / S, (Mouse.y - OY) / S
    local dn = ismouse1pressed()
    Mouse.clicked = dn and not prevDown
    Mouse.down = dn
    prevDown = dn
    local f4 = rbxActive() and iskeypressed(0x73)
    if f4 and not f4Held then UI.visible = not UI.visible end
    f4Held = f4
    local hm = rbxActive() and iskeypressed(0x24)
    if hm and not homeHeld and UI.visible then
        local vp = workspace.CurrentCamera.ViewportSize
        State.x = math.floor((vp.X - UI.W * S) / 2)
        State.y = math.floor((vp.Y - State.h * S) / 2)
        markDirty()
    end
    homeHeld = hm
    for i = #UI.toasts, 1, -1 do
        UI.toasts[i].life = UI.toasts[i].life - dt
        if UI.toasts[i].life <= 0 then table.remove(UI.toasts, i) end
    end
    if UI.delConfirm and tick() > UI.delConfirm.t then UI.delConfirm = nil end
    if UI.binding then captureBind() end
    if UI.focus and not casWarned and rbxActive() and (iskeypressed(0x57) or iskeypressed(0x41) or iskeypressed(0x53) or iskeypressed(0x44)) then
        if not casBound or casEvents == 0 then
            casWarned = true
            warn("[Stance Dev] Movement-key sinking is not confirmed by Matcha; physical keys may reach Roblox")
        end
    end
    watchRespawn()
    processHotkeys()
    handleKeys(dt)
    if UI.dragging and Mouse.down then
        State.x = math.clamp(Mouse.x - UI.dx, -State.w * S + 120, vp.X - 120)
        State.y = math.clamp(Mouse.y - UI.dy, 0, vp.Y - 60)
        OX, OY = State.x, State.y
        Mouse.lx = (Mouse.x - OX) / S
        Mouse.ly = (Mouse.y - OY) / S
    end
    if UI.dragging and not Mouse.down then
        UI.dragging = false
        paintedX = nil
        markDirty()
    end
    local paintNow = os.clock()
    local moving = Mouse.x ~= lastMouseX or Mouse.y ~= lastMouseY
    local draggingLive = UI.visible and UI.dragging and Mouse.down and not wheel.open
    if draggingLive then
        if moving and paintNow - lastDragPaint >= DRAG_INTERVAL then
            if not translateDrawings() then render() end
            lastDragPaint = paintNow
        end
    else
        local interval = (moving or UI.focus or UI.binding or wheel.open or #UI.toasts > 0)
            and PAINT_INTERVAL or IDLE_PAINT_INTERVAL
        local paintDue = paintedX == nil or Mouse.clicked
            or UI.visible ~= lastVisible or UI.page ~= lastPage
            or UI.focus ~= lastFocused or wheel.open ~= lastWheel
            or paintNow - lastPaint >= interval
        if paintDue then render() end
    end
    lastMouseX, lastMouseY = Mouse.x, Mouse.y
    lastVisible, lastPage = UI.visible, UI.page
    lastFocused, lastWheel = UI.focus, wheel.open
    if UI.visible and Mouse.clicked and not wheel.open then
        local hitB
        for i = #UI.buttons, 1, -1 do
            local b = UI.buttons[i]
            if Mouse.lx >= b.x and Mouse.lx <= b.x + b.w and Mouse.ly >= b.y and Mouse.ly <= b.y + b.h then
                hitB = b; break
            end
        end
        if hitB then
            if not hitB.isInput and UI.focus then blur() end
            if hitB.fn then pcall(hitB.fn) end
        else
            if UI.focus then blur() end
            local lx, ly = Mouse.lx, Mouse.ly
            if lx >= UI.W - 22 and lx <= UI.W and ly >= UI.H - 22 and ly <= UI.H then
                UI.resizing = true
                UI.rx = UI.W - lx
                UI.ry = UI.H - ly
            elseif lx >= 0 and lx <= UI.W and ly >= 0 and ly <= 76 then
                UI.dragging = true
                UI.dx = Mouse.x - State.x
                UI.dy = Mouse.y - State.y
            end
        end
    end
    if UI.resizing then
        if Mouse.down then
            State.w = math.max(MIN_W, math.floor(Mouse.lx + UI.rx - (UI.W - UI.W0)))
            State.h = math.max(MIN_H, math.floor(Mouse.ly + UI.ry))
        else
            UI.resizing = false; markDirty()
        end
    end
    syncInput()
    flushSave()
    stepMs = (os.clock() - stepStart) * 1000
    stepPeakMs = math.max(stepPeakMs * 0.98, stepMs)
    stepFrames = stepFrames + 1
    Scheduler.uiCount = Scheduler.uiCount + 1
    if os.clock() - Scheduler.uiWindow >= 1 then
        Scheduler.uiHz = Scheduler.uiCount / (os.clock() - Scheduler.uiWindow)
        Scheduler.uiCount = 0
        Scheduler.uiWindow = os.clock()
    end
end
_G.StanceDevStats = function()
    return {
        squares = #Pool.sq,
        texts = #Pool.tx,
        lines = #Pool.ln,
        triangles = #Pool.tr,
        inputBlocked = inputBlocked,
        focus = UI.focus,
        hoverCapture = UI.visible and Mouse.x >= OX and Mouse.x <= OX + UI.W * S
            and Mouse.y >= OY and Mouse.y <= OY + UI.H * S,
        paintedAt = lastPaint,
        renderMs = renderDuration,
        renderPeakMs = renderPeak,
        renderCount = renderFrames,
        dragMs = dragDuration,
        dragPeakMs = dragPeak,
        dragMoves = dragMoves,
        lastFramePaintAgeMs = (os.clock() - lastPaint) * 1000,
        stepMs = stepMs,
        stepPeakMs = stepPeakMs,
        stepCount = stepFrames,
        heartbeatHz = Scheduler.rates.Heartbeat,
        renderSteppedHz = Scheduler.rates.RenderStepped,
        taskHz = Scheduler.rates.Task,
        taskWait = Scheduler.taskWait,
        inputSent = inputSent,
        inputSetCalls = inputSetCalls,
        inputSetErrors = inputSetErrors,
        casBound = casBound,
        casEvents = casEvents,
        inputHover = inputHover,
        inputChanged = inputChanged,
        uiHz = Scheduler.uiHz,
        scheduler = Scheduler.active,
        schedulerChanges = Scheduler.changes,
        dragging = UI.dragging,
    }
end
_G.StanceUnload = function()
    alive = false
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    for _, list in pairs(Pool) do
        for _, e in ipairs(list) do pcall(function() e.o:Remove() end) end
    end
    if type(setrobloxinput) == "function" then pcall(setrobloxinput, true) end
    inputSent = true
    inputBlocked = false
    UI.wheelOpen = false
    casSet(false)
    _G.StanceDevStats = nil
    if type(_G.StanceEngineUnload) == "function" then pcall(_G.StanceEngineUnload) end
end
function Scheduler.tick(name)
    if not alive then return end
    local now = os.clock()
    Scheduler.counts[name] = Scheduler.counts[name] + 1
    local sampleSeconds = now - Scheduler.window
    if sampleSeconds >= 1 then
        local best = Scheduler.active
        local bestRate = 0
        for kind, count in pairs(Scheduler.counts) do
            Scheduler.rates[kind] = count / sampleSeconds
            Scheduler.counts[kind] = 0
            if Scheduler.rates[kind] > bestRate then
                best = kind
                bestRate = Scheduler.rates[kind]
            end
        end
        Scheduler.window = now
        if Scheduler.rates.RenderStepped >= 115 then
            best = "RenderStepped"
        elseif Scheduler.rates.Task >= 115 then
            best = "Task"
        elseif Scheduler.rates.Heartbeat >= 115 then
            best = "Heartbeat"
        end
        if Scheduler.active ~= best then
            Scheduler.active = best
            Scheduler.changes = Scheduler.changes + 1
            print("[Stance Dev] UI scheduler: " .. best .. " (" .. string.format("%.1f", Scheduler.rates[best]) .. " Hz)")
        end
    end
    if Scheduler.active ~= name or now - Scheduler.lastStep < 1 / 120 then return end
    local dt = math.min(now - Scheduler.lastStep, 0.25)
    Scheduler.lastStep = now
    local ok, err = pcall(step, dt)
    if not ok and err ~= lastErr then
        lastErr = err
        warn("[Stance] " .. tostring(err))
    end
end
function Scheduler.connect(name, signal)
    local ok, connection = pcall(function()
        return signal:Connect(function() Scheduler.tick(name) end)
    end)
    if ok and connection then connections[#connections + 1] = connection end
end
Scheduler.connect("RenderStepped", RunService.RenderStepped)
Scheduler.connect("Heartbeat", RunService.Heartbeat)
task.spawn(function()
    while alive do
        task.wait(Scheduler.taskWait)
        if alive then Scheduler.tick("Task") end
    end
end)
if engine and type(engine.Status) == "function" then
    local ok, status = pcall(engine.Status)
    if ok and type(status) == "table" and status.available == false then
        warn("[Stance Dev] Playback unavailable: " .. tostring(status.reason))
    end
end
if catalogError then toast(catalogError, "bad")
elseif engineError then toast("Animation engine unavailable: " .. engineError, "bad")
else toast("Stance loaded: " .. tostring(#PACKS) .. " animation packs", "good") end
