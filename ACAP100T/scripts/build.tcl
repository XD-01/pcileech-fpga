# -----------------------------------------------------------------------------
# ACAP-100T Vivado batch build
#
# Usage (Windows):
#   vivado -mode batch -source scripts\build.tcl -tclargs -part xc7a100tfgg484-2 -jobs 8
#
# Usage (Linux):
#   vivado -mode batch -source scripts/build.tcl -tclargs -part xc7a100tfgg484-2 -jobs 8
#
# Outputs (output/):
#   acap100t.bit          JTAG configuration file
#   acap100t.bin          raw bitstream bin (CH347 / programmer input)
#   acap100t_flash.bin    SPIx4 flash image
#   acap100t.mcs          SPIx4 MCS image
#   timing_summary.rpt
#   utilization.rpt
#   drc.rpt
#
# The project is recreated on every run so that edits in src/ are always used.
# -----------------------------------------------------------------------------

proc fail { msg } {
    puts "-------------------------------------------------------------"
    puts " ERROR: $msg"
    puts "-------------------------------------------------------------"
    exit 1
}

set script_dir [file normalize [file dirname [info script]]]
set root       [file normalize "$script_dir/.."]
set part       "xc7a100tfgg484-2"
set jobs       8
set outdir     "$root/output"
set projdir    "$root/build/vivado"
set projname   "acap100t"

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
for {set i 0} {$i < $::argc} {incr i} {
    set opt [lindex $::argv $i]
    switch -- $opt {
        -part   { incr i; set part [lindex $::argv $i] }
        -jobs   { incr i; set jobs [lindex $::argv $i] }
        -outdir { incr i; set outdir [lindex $::argv $i] }
        -proj   { incr i; set projdir [lindex $::argv $i] }
        default { puts "WARNING: ignoring unknown argument '$opt'" }
    }
}

puts "-------------------------------------------------------------"
puts " ACAP-100T capture-card firmware build"
puts "   part    : $part"
puts "   jobs    : $jobs"
puts "   project : $projdir"
puts "   output  : $outdir"
puts "-------------------------------------------------------------"

# -----------------------------------------------------------------------------
# Project
# -----------------------------------------------------------------------------
if {[file exists $projdir]} {
    file delete -force $projdir
}
file mkdir $projdir
file mkdir $outdir

create_project -force $projname $projdir -part $part

# -----------------------------------------------------------------------------
# RTL
# -----------------------------------------------------------------------------
set rtl_files [glob -nocomplain -directory "$root/src" *.sv]
if {[llength $rtl_files] == 0} { fail "no RTL files found in $root/src" }
add_files -norecurse $rtl_files

set header "$root/src/acap_pkg.svh"
if {![file exists $header]} { fail "missing $header" }
add_files -norecurse $header
set header_obj [get_files $header]
set_property file_type "Verilog Header" $header_obj

set_property include_dirs [list "$root/src"] [get_filesets sources_1]
set_property top acap_top [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]

# -----------------------------------------------------------------------------
# IP and configuration-space images
# -----------------------------------------------------------------------------
# The XCI files were exported from the original CaptainDMA project and carry
# its relative .gen output directory.  Normalise that to a local directory so
# the build is self-contained when the XCIs are added by reference.
foreach xci [glob -nocomplain -directory "$root/ip" *.xci] {
    set fh [open $xci r]
    set data [read $fh]
    close $fh
    if {[string first "pcileech_100t484_x1.gen" $data] >= 0} {
        regsub -all {\.\./\.\./\.\./\.\./pcileech_100t484_x1\.gen/sources_1/ip} \
            $data {./ip_out} data
        set fh [open $xci w]
        puts -nonewline $fh $data
        close $fh
    }
}

set ip_files [glob -nocomplain -directory "$root/ip" *.xci]
if {[llength $ip_files] == 0} { fail "no IP files found in $root/ip" }
add_files -norecurse $ip_files
add_files -norecurse [glob -nocomplain -directory "$root/ip" *.coe]

set ips [get_ips -quiet *]
if {[llength $ips] == 0} { fail "no IP instances were recognised" }

