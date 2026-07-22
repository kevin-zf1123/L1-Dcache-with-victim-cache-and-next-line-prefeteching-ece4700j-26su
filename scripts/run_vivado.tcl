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
    [file join $src_dir l1d_stream_prefetch.sv] \
    [file join $src_dir l1d_prefetch_controller.sv] \
    [file join $src_dir l1d_shadow_cache.sv] \
    [file join $src_dir l1d_cache_legacy.sv] \
    [file join $src_dir l1d_cache_optimized.sv] \
    [file join $src_dir l1d_cache.sv] \
    [file join $src_dir l1d_cache_deploy.sv] \
    [file join $src_dir l1d_fpga_harness.sv]]
add_files -fileset sim_1 -norecurse [list \
    [file join $src_dir tb_l1d_cache.sv] \
    [file join $src_dir tb_l1d_cache_oop.sv] \
    [file join $src_dir tb_l1d_prefetch_units.sv] \
    [file join $src_dir tb_l1d_cache_p3.sv] \
    [file join $src_dir tb_l1d_cache_optimized_p3.sv] \
    [file join $src_dir tb_l1d_fpga_harness.sv]]
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

proc write_saif_run_tcl {path saif_path} {
    set fp [open $path w]
    puts $fp [format {open_saif {%s}} $saif_path]
    # UG900's portable recursive form is relative to the simulator's current
    # scope; an absolute hierarchy pattern is not consistently accepted by
    # XSim when launched through a Vivado simulation fileset.
    puts $fp {set saif_objects [get_objects -r *]}
    puts $fp {if {[llength $saif_objects] == 0} {
        error "No objects matched the activity scope"
    }}
    puts $fp {log_saif $saif_objects}
    puts $fp "run all"
    puts $fp "close_saif"
    close $fp
}

