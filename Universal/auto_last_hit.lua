-- auto_last_hit.lua - last-hit and deny lane creeps, folder scripts\Universal\ (loaded for EVERY hero;
-- ini section [Universal.auto_last_hit]).
--
-- What it does every tick while enabled:
--   * scans lane creeps near the hero (GetCreepsInRange, both teams, live snapshot from the overlays'
--     per-frame refresh) and attacks the creep my next hit will KILL (an enemy creep), or - with
--     Enable Deny - an allied creep that is BELOW 50% HP.
--   * the one-hit maths match the overlays' memory.h: floor((min + bonus) * 1 - 0.06*armor/(1+0.06*|armor|)),
--     the same formula that paints the yellow "killable" zone on the health bars.
--   * order discipline: at most one attack order per 100 ms, and after attacking a creep the same creep
--     is locked out for Re-attack lock (ms) - attacking the same creep twice within its swing looks like
--     two swings from one attack and starts pulling nothing but aggro.
--   * the C++ feature this replaces is GONE (FeatureAutoLastHit, its tab and its hotkeys); this script
--     plus the bridges (GetCreepsInRange / GetLocalHeroTeam / GetHeroAttackDamage / GetHeroAttackTime /
--     GetHeroProjectileSpeed) are the whole last hit now. The orbwalker (Hero tab) still works next to
--     it and keeps its own shared key.
--
-- TOGGLE: the toggle key (default V) flips the script on/off while you play; the flip is runtime state
-- and is deliberately NOT saved - every game starts with the saved Enable value.

enabledLast = GetSaved("Enable Last Hit", false)
enabledDeny = GetSaved("Enable Deny", false)
scanRange   = math.tointeger(GetSaved("Scan range", 900)) or 900
relockMs    = math.tointeger(GetSaved("Re-attack lock", 350)) or 350
toggleVk    = math.tointeger(GetSaved("Toggle key", 86)) or 86        -- VK 'V' (A-Z = 65-90)

local on = false                    -- runtime flip of the toggle key (never persisted)
local prevToggleDown = false
local nextOrderMs = 0               -- global order gap (100 ms)
local lock = {}                     -- creep index -> TimeMs() until which re-ordering it is locked
local diagNextMs = 0
local lastSay = ""

local function say(text, now)
    if text == lastSay and now < diagNextMs then return end
    lastSay = text
    diagNextMs = now + 1000          -- at most one identical line per second
    LogMessage("last hit: " .. text)
end

-- C++: WouldKill(hp, dmgMin, dmgBonus, armor) - the overlay's own one-hit check
local function oneHitDmg(dmg, armor)
    local a = armor and math.abs(armor) or 0
    local m = 1 - 0.06 * a / (1 + 0.06 * a)
    return math.floor((dmg.min + dmg.bonus) * m + 0.001)
end

-- picks the next target: an enemy creep the next hit KILLS first, otherwise a deny-able ally.
-- returns (index, why, health) or nil.
local function pickTarget(rows, team, dmg, denyOn)
    local hit = oneHitDmg(dmg)
    local idx, why, bestHp = nil, nil, 0
    for _, c in ipairs(rows) do
        if c.health > 0 then
            if c.team ~= team then
                if c.health <= hit and (not idx or c.health < bestHp) then idx, why, bestHp = c.index, "kill", c.health end
            elseif denyOn and c.maxHealth > 0 and c.health * 2 <= c.maxHealth then
                if not idx then idx, why, bestHp = c.index, "deny", c.health end   -- first deny-able ally wins (no HP contest needed)
            end
        end
    end
    return idx, why, bestHp
end

function OnTick()
    -- toggle key: rising edge flips
    local down = IsKeyDown(toggleVk)
    if down and not prevToggleDown then
        on = not on
        lock = {}
        lastSay = ""
        LogMessage("last hit: " .. (on and "ON (toggle key)" or "OFF (toggle key)"))
    end
    prevToggleDown = down
    if not (enabledLast and on) then return end

    local now = TimeMs()
    local me = GetLocalHeroHandle()
    local heroHp = me ~= 0 and GetEntityHealth(me) or nil
    if not heroHp or heroHp <= 0 then lock = {}; return end            -- hero dead or untracked
    local team = GetLocalHeroTeam()
    local dmg = GetHeroAttackDamage()
    if not team or not dmg then return end                             -- untracked/unreadable: nothing safe to compute

    local rows = GetCreepsInRange(scanRange)
    if not rows then return end

    if now >= diagNextMs then
        say(string.format("on (%d creeps in range, dmg %d + %d)", #rows, dmg.min, dmg.bonus), now)
    end

    local idx, why, hp = pickTarget(rows, team, dmg, enabledDeny)
    if not idx then return end
    if now < nextOrderMs or (lock[idx] and now < lock[idx]) then return end
    if Attack(idx) then
        nextOrderMs = now + 100
        lock[idx] = now + relockMs
        say(string.format("%s attack -> creep %d (hp %d)", why == "deny" and "DENY" or "kill", idx, hp), now)
    end
end

function Settings()
    enabledLast = DrawCheckbox("Enable Last Hit", enabledLast)
    enabledDeny = DrawCheckbox("Enable Deny", enabledDeny)
    scanRange = DrawSliderInt("Scan range (units)", 300, 1600, scanRange)
    relockMs = DrawSliderInt("Re-attack lock (ms)", 100, 1000, relockMs)
    toggleVk = DrawKeybind("Toggle key", toggleVk)
    DrawText("Attacks an enemy creep the next hit kills; with Enable Deny an allied creep below 50% HP. One order per 100 ms, the same creep again only after the re-attack lock.")
    DrawText("Save pick: " .. (on and "script is toggled ON this game" or "script is toggled OFF this game (press the toggle key in game)") ..
             string.format(", toggle key VK %d", toggleVk))
    local me = GetLocalHeroHandle()
    if me ~= 0 then
        local bat = GetHeroAttackTime(me)
        local pspd = GetHeroProjectileSpeed(me)
        DrawText(string.format("base attack time read: %s  (UNVERIFIED 0xCE8 - compare with an actually measured interval)",
                 bat and string.format("%.2f s", bat) or "nil"))
        DrawText(string.format("projectile speed: %s (no offset on this build yet)", tostring(pspd)))
    end
end
