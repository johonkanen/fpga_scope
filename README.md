# fpga_scope

An oscilloscope inside the FPGA: eight 16-bit channels, each showing any of the design's
signals. It captures into block RAM around a trigger, or, through a DMA, deep and continuous
into an external memory. The CPU or PC controls it over a register bus. The design names its
signals itself, so the software needs no per-design configuration.

It runs in the [ti60_ac_inout_psu](https://github.com/johonkanen/ti60_ac_inout_psu) power
supply's FPGA (Efinix Ti60, Sapphire SoC, Zephyr). There it streams eight channels into the
HyperRAM and out over Ethernet at up to 3.9 MS/s, 62.5 MB/s
([how](https://github.com/johonkanen/ti60_ac_inout_psu/blob/main/docs/data_stream.md)).

Plain VHDL-2008, vendor independent.

## Features

- 8 channels × 16 bits. Each channel picks one of 8 + `g_probes` sources (up to 64): an
  internal test generator (sine, cosine, triangle, square, sawtooth, noise, sine with noise, a
  sample counter) and the design's probes.
- **Probes describe themselves.** `to_probe(signal)` connects a signal, and
  `probe_entry("name", format)` gives its 16-character name and its format: signed,
  unsigned, or digital (up to 16 one-bit lanes). The names sit in a block RAM that the
  software reads through registers.
- **Sample rate:** clock / (divider + 1).
- **Triggers:**
  - rising, falling or either edge through a level, signed or unsigned;
  - a masked pattern, for digital probes;
  - or none, or a forced trigger (the software builds auto mode on it), and pre-trigger
    samples.
- **Block RAM capture:** `g_depth` samples, read out in time order through a read port.
- **Deep capture** through the capture port into a ring of `g_deep_records` records in an
  external memory. Lost records are counted. In continuous mode the capture keeps going
  until stopped, and register 22 tells the software how far it has got: that is what makes
  streaming possible.

## Files

| File | What |
|---|---|
| `source/scope_pkg.vhd` | constants, `to_probe`, `to_digital`, `probe_entry` |
| `source/scope_capture.vhd` | the scope; its header comment is the register map |
| `source/test_signal_generator.vhd`, `source/sine_table_pkg.vhd` | the 8 internal test sources |
| `source/scope_axis_writer.vhd` | the deep capture port to a 64-bit AXI stream, for a DMA that writes a ring in memory |
| `source/scope_fifo.vhd` | the writer's FIFO, a block RAM of hVHDL_memory_library |
| `source/apb_bus_bridge.vhd` | an APB3 slave to register bus master, for a CPU on APB (register *r* at byte offset 4*r*) |
| `testbench/` | VUnit testbenches, and the 32-bit register bus instance they use |

## Dependencies

Two submodules:

- [hVHDL_fpga_interconnect](https://github.com/hVHDL/hVHDL_fpga_interconnect): the register
  bus. The design provides `fpga_interconnect_pkg` as an instance of
  `fpga_interconnect_generic_pkg` with 32 data bits; `testbench/fpga_interconnect_32bit_pkg.vhd`
  is one, with 16 address bits.
- [hVHDL_memory_library](https://github.com/hVHDL/hVHDL_memory_library):
  `dp_ram_w_configurable_records.vhd` and its `arch_rtl_...` architecture, for the names RAM
  and the FIFO.

```
git clone --recursive https://github.com/johonkanen/fpga_scope
```

A design that already has these libraries compiles the scope's `source/` files against its
own copies, all into one library.

## Use

```vhdl
constant probe_table : probe_table_array(0 to 2) := (
    0 => probe_entry("counter", unsigned_probe),
    1 => probe_entry("adc 0", signed_probe),
    2 => probe_entry("flags", digital_probe));
signal probes : scope_sample_array(0 to 2);
...
probes(0) <= to_probe(counter(15 downto 0));
probes(1) <= to_probe(adc_result);
probes(2) <= to_digital(pll_locked & link_up);   -- lane 1, lane 0

u_scope : entity work.scope_capture
generic map(g_base_address => 600, g_depth => 4096, g_deep_records => 2**22,
            g_probes => 3, g_probe_table => probe_table)
port map(clock => clock, bus_in => bus_in, bus_out => bus_out, probes => probes,
         read_address => read_address, read_data => read_data,
         capture_reset => capture_reset, capture_write => capture_write,
         capture_data => capture_data, capture_flush => capture_flush,
         capture_is_full => capture_is_full, capture_is_ready => capture_is_ready,
         capture_written => capture_written);
```

Probes must be in the scope's clock domain; synchronise other signals first. Without deep
capture, leave the capture outputs open and the inputs at their defaults.

**Deep capture through a DMA.** Connect the capture port to `scope_axis_writer` and its
`tvalid`/`tready`/`tdata` to a DMA's stream-to-memory channel. Each record becomes two
64-bit beats, so 16-bit word `8*s + c` of the buffer is channel `c` of sample `s`. When a
capture ends, the writer pads with zero records up to the DMA's burst boundary, so nothing
is left behind in the DMA. The software restarts the DMA at its buffer before it arms a deep
capture.

**Register map.** See the header of `scope_capture.vhd`. In short:

| Register | Function |
|---|---|
| 0 | command and status |
| 1 | divider |
| 2, 3 | trigger and level |
| 4, 5 | pre-trigger and length |
| 6, 14 | channel sources |
| 7 | generator frequency |
| 8 | sizes |
| 9 | start position |
| 10 | mode (deep, continuous) |
| 11–13, 22 | deep capture state |
| 15 | pattern |
| 16–21 | probe names and formats |

## Tests

```
python3 vunit_run.py -p 8
```

This needs VUnit and nvc (the default) or another VHDL-2008 simulator: set
`VUNIT_SIMULATOR`. It covers the capture modes and triggers (`scope_capture_tb`), the deep
and continuous capture through the AXI writer and the APB bridge with a DMA stand-in
(`scope_axi_tb`), and the FIFO against a model (`scope_fifo_tb`).

## Licence

MIT, see `LICENSE`.
