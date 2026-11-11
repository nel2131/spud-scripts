-- snatcher.lua - Snatcher: auto rune pickup and auto dropped-item pickup, with blink support,
-- folder scripts\Universal\ (loaded for EVERY hero; ini section [Universal.snatcher]).
--
-- What it does every tick while enabled:
--   * RUNES (with a bottle in the main inventory, per the spec): walk to the nearest rune on the
--     map. If an enemy hero is CLOSER to the chosen rune than we are and Use Blink is on and the
--     Blink Dagger is ready (IsItemReady), blink straight at the rune point first (the game caps
--     a long blink to its own max range, no client-side clamp).
--   * ITEMS: chase any dropped item whose label matches the high-value list (gem / rapier /
--     aegis / cheese, plain substring, view the live list in Settings). Stale (dormant) drops
--     are left alone - their position is frozen because nobody on our side sees them.
--   * MOVEMENT: one move order per 400 ms on a moving target; the walk onto the item / rune does
--     the pickup itself (the proven path - the C++ rune pickup's own fallback after 0.8 s).
--   * Swap Bottle is a checkbox but is GATED: dropping the bottle needs DOTA_UNIT_ORDER_DROP_ITEM,
--     whose enum value is NOT on file for this build (the enum table gave MOVE 1 / ATTACK 4 /
--     CAST 5,6,8 / STOP 21 / PICKUP_RUNE 15 only). I need that one value to finish the sequence.
--
-- BUILD-DEPENDENT VALUE LABELS ARE UNVERIFIED: a dropped item's Lua row label comes from the
-- entity's designer name (CEntityIdentity::m_designerName) and its class is matched as
-- "C_DOTA_Item_Physical" - both read live from the snapshot, both logged the first time an
-- item appears ("DROPITEM" / "ENTITY class" lines). Open the Settings tab next to a drop and
-- compare the labels with what actually fell; add words to the list lines below as needed.
--
-- COEXISTENCE: the C++ Auto Rune feature (menu, FeatureRunePickup) drives movement too. It
-- yields to script orders for only 250 ms, so with both on they would alternate. Switch the
-- C++ one off in the menu when this script's Enable Rune Snatch is on.

enableRunes = GetSaved("Enable Rune Snatch", false)
enableItems = GetSaved("Enable Item Snatch", false)
useBlink    = GetSaved("Use Blink", false)
swapBottle  = GetSaved("Swap Bottle", false)
runeRange   = math.tointeger(GetSaved("Rune walk range", 0)) or 0   -- 0 = no cap: any rune on the map
itemRange   = math.tointeger(GetSaved("Item walk range", 0)) or 0   -- 0 = no cap: any matched item on the map

-- the high-value words matched (case-insensitive substring against the item label)
local ITEM_WORDS = { "gem", "rapier", "aegis", "cheese" }

local nextMoveMs = 0        -- move-order throttle (one per 400 ms)
local blinkNextMs = 0       -- at most one blink attempt per 1.5 s
local diagNextMs = 0
local lastSay = ""

local function say(text, now)
    if text == lastSay and now < diagNextMs then return end
    lastSay = text
    diagNextMs = now + 1000
    LogMessage("snatcher: " .. text)
end

local function valueMatch(label)
    if not label or label == "" then return false end
    local low = string.lower(label)
    for _, w in ipairs(ITEM_WORDS) do
        if string.find(low, w, 1, true) then return true end
    end
    return false
end

-- an enemy hero nearer to (tx,ty) than the point (mx,my) is?
local function enemyCloserThan(mx, my, tx, ty)
    local enemies = GetEnemyHeroes()
    if type(enemies) ~= "table" then return false end
    local dMe = (tx - mx) * (tx - mx) + (ty - my) * (ty - my)
    for _, idx in ipairs(enemies) do
        local ex, ey = GetEntityPosition(idx)
        if ex then
            local dE = (tx - ex) * (tx - ex) + (ty - ey) * (ty - ey)
            if dE < dMe then return true end
        end
    end
    return false
end

function OnTick()
    local now = TimeMs()
    if not (enableRunes or enableItems) then return end
    local me = GetLocalHeroHandle()
    if not me then return end
    local mx, my = GetEntityPosition(me)
    if not mx or not my then return end

    -- 1. pick the target: nearest rune with a bottle, otherwise the nearest valuable drop
    local target = nil      -- { x, y, d2, why }
    local contested = false

    if enableRunes then
        local bottle = GetInventorySlot("item_empty_bottle*")
        if bottle then
            local runes = GetRuneEntities()
            if type(runes) == "table" then
                for _, idx in ipairs(runes) do
                    local rx, ry = GetRunePosition(idx)
                    if rx and ry then
                        local d2 = (rx - mx) * (rx - mx) + (ry - my) * (ry - my)
                        if runeRange <= 0 or d2 <= runeRange * runeRange then
                            if not target or d2 < target.d2 then
                                target = { x = rx, y = ry, d2 = d2, why = "rune idx " .. tostring(idx) }
                                contested = enemyCloserThan(mx, my, rx, ry)
                            end
                        end
                    end
                end
            end
        end
    end

    if enableItems then
        local items = GetDroppedItems()
        if type(items) == "table" then
            for _, it in ipairs(items) do
                if not it.stale and valueMatch(it.label) then
                    local d2 = (it.x - mx) * (it.x - mx) + (it.y - my) * (it.y - my)
                    if itemRange <= 0 or d2 <= itemRange * itemRange then
                        if not target or d2 < target.d2 then
                            target = { x = it.x, y = it.y, d2 = d2, why = "item " .. it.label }
                            contested = enemyCloserThan(mx, my, it.x, it.y)
                        end
                    end
                end
            end
        end
    end

    if not target then return end

    -- 2. blink while contested, straight at the point (the game clamps the distance itself)
    if contested and useBlink and now >= blinkNextMs and IsItemReady("item_blink*") == true then
        local slot = GetInventorySlot("item_blink*")
        if slot and UseItemAtPoint(slot, target.x, target.y) then
            blinkNextMs = now + 1500
            say("blink toward " .. target.why .. " (contested)", now)
        end
    end

    -- 3. walk onto the target; walking over it does the pickup itself
    if now >= nextMoveMs then
        MoveTo(target.x, target.y)
        nextMoveMs = now + 400
    end

    if now >= diagNextMs then
        diagNextMs = now + 1000
        if contested then
            say(string.format("target %s, %.0f away, CONTESTED (blink %s)", target.why, math.sqrt(target.d2), IsItemReady("item_blink*") == true and "ready" or "not ready"), now)
        end
    end
end

function Settings()
    enableRunes = DrawCheckbox("Enable Rune Snatch", enableRunes)
    enableItems = DrawCheckbox("Enable Item Snatch", enableItems)
    useBlink    = DrawCheckbox("Use Blink", useBlink)
    swapBottle  = DrawCheckbox("Swap Bottle", swapBottle)
    if swapBottle then
        DrawText("Swap Bottle is GATED on build 6972: dropping the bottle needs DOTA_UNIT_ORDER_DROP_ITEM, whose enum value is not on file (the enum table gave MOVE 1 / ATTACK 4 / CAST 5,6,8 / STOP 21 / PICKUP_RUNE 15). The pickup-back steps exist; the drop step waits for that one value.")
    end
    runeRange = math.tointeger(DrawSliderInt("Rune walk range", 0, 9000, runeRange)) or runeRange
    itemRange = math.tointeger(DrawSliderInt("Item walk range", 0, 9000, itemRange)) or itemRange
    DrawText("Walk range 0 = no cap (goes across the map). Blink into the target fires when an enemy hero is closer to it than we are.")

    -- live audit: what the snapshot holds right now
    local parts = {}
    local runes = GetRuneEntities()
    if type(runes) == "table" then
        local n = 0
        for _, idx in ipairs(runes) do
            if n < 4 then
                local rx, ry = GetRunePosition(idx)
                parts[#parts + 1] = tostring(idx) .. (rx and ("@" .. string.format("%.0f,%.0f", rx, ry)) or "?")
            end
            n = n + 1
        end
        parts[#parts + 1] = "(runes total " .. n .. ")"
    end
    DrawText(table.concat(parts, "  "))
    local labels = {}
    local items = GetDroppedItems()
    if type(items) == "table" then
        for _, it in ipairs(items) do
            if #labels < 6 then labels[#labels + 1] = it.label ~= "" and it.label or ("<no label idx " .. it.index .. ">") .. (it.stale and " STALE" or "") end
        end
    end
    DrawText(#labels > 0 and ("drops on the ground (labels -> tune the word list to these): " .. table.concat(labels, ", ")) or "no dropped items in the snapshot right now")
end
