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
file mkdir $report_root
create_project -force l1d_baseline $build_dir -part $part_name
set_property target_language Verilog [current_project]

add_files -norecurse [list \
    [file join $src_dir l1d_sram.sv] \
    [file join $src_dir l1d_next_line_prefetch.sv] \
    [file join $src_dir l1d_cache.sv]]
add_files -fileset sim_1 -norecurse [file join $src_dir tb_l1d_cache.sv]
add_files -fileset constrs_1 -norecurse \
    [file join $constraints_dir l1d_baseline.xdc]

set_property top l1d_cache [get_filesets sources_1]
set_property top tb_l1d_cache [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set simulation_configurations [list \
    [list direct_mapped_vc4 \
        "NUM_WAYS=1 ENABLE_PREFETCH=0 VICTIM_ENTRIES=4" ""] \
    [list two_way_vc4 \
        "NUM_WAYS=2 ENABLE_PREFETCH=0 VICTIM_ENTRIES=4" ""] \
    [list two_way_vc8 \
        "NUM_WAYS=2 ENABLE_PREFETCH=0 VICTIM_ENTRIES=8" ""] \
    [list next_line_prefetch_vc4 \
        "NUM_WAYS=2 ENABLE_PREFETCH=1 VICTIM_ENTRIES=4" ""] \
    [list workload_direct_mapped_vc4 \
        "NUM_WAYS=1 ENABLE_PREFETCH=0 VICTIM_ENTRIES=4" \
        "-testplusarg WORKLOADS_ONLY"] \
    [list workload_two_way_vc4 \
        "NUM_WAYS=2 ENABLE_PREFETCH=0 VICTIM_ENTRIES=4" \
        "-testplusarg WORKLOADS_ONLY"] \
    [list workload_next_line_prefetch_vc4 \
        "NUM_WAYS=2 ENABLE_PREFETCH=1 VICTIM_ENTRIES=4" \
        "-testplusarg WORKLOADS_ONLY"]]

foreach configuration $simulation_configurations {
    lassign $configuration name generics more_options
    puts "Running Vivado behavioral simulation: $name"
    set_property generic $generics [get_filesets sim_1]
    set_property -dict [list \
        xsim.simulate.xsim.more_options $more_options] \
        [get_filesets sim_1]
    launch_simulation -simset sim_1 -mode behavioral
    run all
    close_sim

    set sim_log [file join $build_dir l1d_baseline.sim sim_1 behav xsim simulate.log]
    if {[file exists $sim_log]} {
        file copy -force $sim_log \
            [file join $report_root "${name}_simulation.log"]
    }
}

set synthesis_configurations [list \
    [list direct_mapped_vc4 \
        "NUM_WAYS=1 ENABLE_PREFETCH=0 VICTIM_ENTRIES=4"] \
    [list two_way_vc4 \
        "NUM_WAYS=2 ENABLE_PREFETCH=0 VICTIM_ENTRIES=4"] \
    [list two_way_vc8 \
        "NUM_WAYS=2 ENABLE_PREFETCH=0 VICTIM_ENTRIES=8"] \
    [list next_line_prefetch_vc4 \
        "NUM_WAYS=2 ENABLE_PREFETCH=1 VICTIM_ENTRIES=4"]]

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
