-- combo.lua - ONE-BUTTON Invoker combos, hero folder Invoker\.
-- Hold the combo key near an enemy hero: the script builds every spell it needs (orb presses + Invoke, 50 ms apart),
-- then casts it at the right moment. Five combos (Settings > Combo):
--   1 Standard            Tornado -> EMP -> Deafening Blast        (timed from the Tornado)
--   2 Sunstrike Finish    Tornado -> Sun Strike -> Deafening Blast (timed from the Tornado)
--   3 Teamfight           Tornado -> EMP -> Chaos Meteor -> Deafening Blast (timed from the Tornado)
--   4 Solo Kill           Cold Snap -> Forge Spirit -> Alacrity    (instant sequence, 150 ms between casts)
--   5 Escape / Initiate   Ghost Walk -> Tornado -> EMP             (Ghost Walk at once, then the Tornado timing)
--
-- TIMING IS COMPUTED, NOT TYPED. Every number is from this install's npc_dota_hero_invoker.txt:
--   Tornado:  cast point 0.05 s, flies 1000 units/s, lifts 1.2 .. 2.8 s by Quas level (1.0 + 0.2 * level; confirmed in the lobby log:
--             Quas 8 -> the enemy state flag lasted 2.6 s). It lands on the target after 0.05 + distance / 1000 s.
--   EMP: detonates 2.9 s after its cast.   Sun Strike: 1.7 s.   Chaos Meteor: lands 1.3 s after its cast.
--   Deafening Blast: flies 1100 units/s (range 1000).
-- The middle spells are cast so they go off exactly when the target comes back down; the blast so that it ARRIVES then.
-- A wait that comes out negative means "as soon as the spell is built". The Quas / Wex / Exort levels are read every combo start
-- (GetAbilityLevel); a level above 7 is real on this build (the ability tables have 9 entries, the lobby hero is level 30).
--
-- AUTO-PREPARE: while the script is idle and an enemy hero is within 1.6 x the pickup radius, the first spell of the chosen combo is invoked in advance
-- (orb presses + Invoke, 50 ms apart), so pressing the key casts it at once instead of building it first. It never casts anything, it runs at most once
-- every 4 s, and it can be switched off (Auto-prepare). States: idle -> prep -> build -> settle -> wait -> (cast, inside the wait) -> next step ... -> done.
--
-- Invoke memory holds TWO spells, and the slots shift as Invoke cycles: every spell is looked up by its class name (ending anchor
-- "$", so "EMP$" can never match "Empty1") right before its cast, and a spell that was pushed out is built again. While a long
-- wait runs, the NEXT spell is invoked in the background.

-- ── script settings (persisted to [Invoker.combo]; keys are the widget LABELS) ──
enabled   = GetSaved("Enable combo", false)   -- combo scripts default OFF: spell orders on the wrong hero are a gift
comboKey  = GetSaved("Combo key", 70)         -- VK 'F' (A-Z = 65-90, F1-F12 = 112-123) - set it on the Binds sub-tab
comboMode = math.tointeger(GetSaved("Combo mode", 1)) or 1   -- 1..5, see above (the saved value arrives as a float: kept an integer)
dbMode    = math.tointeger(GetSaved("Blast timing", 1)) or 1       -- 1 = the blast arrives as the target lands (computed), 2 = cast right after the middle spell
radius    = GetSaved("Pickup radius", 650)    -- enemy pickup range
prepKey   = GetSaved("Prepare key", 75)         -- VK 75 = K: invoke the first spell of the chosen combo on demand (set it on the Binds sub-tab)
autoEscape = GetSaved("Auto-Escape", false)      -- below the HP threshold, with an enemy hero close, run the Escape combo (Ghost Walk -> Tornado -> EMP) by itself
hpThreshold = GetSaved("HP Threshold", 30)       -- percent
hudOn     = GetSaved("Skill HUD", true)           -- the on-screen row of castable spells
panelKey  = GetSaved("Panel key", 115)        -- VK 115 = F4: the engine toggles the Combo Panel with it (the engine reads this global every frame)
hudSize   = GetSaved("HUD icon size", 44)
hudX      = GetSaved("HUD x (%)", 50)
hudY      = GetSaved("HUD y (%)", 84)
autoPrep  = GetSaved("Auto-prepare", true)    -- while idle with an enemy hero close, keep the FIRST spell of the chosen combo invoked

BUILD_STEP_MS = 50     -- gap between orb presses / the Invoke press
STEP_GAP_MS   = 150    -- gap between the casts of the instant combo (Solo Kill)
-- The first TWO spells of each combo (same order as COMBOS): Invoke memory holds two, and both are invoked before the key is pressed.
PREP_SPELLS = {
    { "Tornado", "EMP" },          -- 1 Standard
    { "Tornado", "SunStrike" },    -- 2 Sunstrike Finish
    { "Tornado", "EMP" },          -- 3 Teamfight
    { "ColdSnap", "ForgeSpirit" }, -- 4 Solo Kill
    { "GhostWalk", "Tornado" },    -- 5 Escape / Initiate
}