# Upgrade the IPs to the installed Vivado version.  The original XCI files were
# produced by Vivado 2022.x; upgrade_ip keeps them usable in newer releases.
upgrade_ip $ips

foreach f [get_files -quiet *.xci] {
    set_property generate_files_for_reference 0 $f
    set_property registered_with_manager 1 $f
    if {![get_property is_locked $f]} {
        catch { set_property synth_checkpoint_mode Singular $f }
    }
}

# -----------------------------------------------------------------------------
# Constraints
# -----------------------------------------------------------------------------
set xdc "$root/constrs/acap100t.xdc"
if {![file exists $xdc]} { fail "missing $xdc" }
add_files -fileset constrs_1 -norecurse $xdc

# -----------------------------------------------------------------------------
# Runs (create them if the Vivado version did not do so automatically)
# -----------------------------------------------------------------------------
set year [lindex [split [version -short] "."] 0]

if {[get_runs -quiet synth_1] == ""} {
    create_run -name synth_1 -part $part \
        -flow "Vivado Synthesis $year" \
        -strategy "Vivado Synthesis Defaults" \
        -constrset constrs_1
}
if {[get_runs -quiet impl_1] == ""} {
    create_run -name impl_1 -part $part \
        -flow "Vivado Implementation $year" \
        -strategy "Vivado Implementation Defaults" \
        -constrset constrs_1 -parent_run synth_1
}

set_property steps.write_bitstream.args.bin_file    1 [get_runs impl_1]
set_property steps.write_bitstream.args.readback_file 0 [get_runs impl_1]
set_property steps.write_bitstream.args.verbose     0 [get_runs impl_1]

# -----------------------------------------------------------------------------
# Synthesis
# -----------------------------------------------------------------------------
puts "-------------------------------------------------------------"
puts " SYNTHESIS"
puts "-------------------------------------------------------------"
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    fail "synthesis failed: [get_property STATUS [get_runs synth_1]]"
}

# -----------------------------------------------------------------------------
# Implementation + bitstream
# -----------------------------------------------------------------------------
puts "-------------------------------------------------------------"
puts " IMPLEMENTATION / BITSTREAM"
puts "-------------------------------------------------------------"
launch_runs impl_1 -jobs $jobs -to_step write_bitstream
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
if {![string match "*Complete*" $impl_status]} {
    fail "implementation failed: $impl_status"
}

set impl_dir [get_property DIRECTORY [get_runs impl_1]]
set bit_src  [file join $impl_dir "acap_top.bit"]
set bin_src  [file join $impl_dir "acap_top.bin"]

if {![file exists $bit_src]} { fail "bitstream not found: $bit_src" }
if {![file exists $bin_src]} { fail "bin file not found: $bin_src" }

file copy -force $bit_src [file join $outdir "acap100t.bit"]
file copy -force $bin_src [file join $outdir "acap100t.bin"]

# Flash images.  The CaptainDMA 100T uses a 4-bit SPI flash.  The raw .bin
# above is what the CH347 programming tool expects; the cfgmem outputs are
# provided for JTAG / indirect SPI programming flows.
write_cfgmem -force -format BIN -interface SPIx4 -size 16 \
    -loadbit "up 0x00000000 $bit_src" \
    [file join $outdir "acap100t_flash.bin"]

write_cfgmem -force -format MCS -interface SPIx4 -size 16 \
    -loadbit "up 0x00000000 $bit_src" \
    [file join $outdir "acap100t.mcs"]

# -----------------------------------------------------------------------------
# Reports
# -----------------------------------------------------------------------------
open_run impl_1
report_timing_summary -delay_type max -max_paths 20 -file [file join $outdir "timing_summary.rpt"]
report_utilization -file [file join $outdir "utilization.rpt"]
report_drc -file [file join $outdir "drc.rpt"]
close_design

puts "-------------------------------------------------------------"
puts " BUILD COMPLETE"
puts "   $outdir/acap100t.bit"
puts "   $outdir/acap100t.bin"
puts "   $outdir/acap100t_flash.bin"
puts "   $outdir/acap100t.mcs"
puts "-------------------------------------------------------------"
