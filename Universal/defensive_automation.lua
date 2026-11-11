-- defensive_automation.lua - hero-independent defensive items, folder scripts\Universal\ (loaded for EVERY hero; ini section [Universal.defensive_automation]).
--
--   Auto-Cleanse       when I am stunned or hexed: use Black King Bar.
--   Auto-Silence-Break when I am silenced:         use Manta Style (it dispels the silence).
--
-- Both are OFF until you switch them on. A condition must hold for 150 ms before the item is used, and after a use the script waits a second before trying again.
--
-- IMPORTANT, about the game rules (not about this script): a STUNNED or HEXED unit cannot use items at all, so the game refuses a Black King Bar order sent while the unit is
-- stunned or hexed. The Auto-Cleanse trigger does what was asked (it sends the order the moment the state is seen) and logs it, but it cannot succeed against a stun or a hex that is
-- already on you. Use it for the cases where the item CAN be used (the effect is not a full disable), or switch on Disable Guard (Hero tab), which uses the item BEFORE a disable lands.
-- Silence is different: items can still be used while silenced, so the Manta Style trigger is expected to work.
--
-- Effect names are matched against the client's class names: "Stunned" = CDOTA_Modifier_Stunned. "name*" starts with, "*name" ends with, "*name*" contains. The patterns below are the
-- real class names found in this build's client.dll; hero-specific stuns end in _Stun or _Stunned, so "*_Stun" and "*_Stunned" catch Earthshaker's Fissure, Jakiro's Ice Path and so on.

enabledCleanse = GetSaved("Enable Auto-Cleanse", false)
enabledSilence = GetSaved("Enable Auto-Silence-Break", false)

STUN_PATTERNS    = { "Stunned", "Bashed", "*_Stun", "*_Stunned" }
HEX_PATTERNS     = { "Hexed", "SheepStick*" }
SILENCE_PATTERNS = { "Silence", "*_Silence", "*_Silence_Debuff" }

DELAY_MS   = 150    -- the condition must hold this long before the item is used
RETRY_MS   = 1000   -- after a use (or a refused use) wait this long before the next try
BKB_ITEM   = "item_black_king_bar"
MANTA_ITEM = "item_manta*"      -- the client class is C_DOTA_Item_MantaStyle

cleanseSince, silenceSince = 0, 0
cleanseNext, silenceNext = 0, 0
local warnedStun = false

-- the first pattern of the list that matches one of my status effects (nil = none, false = the list could not be read)
local function active(me, patterns)
    for _, p in ipairs(patterns) do
        local r = HasStatusEffect(me, p)
        if r == nil then return false end
        if r then return p end
    end
    return nil
end

function OnTick()
    if not enabledCleanse and not enabledSilence then return end
    local me = GetLocalHeroHandle()
    if me == 0 then return end
    local hp = GetEntityHealth(me)
    if not hp or hp <= 0 then cleanseSince, silenceSince = 0, 0; return end   -- dead (or unreadable): nothing to do
    local now = TimeMs()

    if enabledCleanse then
        local hit = active(me, STUN_PATTERNS) or active(me, HEX_PATTERNS)
        if hit then
            if cleanseSince == 0 then cleanseSince = now end
            if now - cleanseSince >= DELAY_MS and now >= cleanseNext then
                local slot = GetInventorySlot(BKB_ITEM)
                cleanseNext = now + RETRY_MS
                if slot then
                    if ExecuteItem(slot) then
                        LogMessage(string.format("defensive: Auto-Cleanse - %s on me, Black King Bar (slot %d) ordered", tostring(hit), slot))
                        if not warnedStun then warnedStun = true; LogMessage("defensive: note - a stunned or hexed unit cannot use items; the game will usually refuse this order") end
                    else
                        LogMessage("defensive: Auto-Cleanse - Black King Bar not ready (cooldown / mana)")
                    end
                else
                    LogMessage("defensive: Auto-Cleanse - no Black King Bar in the inventory")
                end
            end
        else
            cleanseSince = 0
        end
    end

    if enabledSilence then
        local hit = active(me, SILENCE_PATTERNS)
        if hit then
            if silenceSince == 0 then silenceSince = now end
            if now - silenceSince >= DELAY_MS and now >= silenceNext then
                local slot = GetInventorySlot(MANTA_ITEM)
                silenceNext = now + RETRY_MS
                if slot then
                    if ExecuteItem(slot) then
                        LogMessage(string.format("defensive: Auto-Silence-Break - %s on me, Manta Style (slot %d) ordered", tostring(hit), slot))
                    else
                        LogMessage("defensive: Auto-Silence-Break - Manta Style not ready (cooldown / mana)")
                    end
                else
                    LogMessage("defensive: Auto-Silence-Break - no Manta Style in the inventory")
                end
            end
        else
            silenceSince = 0
        end
    end
end

function Settings()
    enabledCleanse = DrawCheckbox("Enable Auto-Cleanse", enabledCleanse)
    enabledSilence = DrawCheckbox("Enable Auto-Silence-Break", enabledSilence)
    DrawText("Auto-Cleanse (stunned or hexed -> Black King Bar) and Auto-Silence-Break (silenced -> Manta Style). Each waits 150 ms before using the item, then 1 s between tries.")
    DrawText("A stunned or hexed unit cannot use items, so the game normally refuses the Black King Bar order in that case; Disable Guard (Hero tab) uses the item before the disable lands. Silence does not block items.")
    local me = GetLocalHeroHandle()
    if me ~= 0 then
        local fx = GetStatusEffects(me)
        DrawText("Status effects on me now: " .. (fx and (#fx > 0 and table.concat(fx, ", ") or "none") or "unreadable"))
    end
end
