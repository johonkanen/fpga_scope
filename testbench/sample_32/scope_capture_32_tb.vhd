-- scope_capture with 32 bit samples (testbench/sample_32/scope_pkg_32.vhd):
--   - register 23 reports the width;
--   - a 32 bit probe arrives whole, one channel per word;
--   - the float trigger compare finds rising crossings of positive and negative levels;
--   - with register 1 bit 31 the samples follow sample_strobe;
--   - a deep capture record is 256 bits, channel 0 on top.
LIBRARY ieee  ;
    USE ieee.NUMERIC_STD.all  ;
    USE ieee.std_logic_1164.all  ;
    use ieee.float_pkg.all;

library vunit_lib;
context vunit_lib.vunit_context;

    use work.scope_pkg.all;
    use work.fpga_interconnect_pkg.all;

entity scope_capture_32_tb is
  generic (runner_cfg : string);
end;

architecture vunit_simulation of scope_capture_32_tb is

    constant base  : natural := 600;
    constant depth : natural := 1024;

    signal clock   : std_logic := '0';
    signal bus_in, bus_out : fpga_interconnect_record := init_fpga_interconnect;
    signal probes  : scope_sample_array(0 to 2) := (others => (others => '0'));
    constant probe_table : probe_table_array(0 to 2) := (
        0 => probe_entry("count32", unsigned_probe),
        1 => probe_entry("ramp", float_probe),
        2 => probe_entry("lanes", digital_probe));
    signal read_address : natural := 0;
    signal read_data    : std_logic_vector(31 downto 0);
    signal bus_read_data : std_logic_vector(31 downto 0);
    signal bus_read_done : boolean := false;

    signal sample_strobe : boolean := false;
    signal strobe_period : natural := 5;

    -- the memory behind the capture port: takes every record at once
    constant deep_records : natural := 1024;
    type record_array is array (0 to deep_records-1) of std_logic_vector(record_bits-1 downto 0);
    signal ring : record_array;
    signal capture_reset, capture_write, capture_flush : boolean := false;
    signal capture_data     : std_logic_vector(record_bits-1 downto 0);
    signal capture_written  : unsigned(31 downto 0) := (others => '0');

    -- the ramp: -3.0 + 0.01 n, n = 0..599, again and again
    function ramp(n : natural) return std_logic_vector is
    begin
        return to_slv(to_float(-3.0 + 0.01 * real(n mod 600), 8, 23));
    end function;

    function to_real_fp(x : std_logic_vector(31 downto 0)) return real is
    begin
        return to_real(to_float(x, 8, 23));
    end function;

