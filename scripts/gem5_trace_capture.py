#!/usr/bin/env python3
"""
gem5 config script for capturing data-memory traces with the O3 StoreTrace
probe listener.

Keep this file in the project repo and invoke it from WSL against a gem5 build
that includes the StoreTrace patch, for example:

    ~/gem5/build/X86/gem5.opt /mnt/d/.../scripts/gem5_trace_capture.py \
        --cmd /path/to/workload \
        --options "arg1 arg2" \
        --trace-file /mnt/d/.../traces/workload_access.trace

The output format is:

    tick op addr size wstrb data [pc]
"""

import argparse
import shlex

import m5
from m5.objects import (
    AddrRange,
    DDR3_1600_8x8,
    DerivO3CPU,
    MemCtrl,
    Process,
    Root,
    SEWorkload,
    SrcClockDomain,
    StoreTrace,
    System,
    SystemXBar,
    VoltageDomain,
)


def build_parser():
    parser = argparse.ArgumentParser(
        description="Capture gem5 data-memory packet traces for RTL replay prep"
    )
    parser.add_argument("--cmd", required=True, help="Workload binary path")
    parser.add_argument(
        "--options",
        default="",
        help="Command-line options passed to the workload",
    )
    parser.add_argument(
        "--trace-file",
        required=True,
        help="Output mixed read/write trace path",
    )
    parser.add_argument(
        "--max-ticks",
        type=int,
        default=1_000_000_000,
        help="Simulation tick limit",
    )
    parser.add_argument(
        "--mem-size",
        default="512MB",
        help="Physical memory size",
    )
    parser.add_argument(
        "--cacheline-size",
        type=int,
        default=64,
        help="gem5 cache line size in bytes",
    )
    parser.add_argument(
        "--cpu-clock",
        default="2GHz",
        help="CPU and system clock",
    )
    parser.add_argument(
        "--with-pc",
        action="store_true",
        help="Reserved for compatibility; PC inclusion is handled by StoreTrace",
    )
    return parser


def main():
    args = build_parser().parse_args()

    system = System()
    system.clk_domain = SrcClockDomain(
        clock=args.cpu_clock, voltage_domain=VoltageDomain()
    )
    system.mem_mode = "timing"
    system.mem_ranges = [AddrRange(args.mem_size)]
    system.cache_line_size = args.cacheline_size

    system.cpu = DerivO3CPU()
    system.membus = SystemXBar()
    system.system_port = system.membus.cpu_side_ports

    system.store_trace = StoreTrace(
        manager=system.cpu,
        file_name=args.trace_file,
    )

    system.cpu.icache_port = system.membus.cpu_side_ports
    system.cpu.dcache_port = system.membus.cpu_side_ports
    system.cpu.createInterruptController()
    system.cpu.interrupts[0].pio = system.membus.mem_side_ports
    system.cpu.interrupts[0].int_requestor = system.membus.cpu_side_ports
    system.cpu.interrupts[0].int_responder = system.membus.mem_side_ports

    system.mem_ctrl = MemCtrl(dram=DDR3_1600_8x8())
    system.mem_ctrl.dram.range = system.mem_ranges[0]
    system.mem_ctrl.port = system.membus.mem_side_ports

    process = Process()
    process.cmd = [args.cmd] + shlex.split(args.options)
    system.workload = SEWorkload.init_compatible(args.cmd)
    system.cpu.workload = process
    system.cpu.createThreads()

    root = Root(full_system=False, system=system)
    m5.instantiate()
    exit_event = m5.simulate(args.max_ticks)
    print(f"gem5 exited at tick {m5.curTick()} because {exit_event.getCause()}")


# if __name__ == "__main__":
main()
