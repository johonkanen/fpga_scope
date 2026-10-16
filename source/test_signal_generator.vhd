library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    use work.scope_pkg.all;
    use work.sine_table_pkg.all;

-- Test signals for the oscilloscope, one new value per sample_enable:
--   0 sine, 1 cosine, 2 triangle, 3 square, 4 sawtooth, 5 noise (LFSR),
--   6 sine with noise, 7 sample counter
-- The signal frequency is phase_increment/2**32 of the sample rate.
entity test_signal_generator is
    port(
        clock           : in std_logic;
        sample_enable   : in boolean;
        phase_increment : in unsigned(31 downto 0);
        samples         : out scope_sample_array(0 to 7)
    );
end entity test_signal_generator;

architecture rtl of test_signal_generator is

    signal phase   : unsigned(31 downto 0) := (others => '0');
    signal lfsr    : std_logic_vector(31 downto 0) := x"ACE11234";
    -- flip-flops, not Efinity's SRL8 shift registers: their clock enable, sample_enable, could
    -- not be routed to them once the design grew (place and route: "could not find any path")
    attribute syn_srlstyle : string;
    attribute syn_srlstyle of lfsr : signal is "registers";
    signal counter : unsigned(15 downto 0) := (others => '0');

    function to_sample(value : integer) return scope_sample is
    begin
        return std_logic_vector(to_signed(value, scope_sample_bits));
    end function;

begin

    process(clock)
        variable index, cosine_index : natural range 0 to sine_table_length-1;
        variable sine_value          : integer range -32768 to 32767;
        variable triangle            : signed(16 downto 0);
        variable noise               : signed(15 downto 0);
    begin
        if rising_edge(clock) then
            if sample_enable then
                phase   <= phase + phase_increment;
                lfsr    <= lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
                counter <= counter + 1;

                index        := to_integer(phase(31 downto 22));
                cosine_index := to_integer(phase(31 downto 22) + 256);
                sine_value   := sine_table(index);
                noise        := signed(lfsr(15 downto 0));

                -- triangle from the top 17 bits of the phase: up in the first half, down in the second
                if phase(31) = '0' then
                    triangle := signed('0' & phase(30 downto 15)) - 16384*2;
                else
                    triangle := 32767 - signed('0' & phase(30 downto 15));
                end if;

                samples(0) <= to_sample(sine_value);
                samples(1) <= to_sample(sine_table(cosine_index));
                samples(2) <= std_logic_vector(resize(triangle, 16));
                if phase(31) = '0' then
                    samples(3) <= to_sample(24000);
                else
                    samples(3) <= to_sample(-24000);
                end if;
                samples(4) <= std_logic_vector(phase(31 downto 16) xor x"8000");
                samples(5) <= std_logic_vector(noise);
                samples(6) <= to_sample(sine_value/2 + to_integer(noise(15 downto 4)));
                samples(7) <= std_logic_vector(counter);
            end if;
        end if;
    end process;

end architecture rtl;