begin

    clock <= not clock after 4 ns;

    u_scope : entity work.scope_capture
    generic map(g_base_address => base, g_depth => depth, g_deep_records => deep_records, g_probes => 3,
                g_probe_table => probe_table)
    port map(clock => clock, bus_in => bus_in, bus_out => bus_out, probes => probes,
             read_address => read_address, read_data => read_data,
             capture_reset => capture_reset, capture_write => capture_write, capture_data => capture_data,
             capture_flush => capture_flush, capture_written => capture_written,
             sample_strobe => sample_strobe);

    signals : process(clock)
        variable n : natural := 0;
        variable strobe_count : natural := 0;
    begin
        if rising_edge(clock) then
            n := n + 1;
            probes(0) <= std_logic_vector(to_unsigned(16#12340000# + n, 32));
            probes(1) <= ramp(n);
            probes(2) <= std_logic_vector(to_unsigned(n mod 2**20, 32));
            sample_strobe <= strobe_count = 0;
            strobe_count := (strobe_count + 1) mod strobe_period;
        end if;
    end process;

    capture_port : process(clock)
        variable taken : unsigned(31 downto 0) := (others => '0');
    begin
        if rising_edge(clock) then
            if capture_write then
                ring(to_integer(taken) mod deep_records) <= capture_data;
                taken := taken + 1;
            end if;
            if capture_reset then
                taken := (others => '0');
            end if;
            capture_written <= taken;
        end if;
    end process;

    capture_bus_reads : process(clock)
    begin
        if rising_edge(clock) then
            bus_read_done <= false;
            if write_to_address_is_requested(bus_out, 0) then
                bus_read_data <= get_slv_data(bus_out);
                bus_read_done <= true;
            end if;
        end if;
    end process;

    main : process
        type sample_matrix is array (0 to depth-1, 0 to scope_channels-1) of std_logic_vector(31 downto 0);
        variable samples : sample_matrix;
        variable word, start : std_logic_vector(31 downto 0);
        variable r : std_logic_vector(record_bits-1 downto 0);

        procedure bus_write(address : natural; data : std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(clock);
            write_data_to_address(bus_in, address, data);
            wait until rising_edge(clock);
            init_bus(bus_in);
        end procedure;

        procedure bus_write(address : natural; data : natural) is
        begin
            bus_write(address, std_logic_vector(to_unsigned(data, 32)));
        end procedure;

        procedure bus_read(address : natural; data : out std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(clock);
            request_data_from_address(bus_in, address);
            wait until rising_edge(clock);
            init_bus(bus_in);
            wait until rising_edge(clock) and bus_read_done for 1 us;
            check(bus_read_done, "no response from " & integer'image(address));
            data := bus_read_data;
        end procedure;

        procedure wait_until_done is
            variable status : std_logic_vector(31 downto 0);
        begin
            for i in 0 to 10000 loop
                bus_read(base, status);
                exit when status(2 downto 0) = "100";
                wait for 1 us;
            end loop;
            check_equal(status(2 downto 0), std_logic_vector'("100"), "capture done");
        end procedure;

        -- one channel per word: word 8 s + k is channel k of sample s
        procedure read_capture(count : natural) is
        begin
            for s in 0 to count-1 loop
                for k in 0 to words_per_sample-1 loop
                    wait until rising_edge(clock);
                    read_address <= words_per_sample*s + k;
                    for d in 1 to scope_read_latency loop
                        wait until rising_edge(clock);
                    end loop;
                    samples(s, k) := read_data;
                end loop;
            end loop;
        end procedure;

        procedure check_steps(count, channel, step : natural) is
        begin
            for s in 1 to count-1 loop
                if unsigned(samples(s, channel)) - unsigned(samples(s-1, channel)) /= step then
                    check(false, "channel " & integer'image(channel) & " steps by "
                          & integer'image(to_integer(unsigned(samples(s, channel)) - unsigned(samples(s-1, channel))))
                          & " at sample " & integer'image(s) & ", not " & integer'image(step));
                    exit;
                end if;
            end loop;
        end procedure;

        procedure float_rising_trigger_at(level : real) is
            variable before, at : real;
        begin
            bus_write(base + 2, 16#501#);            -- channel 1, rising, enabled, float
            bus_write(base + 3, to_slv(to_float(level, 8, 23)));
            bus_write(base + 4, 50);
            bus_write(base + 5, 100);
            bus_write(base + 0, 1);
            wait_until_done;
            read_capture(100);
            before := to_real_fp(samples(49, 1));
            at     := to_real_fp(samples(50, 1));
            info("level " & real'image(level) & ": before " & real'image(before) & ", at " & real'image(at));
            check(before < level and at >= level, "rising crossing of " & real'image(level) & " at the trigger sample");
        end procedure;

    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop
            bus_write(base + 6, 16#070A0908#);           -- channels 0..3: the probes, the counter

            if run("register_23_reports_32_bits_and_8_words") then
                bus_read(base + 23, word);
                check_equal(word, std_logic_vector(to_unsigned(8 * 256 + 32, 32)));
                bus_write(base + 16, 9);                 -- probe 1
                wait for 1 us;
                bus_read(base + 21, word);
                check_equal(to_integer(unsigned(word)), float_probe, "format of the float probe");

            elsif run("a_32_bit_probe_arrives_whole") then
                bus_write(base + 4, 10);
                bus_write(base + 5, 200);
                bus_write(base + 0, 1);                  -- no trigger enabled: at once
                wait_until_done;
                read_capture(200);
                check(unsigned(samples(0, 0)) > 16#12340000#, "upper bits of the probe kept");
                check_steps(200, 0, 1);
                check_steps(200, 3, 1);                  -- the generator's counter channel

            elsif run("float_trigger_on_positive_and_negative_levels") then
                float_rising_trigger_at(0.5);
                float_rising_trigger_at(-1.25);
                float_rising_trigger_at(-2.995);

            elsif run("samples_follow_the_strobe") then
                bus_write(base + 1, x"80000000");        -- every strobe
                bus_write(base + 4, 10);
                bus_write(base + 5, 100);
                bus_write(base + 0, 1);
                wait_until_done;
                read_capture(100);
                check_steps(100, 0, 5);
                bus_write(base + 1, x"80000001");        -- every second strobe
                bus_write(base + 0, 1);
                wait_until_done;
                read_capture(100);
                check_steps(100, 0, 10);

            elsif run("deep_capture_records_are_256_bits") then
                bus_write(base + 10, 1);                 -- deep
                bus_write(base + 4, 10);
                bus_write(base + 5, 300);
                bus_write(base + 0, 1);
                wait_until_done;
                bus_read(base + 12, start);
                for s in 0 to 299 loop
                    r := ring((to_integer(unsigned(start)) + s) mod deep_records);
                    for k in 0 to scope_channels-1 loop
                        samples(s, k) := r(record_bits-1 - 32*k downto record_bits-32 - 32*k);
                    end loop;
                end loop;
                check(unsigned(samples(0, 0)) > 16#12340000#, "upper bits of the probe kept");
                check_steps(300, 0, 1);
                check_steps(300, 3, 1);

            end if;
        end loop;
        test_runner_cleanup(runner);
    end process;

end architecture vunit_simulation;
