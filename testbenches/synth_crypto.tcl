# Run with Vivado batch mode. Optional first -tclargs argument is My_Top_Module;
# otherwise synthesize just the multiplier for the Basys 3 at 100 MHz.
set repo [file normalize [file join [file dirname [info script]] ..]]
set rtl [file join $repo kryptonite kryptonite.srcs sources_1 new]
set mem [file join $repo kryptonite kryptonite.srcs sources_1 imports mem_files]
set run [file join $repo .crypto.sim]
file mkdir $run
cd $run
foreach path [glob [file join $mem *.mem]] {
    file copy -force $path [file join $run [file tail $path]]
}
set keys [file join $run crypto keys board1]
file mkdir $keys
foreach path [glob [file join $repo crypto keys board1 *.mem]] {
    file copy -force $path [file join $keys [file tail $path]]
}
set top shared_poly_multiplier
if {$argc > 0} { set top [lindex $argv 0] }
if {$top ni {shared_poly_multiplier My_Top_Module}} { error "Unsupported top: $top" }
if {$top eq "My_Top_Module"} {
    read_vhdl [glob [file join $rtl *.vhd]]
    read_verilog [glob [file join $rtl *.v]]
    foreach path [glob [file join $repo anannya_ui *.v]] {
        if {![string match tb_* [file tail $path]]} { read_verilog [list $path] }
    }
} else {
    foreach name {shared_poly_multiplier mod_mult_pipeline ntt_core intt_core butterfly butterfly_inv barrett_reduce} {
        read_verilog [list [file join $rtl $name.v]]
    }
}
set clock_file [file join $run crypto_clock.xdc]
set channel [open $clock_file w]
puts $channel {create_clock -name clk -period 10.000 [get_ports clk]}
close $channel
read_xdc [list $clock_file]
if {$top eq "My_Top_Module"} {
    # Preserve the PS/2 bidirectional pins as real I/O buffers at board level.
    synth_design -top $top -part xc7a35tcpg236-1
} else {
    synth_design -top $top -part xc7a35tcpg236-1 -mode out_of_context
}
report_utilization -file ${top}_utilization.rpt
report_timing_summary -file ${top}_timing.rpt
write_checkpoint -force ${top}_synth.dcp
puts "PASS: synthesized $top for xc7a35tcpg236-1"
puts "Worst setup slack (ns): [get_property SLACK [get_timing_paths -max_paths 1]]"
