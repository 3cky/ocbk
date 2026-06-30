// vm1_vcram_syn - synthesizable stub of the vm1 register-file RAM.
//
// On the flip-flop register-file path (CONFIG_VM1_CORE_REG_USES_RAM=0, which
// this project ships) vm1_reg_ram / vm1_vcram is still elaborated but its
// outputs are unused - the core selects the FF register file. The upstream
// behavioural model (vm1_simlib.v) has two write ports onto one array and is
// not synthesizable (Quartus: "multiple constant drivers"), and the Altera
// megafunction model (vm1_alib.v) is hard-coded to Cyclone III. This stub ties
// the outputs off so the synthesiser strips the whole unused instance.
//
// NOTE: valid ONLY for the FF register-file path. Selecting the RAM path
// (REG_USES_RAM=1) on hardware needs a real dual-port RAM here (regenerate the
// altsyncram for Cyclone / EP1C12).
module vm1_vcram (
   address_a, address_b, byteena_a, clock,
   data_a, data_b, wren_a, wren_b, q_a, q_b);

   input  [5:0]  address_a;
   input  [5:0]  address_b;
   input  [1:0]  byteena_a;
   input         clock;
   input  [15:0] data_a;
   input  [15:0] data_b;
   input         wren_a;
   input         wren_b;
   output [15:0] q_a;
   output [15:0] q_b;

   assign q_a = 16'b0;
   assign q_b = 16'b0;

endmodule
