-- SPDX-License-Identifier: GPL-3.0-or-later
-- Video state at several frames, for scripts/vid_capture.py: what MAME drew each frame
-- from, dumped in the same frame_done callback that follows the drawing.
--
--   VC_OUT     output directory (exists); writes f<frame>_{vram,palette,spriteram,scroll}.bin
--              and MAME's snapshot of the same frame (snapshot directory: -snapshot_directory)
--   VC_FRAMES  "900,1500,..." frames to capture, ascending
--   VC_COIN    frame to insert a coin and press Start, then hold P1 Right and pulse
--              P1 Button 1 (0 = attract only)
--
-- Tile RAM and palette through the CPU's view (pirates.cpp 351-356, readable RAM); the
-- write-only sprite list and scroll from their shares (347, 350).

local OUT    = os.getenv("VC_OUT")
local COIN   = tonumber(os.getenv("VC_COIN") or "0")
local frames = {}
for f in string.gmatch(os.getenv("VC_FRAMES") or "", "(%d+)") do frames[tonumber(f)] = true end
local last = 0
for f in pairs(frames) do if f > last then last = f end end

local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]
local function share(tag) return assert(mach.memory.shares[tag], "no share " .. tag) end
local spr, scr = share(":spriteram"), share(":scroll")

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
end
local f_coin, f_start = field("Coin 1"), field("1 Player Start")
local f_right, f_b1 = field("P1 Right"), field("P1 Button 1")

local function dump_space(path, lo, hi)
    local f = assert(io.open(path, "wb"))
    local parts = {}
    for a = lo, hi, 2 do
        local w = prog:read_u16(a)
        parts[#parts + 1] = string.char(w >> 8, w & 0xff)
    end
    f:write(table.concat(parts)); f:close()
end
local function dump_share(path, s, bytes)
    local f = assert(io.open(path, "wb"))
    local parts = {}
    for a = 0, bytes - 2, 2 do
        local w = s:read_u16(a)
        parts[#parts + 1] = string.char(w >> 8, w & 0xff)
    end
    f:write(table.concat(parts)); f:close()
end

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
    if frames[n] then
        local p = string.format("%s/f%d_", OUT, n)
        dump_space(p .. "vram.bin", 0x900000, 0x904187)
        dump_space(p .. "palette.bin", 0x800000, 0x803fff)
        dump_share(p .. "spriteram.bin", spr, 0x800)
        dump_share(p .. "scroll.bin", scr, 2)
        mach.video:snapshot()
        print(string.format("VIDCAP frame %d", n))
    end
    if n >= last then mach:exit() end
end)
