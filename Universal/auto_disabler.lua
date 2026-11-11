-- auto_disabler.lua - Auto Disabler: offensive items cast on enemy heroes by themselves,
-- folder scripts\Universal\ (loaded for EVERY hero; ini section [Universal.auto_disabler]).
--
-- Triggers (either one arms the items; the shot lands after Chance + Delay + a random 50-150 ms):
--   * the target is CHANNELING a spell or inside a cast point (IsCasting - bridge note: the
--     AbilityInPhase 0x634 flag has NOT yet been observed in game, this is best-effort), or
--   * the target is one shot from dying: current HP < my attack roll (min + bonus) + a
--     "Burst bonus HP" slider for the item/spell damage this engine cannot read.
-- Anti-waste gates, matched against the live modifier class names (GetStatusEffects):
--   * already disabled ("stun", "hex", "sheep", "sleep" inside the class name) or an illusion
--     ("illusion") -> no item at all;
--   * spell immune ("magicimmune", "immune", "avatar") -> no item at all (BKB and friends);
--   * already silenced ("silence", "mute") -> Orchid / Bloodthorn skipped; Hex and Abyssal
--     still fire (their stun is the point);
--   * farther than Max cast range -> ignored, because an out-of-range DOTA_UNIT_ORDER_CAST_TARGET
--     makes the game walk the hero toward the enemy instead of standing still.
-- These word lists are HEURISTICS, not build data: keep the Settings tab open next to a buffed
-- enemy, it prints the real class names of the first enemy hero, and add words there if anything
-- slips through. The one source of truth for what a class name looks like on this build is that dump.
--
-- The humanizer: a passing trigger gets ONE Chance to Trigger roll; on success the target is armed
-- for Delay (slider) + a random 50-150 ms and must STILL hold the trigger at the fire moment
-- (the channel ended or the target healed above the burst line -> the shot is cancelled).
-- A fired target stands down 2 s before re-arming; a failed chance roll stands down 2 s so a
-- 30% chance does not re-roll every tick; different targets stand at least 300 ms apart.
-- No toggle key on purpose: the checkbox is the switch (the spec wants no hotkey here).

enabled     = GetSaved("Enable Auto Disabler", false)
allowHex    = GetSaved("Use Hex (Sheepstick)", true)
allowOrchid = GetSaved("Use Orchid", false)
allowThorn  = GetSaved("Use Bloodthorn", false)
allowAbyss  = GetSaved("Use Abyssal Blade", false)
chance      = math.tointeger(GetSaved("Chance to Trigger %", 100)) or 100
delayS      = GetSaved("Delay (s)", 0.15)
burstExtra  = math.tointeger(GetSaved("Burst bonus HP", 250)) or 250
maxRange    = math.tointeger(GetSaved("Max cast range", 800)) or 800

-- Item patterns in the engine's own dialect: item data names ("item_sheepstick" ...), matched
-- case/underscore-insensitively against the item's RTTI class with a trailing "*" for suffix slack
-- (the same house pattern the dodge/defensive scripts use; the Settings audit below shows hit/miss).
local ITEMS = {
    { name = "Hex (Sheepstick)", pattern = "item_sheepstick*",    silence = false, on = function() return allowHex end },
    { name = "Orchid",           pattern = "item_orchid*",        silence = true,  on = function() return allowOrchid end },
    { name = "Bloodthorn",       pattern = "item_bloodthorn*",    silence = true,  on = function() return allowThorn end },
    { name = "Abyssal Blade",    pattern = "item_abyssal_blade*", silence = false, on = function() return allowAbyss end },
}

local DISABLED_WORDS = { "stun", "hex", "sheep", "sleep", "illusion" }
local IMMUNE_WORDS   = { "magicimmune", "immune", "avatar" }
local SILENCE_WORDS  = { "silence", "mute" }

local pend = {}            -- enemy index -> { at = TimeMs, why = "channel" | "kill" }
local gap = {}             -- enemy index -> TimeMs until which re-arming is off
local globalNextMs = 0     -- at least 300 ms between shots on different targets
local firedCount = 0
local diagNextMs = 0
local lastSay = ""

local function say(text, now)
    if text == lastSay and now < diagNextMs then return end
    lastSay = text
    diagNextMs = now + 1000
    LogMessage("disabler: " .. text)
end

-- modifier class substrings (case-insensitive plain find on the live RTTI names)
local function classHit(fx, words)
    for _, cls in ipairs(fx) do
        local low = string.lower(cls)
        for _, w in ipairs(words) do
            if string.find(low, w, 1, true) then return true end
        end
    end
    return false
end

local function heroXY(idx)
    local x, y = GetEntityPosition(idx)
    if not x or not y then return nil, nil end
    return x, y
end

local function burstNow()
    local dmg = GetHeroAttackDamage()
    if not dmg or not dmg.min then return nil end
    return (dmg.min + (dmg.bonus or 0)) + burstExtra
end

-- (why | nil, short reason, fx): the why arms a shot; the gates are the anti-waste list.
local function evaluateTarget(idx, burst)
    local hp = GetEntityHealth(idx)
    if not hp or hp <= 0 then return nil, "dead or unreadable", nil end
    local fx = GetStatusEffects(idx)
    if not fx then return nil, "buffs unreadable", nil end
    if classHit(fx, DISABLED_WORDS) then return nil, "already disabled", fx end
    if classHit(fx, IMMUNE_WORDS) then return nil, "immune", fx end
    if IsCasting(idx) then return "channel", nil, fx end
    if burst and hp < burst then return "kill", nil, fx end
    return nil, "idle", fx