COMBOS = {
    "Standard (Tornado -> EMP -> Blast)",
    "Sunstrike Finish (Tornado -> Sun Strike -> Blast)",
    "Teamfight (Tornado -> EMP -> Chaos Meteor -> Blast)",
    "Solo Kill (Cold Snap -> Forge Spirit -> Alacrity)",
    "Escape / Initiate (Ghost Walk -> Tornado -> EMP)",
}
DB_MODES = {
    "As the target lands (computed from the distance)",
    "Right after the middle spell",
}

-- Install data (see the header).
CAST_POINT    = 0.05
TORNADO_SPEED = 1000
EMP_DELAY     = 2.9
SUN_DELAY     = 1.7
METEOR_LAND   = 1.3
DB_SPEED      = 1100
DB_RANGE      = 1000
function tornadoLift(quasLevel)
    local q = math.min(math.max(quasLevel, 1), 9)
    return 1.0 + 0.2 * q
end

-- Orb / Invoke keys are resolved by class name every time (the ability list is the truth, no assumed slot numbers).
ORBS = { Q = "Quas$", W = "Wex$", E = "Exort$", R = "Invoke$" }

-- kind: how it is cast.  recipe: the three orbs (the Invoke press is added).
SPELLS = {
    Tornado     = { key = "Tornado$",       recipe = { "Q", "W", "W" }, kind = "point" },
    EMP         = { key = "EMP$",           recipe = { "W", "W", "W" }, kind = "point" },
    SunStrike   = { key = "SunStrike$",     recipe = { "E", "E", "E" }, kind = "point" },
    Deafening   = { key = "DeafeningBlast$", recipe = { "Q", "W", "E" }, kind = "point" },
    ChaosMeteor = { key = "ChaosMeteor$",   recipe = { "E", "E", "W" }, kind = "point" },
    ColdSnap    = { key = "ColdSnap$",      recipe = { "Q", "Q", "Q" }, kind = "unit" },
    ForgeSpirit = { key = "ForgeSpirit$",   recipe = { "E", "E", "Q" }, kind = "none" },
    Alacrity    = { key = "Alacrity$",      recipe = { "W", "W", "E" }, kind = "self" },
    GhostWalk   = { key = "GhostWalk$",     recipe = { "Q", "Q", "W" }, kind = "none" },
}

state = "idle"       -- idle | prep | build | settle | wait
plan = nil           -- the steps of the running combo: { { spell, from, ms }, ... } (from: "tornado" = after the Tornado cast, "prev" = after the previous cast)
idx = 0              -- current step
target = nil         -- enemy chained into the running combo
build = nil          -- { spell, seq = {"Q","W","W","R"}, i }
stamp = 0            -- TimeMs() of the last build press
tornadoStamp = 0     -- TimeMs() of the Tornado cast: "tornado" waits are measured from it
prevCast = 0         -- TimeMs() of the previous cast (or of the combo start)
settleSpell = nil    -- the spell whose Invoke press was just queued (state "settle")
preparing = false    -- true while the idle / manual prepare is building the first two spells (no combo plan exists then)
prepBuilds = 0       -- builds started by the current prepare (a safety bound)
prepNextMs = 0       -- earliest time of the next auto-prepare
escapeNextMs = 0     -- earliest time of the next Auto-Escape
retries = 0
lockUntil = 0        -- a failed or finished combo cannot restart before this time (a held key used to retry on every tick)

local lastDiagMs = 0
local wasDown = false
local prepWasDown = false
local lastModeLogged = nil
local tickCount = 0
function diag(msg)
    local t = TimeMs()
    if t - lastDiagMs >= 1500 then lastDiagMs = t; LogMessage("combo diag: " .. msg) end
end

function reset(lockMs)
    lockUntil = TimeMs() + (lockMs or 600)
    preparing = false
    state = "idle"
    plan = nil
    idx = 0
    target = nil
    build = nil
    retries = 0
end

-- The slot of a spell that is INVOKED (in the Invoke memory), or nil. Invoker keeps every spell as a hidden BASE ability that cannot be cast: FindAbilitySlot finds
-- that base ability (slot 8, 15 ...) when the spell is not invoked, and a cast order on it is dropped by the game. So the slot is accepted only when the ability is
-- not hidden. If the hidden flag cannot be read, a slot before the Invoke slot (the two memory slots sit just before it) counts as invoked.
function slotOf(me, spell)
    local s = FindAbilitySlot(me, SPELLS[spell].key)
    if not s then return nil end
    local hidden = IsAbilityHidden(me, s)
    if hidden == true then return nil end
    if hidden == nil then
        local inv = FindAbilitySlot(me, ORBS.R)
        if not inv or s >= inv then return nil end
    end
    return s
