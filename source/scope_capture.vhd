library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    use work.scope_pkg.all;
    use work.fpga_interconnect_pkg.all;
    use work.dual_port_ram_pkg.all;

-- Oscilloscope capture: scope_channels channels, each from one of the 8 + g_probes sources
-- (the test generator, then the probes, see scope_pkg),
-- sampled every sample_divider+1 clocks into a g_depth sample ring buffer around a trigger.
--
-- A capture is started with arm. The buffer first fills with the pre-trigger samples, then
-- the trigger is awaited (or taken at once when the trigger is disabled), then the samples
-- after the trigger are recorded and the capture is done. The finished capture is read
-- through the read port in time order, sample 0 is the oldest pre-trigger sample.
--
-- register map, offsets from g_base_address
--   0  W: command bit0 arm, bit1 force trigger, bit2 stop
--      R: status  bits 2:0 state (0 idle, 1 pre-trigger, 2 waiting for trigger,
--                 3 post-trigger, 4 done), bit 8 trigger was forced,
--                 bits 31:16 number of completed captures
--   1  RW sample divider, a sample every divider+1 clocks
--   2  RW trigger: bits 2:0 channel, bits 5:4 condition (0 rising, 1 falling, 2 either edge
--         through the level, 3 pattern), bit 8 enable, bit 9 compare the level unsigned
--   3  RW trigger level, 16 bits
--   4  RW pre-trigger samples
--   5  RW record length in samples, 1..g_depth
--   6  RW sources of channels 0..3, 8 bits per channel, channel 0 in bits 7:0
--   7  RW test generator phase increment, frequency = increment/2**32 * sample rate
--   8  R  bits 15:0 g_depth, bits 23:16 channels, bits 31:24 sources (8 + g_probes)
--   9  R  ring buffer position of sample 0 of the capture
--  10  RW mode: bit0 deep capture into the HyperRAM, bit1 continuous (with bit0): after the
--         trigger the capture goes on until stop, the ring written over and over
--  11  R  deep capture: records the capture port did not take, the capture is broken if not 0
--  12  R  deep capture: ring record of sample 0 of the capture
--  13  R  deep capture: records in the ring
--  14  RW sources of channels 4..7, 8 bits per channel, channel 4 in bits 7:0
--  15  RW pattern trigger: bits 15:0 pattern, bits 31:16 mask; the trigger is a sample
--         whose masked value equals the masked pattern when the one before did not
--  16  RW probe table index, a source number
--  17..20  R  name of the source, 16 characters, the first in bits 31:24 of register 17,
--         unused characters are 0
--  21  R  format of the source: 0 signed, 1 unsigned, 2 digital (bit n is lane n)
--         (the names and formats are a block RAM, five words a source: a write of the index
--         fetches them into 17..21, there within 16 clocks)
--  22  R  deep capture: records the capture port has taken since the arm (capture_written),
--         how far a continuous capture has got
--
-- Deep capture writes the samples through the capture port into a ring of g_deep_records
-- records in an external memory instead of the block RAM; pre-trigger samples and length
-- are then 32 bit values up to the ring size. The capture is done when the last sample is in
-- the memory. Sample s of the capture is record (start + s) mod ring, eight words each.
--
-- The capture port, served by a memory controller or by scope_axis_writer and a DMA:
--   capture_reset     one clock at the arm: the ring starts again at record 0
--   capture_write     a record (channel 0 in bits 127:112 ... channel 7 in bits 15:0)
--   capture_flush     high from the capture's last record until it is done: write out
--                     everything held back
--   capture_is_full   records written now would be lost (counted in register 11)
--   capture_is_ready  the port has finished its reset; the capture waits for it
--   capture_written   records in the memory since the reset; the capture is done when it
--                     reaches the last record
entity scope_capture is
    generic(
        g_base_address : natural := 600;
        g_depth        : natural := 4096;   -- power of two
        g_deep_records : natural := 2**22;  -- power of two
        g_probes       : natural range 1 to 56 := 8;     -- 64 sources at most (the names' RAM)
        g_probe_table  : probe_table_array
    );
    port(
        clock        : in std_logic;
        bus_in       : in fpga_interconnect_record;
        bus_out      : out fpga_interconnect_record;
        probes       : in scope_sample_array(0 to g_probes-1);
        -- capture readout in 32 bit words, data scope_read_latency clocks after the address
        read_address : in natural;
        read_data    : out std_logic_vector(31 downto 0);
        -- deep capture through the capture port, see above
        capture_reset   : out boolean;
        capture_write   : out boolean;
        capture_data    : out std_logic_vector(127 downto 0);
        capture_flush   : out boolean;
        capture_is_full : in boolean := false;
        capture_is_ready : in boolean := true;
        capture_written : in unsigned(31 downto 0) := (others => '0')
    );
end entity scope_capture;

architecture rtl of scope_capture is

    constant record_bits : natural := scope_channels*scope_sample_bits;
    subtype ring_address is natural range 0 to g_depth-1;
    type ring_memory is array (0 to g_depth-1) of std_logic_vector(record_bits-1 downto 0);
    signal memory : ring_memory := (others => (others => '0'));

    type states is (idle, pre_trigger, wait_for_trigger, post_trigger, done, deep_reset, deep_flush);
    signal state : states := idle;

    signal sample_divider  : std_logic_vector(31 downto 0) := (others => '0');
    signal trigger_control : std_logic_vector(31 downto 0) := (others => '0');
    signal trigger_level   : std_logic_vector(31 downto 0) := (others => '0');
    signal pre_samples     : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(g_depth/2, 32));
    signal record_length   : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(g_depth, 32));
    constant source_count  : natural := generator_sources + g_probes;
    signal channel_sources    : std_logic_vector(31 downto 0) := x"03020100";
    signal channel_sources_hi : std_logic_vector(31 downto 0) := x"07060504";
    signal trigger_pattern : std_logic_vector(31 downto 0) := (others => '0');
    signal probe_index     : std_logic_vector(31 downto 0) := (others => '0');
    -- the names' RAM: source s's words at s * 8 + 0..4 (four of its name, then its format)
    type name_word_array is array (0 to 4) of std_logic_vector(31 downto 0);
    signal name_words      : name_word_array := (others => (others => '0'));
    signal fetch_word      : natural range 0 to 5 := 5;    -- 5: none under way
    signal fetch_requested : boolean := false;
    signal previous_match  : boolean := true;

    constant generator_table : probe_table_array(0 to generator_sources-1) := (
        probe_entry("sine"), probe_entry("cosine"), probe_entry("triangle"), probe_entry("square"),
        probe_entry("sawtooth"), probe_entry("noise"), probe_entry("sine + noise"),
        probe_entry("counter", unsigned_probe));
    function name_ram_init return ram_array is
        variable words : ram_array(0 to 511)(31 downto 0) := (others => (others => '0'));
        variable entry : probe_table_entry;
    begin
        for s in 0 to generator_sources + g_probes - 1 loop
            if s < generator_sources then
                entry := generator_table(s);
            else
                entry := g_probe_table(s - generator_sources);
            end if;
            for w in 0 to 3 loop
                words(s * 8 + w) := entry(entry'left - 32 * w downto entry'left - 32 * w - 31);
            end loop;
            words(s * 8 + 4) := x"000000" & entry(7 downto 0);
        end loop;
        return words;
    end function;

    constant name_ram_subtype : dpram_ref_record := create_ref_subtypes(datawidth => 32, addresswidth => 9);
    signal name_a_in, name_b_in   : name_ram_subtype.ram_in'subtype;
    signal name_a_out, name_b_out : name_ram_subtype.ram_out'subtype;

    signal phase_increment : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(2**32/100, 32));
    signal status          : std_logic_vector(31 downto 0) := (others => '0');
    signal information     : std_logic_vector(31 downto 0);

    signal divider_count   : natural := 0;
    signal sample_enable   : boolean := false;
    signal generator       : scope_sample_array(0 to 7);
    signal sources         : scope_sample_array(0 to source_count-1);
    signal channels        : scope_sample_array(0 to scope_channels-1) := (others => (others => '0'));
    signal channels_valid  : boolean := false;
    signal previous_value  : signed(15 downto 0) := (others => '0');

    constant max_samples   : natural := maximum(g_depth, g_deep_records);
    signal write_pointer   : ring_address := 0;
    signal start_pointer   : ring_address := 0;
    signal sample_count    : natural range 0 to max_samples := 0;
    signal pre_count       : natural range 0 to max_samples := 0;
    signal post_count      : natural range 0 to max_samples := 0;

    signal mode            : std_logic_vector(31 downto 0) := (others => '0');
    signal is_deep         : boolean := false;
    signal is_continuous   : boolean := false;
    signal pushed          : unsigned(31 downto 0) := (others => '0');   -- records sent to the capture port
    signal overflows       : unsigned(31 downto 0) := (others => '0');
    signal start_record    : unsigned(31 downto 0) := (others => '0');
    signal reset_timer     : natural range 0 to 63 := 0;
    signal is_forced       : boolean := false;
    signal force_requested : boolean := false;
    signal captures        : unsigned(15 downto 0) := (others => '0');

    signal read_record     : std_logic_vector(record_bits-1 downto 0) := (others => '0');
    signal read_lane       : natural range 0 to words_per_sample-1 := 0;

    function to_bit(b : boolean) return std_logic is
    begin
        if b then return '1'; else return '0'; end if;
    end function;

    function state_code(s : states) return natural is
    begin
        return states'pos(s);
    end function;

    function limit32(value : std_logic_vector; maximum : natural) return natural is
    begin
        if unsigned(value) > maximum then
            return maximum;
        end if;
        return to_integer(unsigned(value(30 downto 0)));
    end function;

    function limit(value : std_logic_vector; maximum : natural) return natural is
        variable v : natural;
    begin
        v := to_integer(unsigned(value(15 downto 0)));
        if value(31 downto 16) /= x"0000" or v > maximum then
            return maximum;
        end if;
        return v;
    end function;

