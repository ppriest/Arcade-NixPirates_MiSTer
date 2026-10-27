# SPDX-License-Identifier: GPL-3.0-or-later
# Read the core's debug probes over JTAG (In-System Sources and Probes).
#
#   python scripts/read_issp.py [instance] [clear] [set N] [pulse N]
#
# SignalTap acquisition is GUI-only in Quartus Prime Lite 17.0 -- there are no
# *signaltap* Tcl commands -- so ISSP is what a headless workflow can drive.
#
# The probe bus layout is defined where the bus is BUILT (the issp instance in
# the top-level .sv), not here. Keep the field tables in step with it: a
# silently shifted field decodes as plausible nonsense rather than as an error.
#
# Counters typically SATURATE and count per-cycle events, so they pin almost
# immediately: `clear` first and read again for a rate.

# --- core-specific: edit for this core -------------------------------------
# One table per ISSP instance id, {name lo hi format}; format is dec, sdec
# (signed 16), hex or bit. Bit numbers index the probe bus as the RTL
# concatenates it. Add an entry to the `switch` further down for each table.
# By convention source bit 0 pulsed is the counter clear.
# F: NixPirates.sv, "Instance F"
set fields_F {
    {rom_bytes        0  31 dec}
    {bus_cycles      32  63 dec}
    {last_addr       64  87 hex}
    {oki_writes      88 103 dec}
    {frames         104 111 dec}
    {rom_loaded     112 112 bit}
    {core_reset     113 113 bit}
    {ioctl_download 114 114 bit}
    {dl_seen_wr     115 115 bit}
    {ldr_active     116 116 bit}
    {ldr_done       117 117 bit}
    {flip           118 118 bit}
    {pll_locked     119 119 bit}
    {reset          120 120 bit}
    {RESET          121 121 bit}
    {status0        122 122 bit}
    {buttons1       123 123 bit}
    {dl0_seen       124 124 bit}
    {ldr_pending    125 125 bit}
    {pause_cpu      126 126 bit}
    {hs_pause       127 127 bit}
}
# D, E: NixPirates.sv, "Instance D", "Instance E"
set fields_D {
    {core_nz   0  15 dec} {vga_nz   16  31 dec} {pal_nz   32  47 dec} {pen_nz   48  63 dec}
    {pal_wr   64  79 dec} {vram_wr  80  95 dec} {b1_rdy   96 111 dec} {b2_rdy  112 127 dec}
}
set fields_E {
    {b1_nz     0  15 dec} {b2_nz    16  31 dec} {vis      32  47 dec} {de       48  63 dec}
    {last_pen 64  76 hex} {last_pal 77  92 hex} {crt_on   93  93 bit} {fb_en    94  94 bit}
    {fsd      95  95 bit} {dvideo   96  96 bit} {fx       97  99 dec}
}
set fields_G {
    {c0_data   0  15 hex} {c0_addr  16  38 hex} {c0_rw  39  39 bit}
    {c1_data  40  55 hex} {c1_addr  56  78 hex} {c1_rw  79  79 bit}
    {c2_data  80  95 hex} {c2_addr  96 118 hex} {c2_rw 119 119 bit} {nvec_lo 120 127 dec}
}
set fields_H {
    {c3_data   0  15 hex} {c3_addr  16  38 hex} {c3_rw  39  39 bit}
    {c4_data  40  55 hex} {c4_addr  56  78 hex} {c4_rw  79  79 bit}
    {c5_data  80  95 hex} {c5_addr  96 118 hex} {c5_rw 119 119 bit} {nvec_hi 120 127 dec}
}
# ---------------------------------------------------------------------------

proc bits_to_int {s lo hi} {
    # read_probe_data returns the bus MSB-first, so index from the right.
    set n [string length $s]
    set v 0
    for {set i $hi} {$i >= $lo} {incr i -1} {
        set c [string index $s [expr {$n - 1 - $i}]]
        set v [expr {$v * 2 + ($c eq "1" ? 1 : 0)}]
    }
    return $v
}

