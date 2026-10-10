-- Which 256-byte pages the main CPU reads and writes, from power-on, for
-- scripts/mem_scan.py. Also the first 0x100 words of the (decrypted)
-- "maincpu" region: the vector table as the CPU sees it.
--
--   MS_OUT     output file
--   MS_FRAMES  frames to run
--   MS_COIN    frame to insert a coin and press Start (0 = attract only)
--   MS_MAPPED  "hexlo:hexhi,..." the driver's mapped ranges; any access outside
--              them is also logged by exact address, with the PC and frame
--              of its first occurrence
--
-- Program-ROM reads (0x000000-0x0fffff) are not tapped: they are every fetch.

local OUT    = os.getenv("MS_OUT")
local FRAMES = tonumber(os.getenv("MS_FRAMES") or "3600")
local COIN   = tonumber(os.getenv("MS_COIN") or "0")

local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]
local rgn  = mach.memory.regions[":maincpu"]

local cpu = mach.devices[":maincpu"]
local mapped = {}
for spec in string.gmatch(os.getenv("MS_MAPPED") or "", "([^,]+)") do
    local lo, hi = spec:match("(%x+):(%x+)")
    mapped[#mapped + 1] = {tonumber(lo, 16), tonumber(hi, 16)}
end
local function is_mapped(a)
    for _, r in ipairs(mapped) do
        if a >= r[1] and a <= r[2] then return true end
    end
    return false
end
local odd = {}      -- "w 500800" -> {count, first pc, first frame}
local n = 0
local function note(kind, offset)
    if #mapped == 0 or is_mapped(offset) then return end
    local k = string.format("%s %06x", kind, offset)
    local e = odd[k]
    if e then e[1] = e[1] + 1 else odd[k] = {1, cpu.state["PC"].value, n} end
end

local rd, wr = {}, {}
_G.__ms_taps = {
    prog:install_write_tap(0x000000, 0xffffff, "ms_w", function(offset, data, mask)
        local p = offset >> 8
        wr[p] = (wr[p] or 0) + 1
        note("w", offset)
        return data
    end),
    prog:install_read_tap(0x100000, 0xffffff, "ms_r", function(offset, data, mask)
        local p = offset >> 8
        rd[p] = (rd[p] or 0) + 1
        note("r", offset)
        return data
    end),
}

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end
local f_coin, f_start = field("Coin 1"), field("1 Player Start")
local f_right, f_b1 = field("P1 Right"), field("P1 Button 1")

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
        f:write(string.format("frames %d\n", FRAMES))
        local function dump(tag, t)
            local keys = {}
            for k in pairs(t) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do f:write(string.format("%s %06x %d\n", tag, k << 8, t[k])) end
        end
        dump("w", wr)
        dump("r", rd)
        local keys = {}
        for k in pairs(odd) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local e = odd[k]
            f:write(string.format("odd %s %d %06x %d\n", k, e[1], e[2], e[3]))
        end
        local v = {}
        for i = 0, 0xff do v[#v + 1] = string.format("%04x", rgn:read_u16(i * 2)) end
        f:write("vec " .. table.concat(v, ",") .. "\n")
        f:close()
        mach:exit()
    end
end)
