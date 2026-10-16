library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

-- Oscilloscope constants and types.
-- A sample record holds all scope_channels channels of one sample instant, 16 bits each.
-- The capture is read out as 32 bit words, two channels per word: word 4*s + k of a
-- capture holds channel 2k in bits 31:16 and channel 2k+1 in bits 15:0 of sample s.
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
-- A digital probe holds up to 16 one bit signals, bit n is lane n. Signals of other clock
-- domains must be synchronised before they are probed.
package scope_pkg is

    constant scope_channels    : natural := 8;
    constant generator_sources : natural := 8;    -- sources 0..7, the probes follow
    constant scope_sample_bits : natural := 16;
    constant words_per_sample  : natural := scope_channels/2;

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

    function probe_entry(name : string; format : natural := signed_probe) return probe_table_entry;

    function to_probe(value : signed) return scope_sample;           -- low 16 bits, sign extended
    function to_probe(value : unsigned) return scope_sample;         -- low 16 bits
    function to_probe(value : std_logic_vector) return scope_sample; -- low 16 bits
    function to_probe(value : integer) return scope_sample;
    function to_digital(lanes : std_logic_vector) return scope_sample; -- lane n is bit n
    function to_digital(lane0 : boolean) return scope_sample;

end package scope_pkg;

package body scope_pkg is

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

end package body scope_pkg;
