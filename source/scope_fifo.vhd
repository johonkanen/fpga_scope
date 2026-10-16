library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    use work.dual_port_ram_pkg.all;

-- Single clock FIFO in a block RAM of hVHDL_memory_library (dual_port_ram, no output
-- register): port a writes, port b reads. read_data is valid the clock after read is
-- asserted. Writes to a full FIFO and reads from an empty one are ignored. clear empties it.
entity scope_fifo is
    generic(
        g_width : positive := 32;
        g_depth : positive := 512    -- power of two
    );
    port(
        clock      : in std_logic;
        clear      : in boolean := false;
        write      : in boolean;
        write_data : in std_logic_vector(g_width-1 downto 0);
        read       : in boolean;
        read_data  : out std_logic_vector(g_width-1 downto 0);
        count      : out natural range 0 to g_depth;
        is_empty   : out boolean;
        is_full    : out boolean
    );
end entity scope_fifo;

architecture rtl of scope_fifo is

    function address_bits return natural is
        variable bits : natural := 0;
    begin
        while 2**bits < g_depth loop
            bits := bits + 1;
        end loop;
        return bits;
    end function;

    constant ram_subtype : dpram_ref_record := create_ref_subtypes(datawidth => g_width, addresswidth => address_bits);
    constant ram_init    : ram_array(0 to g_depth-1)(g_width-1 downto 0) := (others => (others => '0'));
    signal ram_a_in, ram_b_in   : ram_subtype.ram_in'subtype;
    signal ram_a_out, ram_b_out : ram_subtype.ram_out'subtype;

    signal write_pointer, read_pointer : natural range 0 to g_depth-1 := 0;
    signal fill : natural range 0 to g_depth := 0;
    signal do_write, do_read : boolean;

begin

    count    <= fill;
    is_empty <= fill = 0;
    is_full  <= fill = g_depth;

    do_write <= write and fill < g_depth;
    do_read  <= read and fill > 0;

    -- the requests go to the RAM in the clock they come, as the RAM registers them itself
    ram_a_in.address           <= to_unsigned(write_pointer, address_bits);
    ram_a_in.data              <= write_data;
    ram_a_in.write_requested   <= '1' when do_write else '0';
    ram_a_in.read_is_requested <= '0';
    ram_b_in.address           <= to_unsigned(read_pointer, address_bits);
    ram_b_in.data              <= (others => '0');
    ram_b_in.write_requested   <= '0';
    ram_b_in.read_is_requested <= '1' when do_read else '0';
    read_data <= get_ram_data(ram_b_out);

    u_ram : entity work.dual_port_ram
    generic map(g_dpram_subtype => ram_subtype, g_ram_init_values => ram_init, g_output_register => false)
    port map(clock => clock, ram_a_in => ram_a_in, ram_a_out => ram_a_out,
             ram_b_in => ram_b_in, ram_b_out => ram_b_out);

    process(clock)
    begin
        if rising_edge(clock) then
            if do_write then
                write_pointer <= (write_pointer + 1) mod g_depth;
            end if;
            if do_read then
                read_pointer <= (read_pointer + 1) mod g_depth;
            end if;

            if do_write and not do_read then
                fill <= fill + 1;
            elsif do_read and not do_write then
                fill <= fill - 1;
            end if;

            if clear then
                write_pointer <= 0;
                read_pointer  <= 0;
                fill          <= 0;
            end if;
        end if;
    end process;

end architecture rtl;