end

-- the trigger must still hold at the fire moment (no gate re-check here - fireAt re-evaluates fully)
local function holdsThrough(idx, why, burst)
    local hp = GetEntityHealth(idx)
    if not hp or hp <= 0 then return false end
    if why == "kill" then return burst ~= nil and hp < burst or false end
    if why == "channel" then return IsCasting(idx) == true end
    return false
end

-- fires the FIRST enabled item that is in the inventory and ready; silence items skip silenced targets
local function fireAt(idx, now)
    local st, why, fx = evaluateTarget(idx, burstNow())
    if not st then
        gap[idx] = now + 500
        say("cancel at fire (" .. why .. ") on " .. idx, now)
        return
    end
    for _, it in ipairs(ITEMS) do
        if it.on() and not (it.silence and classHit(fx, SILENCE_WORDS)) then
            local slot = GetInventorySlot(it.pattern)
            if slot and UseItemOnTarget(slot, idx) then
                firedCount = firedCount + 1
                gap[idx] = now + 2000
                globalNextMs = now + 300
                say(string.format("fired %s (slot %s) on %s (%s)", it.name, tostring(slot), tostring(idx), st), now)
                return
            end
        end
    end
    gap[idx] = now + 400        -- nothing enabled/ready right now; stand off a beat, re-arm later
end

function OnTick()
    local now = TimeMs()
    if not enabled then
        pend = {}
        return
    end

    -- pending shots: hold and release, or cancel when the trigger (or range) broke on the way
    local mx, my = heroXY(GetLocalHeroHandle())
    local burst = burstNow()
    for idx, p in pairs(pend) do
        if now >= p.at then
            pend[idx] = nil
            fireAt(idx, now)
        else
            local ok = holdsThrough(idx, p.why, burst)
            if ok then
                local x, y = heroXY(idx)
                if not x or not mx or (x - mx) * (x - mx) + (y - my) * (y - my) > maxRange * maxRange then
                    ok = false
                end
            end
            if not ok then pend[idx] = nil end
        end
    end

    -- scan for new triggers
    local seen, chCount, killCount = 0, 0, 0
    if now >= globalNextMs then
        local enemies = GetEnemyHeroes()
        if type(enemies) == "table" then
            for _, idx in ipairs(enemies) do
                seen = seen + 1
                if not pend[idx] and (not gap[idx] or now >= gap[idx]) then
                    local st = evaluateTarget(idx, burst)
                    if st == "channel" then chCount = chCount + 1 end
                    if st == "kill" then killCount = killCount + 1 end
                    if st then
                        local x, y = heroXY(idx)
                        if x and mx and (x - mx) * (x - mx) + (y - my) * (y - my) <= maxRange * maxRange then
                            if math.random(100) <= chance then
                                pend[idx] = { at = now + math.floor(delayS * 1000 + 0.5) + math.random(50, 150), why = st }
                            else
                                gap[idx] = now + 2000      -- a lost roll stands down, no reroll spam
                            end
                        end
                    end
                end
            end
        end
    end

    -- diagnostics, at most one line per second
    if now >= diagNextMs then
        diagNextMs = now + 1000
        local armed = 0
        for _ in pairs(pend) do armed = armed + 1 end
        say(string.format("targets %d, channeling %d, killable %d, armed %d, fired %d", seen, chCount, killCount, armed, firedCount), now)
    end
end

function Settings()
    enabled     = DrawCheckbox("Enable Auto Disabler", enabled)
    allowHex    = DrawCheckbox("Use Hex (Sheepstick)", allowHex)
    allowOrchid = DrawCheckbox("Use Orchid", allowOrchid)
    allowThorn  = DrawCheckbox("Use Bloodthorn", allowThorn)
    allowAbyss  = DrawCheckbox("Use Abyssal Blade", allowAbyss)
    chance      = math.tointeger(DrawSliderInt("Chance to Trigger %", 0, 100, chance)) or chance
    delayS      = DrawSliderFloat("Delay (s)", 0.0, 1.0, delayS)
    burstExtra  = math.tointeger(DrawSliderInt("Burst bonus HP", 0, 800, burstExtra)) or burstExtra
    maxRange    = math.tointeger(DrawSliderInt("Max cast range", 250, 1200, maxRange)) or maxRange
    DrawText("Trigger: channeling / cast point (IsCasting, the 0x634 flag is UNVERIFIED in game) OR one shot from dying (HP < attack roll + burst bonus).")
    DrawText("Anti-waste: skips already stun/hex/sheep/sleep classes and illusions, magic-immune / immune / avatar classes; Orchid and Bloodthorn also skip silenced targets.")
    local parts = {}
    for _, it in ipairs(ITEMS) do
        local slot = GetInventorySlot(it.pattern)
        parts[#parts + 1] = it.name .. (slot and (" slot " .. slot) or " not found")
    end
    DrawText("inventory: " .. table.concat(parts, ", "))
    local enemies = GetEnemyHeroes()
    local fx = nil
    if type(enemies) == "table" then
        for _, idx in ipairs(enemies) do
            fx = GetStatusEffects(idx)
            if fx then break end
        end
    end
    if fx then
        DrawText("first enemy's modifier classes (tune the word lists against this): " .. table.concat(fx, ", "))
    else
        DrawText("no readable enemy buff list right now - open this tab next to an enemy hero.")
    end
end