end

-- One log line with the whole ability layout: index:ClassSuffix(h = hidden) - this is how the memory slots and the base slots are seen in the log.
local layoutLogged = 0
function logLayout(me, why)
    if layoutLogged >= 8 then return end
    layoutLogged = layoutLogged + 1
    local parts = {}
    for i = 0, 17 do
        local n = GetAbilityName(me, i)
        if n then
            local short = string.gsub(n, "^C?_?DOTA_Ability_Invoker_", "")
            local h = IsAbilityHidden(me, i)
            parts[#parts + 1] = string.format("%d:%s%s", i, short, h == true and "(h)" or (h == nil and "(?)" or ""))
        end
    end
    LogMessage("combo layout (" .. why .. "): " .. table.concat(parts, " "))
end

-- The first of the two prep spells that is not invoked yet (nil = both are ready). Looked at again after every build: invoking one can push the other out.
function nextMissing(me)
    local list = PREP_SPELLS[comboMode] or PREP_SPELLS[1]
    for _, sp in ipairs(list) do
        if not slotOf(me, sp) then return sp end
    end
    return nil
end

-- ── the plan of the chosen combo: steps with their waits, computed from the orb levels and the distance ──
-- Returns the steps, or nil + a reason.
function makePlan(me, dist, modeArg)
    local mode = modeArg or comboMode
    local qs, ws, es = FindAbilitySlot(me, ORBS.Q), FindAbilitySlot(me, ORBS.W), FindAbilitySlot(me, ORBS.E)
    local qr = qs and GetAbilityLevel(me, qs)
    local wr = ws and GetAbilityLevel(me, ws)
    local er = es and GetAbilityLevel(me, es)
    -- the raw reads, exactly as the bridge returned them (nil = the slot or the level read failed)
    LogMessage(string.format("combo: GetAbilityLevel raw -> Quas slot=%s level=%s | Wex slot=%s level=%s | Exort slot=%s level=%s", tostring(qs), tostring(qr), tostring(ws), tostring(wr), tostring(es), tostring(er)))
    if qr == nil or wr == nil or er == nil then return nil, "an orb ability was not found / its level is unreadable" end
    local q, w, e = qr, wr, er

    local arrive = CAST_POINT + dist / TORNADO_SPEED
    local lift = tornadoLift(q)
    local land = arrive + lift
    local function atLand(delay) return math.floor(math.max(0, land - delay - CAST_POINT) * 1000) end
    local dbFly = CAST_POINT + math.min(dist, DB_RANGE) / DB_SPEED
    local function blast()
        if dbMode == 2 then return { spell = "Deafening", from = "prev", ms = 0 } end
        return { spell = "Deafening", from = "tornado", ms = math.floor(math.max(0, land - dbFly) * 1000) }
    end

    local steps
    if mode == 1 then
        steps = { { spell = "Tornado", from = "prev", ms = 0 }, { spell = "EMP", from = "tornado", ms = atLand(EMP_DELAY) }, blast() }
    elseif mode == 2 then
        steps = { { spell = "Tornado", from = "prev", ms = 0 }, { spell = "SunStrike", from = "tornado", ms = atLand(SUN_DELAY) }, blast() }
    elseif mode == 3 then
        steps = { { spell = "Tornado", from = "prev", ms = 0 }, { spell = "EMP", from = "tornado", ms = atLand(EMP_DELAY) },
                  { spell = "ChaosMeteor", from = "tornado", ms = atLand(METEOR_LAND) }, blast() }
    elseif mode == 4 then
        steps = { { spell = "ColdSnap", from = "prev", ms = 0 }, { spell = "ForgeSpirit", from = "prev", ms = STEP_GAP_MS }, { spell = "Alacrity", from = "prev", ms = STEP_GAP_MS } }
    else
        steps = { { spell = "GhostWalk", from = "prev", ms = 0 }, { spell = "Tornado", from = "prev", ms = 0 }, { spell = "EMP", from = "tornado", ms = atLand(EMP_DELAY) } }
    end

    -- every orb the plan needs must be skilled
    local lv = { Q = q, W = w, E = e }
    for _, st in ipairs(steps) do
        for _, o in ipairs(SPELLS[st.spell].recipe) do
            if lv[o] < 1 then return nil, string.format("%s needs %s skilled (levels read: Q%d W%d E%d)", st.spell, ORBS[o]:gsub("%$", ""), q, w, e) end
        end
    end

    local usesTornado = mode ~= 4
    local parts = {}
    for i, st in ipairs(steps) do parts[#parts + 1] = string.format("%s +%d ms (%s)", st.spell, st.ms, st.from) end
    LogMessage(string.format("combo start [%s]: Q%d W%d E%d, target %.0f units away%s | %s",
        COMBOS[mode] or "?", q, w, e, dist,
        usesTornado and string.format(": tornado arrives in %.2f s, lifts %.1f s, lands at %.2f s", arrive, lift, land) or "",
        table.concat(parts, " | ")))
    if usesTornado and dist > DB_RANGE and (mode == 1 or mode == 2 or mode == 3) then
        LogMessage(string.format("combo: the target is %.0f units away, beyond the blast range %d: the blast would fall short", dist, DB_RANGE))
    end
    return steps
end

-- Start a combo of `mode` on `target0` (shared by the key and by Auto-Escape).
function beginCombo(me, target0, dist0, mode)
    logLayout(me, "combo start")
    LogMessage(string.format("combo diag: Starting mode %s (%s)", tostring(mode), COMBOS[mode] or "?"))
    local steps, why = makePlan(me, dist0, mode)
    if not steps then LogMessage("combo: " .. why .. " - aborting this combo"); lockUntil = TimeMs() + 1500; return false end
    plan, idx, target, retries = steps, 1, target0, 0
    prevCast, tornadoStamp = TimeMs(), 0
    state = "prep"
    return true
end

-- Can the Invoke recipe of this spell be built at all (every orb it needs is skilled)? An unskilled orb makes Invoke do nothing, and the prepare would retry for ever.
function canBuild(me, spell)
    for _, o in ipairs(SPELLS[spell].recipe) do
        local s = FindAbilitySlot(me, ORBS[o])
        local lv = s and GetAbilityLevel(me, s)
        if not lv or lv < 1 then return false end
    end
    return true
end

-- ── building a spell: orb presses and the Invoke press, 50 ms apart ──
function startBuild(me, spell)
    local seq = {}
    for _, o in ipairs(SPELLS[spell].recipe) do seq[#seq + 1] = o end
    seq[#seq + 1] = "R"
    build = { spell = spell, seq = seq, i = 1 }
    state = "build"
    stamp = TimeMs()
end

function buildStep(me)
    if TimeMs() - stamp < BUILD_STEP_MS then return end
    local o = build.seq[build.i]
    local slot = FindAbilitySlot(me, ORBS[o])
    if not slot or not CastAbilityNoTarget(slot) then
        LogMessage("combo: the order queue refused an orb / Invoke press (" .. tostring(o) .. ")")
        reset(1000); return
    end
    build.i = build.i + 1
    stamp = TimeMs()
    if build.i > #build.seq then
        -- the Invoke press is queued, not executed yet: the "settle" state polls for the spell (up to 400 ms) before the cast step trusts it
        settleSpell = build.spell
        state = "settle"
        build = nil
    end
end

-- Execute the cast of step `idx`.
function castStep(me)
    local st = plan[idx]
    local slot = slotOf(me, st.spell)   -- resolved right before the cast: Invoke memory shifts
    if not slot then state = "prep"; retries = retries + 1; if retries > 3 then reset(1000) end return end
    local cd = GetAbilityCooldown(me, slot)
    if not cd or cd > 0 then
        LogMessage("combo: '" .. st.spell .. "' on cooldown - combo aborted")
        reset(1500); return
    end
    local kind, ok = SPELLS[st.spell].kind, false
    local tx, ty = GetEntityPosition(target)
    if kind == "point" then
        if not tx then LogMessage("combo: target position lost - combo aborted"); reset(); return end
        ok = CastAbilityAtPoint(tx, ty, slot)
    elseif kind == "unit" then
        ok = CastAbilityAtUnit(target, slot)
    elseif kind == "self" then
        ok = CastAbilityAtUnit(me, slot)
    else
        ok = CastAbilityNoTarget(slot)
    end
    if not ok then LogMessage("combo: the order queue refused " .. st.spell); reset(1000); return end
    LogMessage(string.format("combo: %s (slot %d)%s", st.spell, slot, tx and string.format(" at %.0f, %.0f", tx, ty) or ""))
    local now = TimeMs()
    if st.spell == "Tornado" then tornadoStamp = now end
    prevCast = now
    idx = idx + 1
    retries = 0
    if idx > #plan then
        LogMessage("combo: combo complete")
        reset()
    else
        state = "prep"
    end
end

function TickBody()
    tickCount = tickCount + 1
    if tickCount % 60 == 1 then   -- heartbeat: proves the script ticks and shows what it reads
        local hb = GetLocalHeroHandle()
        local qs, ws = hb ~= 0 and FindAbilitySlot(hb, ORBS.Q), hb ~= 0 and FindAbilitySlot(hb, ORBS.W)
        LogMessage(string.format("combo tick %d: comboKey=%s IsKeyDown=%s enabled=%s state=%s mode=%s hero=%s Quas(slot %s)=%s Wex(slot %s)=%s",
            tickCount, tostring(comboKey), tostring(comboKey ~= 0 and IsKeyDown(comboKey)), tostring(enabled), state, tostring(comboMode), tostring(hb ~= 0 and HeroName(hb)),
            tostring(qs), tostring(qs and GetAbilityLevel(hb, qs)), tostring(ws), tostring(ws and GetAbilityLevel(hb, ws))))
    end
    if comboMode ~= lastModeLogged then
        lastModeLogged = comboMode
        LogMessage(string.format("combo diag: selected mode is %s (%s)", tostring(comboMode), COMBOS[comboMode] or "?"))
    end
    local keyDown = comboKey ~= 0 and IsKeyDown(comboKey)
    if keyDown and not wasDown then LogMessage(string.format("combo diag: VK %d went DOWN (the script sees the key); enabled=%s state=%s", comboKey, tostring(enabled), state)) end
    wasDown = keyDown
    if not enabled or comboKey == 0 then
        if keyDown then diag("the key is down but 'Enable combo' is OFF (Heroes > Invoker > Auto Usage)") end
        return
    end
    local me = GetLocalHeroHandle()
    if me == 0 then return end
    local now = TimeMs()

    -- ── manual prepare: the prep key invokes the first spell of the chosen combo on demand (rising edge, only while idle, never while the combo key is held) ──
    local prepDown = prepKey ~= 0 and prepKey ~= comboKey and IsKeyDown(prepKey)
    local prepPressed = prepDown and not prepWasDown
    prepWasDown = prepDown
    if prepPressed and state == "idle" and not keyDown then
        local nmp = HeroName(me)
        if not nmp or not string.find(string.lower(nmp), "invoker", 1, true) then
            LogMessage("combo: Manual Auto-Prepare ignored - my hero is " .. tostring(nmp) .. ", not Invoker")
        else
            local missing = nextMissing(me)
            local list = PREP_SPELLS[comboMode] or PREP_SPELLS[1]
            if not missing then
                LogMessage("combo: Manual Auto-Prepare - " .. list[1] .. " and " .. list[2] .. " are already invoked")
            else
                logLayout(me, "manual prepare")
                LogMessage("LUA: Manual Auto-Prepare triggered - invoking " .. list[1] .. " and " .. list[2])
                retries = 0
                prepBuilds = 1
                preparing = true
                startBuild(me, missing)
            end
        end
        return
    end

    -- ── idle: hold-to-run - a finished combo restarts on the next target while the key is held ──
    if state == "idle" then
        if not keyDown and autoPrep and now >= lockUntil and now >= prepNextMs then
            -- auto-prepare: the first spell of the chosen combo, only for Invoker and only with an enemy hero close (never casts, 1 try per 4 s)
            local nm0 = HeroName(me)
            local missing0 = nextMissing(me)
            if missing0 and not canBuild(me, missing0) then prepNextMs = now + 8000; missing0 = nil end   -- an orb of the recipe is not skilled: Invoke would do nothing
            if nm0 and string.find(string.lower(nm0), "invoker", 1, true) and missing0 then
                local mx0, my0 = GetEntityPosition(me)
                local close = false
                if mx0 then
                    local en = GetEnemyHeroes()
                    for i = 1, #en do
                        local x, y = GetEntityPosition(en[i])
                        if x and ((x - mx0) ^ 2 + (y - my0) ^ 2) ^ 0.5 <= radius * 1.6 then close = true; break end
                    end
                end
                if close then
                    prepNextMs = now + 4000
                    retries = 0
                    preparing = true
                    prepBuilds = 1
                    logLayout(me, "auto-prepare")
                    local lst = PREP_SPELLS[comboMode] or PREP_SPELLS[1]
                    LogMessage("combo: auto-prepare - invoking " .. lst[1] .. " and " .. lst[2] .. " ahead of the combo")
                    startBuild(me, missing0)
                    return
                end
            end
        end
        if autoEscape and comboMode ~= 5 and not keyDown and not wasDown and now >= lockUntil and now >= escapeNextMs then
            -- Auto-Escape: my health below the threshold with an enemy hero close -> the Escape combo (Ghost Walk -> Tornado -> EMP) on the nearest one. The Combo mode setting is NOT touched.
            local hp, maxhp = GetEntityHealth(me), GetEntityMaxHealth(me)
            if hp and maxhp and maxhp > 0 and hp > 0 then
                local pct = 100.0 * hp / maxhp
                if pct < hpThreshold then
                    local mxe, mye = GetEntityPosition(me)
                    local tgt, td = nil, math.huge
                    if mxe then
                        local en = GetEnemyHeroes()
                        for i = 1, #en do
                            local x, y = GetEntityPosition(en[i])
                            if x then
                                local d = ((x - mxe) ^ 2 + (y - mye) ^ 2) ^ 0.5
                                if d <= radius * 1.6 and d < td then tgt, td = en[i], d end
                            end
                        end
                    end
                    local nme = HeroName(me)
                    if tgt and nme and string.find(string.lower(nme), "invoker", 1, true) then
                        escapeNextMs = now + 10000
                        LogMessage(string.format("Auto-Escape triggered! HP: %d%%", math.floor(pct)))
                        beginCombo(me, tgt, td, 5)
                        return
                    end
                end
            end
        end
        if not keyDown or now < lockUntil then return end
        local nm = HeroName(me)
        if not nm or not string.find(string.lower(nm), "invoker", 1, true) then diag("my hero is " .. tostring(nm) .. ", not Invoker") return end
        local mx, my = GetEntityPosition(me)
        if not mx then return end
        local target0, dist0, nearest = nil, math.huge, nil
        local enemies = GetEnemyHeroes()
        for i = 1, #enemies do
            local x, y = GetEntityPosition(enemies[i])
            if x then
                local d = ((x - mx) ^ 2 + (y - my) ^ 2) ^ 0.5
                if not nearest or d < nearest then nearest = d end
                if d <= radius and d < dist0 then target0, dist0 = enemies[i], d end
            end
        end
        if not target0 then
            diag(string.format("no enemy HERO within %d units (heroes in the list: %d, nearest: %s). Target dummies, creeps and heroes out of sight are not in that list.", radius, #enemies, nearest and string.format("%.0f", nearest) or "none"))
            return
        end
        beginCombo(me, target0, dist0, comboMode)
        return
    end

    -- ── auto-prepare running: build the first spell, then back to idle (no plan, no cast) ──
    if preparing then
        if state == "build" then if build then buildStep(me) else state = "idle"; preparing = false end return end
        if state == "settle" then
            if slotOf(me, settleSpell) then
                LogMessage("combo: prepare - " .. tostring(settleSpell) .. " is invoked")
                local nxt = nextMissing(me)
                if nxt and prepBuilds < 4 then
                    prepBuilds = prepBuilds + 1
                    startBuild(me, nxt)            -- the second spell follows at once (the 50 ms press gap applies)
                else
                    local lst = PREP_SPELLS[comboMode] or PREP_SPELLS[1]
                    LogMessage(nxt and "combo: prepare stopped after 4 builds" or ("combo: prepare done - " .. lst[1] .. " and " .. lst[2] .. " are invoked"))
                    preparing = false; state = "idle"
                end
            elseif now - stamp > 400 then
                LogMessage("combo: prepare failed - Invoke did not produce " .. tostring(settleSpell) .. " (no mana or Invoke on cooldown?); backing off 15 s")
                prepNextMs = now + 15000
                preparing = false; state = "idle"
            end
            return
        end
        preparing = false; state = "idle"   -- any other state: give up cleanly
        return
    end

    -- ── running combo: a vanished enemy is a clean abort ──
    if not target or not plan then reset(); return end
    if not GetEntityPosition(target) then LogMessage("combo: the target left the list - combo aborted"); reset(); return end

    if state == "build" then
        if build then buildStep(me) else state = "prep" end
        return
    end

    local st = plan[idx]
    if state == "settle" then
        if slotOf(me, settleSpell) then state = "wait"; return end
        if now - stamp > 400 then
            retries = retries + 1
            if retries > 3 then LogMessage("combo: Invoke finished but '" .. tostring(settleSpell) .. "' did not appear (3 tries)"); reset(1000) else state = "prep" end
        end
        return
    end
    if state == "prep" then
        if slotOf(me, st.spell) then state = "wait" else startBuild(me, st.spell) end
        return
    end

    if state == "wait" then
        local base = st.from == "tornado" and tornadoStamp or prevCast
        local left = st.ms - (now - base)
        if left <= 0 then castStep(me); return end
        -- a long wait: build the NEXT spell in the background (never when the cast is near, the build takes ~200 ms)
        local nx = plan[idx + 1]
        if left > 250 and nx and nx.spell ~= st.spell and not slotOf(me, nx.spell) and retries < 3 then
            retries = retries + 1
            startBuild(me, nx.spell)
        end
        return
    end
end

-- OnTick is a guard around the real tick: an error inside it is logged and the combo reset, but the script is NOT stopped
-- (the engine stops a script on any uncaught error).
function OnTick()
    local ok, err = pcall(TickBody)
    if not ok then
        reset()
        diag("error inside the combo tick (script keeps running): " .. tostring(err))
    end
end

-- ── the skill HUD ──
-- Each spell can carry its own picture as a Base64 PNG: paste the string between the quotes of ICON_B64 below. A spell whose string is empty uses, in this order, icons\<name>.png next to this
-- script (optional folder, nothing checks for it: a missing file is simply skipped), then the picture the DLL already has for this hero's ability, then a solid colour square.
-- The strings below are EMPTY placeholders on purpose (no real image data is invented here).
ICON_B64 = {
    Tornado = "",        -- e.g. "iVBORw0KGgo..."
    EMP = "",
    SunStrike = "",
    ChaosMeteor = "",
    Deafening = "",
    ColdSnap = "",
    ForgeSpirit = "",
    Alacrity = "",
    GhostWalk = "",
}
ICON_NAME = { Tornado = "tornado", EMP = "emp", SunStrike = "sun_strike", ChaosMeteor = "chaos_meteor", Deafening = "deafening_blast",
              ColdSnap = "cold_snap", ForgeSpirit = "forge_spirit", Alacrity = "alacrity", GhostWalk = "ghost_walk" }

-- class name -> SPELLS key, case-insensitive: the RTTI casing of each Invoker spell class is not assumed here
local function keyOfClassSuffix(cls)
    local lo = string.lower(cls)
    for k, v in pairs(SPELLS) do
        if string.find(lo, string.lower(v.key:gsub("%$$", "")), 1, true) then return k end
    end
    return nil
end

-- ── the live Skill HUD ──
-- Instead of a hardcoded spell list (or assumed slot numbers like 6 and 7 - a user-supplied guess,
-- not a verified layout on this build), the HUD scans the whole ability list for the classes that
-- are in the Invoke memory RIGHT NOW (hidden flag false) and draws each of them with its live
-- cooldown from GetAbilityCooldown. Whatever is invoked shows up - Sun Strike and Ice Wall
-- included - and it disappears the moment Invoke cycles it out. Unknown Invoker class suffixes
-- (Ice Wall is not in SPELLS) display with their suffix as the icon name; the spare "Empty" slots
-- and the hidden base slots are skipped, a hidden flag that cannot be read (nil) counts as
-- unknown and is not drawn, same discipline as slotOf().

-- Called by the engine every frame on the render thread.
local hudDiagMs = 0   -- next moment the 1 Hz cooldown diag line may be logged
-- Cooldowns come from GetCooldownByName (RTTI class name -> the ability entity -> its fields),
-- never the slot index: a logical slot is what shifts under Invoke, the entity and its name are not.
-- The 1 Hz diag line logs both cooldown fields (m_fCooldown 0x638 and m_flCooldownLength 0x63C)
-- exactly as read, per invoked slot - read failures are stamped READ-FAILED, never silently
-- drawn as "ready". Compare that line with the game's own D/F icon cooldown once and the
-- 0x638-vs-UI question is settled by evidence; if they track but disagree with the UI game's
-- icon, the mismatch is at a different source and the log says which.
-- the spells of each combo, in the order they are cast (same order as COMBOS)
HUD_SPELLS = {
    { "Tornado", "EMP", "Deafening" },
    { "Tornado", "SunStrike", "Deafening" },
    { "Tornado", "EMP", "ChaosMeteor", "Deafening" },
    { "ColdSnap", "ForgeSpirit", "Alacrity" },
    { "GhostWalk", "Tornado", "EMP" },
}

function DrawHud()
    if not enabled or not hudOn then return end
    local me = GetLocalHeroHandle()
    if me == 0 then return end
    local nm = HeroName(me)
    if not nm or not string.find(string.lower(nm), "invoker", 1, true) then return end
    SetHudPosition(hudX / 100.0, hudY / 100.0)
    SetHudPanel("Dynamic")                 -- the titled panel with the flame mark; asked for every frame, so the HUD updates every frame

    -- row 1: the spells that are in the Invoke memory RIGHT NOW (not hidden, not an orb, not Invoke, not an empty slot), with their live cooldown by class name
    local drawn, diag = 0, nil
    for slot = 0, 17 do
        local n = GetAbilityName(me, slot)
        if n and string.find(n, "_Ability_Invoker_", 1, true) and IsAbilityHidden(me, slot) == false then
            local suff = string.gsub(n, "^.*_Ability_Invoker_", "")
            local lo = string.lower(suff)
            if suff ~= "" and not string.find(lo, "empty", 1, true) and lo ~= "quas" and lo ~= "wex" and lo ~= "exort" and lo ~= "invoke" then
                local key = keyOfClassSuffix(n)
                local cd, cdLen = GetCooldownByName(me, suff .. "$")      -- "$": the class name must END with it ("EMP" can never match "Empty1")
                local b64 = key and ICON_B64[key] or ""
                local iname = key and (ICON_NAME[key] or key) or lo
                DrawSkillIcon((b64 ~= "") and b64 or iname, cd or 0, hudSize, true)
                drawn = drawn + 1
                local token = string.format("HUD: %s slot=%d cd=%s len=%s", suff, slot, cd and string.format("%.1f", cd) or "READ-FAILED", cdLen and string.format("%.1f", cdLen) or "nil")
                diag = diag and (diag .. " | " .. token) or token
            end
        end
    end
    if drawn == 0 then DrawText("no spell invoked") end
    HudRow()

    -- row 2: the passive orbs with their level, and Invoke with its cooldown
    for _, o in ipairs({ { "Quas", "quas" }, { "Wex", "wex" }, { "Exort", "exort" } }) do
        local s = FindAbilitySlot(me, o[1] .. "$")
        local lv = s and GetAbilityLevel(me, s)
        DrawSkillIcon(o[2], 0, hudSize, true, lv and tostring(lv) or "?")
    end
    local icd = GetCooldownByName(me, "Invoke$")
    DrawSkillIcon("invoke", icd or 0, hudSize, true)
    HudRow()

    -- row 3: the spells of the selected combo, in cast order (a spell that is not invoked yet shows "off")
    for _, sp in ipairs(HUD_SPELLS[comboMode] or HUD_SPELLS[1]) do
        local cd = GetCooldownByName(me, SPELLS[sp].key)
        local b64 = ICON_B64[sp]
        DrawSkillIcon((b64 and b64 ~= "") and b64 or ICON_NAME[sp], cd or 0, hudSize, true, cd == nil and "off" or nil)
    end
    HudRow()

    if diag then
        local now = TimeMs()
        if now - hudDiagMs >= 1000 then hudDiagMs = now; LogMessage(diag) end
    end
end

-- ── the Combo Panel: the engine gives every script with a Panel() function its own dragable
-- window (toggle key = panelKey above, F4 by default). The widgets reuse the Settings() labels,
-- so both UIs read and write the same [Invoker.combo] values.
function Panel()
    local st = state == "idle" and (preparing and "prepare running" or "idle") or state
    DrawText(string.format("State: %s | %s", st, COMBOS[comboMode] or "?"))
    comboMode = DrawCombo("Combo mode", COMBOS, comboMode)
    autoPrep = DrawCheckbox("Auto-prepare", autoPrep)
    autoEscape = DrawCheckbox("Auto-Escape", autoEscape)
    hpThreshold = DrawSliderInt("HP Threshold", 5, 80, hpThreshold)
    hudOn = DrawCheckbox("Skill HUD", hudOn)
end

function Settings()
    enabled = DrawCheckbox("Enable combo", enabled)
    comboMode = DrawCombo("Combo mode", COMBOS, comboMode)
    dbMode = DrawCombo("Blast timing", DB_MODES, dbMode)
    hudOn = DrawCheckbox("Skill HUD", hudOn)
    hudSize = DrawSliderInt("HUD icon size", 24, 80, hudSize)
    hudX = DrawSliderInt("HUD x (%)", 5, 95, hudX)
    hudY = DrawSliderInt("HUD y (%)", 5, 95, hudY)
    autoPrep = DrawCheckbox("Auto-prepare", autoPrep)
    autoEscape = DrawCheckbox("Auto-Escape", autoEscape)
    hpThreshold = DrawSliderInt("HP Threshold", 5, 80, hpThreshold)
    radius = DrawSliderInt("Pickup radius", 300, 800, radius)
    local me = GetLocalHeroHandle()
    local qs = me ~= 0 and FindAbilitySlot(me, ORBS.Q)
    local ws = me ~= 0 and FindAbilitySlot(me, ORBS.W)
    local es = me ~= 0 and FindAbilitySlot(me, ORBS.E)
    local q = qs and GetAbilityLevel(me, qs) or 0
    local w = ws and GetAbilityLevel(me, ws) or 0
    local e = es and GetAbilityLevel(me, es) or 0
    DrawText(string.format("Orb levels now: Quas %d, Wex %d, Exort %d.", q, w, e))
    DrawText(string.format("Tornado lifts %.1f s at this Quas level and flies at %d units/s; EMP detonates %.1f s after its cast, Sun Strike %.1f s, Chaos Meteor lands %.1f s after.", tornadoLift(q), TORNADO_SPEED, EMP_DELAY, SUN_DELAY, METEOR_LAND))
    DrawText("Auto-Escape: below the HP threshold, with an enemy hero close, Ghost Walk -> Tornado -> EMP runs by itself (never while you hold the combo key; at most once per 10 s). The Combo mode setting stays as it is.")
    DrawText("Timing is computed from these levels and the distance to the target; nothing to tune. Solo Kill is an instant sequence (150 ms between casts).")
end

function Binds()
    comboKey = DrawKeybind("Combo key", comboKey)
    prepKey = DrawKeybind("Prepare key", prepKey)
    panelKey = DrawKeybind("Panel key", panelKey)
    DrawText("Prepare key (default K): invokes the first spell of the chosen combo (Tornado, Cold Snap or Ghost Walk) on demand, without casting it. Auto-prepare does the same by itself when an enemy hero is close.")
    DrawText("Panel key (default F4, VK 115): opens and closes the dragable Combo Panel in game. Its position is saved to the ini. The key only toggles in game content - menu open or a panic state never flip it.")
    DrawText("Defaults to F (70). The key works in game only (menu closed, game focused) - typing in the menu never starts a combo.")
end
