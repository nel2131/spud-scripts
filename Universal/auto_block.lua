-- auto_block.lua - creep block, folder scripts\Universal\ (loaded for EVERY hero; ini section
-- [Universal.auto_block]).
--
-- HOLD the hold key (default: mouse XBUTTON2, the same button the old C++ block used) while your wave
-- marches, and the hero walks in front of the closest lane creep, on its path, so the wave keeps running
-- into the hero instead of moving on. Release the key (or stop the creep) and the hero is yours again.
--
-- How it works now (the C++ version is gone):
--   * GetClosestLaneCreep()    the wave's creep nearest to me (either team - the one you face is both).
--   * IsCreepMoving(creep)     speed above 40 units/s. A creep that stopped - or is standing still
--                              swinging at someone - reads as NOT moving, and the hero stops blocking.
--   * GetCreepVelocity(creep)  the creep's smoothed world velocity (units per second, from the same
--                              per-frame position samples the overlays use) -> the path direction.
--   * MoveTo(point)            1 point = the creep's position + direction * Block Distance. Re-sent at
--                              most every 100 ms, so the hero keeps catching up with the turning creep.
--
-- HOLD ONLY: the key is polled with IsKeyDown, which reads the Game window focus / menu / panic gates
-- itself - nothing runs while you type in menus or when panic is on.

enabledBlock = GetSaved("Enable Auto Block", false)
blockDist    = math.tointeger(GetSaved("Block Distance", 400)) or 400
holdVk       = math.tointeger(GetSaved("Hold key", 6)) or 6          -- VK_XBUTTON2 by default (mouse button 5)

local diagNextMs = 0

function OnTick()
    if not enabledBlock then return end
    if not IsKeyDown(holdVk) then return end                          -- not held: the hero is the user's

    local now = TimeMs()
    local me = GetLocalHeroHandle()
    local heroHp = me ~= 0 and GetEntityHealth(me) or nil
    if not heroHp or heroHp <= 0 then return end

    local creep = GetClosestLaneCreep()
    if not creep then return end

    local moving = IsCreepMoving(creep)
    if moving == nil or moving == false then return end               -- stopped / attacking: stop blocking

    local vx, vy = GetCreepVelocity(creep)
    if not vx then return end
    local pos = GetEntityPosition(creep)
    if not pos then return end
    local hpos = GetEntityPosition(me)
    if not hpos then return end
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed < 1 then return end                                      -- moving flag on but no vector: skip a junk frame
    local dx, dy = vx / speed, vy / speed
    local tx, ty = pos[1] + dx * blockDist, pos[2] + dy * blockDist

    -- MoveTo throttles nothing itself; keep the order stream one per 100 ms so the creep can turn and the
    -- hero steers with it instead of stacking 8 orders per frame in the queue.
    luaBlockOrderMs = luaBlockOrderMs or 0
    if now - luaBlockOrderMs >= 100 then
        local ok = MoveTo(tx, ty)
        if ok and now >= diagNextMs then
            diagNextMs = now + 1000
            local d = math.sqrt((pos[1] - hpos[1]) ^ 2 + (pos[2] - hpos[2]) ^ 2)
            LogMessage(string.format("block: leading creep %d, %.0f away, speed %.0f, aiming %d units ahead", creep, d, speed, blockDist))
        end
        luaBlockOrderMs = now
    end
end

function Settings()
    enabledBlock = DrawCheckbox("Enable Auto Block", enabledBlock)
    blockDist = DrawSliderInt("Block Distance (units ahead of the creep)", 150, 800, blockDist)
    holdVk = DrawKeybind("Hold key", holdVk)
    DrawText("While the hold key is down the hero stands in front of the closest lane creep, on its path, blocking the wave. Release to play freely.")
    DrawText("When the creep stops moving (or stands to attack), the hero stops blocking until it moves again.")
end
