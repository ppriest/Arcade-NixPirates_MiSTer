-- Sprites per scanline as MAME draws them, for scripts/sprite_load.py.
--
--   SL_OUT     output file
--   SL_SKIP    frames to run before counting
--   SL_FRAMES  frames to count
--   SL_COIN    frame to insert a coin, press Start, then hold P1 Right and
--              pulse P1 Button 1 (0 = attract only)
--
-- Walks the sprite list from the "spriteram" share the way pirates.cpp
-- draw_sprites() does (entry k: colour word 4k, x word 4k+1, code word 4k+2,
-- y word 4k-1; end at y bit 15), at frame_done, when MAME has just drawn it.
-- The share is read directly: 0x500000-0x5007ff is writeonly() in the CPU map.

local OUT    = os.getenv("SL_OUT")
local SKIP   = tonumber(os.getenv("SL_SKIP") or "600")
local FRAMES = tonumber(os.getenv("SL_FRAMES") or "1800")
local COIN   = tonumber(os.getenv("SL_COIN") or "0")

local mach  = manager.machine
local share = mach.memory.shares[":spriteram"]
assert(share, "no :spriteram share")

local VIS_TOP, VIS_BOT, VIS_W = 16, 239, 288

local function word(i) return share:read_u16(i * 2) end

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end
local f_coin, f_start = field("Coin 1"), field("1 Player Start")
local f_right, f_b1 = field("P1 Right"), field("P1 Button 1")

local line_max_any, line_max_vis = 0, 0
local frame_hist_vis = {}     -- per-frame worst visible-line count -> frames
local len_max, len_sum = 0, 0
local worst_frame, worst_line = -1, -1
local n = 0

emu.register_frame_done(function()
    n = n + 1
    if COIN > 0 and f_coin and f_start then
        f_coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
        f_start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
        if n >= COIN + 96 then
            if f_right then f_right:set_value(1) end
            if f_b1 then f_b1:set_value((n % 20) < 4 and 1 or 0) end
        end
    end
    if n <= SKIP then return end

    local any, vis = {}, {}
    local len = 0
    for k = 1, 254 do
        local yraw = word(4 * k - 1)
        if (yraw & 0x8000) ~= 0 then break end
        len = len + 1
        local x = word(4 * k + 1) - 32
        local y = 0xf2 - yraw
        local onx = (x + 15 >= 0) and (x < VIS_W)
        for l = math.max(y, VIS_TOP), math.min(y + 15, VIS_BOT) do
            any[l] = (any[l] or 0) + 1
            if onx then vis[l] = (vis[l] or 0) + 1 end
        end
    end
    len_sum = len_sum + len
    if len > len_max then len_max = len end
    local fmax = 0
    for l, c in pairs(any) do if c > line_max_any then line_max_any = c end end
    for l, c in pairs(vis) do
        if c > fmax then fmax = c end
        if c > line_max_vis then line_max_vis = c; worst_frame = n; worst_line = l end
    end
    frame_hist_vis[fmax] = (frame_hist_vis[fmax] or 0) + 1

    if n == SKIP + FRAMES then
        mach.video:snapshot()
        local f = assert(io.open(OUT, "w"))
        f:write(string.format("frames %d\nlist_max %d\nlist_mean %.1f\n", FRAMES, len_max, len_sum / FRAMES))
        f:write(string.format("line_max_any %d\nline_max_visible %d\nworst_frame %d\nworst_line %d\n",
            line_max_any, line_max_vis, worst_frame, worst_line))
        local keys = {}
        for k in pairs(frame_hist_vis) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do f:write(string.format("framemax %d %d\n", k, frame_hist_vis[k])) end
        f:close()
        mach:exit()
    end
end)