proc normalize_saif_root {path} {
    # XSim 2020.2 encodes a parameterized top as
    # tb_l1d_fpga_harness\(PARAM\=VALUE...\), which Vivado 2024.2's SAIF
    # reader rejects even though both tools are launched by the same Vivado
    # installation.  Only canonicalize that root instance token; all nested
    # hierarchy and activity records remain byte-for-byte semantically equal.
    set fp [open $path r]
    set text [read $fp]
    close $fp
    set replacements [regsub -all -line -- \
        {^[ \t]*\(INSTANCE[ \t]+tb_l1d_fpga_harness[^\r\n]*} \
        $text {   (INSTANCE tb_l1d_fpga_harness} normalized]
    if {$replacements != 1} {
        error "Expected exactly one parameterized SAIF root in $path; found $replacements"
    }
    set fp [open $path w]
    puts -nonewline $fp $normalized
    close $fp
}

proc write_synthesis_reports {report_dir} {
    report_utilization \
        -file [file join $report_dir utilization.rpt]
    report_utilization -hierarchical \
        -file [file join $report_dir hierarchical_utilization.rpt]
    report_timing_summary -delay_type min_max -report_unconstrained \
        -check_timing_verbose \
        -file [file join $report_dir timing_summary.rpt]
    report_timing -setup -max_paths 20 -nworst 20 -sort_by slack \
        -path_type full_clock_expanded \
        -file [file join $report_dir timing_top20.rpt]
    report_high_fanout_nets -timing -load_types -max_nets 50 \
        -file [file join $report_dir high_fanout.rpt]
    report_control_sets -verbose -sort_by {clk clkEn} \
        -file [file join $report_dir control_sets.rpt]
    check_timing -verbose \
        -file [file join $report_dir unconstrained_paths.rpt]
    report_power \
        -file [file join $report_dir power_vectorless.rpt]
}

proc write_implementation_reports {report_dir saif_path} {
    report_utilization \
        -file [file join $report_dir post_route_utilization.rpt]
    report_utilization -hierarchical \
        -file [file join $report_dir post_route_hierarchical_utilization.rpt]
    report_timing_summary -delay_type min_max -report_unconstrained \
        -check_timing_verbose \
        -file [file join $report_dir post_route_timing_summary.rpt]
    report_timing -setup -max_paths 20 -nworst 20 -sort_by slack \
        -path_type full_clock_expanded \
        -file [file join $report_dir post_route_timing_top20.rpt]
    report_high_fanout_nets -timing -load_types -max_nets 50 \
        -file [file join $report_dir post_route_high_fanout.rpt]
    report_control_sets -verbose -sort_by {clk clkEn} \
        -file [file join $report_dir post_route_control_sets.rpt]
    check_timing -verbose \
        -file [file join $report_dir post_route_unconstrained_paths.rpt]
    report_power \
        -file [file join $report_dir post_route_power_vectorless.rpt]
    read_saif -strip_path tb_l1d_fpga_harness/dut \
        -out_file [file join $report_dir activity_annotation.rpt] \
        $saif_path
    report_power \
        -file [file join $report_dir post_route_power_activity.rpt]
}

set smoke_trace [file normalize [file join $root_dir traces smoke.trace]]
set generated_pointer_trace [file normalize \
    [file join $root_dir traces generated phase3_pointer_permutation.trace]]
set run_all_tcl [file join $build_dir xsim_run_all.tcl]
write_run_all_tcl $run_all_tcl

set simulation_configurations [list \
    [list dm_s8_vc4_pf0 \
        "NUM_WAYS=1 NUM_SETS=8 LINE_BYTES=16 ENABLE_PREFETCH=0 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 VICTIM_ENTRIES=4 MEM_LATENCY=2 MEM_BACKPRESSURE_MODE=1 CPU_BACKPRESSURE_MODE=0" "-testplusarg CONFIG_ID=dm_s8_vc4_pf0"] \
    [list 2w_s4_vc4_pf0 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=0 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 VICTIM_ENTRIES=4 MEM_LATENCY=2 MEM_BACKPRESSURE_MODE=1 CPU_BACKPRESSURE_MODE=0" "-testplusarg CONFIG_ID=2w_s4_vc4_pf0"] \
    [list 2w_s4_vc8_pf0 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=0 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 VICTIM_ENTRIES=8 MEM_LATENCY=2 MEM_BACKPRESSURE_MODE=1 CPU_BACKPRESSURE_MODE=0" "-testplusarg CONFIG_ID=2w_s4_vc8_pf0"] \
    [list 2w_s4_vc4_pf1 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=1 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 VICTIM_ENTRIES=4 MEM_LATENCY=2 MEM_BACKPRESSURE_MODE=1 CPU_BACKPRESSURE_MODE=0" "-testplusarg CONFIG_ID=2w_s4_vc4_pf1"] \
    [list trace_replay_smoke_2w_s4_vc4_pf0 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=0 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 VICTIM_ENTRIES=4 MEM_LATENCY=2 MEM_BACKPRESSURE_MODE=1 CPU_BACKPRESSURE_MODE=0" \
        "-testplusarg TRACE=$smoke_trace -testplusarg TRACE_ID=smoke -testplusarg CONFIG_ID=2w_s4_vc4_pf0"] \
    [list trace_replay_generated_pointer_2w_s4_vc4_pf1 \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=1 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 VICTIM_ENTRIES=4 MEM_LATENCY=2 MEM_BACKPRESSURE_MODE=1 CPU_BACKPRESSURE_MODE=0" \
        "-testplusarg TRACE=$generated_pointer_trace -testplusarg TRACE_ID=generated_pointer -testplusarg CONFIG_ID=2w_s4_vc4_pf1"] \
    [list 2w_s4_vc4_pf1_low_latency \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=1 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 VICTIM_ENTRIES=4 MEM_LATENCY=0 MEM_BACKPRESSURE_MODE=0 CPU_BACKPRESSURE_MODE=0" "-testplusarg CONFIG_ID=2w_s4_vc4_pf1"] \
    [list 2w_s4_vc4_pf1_high_latency_random_bp \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 ENABLE_PREFETCH=1 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 VICTIM_ENTRIES=4 MEM_LATENCY=8 MEM_BACKPRESSURE_MODE=2 CPU_BACKPRESSURE_MODE=0" "-testplusarg CONFIG_ID=2w_s4_vc4_pf1"]]

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

# Run the focused metadata/controller/shadow and PF-MSHR suites in XSim as
# independent tops.  These complement the workload harness with assertions for
# candidate TTL/coalescing, controller hysteresis, causal shadow outcomes,
# response capture, hit-under-prefetch, merge, discard, and set quota.
foreach auxiliary [list \
    [list prefetch_units tb_l1d_prefetch_units] \
    [list p3_prefetch_mshr tb_l1d_cache_p3] \
    [list p3_prefetch_edges tb_l1d_cache_optimized_p3]] {
    lassign $auxiliary name auxiliary_top
    puts "Running Vivado auxiliary simulation: $name"
    set_property top $auxiliary_top [get_filesets sim_1]
    set_property generic {} [get_filesets sim_1]
    set_property -dict [list \
        xsim.simulate.xsim.more_options {} \
        xsim.simulate.custom_tcl $run_all_tcl \
        xsim.simulate.log_all_signals false] \
        [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation -simset sim_1 -mode behavioral
    catch {close_sim}
    set sim_log [file join $build_dir l1d_baseline.sim sim_1 behav xsim simulate.log]
    if {[file exists $sim_log]} {
        file copy -force $sim_log \
            [file join $report_root "${name}_simulation.log"]
    }
}
set_property top tb_l1d_cache_oop [get_filesets sim_1]
update_compile_order -fileset sim_1

# Activity sources use the same small-I/O harness that is implemented below.
# This keeps SAIF hierarchy attributable to the exact post-route top.
set activity_root [file join $report_root activity]
file mkdir $activity_root
set common_tuning_generics \
    "PF_IDLE_GUARD=2 PF_EPOCH_DEMANDS=256 PF_OFF_DEMANDS=512 PF_PROBE_BUDGET=8 PF_PROBE_REFILL=16 PF_ON_REFILL=8"
set activity_configurations [list \
    [list optimized_pf0_deploy \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 VICTIM_ENTRIES=4 ENABLE_PREFETCH=0 PREFETCH_POLICY=1 PF_OPT_LEVEL=1 PF_USE_STREAM=0 PF_USE_ADAPTIVE=0 PF_USE_SHADOW=0 PF_USE_MSHR=0 VC_FORMAT_IN_SWAP=1"] \
    [list p3_deploy \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 VICTIM_ENTRIES=4 ENABLE_PREFETCH=1 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 PF_USE_STREAM=1 PF_USE_ADAPTIVE=1 PF_USE_SHADOW=1 PF_USE_MSHR=1 VC_FORMAT_IN_SWAP=1"] \
    [list p3_lite_mshr_fixed \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 VICTIM_ENTRIES=4 ENABLE_PREFETCH=1 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 PF_USE_STREAM=1 PF_USE_ADAPTIVE=0 PF_USE_SHADOW=0 PF_USE_MSHR=1 VC_FORMAT_IN_SWAP=1"] \
    [list legacy_matched \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 VICTIM_ENTRIES=4 ENABLE_PREFETCH=1 PREFETCH_POLICY=0 PF_OPT_LEVEL=0 PF_USE_STREAM=0 PF_USE_ADAPTIVE=0 PF_USE_SHADOW=0 PF_USE_MSHR=0 VC_FORMAT_IN_SWAP=1"]]

foreach configuration $activity_configurations {
    lassign $configuration name generics
    set generics "$generics $common_tuning_generics"
    puts "Running Vivado activity simulation: $name"
    set saif_path [file join $activity_root "${name}.saif"]
    set saif_tcl [file join $build_dir "xsim_${name}_saif.tcl"]
    write_saif_run_tcl $saif_tcl $saif_path
    set_property top tb_l1d_fpga_harness [get_filesets sim_1]
    set_property generic $generics [get_filesets sim_1]
    set_property -dict [list \
        xsim.simulate.xsim.more_options {} \
        xsim.simulate.custom_tcl $saif_tcl \
        xsim.simulate.log_all_signals false] \
        [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation -simset sim_1 -mode behavioral
    catch {close_sim}
    if {[file exists $saif_path]} {
        normalize_saif_root $saif_path
    }
    set sim_log [file join $build_dir l1d_baseline.sim sim_1 behav xsim simulate.log]
    if {[file exists $sim_log]} {
        file copy -force $sim_log \
            [file join $report_root "harness_${name}_simulation.log"]
    }
    if {![file exists $saif_path] || [file size $saif_path] < 100} {
        error "SAIF activity capture failed for $name"
    }
    if {![file exists $sim_log]} {
        error "Harness simulation log is missing for $name"
    }
    set sim_fp [open $sim_log r]
    set sim_text [read $sim_fp]
    close $sim_fp
    if {[string first "PASS: deploy harness" $sim_text] < 0} {
        error "Harness simulation did not pass for $name"
    }
    puts "SAIF_ACTIVITY PASS name=$name bytes=[file size $saif_path]"
}

# Eight matched out-of-context synthesis variants isolate research observation
# cost from deployable feature cost and include the controlled VC formatter
# A/B.  All use the same 2-way/4-set/4-entry geometry and 10 ns constraint.
set ooc_configurations [list \
    [list optimized_pf0_deploy l1d_cache_deploy \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 VICTIM_ENTRIES=4 ENABLE_PREFETCH=0 PREFETCH_POLICY=1 PF_OPT_LEVEL=1 PF_USE_STREAM=0 PF_USE_ADAPTIVE=0 PF_USE_SHADOW=0 PF_USE_MSHR=0 VC_FORMAT_IN_SWAP=1"] \
    [list optimized_pf0_deploy_vc_lookup l1d_cache_deploy \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 VICTIM_ENTRIES=4 ENABLE_PREFETCH=0 PREFETCH_POLICY=1 PF_OPT_LEVEL=1 PF_USE_STREAM=0 PF_USE_ADAPTIVE=0 PF_USE_SHADOW=0 PF_USE_MSHR=0 VC_FORMAT_IN_SWAP=0"] \
    [list p3_research l1d_cache \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 VICTIM_ENTRIES=4 ENABLE_PREFETCH=1 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 PF_USE_STREAM=1 PF_USE_ADAPTIVE=1 PF_USE_SHADOW=1 PF_USE_MSHR=1"] \
    [list p3_deploy l1d_cache_deploy \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 VICTIM_ENTRIES=4 ENABLE_PREFETCH=1 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 PF_USE_STREAM=1 PF_USE_ADAPTIVE=1 PF_USE_SHADOW=1 PF_USE_MSHR=1"] \
    [list p3_no_shadow_proxy l1d_cache_deploy \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 VICTIM_ENTRIES=4 ENABLE_PREFETCH=1 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 PF_USE_STREAM=1 PF_USE_ADAPTIVE=1 PF_USE_SHADOW=0 PF_USE_MSHR=1"] \
    [list p3_lite_mshr_fixed l1d_cache_deploy \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 VICTIM_ENTRIES=4 ENABLE_PREFETCH=1 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 PF_USE_STREAM=1 PF_USE_ADAPTIVE=0 PF_USE_SHADOW=0 PF_USE_MSHR=1"] \
    [list stream_detector_only l1d_cache_deploy \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 VICTIM_ENTRIES=4 ENABLE_PREFETCH=1 PREFETCH_POLICY=1 PF_OPT_LEVEL=3 PF_USE_STREAM=1 PF_USE_ADAPTIVE=0 PF_USE_SHADOW=0 PF_USE_MSHR=0"] \
    [list legacy_matched l1d_cache_deploy \
        "NUM_WAYS=2 NUM_SETS=4 LINE_BYTES=16 VICTIM_ENTRIES=4 ENABLE_PREFETCH=1 PREFETCH_POLICY=0 PF_OPT_LEVEL=0 PF_USE_STREAM=0 PF_USE_ADAPTIVE=0 PF_USE_SHADOW=0 PF_USE_MSHR=0"]]

set ooc_root [file join $report_root ooc]
file mkdir $ooc_root
foreach configuration $ooc_configurations {
    lassign $configuration name synthesis_top generics
    set generics "$generics $common_tuning_generics"
    set report_dir [file join $ooc_root $name]
    file mkdir $report_dir

    puts "Running Vivado synthesis: $name"
    set_property top $synthesis_top [get_filesets sources_1]
    set_property generic $generics [get_filesets sources_1]
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
        -value {-mode out_of_context} -objects [get_runs synth_1]
    update_compile_order -fileset sources_1
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1

    set run_status [get_property STATUS [get_runs synth_1]]
    if {![string match "*Complete*" $run_status]} {
        error "Synthesis failed for $name: $run_status"
    }

    open_run synth_1
    write_synthesis_reports $report_dir
    write_checkpoint -force [file join $report_dir synth.dcp]
    close_design
}

# Place and route the small-I/O harness for the matched PF0, full P3, P3-lite,
# and legacy points.  Report these separately from OOC cache timing.
set implementation_root [file join $report_root implementation]
file mkdir $implementation_root
set implementation_configurations $activity_configurations

foreach configuration $implementation_configurations {
    lassign $configuration name generics
    set generics "$generics $common_tuning_generics"
    set report_dir [file join $implementation_root $name]
    file mkdir $report_dir

    puts "Running Vivado implementation: $name"
    set_property top l1d_fpga_harness [get_filesets sources_1]
    set_property generic $generics [get_filesets sources_1]
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
        -value {} -objects [get_runs synth_1]
    set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
    update_compile_order -fileset sources_1
    reset_run impl_1
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    set synth_status [get_property STATUS [get_runs synth_1]]
    if {![string match "*Complete*" $synth_status]} {
        error "Harness synthesis failed for $name: $synth_status"
    }

    launch_runs impl_1 -to_step route_design -jobs 4
    wait_on_run impl_1
    set impl_status [get_property STATUS [get_runs impl_1]]
    if {![string match "*Complete*" $impl_status]} {
        error "Implementation failed for $name: $impl_status"
    }

    open_run impl_1
    set saif_path [file join $activity_root "${name}.saif"]
    write_implementation_reports $report_dir $saif_path
    write_checkpoint -force [file join $report_dir post_route.dcp]
    close_design
}

puts "Vivado simulation, OOC synthesis, and implementation matrix completed: $report_root"