begin

    status      <= std_logic_vector(captures) & "0000000" & to_bit(is_forced)
                   & "00000" & std_logic_vector(to_unsigned(state_code(state), 3));
    information <= std_logic_vector(to_unsigned(source_count, 8)) & std_logic_vector(to_unsigned(scope_channels, 8))
                   & std_logic_vector(to_unsigned(g_depth, 16));

    sources(0 to generator_sources-1) <= generator;
    sources(generator_sources to source_count-1) <= probes;

    u_generator : entity work.test_signal_generator
    port map(clock, sample_enable, unsigned(phase_increment), generator);

    u_names : entity work.dual_port_ram
    generic map(g_dpram_subtype => name_ram_subtype, g_ram_init_values => name_ram_init, g_output_register => false)
    port map(clock => clock, ram_a_in => name_a_in, ram_a_out => name_a_out,
             ram_b_in => name_b_in, ram_b_out => name_b_out);

------------------------------------------------------------------------
    capture : process(clock)
        variable channel_index : natural range 0 to scope_channels-1;
        variable level, value  : signed(15 downto 0);
        variable edge          : std_logic_vector(1 downto 0);
        variable is_trigger    : boolean;
        variable record_value  : std_logic_vector(record_bits-1 downto 0);
        variable source        : natural range 0 to 255;
        variable below_now, below_before, match : boolean;
        variable mask          : std_logic_vector(15 downto 0);

        -- value < level, signed or unsigned
        function is_below(value, level : signed(15 downto 0); as_unsigned : boolean) return boolean is
        begin
            if as_unsigned then
                return unsigned(value) < unsigned(level);
            end if;
            return value < level;
        end function;
    begin
        if rising_edge(clock) then
            init_bus(bus_out);
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 0, status);
            connect_data_to_address          (bus_in, bus_out, g_base_address + 1, sample_divider);
            connect_data_to_address          (bus_in, bus_out, g_base_address + 2, trigger_control);
            connect_data_to_address          (bus_in, bus_out, g_base_address + 3, trigger_level);
            connect_data_to_address          (bus_in, bus_out, g_base_address + 4, pre_samples);
            connect_data_to_address          (bus_in, bus_out, g_base_address + 5, record_length);
            connect_data_to_address          (bus_in, bus_out, g_base_address + 6, channel_sources);
            connect_data_to_address          (bus_in, bus_out, g_base_address + 7, phase_increment);
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 8, information);
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 9, std_logic_vector(to_unsigned(start_pointer, 32)));
            connect_data_to_address          (bus_in, bus_out, g_base_address + 10, mode);
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 11, std_logic_vector(overflows));
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 12, std_logic_vector(start_record));
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 13, std_logic_vector(to_unsigned(g_deep_records, 32)));
            connect_data_to_address          (bus_in, bus_out, g_base_address + 14, channel_sources_hi);
            connect_data_to_address          (bus_in, bus_out, g_base_address + 15, trigger_pattern);
            connect_data_to_address          (bus_in, bus_out, g_base_address + 16, probe_index);
            for i in 0 to 4 loop
                connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 17 + i, name_words(i));
            end loop;
            connect_read_only_data_to_address(bus_in, bus_out, g_base_address + 22, std_logic_vector(capture_written));

            -- probe table readout: a new index's five words fetched from the names' RAM, one at
            -- a time; an index past the sources reads zeros
            init_ram(name_a_in);
            init_ram(name_b_in);
            if write_is_requested_to_address(bus_in, g_base_address + 16) then
                name_words      <= (others => (others => '0'));
                fetch_requested <= false;
                if unsigned(get_slv_data(bus_in)) < source_count then
                    fetch_word <= 0;
                else
                    fetch_word <= 5;
                end if;
            elsif fetch_word < 5 then
                if not fetch_requested then
                    request_data_from_ram(name_b_in, to_integer(unsigned(probe_index(5 downto 0))) * 8 + fetch_word);
                    fetch_requested <= true;
                elsif ram_read_is_ready(name_b_out) then
                    name_words(fetch_word) <= get_ram_data(name_b_out);
                    fetch_requested <= false;
                    fetch_word      <= fetch_word + 1;
                end if;
            end if;

            capture_reset <= false;
            capture_write <= false;
            -- the capture FIFO decides on the clock it sees the write
            if capture_write and capture_is_full then
                overflows <= overflows + 1;
            end if;

            -- sample clock
            sample_enable <= false;
            if divider_count < to_integer(unsigned(sample_divider(23 downto 0))) then
                divider_count <= divider_count + 1;
            else
                divider_count <= 0;
                sample_enable <= true;
            end if;

            -- channel selection, valid the clock after the generator has updated
            channels_valid <= sample_enable;
            for i in 0 to scope_channels-1 loop
                if i < 4 then
                    source := to_integer(unsigned(channel_sources(8*i+7 downto 8*i)));
                else
                    source := to_integer(unsigned(channel_sources_hi(8*(i-4)+7 downto 8*(i-4))));
                end if;
                if source < source_count then
                    channels(i) <= sources(source);
                else
                    channels(i) <= (others => '0');
                end if;
            end loop;

            -- commands
            if write_is_requested_to_address(bus_in, g_base_address) then
                if get_slv_data(bus_in)(0) = '1' then
                    sample_count <= 0;
                    is_forced       <= false;
                    force_requested <= false;
                    is_deep <= mode(0) = '1';
                    is_continuous <= mode(0) = '1' and mode(1) = '1';
                    if mode(0) = '1' then
                        pre_count <= limit32(pre_samples, g_deep_records - 1);
                        if limit32(record_length, g_deep_records) > limit32(pre_samples, g_deep_records - 1) then
                            post_count <= limit32(record_length, g_deep_records) - limit32(pre_samples, g_deep_records - 1);
                        else
                            post_count <= 1;
                        end if;
                        -- restart the ring at record 0 and wait for the controller to take it
                        capture_reset <= true;
                        pushed        <= (others => '0');
                        overflows     <= (others => '0');
                        reset_timer   <= 0;
                        state <= deep_reset;
                    else
                        pre_count <= limit(pre_samples, g_depth - 1);
                        if limit(record_length, g_depth) > limit(pre_samples, g_depth - 1) then
                            post_count <= limit(record_length, g_depth) - limit(pre_samples, g_depth - 1);
                        else
                            post_count <= 1;
                        end if;
                        state <= pre_trigger;
                    end if;
                end if;
                if get_slv_data(bus_in)(1) = '1' then
                    force_requested <= true;
                end if;
                if get_slv_data(bus_in)(2) = '1' then
                    state <= idle;
                end if;
            end if;

            ------------------------------------------------------------
            if channels_valid then
                for i in 0 to scope_channels-1 loop
                    record_value(scope_sample_bits*(scope_channels-i)-1 downto scope_sample_bits*(scope_channels-i-1)) := channels(i);
                end loop;

                channel_index := to_integer(unsigned(trigger_control(2 downto 0)));
                value  := signed(channels(channel_index));
                level  := signed(trigger_level(15 downto 0));
                edge   := trigger_control(5 downto 4);
                previous_value <= value;
                below_now    := is_below(value, level, trigger_control(9) = '1');
                below_before := is_below(previous_value, level, trigger_control(9) = '1');
                mask  := trigger_pattern(31 downto 16);
                match := (std_logic_vector(value) and mask) = (trigger_pattern(15 downto 0) and mask);
                previous_match <= match;
                CASE edge is
                    WHEN "00"   => is_trigger := below_before and not below_now;
                    WHEN "01"   => is_trigger := not below_before and below_now;
                    WHEN "10"   => is_trigger := below_before /= below_now;
                    WHEN others => is_trigger := match and not previous_match;
                end CASE;
                if trigger_control(8) = '0' then
                    is_trigger := true;
                end if;

                if state = pre_trigger or state = wait_for_trigger or state = post_trigger then
                    if is_deep then
                        capture_write <= true;
                        capture_data  <= record_value;
                        pushed        <= pushed + 1;
                    else
                        memory(write_pointer) <= record_value;
                        write_pointer <= (write_pointer + 1) mod g_depth;
                    end if;
                end if;

                CASE state is
                    WHEN pre_trigger =>
                        if sample_count + 1 >= pre_count then
                            state <= wait_for_trigger;
                        else
                            sample_count <= sample_count + 1;
                        end if;
                        if pre_count = 0 then
                            state <= wait_for_trigger;
                        end if;

                    WHEN wait_for_trigger =>
                        if is_trigger or force_requested then
                            -- this sample is the trigger sample
                            start_pointer <= (write_pointer - pre_count) mod g_depth;
                            start_record  <= (pushed - pre_count) and to_unsigned(g_deep_records - 1, 32);
                            is_forced     <= force_requested and not is_trigger;
                            sample_count  <= 1;
                            if is_continuous then
                                state <= post_trigger;
                            elsif post_count <= 1 and is_deep then
                                state <= deep_flush;
                            elsif post_count <= 1 then
                                captures <= captures + 1;
                                state    <= done;
                            else
                                state <= post_trigger;
                            end if;
                        end if;

                    WHEN post_trigger =>
                        if is_continuous then
                            null;       -- until stop
                        elsif sample_count + 1 >= post_count and is_deep then
                            state <= deep_flush;
                        elsif sample_count + 1 >= post_count then
                            captures <= captures + 1;
                            state    <= done;
                        else
                            sample_count <= sample_count + 1;
                        end if;

                    WHEN others => null;
                end CASE;
            end if;

            -- deep capture: wait for the controller to restart the ring
            CASE state is
                WHEN deep_reset =>
                    if reset_timer < 7 then
                        reset_timer <= reset_timer + 1;
                    elsif capture_is_ready then
                        state <= pre_trigger;
                    end if;

                WHEN deep_flush =>
                    -- the last record has been sent, wait until all taken records are written
                    if not capture_write and capture_written + overflows >= pushed then
                        captures <= captures + 1;
                        state    <= done;
                    end if;

                WHEN others => null;
            end CASE;
        end if;
    end process;

    capture_flush <= state = deep_flush;

------------------------------------------------------------------------
    -- readout: word w is word w mod 4 of sample w/4, counted from the start of the capture.
    -- read_address comes from a register of the reader, so the data is valid
    -- scope_read_latency = 3 clocks after the reader has set the address
    readout : process(clock)
    begin
        if rising_edge(clock) then
            read_record <= memory((start_pointer + (read_address / words_per_sample)) mod g_depth);
            read_lane   <= read_address mod words_per_sample;
            read_data   <= read_record(record_bits-1 - 32*read_lane downto record_bits-32 - 32*read_lane);
        end if;
    end process;

end architecture rtl;
