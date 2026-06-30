// qbus_mem - synthesizable Q-bus memory slave with deterministic RPLY timing.
//
// A synthesizable re-implementation of the behavioural memory model in the
// upstream bk10 timing testbench (cpu11/vm1/.../sim/bk10/bk10_tb.v). It replies
// to the vm1 core a fixed number of clock cycles after DIN/DOUT, hiding its
// (zero) block-RAM latency behind the same N_RAM / N_ROM counts the testbench
// uses, so on-hardware instruction timing reproduces the reference cycle counts.
//
// All Q-bus lines are active-low / inverted, matching the vm1.v pin shell:
//   - the address/data bus ad_n carries ~data; the slave drives it only while
//     returning read data, otherwise releases it (tri-state),
//   - rply_n is open-collector: driven 0 to reply, released (Z) otherwise.
//
// Clocking: `clk` is wired to the inverted CPU clock (pin_clk_n net). The
// upstream model advances its wait-states on `negedge clk` of the CPU clock,
// i.e. the rising edge of pin_clk_n - so clocking this FSM on pin_clk_n mirrors
// the reference timing directly.
//
// Memory map (the slave handles only what the bk10 program needs):
//   RAM 000000-007777 : block RAM (RAM_WORDS x 16), init from MEMFILE
//   ROM 100000,100002 : 2-word bootstrap  (JMP @#001000)
//   I/O 177716        : system register -> 100000   (other I/O -> 0)

module qbus_mem #(
   parameter         MEMFILE   = "mem/bk10_prog.hex",
   parameter integer RAM_WORDS = 2048               // 000000-007777
) (
   input  logic        clk,        // = pin_clk_n (inverted CPU clock)
   input  logic        reset,      // synchronous reset, active high

   inout  wire  [15:0] ad_n,       // shared inverted address/data bus
   input  logic        sync_n,     // address strobe   (active low)
   input  logic        din_n,      // data-in strobe   (active low)
   input  logic        dout_n,     // data-out strobe  (active low)
   input  logic        wtbt_n,     // write/byte status(active low)
   output wire         rply_n,     // transaction reply (open-collector net)

   // Bus-activity taps for liveness / debug (true polarity)
   output wire  [15:0] bus_addr,   // last latched bus address
   output logic        fetch_stb   // 1-cycle pulse on each RAM read transaction
);

   import qbus_pkg::*;

   localparam int unsigned RAM_AW = $clog2(RAM_WORDS);

   // -------------------------------------------------------------------------
   // Block RAM (synchronous, single source of truth via $readmemh)
   // -------------------------------------------------------------------------
   logic [15:0] ram [0:RAM_WORDS-1];
   initial $readmemh(MEMFILE, ram);

   // -------------------------------------------------------------------------
   // Address latch: transparent on the SYNC strobe (closes on its falling
   // edge), exactly as the reference model and real К565РУ5/peripheral latches.
   // The true address is ~ad_n at that instant; a synchronous slave-clock sample
   // would be a fraction of a CPU clock late, after the master releases AD for
   // the data phase. Latching on the bus strobe is how real multiplexed-bus
   // peripherals capture the address. The decode is combinational over the
   // latched address and is only acted upon by the FSM while SYNC is asserted.
   //
   // SYNC is therefore a (slow, logic-derived) clock for this register; the
   // SDC declares it and cuts it from analysis, since the captured address is
   // stable by bus protocol (validated cycle-exact by the bk10 cosim).
   // -------------------------------------------------------------------------
   logic [15:0] addr;
   logic        wflg;

   always_ff @(negedge sync_n) begin
      addr <= ~ad_n;
      wflg <= ~wtbt_n;
   end

   wire sel_ram = !sync_n && (addr <  RAM_TOP);
   wire sel_rom = !sync_n && (addr >= RAM_TOP) && (addr < IO_BASE);
   wire sel_io  = !sync_n && (addr >= IO_BASE);

   assign bus_addr = addr;

   // -------------------------------------------------------------------------
   // Read data source (combinational over latched address)
   // -------------------------------------------------------------------------
   wire [RAM_AW-1:0] ram_idx = addr[RAM_AW:1];
   logic [15:0]      rom_word;
   always_comb begin
      if      (addr == 16'o100000) rom_word = 16'o000137;   // JMP @#...
      else if (addr == 16'o100002) rom_word = 16'o001000;   // ... 001000
      else                         rom_word = 16'o000000;
   end

   wire [15:0] io_word  = (addr == REG_SYS) ? SYS_START : 16'o000000;
   wire [15:0] rd_word  = sel_ram ? ram[ram_idx]
                        : sel_rom ? rom_word
                        :           io_word;

   // -------------------------------------------------------------------------
   // Wait-state FSM (advances on pin_clk_n, mirroring the testbench negedge-clk)
   // -------------------------------------------------------------------------
   typedef enum logic [1:0] { S_IDLE, S_WAIT, S_REPLY } state_t;
   state_t state;

   logic [2:0]  wcnt;
   logic        drive_data;     // slave drives ad_n with read data
   logic        reply;          // slave pulls rply_n low
   logic [15:0] rdata;

   wire       selected = sel_ram | sel_rom | sel_io;
   wire       is_read  = !din_n;
   wire       is_write = !dout_n;
   // Data/RPLY are decided when the down-counter reaches 0 and registered one
   // edge later, so a load of N-2 lands the driven data exactly N slave cycles
   // after the strobe (matching the reference model), with the read/write
   // decision still sampled while the CPU holds DIN/DOUT asserted.
   wire [2:0] wait_n   = sel_ram ? (N_RAM-2) : (N_ROM-2);

   always_ff @(posedge clk) begin
      fetch_stb <= 1'b0;
      if (reset) begin
         state      <= S_IDLE;
         drive_data <= 1'b0;
         reply      <= 1'b0;
         wcnt       <= '0;
      end else begin
         unique case (state)
            S_IDLE: begin
               drive_data <= 1'b0;
               reply      <= 1'b0;
               if (!sync_n && selected && (is_read || is_write)) begin
                  wcnt  <= wait_n[2:0];
                  state <= S_WAIT;
               end
            end
            S_WAIT: begin
               if (wcnt == 0) begin
                  reply <= 1'b1;                  // assert RPLY
                  if (is_read) begin
                     rdata      <= rd_word;
                     drive_data <= 1'b1;
                     if (sel_ram) fetch_stb <= 1'b1;
                  end else if (is_write && sel_ram) begin
                     if (wflg) begin              // byte write
                        if (addr[0]) ram[ram_idx][15:8] <= ~ad_n[15:8];
                        else         ram[ram_idx][7:0]  <= ~ad_n[7:0];
                     end else begin               // word write
                        ram[ram_idx] <= ~ad_n;
                     end
                  end
                  state <= S_REPLY;
               end else begin
                  wcnt <= wcnt - 1'b1;
               end
            end
            S_REPLY: begin
               // Hold RPLY + data until the CPU drops the strobe, then release.
               if (din_n && dout_n) begin
                  reply      <= 1'b0;
                  drive_data <= 1'b0;
                  state      <= S_IDLE;
               end
            end
         endcase
      end
   end

   // -------------------------------------------------------------------------
   // Bus drivers (inverted polarity; open-collector RPLY)
   // -------------------------------------------------------------------------
   assign ad_n   = drive_data ? ~rdata : 16'hZZZZ;
   assign rply_n = reply      ? 1'b0   : 1'bZ;

endmodule