set do_clear [expr {[lsearch -exact $argv "clear"] >= 0}]
# `set N`   : write source byte N (decimal) and leave it
# `pulse N` : write N, then 0 -- for the edge-triggered controls
set set_val -1; set pulse_val -1
set i [lsearch -exact $argv "set"];   if {$i >= 0} { set set_val   [lindex $argv [expr {$i+1}]] }
set i [lsearch -exact $argv "pulse"]; if {$i >= 0} { set pulse_val [lindex $argv [expr {$i+1}]] }

set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
if {$hw eq ""} { puts "NO JTAG HARDWARE FOUND"; exit 1 }
puts "hardware: $hw"

set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match "*5CSEBA6*" $d] || [string match "*5CSE*" $d] || $dev eq ""} {
        set dev $d
    }
}
if {$dev eq ""} { puts "NO DEVICE FOUND"; exit 1 }
puts "device:   $dev"

# Query instance info BEFORE opening a session: with a session already active
# this fails with "There is already an active In-System Sources and Probes
# session started."
set insts [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
if {[llength $insts] == 0} {
    puts "NO ISSP INSTANCES -- is this an instrumented build?"
    exit 1
}
foreach i $insts { puts "instance: $i" }

# Take the first instance unless one is named on the command line (a single
# argument that is not a keyword or a keyword's value).
set want ""
set skip 0
foreach a $argv {
    if {$skip} { set skip 0; continue }
    if {$a eq "set" || $a eq "pulse"} { set skip 1; continue }
    if {$a ne "clear"} { set want $a }
}
set idx [lindex [lindex $insts 0] 0]
set inst_id [lindex [lindex $insts 0] 3]
if {$want ne ""} {
    foreach i $insts {
        if {[lindex $i 3] eq $want} { set idx [lindex $i 0]; set inst_id $want }
    }
}

# The field table belongs to the INSTANCE. An unrecognised id stops rather
# than guesses.
switch -- $inst_id {
    F       { set fields $fields_F }
    D       { set fields $fields_D }
    E       { set fields $fields_E }
    G       { set fields $fields_G }
    H       { set fields $fields_H }
    default {
        puts "instance id '$inst_id' has no field table -- add one before reading it"
        exit 1
    }
}
puts "decoding instance $inst_id"

start_insystem_source_probe -device_name $dev -hardware_name $hw
set raw [read_probe_data -instance_index $idx]
puts "raw ([string length $raw] bits): $raw"
puts ""

foreach f $fields {
    lassign $f name lo hi fmt
    set v [bits_to_int $raw $lo $hi]
    switch $fmt {
        sdec { if {$v >= 32768} { set v [expr {$v - 65536}] }; puts [format "  %-16s %d" $name $v] }
        hex  { puts [format "  %-16s 0x%08X" $name $v] }
        bit  { puts [format "  %-16s %s"     $name [expr {$v ? "yes" : "no"}]] }
        default { puts [format "  %-16s %d"  $name $v] }
    }
}

# write_source_data takes a BINARY STRING unless -value_in_hex is given; a
# decimal "8" is silently rejected. Every write goes through this, in hex.
proc write_src {idx v} { write_source_data -instance_index $idx -value [format %X $v] -value_in_hex }
if {$set_val >= 0}   { write_src $idx $set_val;   puts "source set to $set_val (reads back 0x[read_source_data -instance_index $idx -value_in_hex])" }
if {$pulse_val >= 0} { write_src $idx $pulse_val; write_src $idx 0; puts "source pulsed $pulse_val" }

if {$do_clear} {
    # Source bit 0 is the counter clear, by convention; the counters are
    # deliberately not reset by the core's own reset.
    write_src $idx 1
    write_src $idx 0
    puts "\ncounters cleared"
}

end_insystem_source_probe
