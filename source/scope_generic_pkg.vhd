library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

-- Oscilloscope constants and types, generic in the sample width.
-- A design compiles one instance of it as scope_pkg: source/scope_pkg.vhd is the 16 bit one,
-- a design with 32 bit samples compiles its own instead, e.g.
--
--     package scope_pkg is new work.scope_generic_pkg generic map (g_sample_bits => 32);
--
-- A sample record holds all scope_channels channels of one sample instant, g_sample_bits
-- each, channel 0 in the record's top bits. The capture is read out as 32 bit words:
--   16 bit samples: word 4*s + k holds channel 2k in bits 31:16 and channel 2k+1 in 15:0;
--   32 bit samples: word 8*s + k holds channel k.
--
-- Probes: any signal of the main clock domain can be shown on the scope. A design drives a
-- scope_sample_array with to_probe(signal) and describes each element in a probe table with
-- probe_entry(name, format); scope_capture serves the table to the PC, which takes the source
-- names and formats from it.
--
--     probes(0) <= to_probe(counter(15 downto 0));
--     probes(1) <= to_digital(link_is_up & pll_locked);   -- lane 1, lane 0
--     constant probe_table : probe_table_array := (
--         0 => probe_entry("counter 15:0", unsigned_probe),
--         1 => probe_entry("locks", digital_probe));
--
-- A digital probe holds up to g_sample_bits one bit signals, bit n is lane n (the pattern
-- trigger sees lanes 0..15). A float probe is an IEEE 754 single (32 bit samples only).
-- Signals of other clock domains must be synchronised before they are probed.
package scope_generic_pkg is
    generic (g_sample_bits : natural := 16);   -- 16 or 32

    constant scope_channels    : natural := 8;
    constant generator_sources : natural := 8;    -- sources 0..7, the probes follow
    constant scope_sample_bits : natural := g_sample_bits;
    constant words_per_sample  : natural := scope_channels*scope_sample_bits/32;
    constant record_bits       : natural := scope_channels*scope_sample_bits;

    subtype scope_sample is std_logic_vector(scope_sample_bits-1 downto 0);
    type scope_sample_array is array (natural range <>) of scope_sample;

    -- read port latency of the capture memory, data follows the address after this many clocks
    constant scope_read_latency : natural := 3;

------------------------------------------------------------------------
    -- probe table: 16 characters of name and a format byte
    constant probe_name_length : natural := 16;
    subtype probe_table_entry is std_logic_vector(8*probe_name_length + 7 downto 0);
    type probe_table_array is array (natural range <>) of probe_table_entry;

    constant signed_probe   : natural := 0;
    constant unsigned_probe : natural := 1;
    constant digital_probe  : natural := 2;
    constant float_probe    : natural := 3;    -- IEEE 754 single, 32 bit samples

    function probe_entry(name : string; format : natural := signed_probe) return probe_table_entry;

    function to_probe(value : signed) return scope_sample;           -- low bits, sign extended
    function to_probe(value : unsigned) return scope_sample;         -- low bits
    function to_probe(value : std_logic_vector) return scope_sample; -- low bits
    function to_probe(value : integer) return scope_sample;
    function to_digital(lanes : std_logic_vector) return scope_sample; -- lane n is bit n
    function to_digital(lane0 : boolean) return scope_sample;

end package scope_generic_pkg;

package body scope_generic_pkg is

    function probe_entry(name : string; format : natural := signed_probe) return probe_table_entry is
        variable entry : probe_table_entry := (others => '0');
        variable c     : natural;
    begin
        for i in 0 to probe_name_length-1 loop
            if i < name'length then
                c := character'pos(name(name'low + i));
            else
                c := 0;
            end if;
            entry(entry'left - 8*i downto entry'left - 8*i - 7) := std_logic_vector(to_unsigned(c, 8));
        end loop;
        entry(7 downto 0) := std_logic_vector(to_unsigned(format, 8));
        return entry;
    end function;

    function to_probe(value : signed) return scope_sample is
    begin
        return std_logic_vector(resize(value, scope_sample_bits));
    end function;

    function to_probe(value : unsigned) return scope_sample is
    begin
        return std_logic_vector(resize(value, scope_sample_bits));
    end function;

    function to_probe(value : std_logic_vector) return scope_sample is
    begin
        return to_probe(unsigned(value));
    end function;

    function to_probe(value : integer) return scope_sample is
    begin
        return std_logic_vector(to_signed(value, scope_sample_bits));
    end function;

    function to_digital(lanes : std_logic_vector) return scope_sample is
        variable v : std_logic_vector(lanes'length-1 downto 0) := lanes;
        variable s : scope_sample := (others => '0');
    begin
        for i in 0 to lanes'length-1 loop
            if i < scope_sample_bits then
                s(i) := v(i);
            end if;
        end loop;
        return s;
    end function;

    function to_digital(lane0 : boolean) return scope_sample is
        variable s : scope_sample := (others => '0');
    begin
        if lane0 then
            s(0) := '1';
        end if;
        return s;
    end function;

end package body scope_generic_pkg;
