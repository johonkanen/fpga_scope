library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    use work.fpga_interconnect_pkg.all;

-- APB3 slave to an fpga_interconnect register bus master: the SoC reaches the bus at
-- register address = PADDR / 4, so register r is at byte offset 4*r of the APB window.
-- A write is one bus write. A read waits for the slave's answer, a write to address 0;
-- with no answer within g_timeout clocks it reads 0, an address nothing decodes.
entity apb_bus_bridge is
    generic(
        g_timeout : positive := 64
    );
    port(
        clock     : in std_logic;
        psel      : in std_logic;
        penable   : in std_logic;
        pwrite    : in std_logic;
        paddr     : in std_logic_vector(15 downto 0);
        pwdata    : in std_logic_vector(31 downto 0);
        prdata    : out std_logic_vector(31 downto 0);
        pready    : out std_logic;
        pslverror : out std_logic;
        bus_out   : out fpga_interconnect_record;
        bus_in    : in fpga_interconnect_record
    );
end entity apb_bus_bridge;

architecture rtl of apb_bus_bridge is
    type states is (idle, reading, finish);
    signal state     : states := idle;
    signal timer     : natural range 0 to g_timeout := 0;
    signal ready     : std_logic := '0';
begin

    pready    <= ready;
    pslverror <= '0';

    process(clock)
        variable address : natural range 0 to 2**14-1;
    begin
        if rising_edge(clock) then
            init_bus(bus_out);
            ready <= '0';
            address := to_integer(unsigned(paddr(15 downto 2)));

            CASE state is
                WHEN idle =>
                    -- the access phase; ready is high in the clock that completes a transfer
                    if psel = '1' and penable = '1' and ready = '0' then
                        if pwrite = '1' then
                            write_data_to_address(bus_out, address, pwdata);
                            state <= finish;
                        else
                            request_data_from_address(bus_out, address);
                            timer <= 0;
                            state <= reading;
                        end if;
                    end if;

                WHEN reading =>
                    if write_to_address_is_requested(bus_in, 0) then
                        prdata <= get_slv_data(bus_in);
                        state  <= finish;
                    elsif timer = g_timeout then
                        prdata <= (others => '0');
                        state  <= finish;
                    else
                        timer <= timer + 1;
                    end if;

                WHEN finish =>
                    ready <= '1';
                    state <= idle;
            end CASE;
        end if;
    end process;

end architecture rtl;
