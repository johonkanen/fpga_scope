library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

library vunit_lib;
    context vunit_lib.vunit_context;

-- scope_fifo against a model queue: random writes and reads, also to a full and from an
-- empty FIFO, a clear in the middle; every word read is the one the model expects, the
-- count and the flags follow the model.
entity scope_fifo_tb is
    generic(runner_cfg : string);
end entity;

architecture sim of scope_fifo_tb is
    constant depth : natural := 16;
    constant width : natural := 24;

    signal clock      : std_logic := '0';
    signal done       : boolean := false;
    signal clear      : boolean := false;
    signal write      : boolean := false;
    signal read       : boolean := false;
    signal write_data : std_logic_vector(width-1 downto 0) := (others => '0');
    signal read_data  : std_logic_vector(width-1 downto 0);
    signal count      : natural range 0 to depth;
    signal is_empty, is_full : boolean;
begin

    clock <= not clock after 5 ns when not done;

    dut : entity work.scope_fifo
    generic map(g_width => width, g_depth => depth)
    port map(clock, clear, write, write_data, read, read_data, count, is_empty, is_full);

    main : process
        type queue_array is array (0 to depth-1) of std_logic_vector(width-1 downto 0);
        variable queue      : queue_array;
        variable head, fill : natural := 0;
        variable seed1, seed2 : positive := 7;
        variable r          : real;
        variable next_word  : natural := 1;
        variable reads, writes, full_writes, empty_reads : natural := 0;
        variable do_write, do_read : boolean;
        variable taken_write, taken_read : boolean;
    begin
        test_runner_setup(runner, runner_cfg);
        for cycle in 0 to 20000 loop
            -- phases that fill it, empty it, and mix both
            uniform(seed1, seed2, r);
            case (cycle / 500) mod 3 is
                when 0      => do_write := r < 0.8; uniform(seed1, seed2, r); do_read := r < 0.2;
                when 1      => do_write := r < 0.2; uniform(seed1, seed2, r); do_read := r < 0.8;
                when others => do_write := r < 0.5; uniform(seed1, seed2, r); do_read := r < 0.5;
            end case;
            write      <= do_write;
            read       <= do_read;
            write_data <= std_logic_vector(to_unsigned(next_word, width));
            clear      <= cycle = 10000;
            wait until rising_edge(clock);
            wait for 1 ns;

            if cycle = 10000 then
                head := 0;
                fill := 0;
            else
                -- both decided on the fill before the clock, as the FIFO does
                taken_read  := do_read and fill > 0;
                taken_write := do_write and fill < depth;
                -- a read's word is valid after the clock that takes it
                if taken_read then
                    check_equal(read_data, queue(head), "the word read");
                    head       := (head + 1) mod depth;
                    reads      := reads + 1;
                elsif do_read then
                    empty_reads := empty_reads + 1;
                end if;
                if taken_write then
                    queue((head + fill - boolean'pos(taken_read)) mod depth) :=
                        std_logic_vector(to_unsigned(next_word, width));
                    next_word := next_word + 1;
                    writes    := writes + 1;
                elsif do_write then
                    full_writes := full_writes + 1;
                end if;
                fill := fill + boolean'pos(taken_write) - boolean'pos(taken_read);
            end if;
            check_equal(count, fill, "count");
            check(is_empty = (fill = 0), "is_empty");
            check(is_full = (fill = depth), "is_full");
        end loop;
        info(integer'image(writes) & " writes, " & integer'image(reads) & " reads, " &
             integer'image(full_writes) & " writes to a full and " & integer'image(empty_reads) &
             " reads from an empty FIFO");
        check(full_writes > 0 and empty_reads > 0, "both ends reached");
        done <= true;
        test_runner_cleanup(runner);
    end process;

end architecture sim;
