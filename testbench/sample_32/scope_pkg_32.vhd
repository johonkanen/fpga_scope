-- The scope's package for 32 bit samples, as a design with float probes compiles it in place
-- of source/scope_pkg.vhd.
package scope_pkg is new work.scope_generic_pkg generic map (g_sample_bits => 32);
