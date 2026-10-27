-- SPDX-License-Identifier: GPL-3.0-or-later
-- Value census of the tile and sprite attribute words the game writes, for
-- scripts/attr_census.py.
--
--   AC_OUT     output file
--   AC_FRAMES  frames to run from power-on
--   AC_COIN    frame to insert a coin and press Start (0 = attract only)
--
-- Per tilemap (MAME's split of 0x900180-0x904187, pirates.cpp prg_map) the OR
-- and the maximum of every word written at an odd word offset from the layer
-- base (the colour word, get_*_tile_info) and at an even one (the code word);
-- the same for the four sprite words (draw_sprites).

local OUT    = os.getenv("AC_OUT")
local FRAMES = tonumber(os.getenv("AC_FRAMES") or "3600")
local COIN   = tonumber(os.getenv("AC_COIN") or "0")

local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]

local acc = {}
local function note(key, v)
    local e = acc[key]
    if not e then e = {0, 0, 0}; acc[key] = e end
    e[1] = e[1] | v
    if v > e[2] then e[2] = v end
    e[3] = e[3] + 1
end

local layers = {
    {"tx", 0x900180, 0x90137f},
    {"fg", 0x901380, 0x902a7f},
    {"bg", 0x902a80, 0x904187},
}
_G.__ac_taps = {}
for _, l in ipairs(layers) do
    local name, lo, hi = l[1], l[2], l[3]
    _G.__ac_taps[#_G.__ac_taps + 1] = prog:install_write_tap(lo, hi, "ac_" .. name, function(offset, data, mask)
        local w = (offset - lo) >> 1
        note(name .. ((w & 1) == 1 and "_colour" or "_code"), data & mask)
        return data
    end)
end
local SPR = {"colour", "x", "code", "y"}
_G.__ac_taps[#_G.__ac_taps + 1] = prog:install_write_tap(0x500000, 0x5007ff, "ac_spr", function(offset, data, mask)
    local w = (offset - 0x500000) >> 1
    note("spr_" .. SPR[(w & 3) + 1], data & mask)
    return data
end)

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end
local f_coin, f_start = field("Coin 1"), field("1 Player Start")
local f_right, f_b1 = field("P1 Right"), field("P1 Button 1")

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
    if n == FRAMES then
        local f = assert(io.open(OUT, "w"))
        local keys = {}
        for k in pairs(acc) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            f:write(string.format("%s or %04x max %04x writes %d\n", k, acc[k][1], acc[k][2], acc[k][3]))
        end
        f:close()
        mach:exit()
    end
end)
