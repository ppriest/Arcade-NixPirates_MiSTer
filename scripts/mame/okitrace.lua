-- The M6295's command writes (0xa00001) and the out_w bank bit (0x600001, bit 6), timed, for
-- sim/sound_tb. Run with -wavwrite for MAME's own output of the same run.
--
--   OT_OUT      output file: one line a write, "<seconds> <o|b> <hex byte>"
--   OT_SECONDS  emulated seconds to run

local OUT     = os.getenv("OT_OUT")
local SECONDS = tonumber(os.getenv("OT_SECONDS") or "30")

local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]
local f    = assert(io.open(OUT, "w"))

local function now()
    return mach.time:as_double()
end

_G.__ot_taps = {
    prog:install_write_tap(0xa00000, 0xa00001, "ot_oki", function(offset, data, mask)
        if mask & 0xff ~= 0 then f:write(string.format("%.9f o %02x\n", now(), data & 0xff)) end
    end),
    prog:install_write_tap(0x600000, 0x600001, "ot_out", function(offset, data, mask)
        if mask & 0xff ~= 0 then f:write(string.format("%.9f b %02x\n", now(), (data >> 6) & 1)) end
    end),
}

emu.register_frame_done(function()
    if now() >= SECONDS then
        f:close()
        mach:exit()
    end
end)
