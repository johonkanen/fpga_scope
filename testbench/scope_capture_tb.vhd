LIBRARY ieee  ;
    USE ieee.NUMERIC_STD.all  ;
    USE ieee.std_logic_1164.all  ;

library vunit_lib;
context vunit_lib.vunit_context;

    use work.scope_pkg.all;
    use work.fpga_interconnect_pkg.all;

entity scope_capture_tb is
  generic (runner_cfg : string);
end;

architecture vunit_simulation of scope_capture_tb is

    constant base  : natural := 600;
    constant depth : natural := 4096;

    signal clock   : std_logic := '0';
    signal bus_in, bus_out : fpga_interconnect_record := init_fpga_interconnect;
    signal probes  : scope_sample_array(0 to 7) := (others => (others => '0'));
    constant probe_table : probe_table_array(0 to 7) := (
        0 => probe_entry("probe zero", unsigned_probe),
        3 => probe_entry("probe three"),
        7 => probe_entry("lanes", digital_probe),
        others => probe_entry("spare"));
    signal read_address : natural := 0;
    signal read_data    : std_logic_vector(31 downto 0);
    signal bus_read_data : std_logic_vector(31 downto 0);
    signal bus_read_done : boolean := false;

    -- model of a memory behind the capture port
    constant deep_records : natural := 4096;
    type record_array is array (0 to deep_records-1) of std_logic_vector(127 downto 0);
    signal ring : record_array;
    signal capture_reset, capture_write, capture_flush, capture_is_full : boolean := false;
    signal capture_is_ready : boolean := true;
    signal capture_data     : std_logic_vector(127 downto 0);
    signal capture_written  : unsigned(31 downto 0) := (others => '0');
    signal force_full       : boolean := false;

