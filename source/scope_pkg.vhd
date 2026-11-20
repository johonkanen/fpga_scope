-- The scope's package for 16 bit samples (scope_generic_pkg.vhd). A design with 32 bit
-- samples compiles its own instance with g_sample_bits => 32 instead of this file.
package scope_pkg is new work.scope_generic_pkg generic map (g_sample_bits => 16);
