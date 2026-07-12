set root_dir [file normalize [file join [file dirname [info script]] ..]]
set src_dir [file join $root_dir src]
set constraints_dir [file join $root_dir constraints]
set build_dir [file join $root_dir build vivado]
set report_root [file join $build_dir reports]

set part_name xc7a35tcpg236-1
if {[info exists ::env(L1D_PART)]} {
    set part_name $::env(L1D_PART)
}

file mkdir $build_dir
if {[file exists $report_root]} {
    file delete -force $report_root
}
file mkdir $report_root
create_project -force l1d_baseline $build_dir -part $part_name
set_property target_language Verilog [current_project]

add_files -norecurse [list \
    [file join $src_dir l1d_sram.sv] \
    [file join $src_dir l1d_next_line_prefetch.sv] \
    [file join $src_dir l1d_cache.sv]]
add_files -fileset sim_1 -norecurse [list \
    [file join $src_dir tb_l1d_cache.sv] \
    [file join $src_dir tb_l1d_cache_oop.sv]]
add_files -fileset constrs_1 -norecurse \
    [file join $constraints_dir l1d_baseline.xdc]

set_property top l1d_cache [get_filesets sources_1]
set_property top tb_l1d_cache_oop [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

proc write_run_all_tcl {path} {
    set fp [open $path w]
    puts $fp "run all"
    close $fp
}

proc write_vcd_run_tcl {path vcd_path} {
    set fp [open $path w]
    puts $fp [format {open_vcd {%s}} $vcd_path]
    foreach pattern [list \
        /tb_l1d_cache_oop/clk \
        /tb_l1d_cache_oop/bus/rst_n \
        /tb_l1d_cache_oop/bus/cfg_* \
        /tb_l1d_cache_oop/bus/cpu_* \
        /tb_l1d_cache_oop/bus/mem_* \
        /tb_l1d_cache_oop/bus/stat_* \
        /tb_l1d_cache_oop/bus/event_* \
        /tb_l1d_cache_oop/bus/cache_idle \
        /tb_l1d_cache_oop/bus/debug_*] {
        puts $fp [format {set objs [get_objects -quiet {%s}]} $pattern]
        puts $fp {if {[llength $objs] > 0} {log_vcd $objs}}
    }
    puts $fp "run all"
    puts $fp "close_vcd"
    close $fp
}

set smoke_trace [file normalize [file join $root_dir traces smoke.trace]]
set generated_pointer_trace [file normalize \
    [file join $root_dir traces generated phase3_pointer_permutation.trace]]
set run_all_tcl [file join $build_dir xsim_run_all.tcl]
write_run_all_tcl $run_all_tcl

set simulation_configurations [list \
    [list dm_s8_vc4_pf0 \
        "NUM_WAYS=1 NUM_SETS=8 LINE_BYTES=16 ENABLE_PREFETCH=0 VICTIM_ENTRIES=4 MEM_LATENCY=2 MEM_BACKPRESSURE_MODE=1 CPU_BACKPRESSURE_MODE=0" "-testplusarg CONFIG_ID=dm_s8_vc4_pf0"] \
    [list 2w_s4_vc4_pf0 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=0 VICTIM_ENTRIES=4 MEM_LATENCY=2 MEM_BACKPRESSURE_MODE=1 CPU_BACKPRESSURE_MODE=0" "-testplusarg CONFIG_ID=2w_s4_vc4_pf0"] \
    [list 2w_s4_vc8_pf0 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=0 VICTIM_ENTRIES=8 MEM_LATENCY=2 MEM_BACKPRESSURE_MODE=1 CPU_BACKPRESSURE_MODE=0" "-testplusarg CONFIG_ID=2w_s4_vc8_pf0"] \
    [list 2w_s4_vc4_pf1 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=1 VICTIM_ENTRIES=4 MEM_LATENCY=2 MEM_BACKPRESSURE_MODE=1 CPU_BACKPRESSURE_MODE=0" "-testplusarg CONFIG_ID=2w_s4_vc4_pf1"] \
    [list trace_replay_smoke_2w_s4_vc4_pf0 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=0 VICTIM_ENTRIES=4 MEM_LATENCY=2 MEM_BACKPRESSURE_MODE=1 CPU_BACKPRESSURE_MODE=0" \
        "-testplusarg TRACE=$smoke_trace -testplusarg TRACE_ID=smoke -testplusarg CONFIG_ID=2w_s4_vc4_pf0"] \
    [list trace_replay_generated_pointer_2w_s4_vc4_pf1 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=1 VICTIM_ENTRIES=4 MEM_LATENCY=2 MEM_BACKPRESSURE_MODE=1 CPU_BACKPRESSURE_MODE=0" \
        "-testplusarg TRACE=$generated_pointer_trace -testplusarg TRACE_ID=generated_pointer -testplusarg CONFIG_ID=2w_s4_vc4_pf1"] \
    [list 2w_s4_vc4_pf1_low_latency \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=1 VICTIM_ENTRIES=4 MEM_LATENCY=0 MEM_BACKPRESSURE_MODE=0 CPU_BACKPRESSURE_MODE=0" "-testplusarg CONFIG_ID=2w_s4_vc4_pf1"] \
    [list 2w_s4_vc4_pf1_high_latency_random_bp \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=1 VICTIM_ENTRIES=4 MEM_LATENCY=8 MEM_BACKPRESSURE_MODE=2 CPU_BACKPRESSURE_MODE=0" "-testplusarg CONFIG_ID=2w_s4_vc4_pf1"]]

foreach configuration $simulation_configurations {
    lassign $configuration name generics more_options
    puts "Running Vivado behavioral simulation: $name"
    set_property generic $generics [get_filesets sim_1]
    set custom_tcl $run_all_tcl
    set run_more_options $more_options
    if {$name eq "2w_s4_vc4_pf1"} {
        set vcd_path [file join $report_root "${name}.vcd"]
        set run_more_options [string trim \
            "$run_more_options -testplusarg DUMP_VCD=$vcd_path"]
    }
    set_property -dict [list \
        xsim.simulate.xsim.more_options $run_more_options \
        xsim.simulate.custom_tcl $custom_tcl \
        xsim.simulate.log_all_signals false] \
        [get_filesets sim_1]
    launch_simulation -simset sim_1 -mode behavioral
    catch {close_sim}

    set sim_log [file join $build_dir l1d_baseline.sim sim_1 behav xsim simulate.log]
    if {[file exists $sim_log]} {
        file copy -force $sim_log \
            [file join $report_root "${name}_simulation.log"]
    }
}

set synthesis_configurations [list \
    [list dm_s8_vc4_pf0 \
        "NUM_WAYS=1 NUM_SETS=8 LINE_BYTES=16 ENABLE_PREFETCH=0 VICTIM_ENTRIES=4"] \
    [list 2w_s4_vc4_pf0 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=0 VICTIM_ENTRIES=4"] \
    [list 2w_s4_vc8_pf0 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=0 VICTIM_ENTRIES=8"] \
    [list 2w_s4_vc4_pf1 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=1 VICTIM_ENTRIES=4"]]

foreach configuration $synthesis_configurations {
    lassign $configuration name generics
    set report_dir [file join $report_root $name]
    file mkdir $report_dir

    puts "Running Vivado synthesis: $name"
    set_property generic $generics [get_filesets sources_1]
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1

    set run_status [get_property STATUS [get_runs synth_1]]
    if {![string match "*Complete*" $run_status]} {
        error "Synthesis failed for $name: $run_status"
    }

    open_run synth_1
    report_utilization \
        -file [file join $report_dir utilization.rpt]
    report_timing_summary \
        -file [file join $report_dir timing_summary.rpt]
    report_power \
        -file [file join $report_dir power.rpt]
    close_design
}

puts "Vivado simulation and synthesis matrix completed: $report_root"