begin

    clock <= not clock after 4 ns;

    u_scope : entity work.scope_capture
    generic map(g_base_address => base, g_depth => depth, g_deep_records => deep_records, g_probes => 8,
                g_probe_table => probe_table)
    port map(clock, bus_in, bus_out, probes, read_address, read_data,
             capture_reset, capture_write, capture_data, capture_flush, capture_is_full,
             capture_is_ready, capture_written);

    -- records are in the memory 40 clocks after they were taken
    capture_port : process(clock)
        type count_delay is array (0 to 39) of unsigned(31 downto 0);
        variable taken : unsigned(31 downto 0) := (others => '0');
        variable delay : count_delay := (others => (others => '0'));
        variable reset_timer : natural := 0;
    begin
        if rising_edge(clock) then
            capture_is_full <= force_full;
            if capture_write and not capture_is_full then
                ring(to_integer(taken) mod deep_records) <= capture_data;
                taken := taken + 1;
            end if;
            capture_written <= delay(39);
            delay := taken & delay(0 to 38);
            if capture_reset then
                taken := (others => '0');
                delay := (others => (others => '0'));
                reset_timer := 30;
            end if;
            capture_is_ready <= reset_timer = 0;
            if reset_timer > 0 then
                reset_timer := reset_timer - 1;
            end if;
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
        type sample_matrix is array (0 to deep_records-1, 0 to scope_channels-1) of integer;
        variable samples : sample_matrix;

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

        -- read a capture through the read port like the stream sender: data three clocks
        -- after the address register
        procedure read_capture(count : natural) is
            variable word : std_logic_vector(31 downto 0);
        begin
            for s in 0 to count-1 loop
                for k in 0 to words_per_sample-1 loop
                    wait until rising_edge(clock);
                    read_address <= words_per_sample*s + k;
                    for d in 1 to scope_read_latency loop
                        wait until rising_edge(clock);
                    end loop;
                    word := read_data;
                    samples(s, 2*k)     := to_integer(signed(word(31 downto 16)));
                    samples(s, 2*k + 1) := to_integer(signed(word(15 downto 0)));
                end loop;
            end loop;
        end procedure;

        procedure check_counter_is_continuous(count : natural) is
        begin
            for s in 1 to count-1 loop
                if (samples(s, 7) - samples(s-1, 7)) mod 65536 /= 1 then
                    check(false, "sample counter jumps at sample " & integer'image(s));
                    exit;
                end if;
            end loop;
        end procedure;

        -- a deep capture from the ring model
        procedure read_deep_capture(count : natural) is
            variable start : std_logic_vector(31 downto 0);
            variable r : std_logic_vector(127 downto 0);
        begin
            bus_read(base + 12, start);
            for s in 0 to count-1 loop
                r := ring((to_integer(unsigned(start)) + s) mod deep_records);
                for c in 0 to scope_channels-1 loop
                    samples(s, c) := to_integer(signed(r(127 - 16*c downto 112 - 16*c)));
                end loop;
            end loop;
        end procedure;

        variable status : std_logic_vector(31 downto 0);
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop
            if run("rising_edge_trigger_on_sine") then
                bus_write(base + 1, 3);                  -- a sample every 4 clocks
                bus_write(base + 7, 2**32/200);          -- 200 samples per period
                bus_write(base + 2, 16#100#);            -- channel 0, rising, enabled
                bus_write(base + 3, 0);                  -- level 0
                bus_write(base + 4, 100);                -- pre-trigger samples
                bus_write(base + 5, 400);                -- record length
                bus_write(base + 0, 1);                  -- arm
                wait_until_done;
                read_capture(400);
                info("trigger sample " & integer'image(samples(100, 0)) & ", before it " & integer'image(samples(99, 0)));
                check(samples(99, 0) < 0 and samples(100, 0) >= 0, "rising zero crossing at the trigger sample");
                check(samples(101, 0) > samples(100, 0), "sine rising after the trigger");
                check_counter_is_continuous(400);
                bus_read(base, status);
                check(status(8) = '0', "trigger was not forced");
                check_equal(to_integer(unsigned(status(31 downto 16))), 1, "capture count");

            elsif run("falling_edge_and_level") then
                bus_write(base + 7, 2**32/300);
                bus_write(base + 2, 16#110#);            -- channel 0, falling, enabled
                bus_write(base + 3, 10000);
                bus_write(base + 4, 50);
                bus_write(base + 5, 200);
                bus_write(base + 0, 1);
                wait_until_done;
                read_capture(200);
                check(samples(49, 0) >= 10000 and samples(50, 0) < 10000, "falling crossing of 10000 at the trigger sample");
                check_counter_is_continuous(200);

            elsif run("free_running_full_depth") then
                bus_write(base + 2, 0);                  -- trigger disabled
                bus_write(base + 4, 0);
                bus_write(base + 5, depth);
                bus_write(base + 0, 1);
                wait_until_done;
                read_capture(depth);
                check_counter_is_continuous(depth);

            elsif run("forced_trigger") then
                bus_write(base + 2, 16#105#);            -- channel 5 rising
                bus_write(base + 6, 16#00000808#);       -- channel 0 and 1 from probe 0 (source 8)
                bus_write(base + 2, 16#100#);            -- channel 0, a constant probe never crosses
                bus_write(base + 3, 100);
                bus_write(base + 4, 10);
                bus_write(base + 5, 50);
                bus_write(base + 0, 1);
                wait for 20 us;
                bus_read(base, status);
                check_equal(status(2 downto 0), std_logic_vector'("010"), "waiting for the trigger");
                bus_write(base + 0, 2);                  -- force
                wait_until_done;
                bus_read(base, status);
                check(status(8) = '1', "forced flag");

            elsif run("deep_capture_around_trigger") then
                bus_write(base + 10, 1);                 -- deep
                bus_write(base + 1, 3);
                bus_write(base + 7, 2**32/200);
                bus_write(base + 2, 16#100#);
                bus_write(base + 3, 0);
                bus_write(base + 4, 1500);               -- more than the block RAM holds
                bus_write(base + 5, 3000);
                bus_write(base + 0, 1);
                -- the trigger is awaited longer than the ring takes, so it wraps
                wait for 160 us;
                wait_until_done;
                read_deep_capture(3000);
                check(samples(1499, 0) < 0 and samples(1500, 0) >= 0, "rising zero crossing at the trigger sample");
                check_counter_is_continuous(3000);
                bus_read(base + 11, status);
                check_equal(to_integer(unsigned(status)), 0, "no overflows");
                bus_read(base + 13, status);
                check_equal(to_integer(unsigned(status)), deep_records, "ring size");

            elsif run("deep_capture_counts_overflows") then
                bus_write(base + 10, 1);
                bus_write(base + 2, 0);
                bus_write(base + 4, 0);
                bus_write(base + 5, 2000);
                bus_write(base + 0, 1);
                wait for 2 us;
                force_full <= true;
                wait for 80 ns;
                force_full <= false;
                wait_until_done;
                bus_read(base + 11, status);
                check(to_integer(unsigned(status)) >= 9 and to_integer(unsigned(status)) <= 11,
                      "overflows " & integer'image(to_integer(unsigned(status))));
                -- back to block RAM captures
                bus_write(base + 10, 0);
                bus_write(base + 5, 100);
                bus_write(base + 0, 1);
                wait_until_done;
                read_capture(100);
                check_counter_is_continuous(100);

            elsif run("probe_table_readout") then
                bus_read(base + 8, status);
                check_equal(to_integer(unsigned(status(31 downto 24))), 16, "sources");
                -- a generator source, a probe and an unused index
                bus_write(base + 16, 7);
                wait for 200 ns;     -- the names' RAM fetch
                bus_read(base + 17, status);
                check_equal(status, std_logic_vector'(x"636F756E"), "name of source 7 starts with coun");
                bus_read(base + 21, status);
                check_equal(to_integer(unsigned(status)), unsigned_probe, "format of the generator counter");
                bus_write(base + 16, 8 + 7);
                wait for 200 ns;
                bus_read(base + 17, status);
                check_equal(status, std_logic_vector'(x"6C616E65"), "lane");
                bus_read(base + 18, status);
                check_equal(status, std_logic_vector'(x"73000000"), "s and zeros");
                bus_read(base + 21, status);
                check_equal(to_integer(unsigned(status)), digital_probe, "digital format");
                bus_write(base + 16, 200);
                wait for 200 ns;
                bus_read(base + 17, status);
                check_equal(status, std_logic_vector'(x"00000000"), "no source 200");

            elsif run("pattern_trigger_on_digital_probe") then
                -- lanes 3:0 of probe 7 count, the trigger waits for lanes 3 and 1 high, 0 low
                bus_write(base + 14, 16#0706050F#);      -- channel 4 from probe 7 (source 15)
                bus_write(base + 2, 16#134#);            -- channel 4, pattern, enabled
                bus_write(base + 15, 16#000B000A#);      -- mask 1011, pattern 1010
                bus_write(base + 4, 10);
                bus_write(base + 5, 40);
                bus_write(base + 0, 1);
                for i in 0 to 400 loop
                    wait until rising_edge(clock);
                    probes(7) <= std_logic_vector(to_unsigned((i / 3) mod 16, 16));
                end loop;
                wait_until_done;
                read_capture(40);
                check_equal(samples(10, 4) mod 16 / 8, 1, "lane 3 at the trigger");
                check_equal(samples(10, 4) mod 2, 0, "lane 0 at the trigger");
                check_equal(samples(10, 4) mod 4 / 2, 1, "lane 1 at the trigger");
                check((samples(9, 4) mod 16) mod 16 /= 10 and (samples(9, 4) mod 16) /= 14, "no match before the trigger");

            elsif run("unsigned_level_trigger") then
                -- probe 0 ramps through 0x8000, which a signed compare sees as a jump to negative
                bus_write(base + 6, 16#03020108#);       -- channel 0 from probe 0
                bus_write(base + 2, 16#300#);            -- channel 0, rising, enabled, unsigned
                bus_write(base + 3, 16#9000#);
                bus_write(base + 4, 5);
                bus_write(base + 5, 20);
                bus_write(base + 0, 1);
                for i in 0 to 300 loop
                    wait until rising_edge(clock);
                    probes(0) <= std_logic_vector(to_unsigned(16#8F00# + 16 * i, 16));
                end loop;
                wait_until_done;
                read_capture(20);
                check(samples(4, 0) mod 65536 < 16#9000# and samples(5, 0) mod 65536 >= 16#9000#, "crossing of 0x9000 unsigned");

            elsif run("probe_source") then
                probes(3) <= x"1234";
                bus_write(base + 6, 16#0302010B#);       -- channel 0 from probe 3 (source 11)
                bus_write(base + 2, 0);
                bus_write(base + 4, 0);
                bus_write(base + 5, 10);
                bus_write(base + 0, 1);
                wait_until_done;
                read_capture(10);
                check_equal(samples(5, 0), 16#1234#, "probe 3 on channel 0");
                check_counter_is_continuous(10);
            end if;
        end loop;

        test_runner_cleanup(runner);
        wait;
    end process;

    test_runner_watchdog(runner, 20 ms);

end vunit_simulation;
