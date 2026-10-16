-- The register bus the scope is tested with: 32 bit data, 16 bit addresses. A design brings
-- its own instance of fpga_interconnect_generic_pkg named fpga_interconnect_pkg; the scope
-- needs 32 bit data.
package fpga_interconnect_pkg is new work.fpga_interconnect_generic_pkg
    generic map(number_of_data_bits => 32,
                number_of_address_bits => 16);
