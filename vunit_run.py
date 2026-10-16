#!/usr/bin/env python3
# The scope's testbenches: python3 vunit_run.py [-p N] (VUnit, VHDL-2008). Uses nvc unless
# VUNIT_SIMULATOR is set.
import os
from pathlib import Path
from vunit import VUnit

os.environ.setdefault("VUNIT_SIMULATOR", "nvc")

root = Path(__file__).resolve().parent
memory = root / "submodules" / "hVHDL_memory_library" / "vhdl2008"
interconnect = root / "submodules" / "hVHDL_fpga_interconnect"

vu = VUnit.from_argv(compile_builtins=False)
vu.add_vhdl_builtins()
lib = vu.add_library("lib")

# what the scope uses: the register bus (32 bit data) and the memory library's block RAM
lib.add_source_files(interconnect / "fpga_interconnect_generic_pkg.vhd")
lib.add_source_files(root / "testbench" / "fpga_interconnect_32bit_pkg.vhd")
lib.add_source_files(memory / "dp_ram_w_configurable_records.vhd")
lib.add_source_files(memory / "sdp_ram_w_configurable_records.vhd")

lib.add_source_files(root / "source" / "*.vhd")
lib.add_source_files(root / "testbench" / "*_tb.vhd")

# the memory library's RAM keeps its contents in a shared variable of a plain type, which
# synthesis infers as block RAM; nvc takes it with --relaxed
if os.environ["VUNIT_SIMULATOR"] == "nvc":
    vu.set_compile_option("nvc.a_flags", ["--relaxed"])

vu.main()
