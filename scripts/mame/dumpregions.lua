-- SPDX-License-Identifier: GPL-3.0-or-later
-- Dump ROM regions as MAME holds them after driver init (decrypted, patched),
-- for scripts/decrypt_model.py.
--
--   DR_OUT      output directory; one <region>.bin per region
--   DR_REGIONS  "maincpu,tiles,..." region tags without the leading colon
--
-- Each region is written in 16-bit big-endian byte order via read_u16 when its
-- tag is maincpu (the 68000's view), byte by byte otherwise.

local OUT  = os.getenv("DR_OUT")
local RGNS = os.getenv("DR_REGIONS") or "maincpu"
local mach = manager.machine

emu.register_frame_done(function()
    for tag in string.gmatch(RGNS, "([^,]+)") do
        local r = assert(mach.memory.regions[":" .. tag], "no region " .. tag)
        local f = assert(io.open(OUT .. "/" .. tag .. ".bin", "wb"))
        local parts = {}
        if tag == "maincpu" then
            for i = 0, r.size // 2 - 1 do
                local w = r:read_u16(i * 2)
                parts[#parts + 1] = string.char(w >> 8, w & 0xff)
                if #parts == 4096 then f:write(table.concat(parts)); parts = {} end
            end
        else
            for i = 0, r.size - 1 do
                parts[#parts + 1] = string.char(r:read_u8(i))
                if #parts == 4096 then f:write(table.concat(parts)); parts = {} end
            end
        end
        f:write(table.concat(parts))
        f:close()
    end
    mach:exit()
end)
