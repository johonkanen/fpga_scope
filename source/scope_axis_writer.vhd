library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

-- scope_capture's deep capture port to a 64 bit AXI stream into a DMA channel that writes a circular buffer in the CPU's
-- memory. The software restarts the DMA at the start of its buffer before it arms a deep
-- capture, which is what capture_reset asks for, so this port is always ready.
--
-- A record is two beats laid out so that the memory holds the channels in order: 16 bit
-- word 8*s + c of the buffer is channel c of sample s (little endian, channel 0 lowest).
--
-- The DMA writes whole bursts of g_burst_records records. When the capture flushes, zero
-- records follow the last one, at least g_min_pad and up to a burst boundary counted from
-- capture_reset: the capture reaches the memory and nothing stays behind in the DMA to
-- land at the start of the next pass. The padding lands after the capture in the ring, so a
-- capture must leave g_min_pad + g_burst_records records of the buffer free.
-- capture_written counts the records the DMA has taken and, while flushing, only once the
-- padding has gone too: the last of them are in the memory within microseconds after that.
entity scope_axis_writer is
    generic(
        g_fifo_records  : positive := 512;   -- power of two
        g_burst_records : positive := 16;    -- the DMA's 256 byte bursts, power of two
        g_min_pad       : positive := 16
    );
    port(
        clock            : in std_logic;
        -- from scope_capture
        capture_reset    : in boolean;
        capture_write    : in boolean;
        capture_data     : in std_logic_vector(127 downto 0);
        capture_flush    : in boolean;
        capture_is_full  : out boolean;
        capture_is_ready : out boolean;
        capture_written  : out unsigned(31 downto 0);
        -- to the DMA channel
        tvalid           : out std_logic;
        tready           : in std_logic;
        tdata            : out std_logic_vector(63 downto 0);
        tkeep            : out std_logic_vector(7 downto 0);
        tlast            : out std_logic
    );
end entity scope_axis_writer;

architecture rtl of scope_axis_writer is
    signal fifo_read     : boolean := false;
    signal fifo_data     : std_logic_vector(127 downto 0);
    signal fifo_is_empty : boolean;

    -- a FIFO read: 2 while the FIFO takes the read, 1 when fifo_data is the record
    signal fetch         : natural range 0 to 2 := 0;
    signal holding       : boolean := false;   -- current is being sent
    signal is_padding    : boolean := false;
    signal second_half   : boolean := false;
    signal current       : std_logic_vector(127 downto 0) := (others => '0');
    signal accepted      : unsigned(31 downto 0) := (others => '0');   -- capture records
    signal sent          : unsigned(31 downto 0) := (others => '0');   -- and padding
    signal pads_sent     : natural range 0 to g_min_pad := 0;

    -- record: channel 0 in bits 127:112 ... channel 7 in bits 15:0
    function channel(r : std_logic_vector(127 downto 0); c : natural) return std_logic_vector is
    begin
        return r(127 - 16*c downto 112 - 16*c);
    end function;
begin

    u_fifo : entity work.scope_fifo
    generic map(g_width => 128, g_depth => g_fifo_records)
    port map(
        clock      => clock,
        clear      => capture_reset,
        write      => capture_write,
        write_data => capture_data,
        read       => fifo_read,
        read_data  => fifo_data,
        count      => open,
        is_empty   => fifo_is_empty,
        is_full    => capture_is_full
    );

    capture_is_ready <= true;

    tvalid <= '1' when holding else '0';
    tkeep  <= (others => '1');
    tlast  <= '0';
    tdata  <= channel(current, 3) & channel(current, 2) & channel(current, 1) & channel(current, 0)
                  when not second_half else
              channel(current, 7) & channel(current, 6) & channel(current, 5) & channel(current, 4);

    process(clock)
        variable sending  : boolean;
        variable sent_now : unsigned(31 downto 0);
        variable pads_now : natural range 0 to g_min_pad;
    begin
        if rising_edge(clock) then
            fifo_read <= false;
            sending   := holding;
            sent_now  := sent;
            pads_now  := pads_sent;

            if holding and tready = '1' then
                if not second_half then
                    second_half <= true;
                else
                    second_half <= false;
                    sending     := false;
                    sent_now    := sent_now + 1;
                    if not is_padding then
                        accepted <= accepted + 1;
                    end if;
                end if;
            end if;

            -- the next record: from the FIFO, or padding once the capture is flushing
            if fetch = 2 then
                fetch <= 1;
            elsif fetch = 1 then
                current    <= fifo_data;
                is_padding <= false;
                sending    := true;
                fetch      <= 0;
            elsif not sending then
                if not fifo_is_empty then
                    fifo_read <= true;
                    fetch     <= 2;
                -- capture_write: the last record goes into the FIFO on this clock, which
                -- still looks empty; the scope raises the flush with that write
                elsif capture_flush and not capture_write
                      and not (pads_now = g_min_pad and sent_now mod g_burst_records = 0) then
                    current    <= (others => '0');
                    is_padding <= true;
                    sending    := true;
                    if pads_now < g_min_pad then
                        pads_now := pads_now + 1;
                    end if;
                end if;
            end if;
            holding   <= sending;
            sent      <= sent_now;
            pads_sent <= pads_now;

            -- all taken: nothing in flight and the padding complete
            if capture_flush and (sending or fetch /= 0 or not fifo_is_empty or capture_write
                                  or pads_now < g_min_pad or sent_now mod g_burst_records /= 0) then
                capture_written <= (others => '0');
            else
                capture_written <= accepted;
            end if;

            if capture_reset then
                fetch       <= 0;
                holding     <= false;
                second_half <= false;
                accepted    <= (others => '0');
                sent        <= (others => '0');
                pads_sent   <= 0;
            end if;
        end if;
    end process;

end architecture rtl;
