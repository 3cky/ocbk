// qbus_slot - cartridge-slot bridge for the internal Q-bus (forward seam).
//
// Maps the shared internal Q-bus (inverted, active-low, open-collector) out to
// the physical 1chipMSX/OneChipBook cartridge-slot pins, so real BK Q-bus
// hardware can be attached later. It is a first-class participant on the same
// shared nets as the vm1 core and the qbus_mem front-end.
//
//   PARAMETER SLOT_ENABLE
//     0 (the shipped value) : the bridge drives NOTHING - all slot pins are
//        released (Hi-Z, left reserved-tristated by the .qsf) and the internal
//        Q-bus is untouched, so the on-chip core + memory run undisturbed.
//     1 (not yet used)      : the bridge connects the internal bus to the slot
//        pins and drives the external-transceiver direction on pSltBdir_n.
//
// Slot pin map (mirrors esemsx3 emsx_top_common.qsf, documented in the .qsf):
//   ad_n[15:0] <-> pSltAdr[15:0]              multiplexed address/data
//   sync_n      -> pSltMerq_n                  address strobe
//   din_n       -> pSltRd_n                    data-in  strobe
//   dout_n      -> pSltWr_n                    data-out strobe
//   wtbt_n      -> pSltIorq_n                  write/byte status
//   rply_n     <-  pSltWait_n  (open-collector, has board pull-up)
//   (DMA / IRQ / iako / init / sp / sel / bsy map onto pSltDat[7:0] + spares;
//    wired when SLOT_ENABLE=1 hardware bring-up happens - see CLAUDE.md's
//    "Open / deferred" section)
//
// ELECTRICAL: Cyclone I is 3.3V LVTTL and NOT 5V-tolerant (PCI clamp only), and
// the board has no FPGA-controlled transceiver. Real 5V BK Q-bus REQUIRES an
// external bidirectional 5V<->3.3V level-shifter; this bridge drives its
// direction on pSltBdir_n from a BusDir-style equation.

module qbus_slot #(
    parameter bit SLOT_ENABLE = 1'b0
) (
    // ---- shared internal Q-bus (inverted, active low) -------------------
    inout  wire  [15:0] ad_n,
    input  wire         sync_n,    // CPU-driven strobes (FPGA is bus master)
    input  wire         din_n,
    input  wire         dout_n,
    input  wire         wtbt_n,
    inout  wire         rply_n,    // open-collector: slot slave may assert

    // ---- physical cartridge-slot pins -----------------------------------
    inout  wire  [15:0] pSltAdr,
    inout  wire         pSltMerq_n,
    inout  wire         pSltRd_n,
    inout  wire         pSltWr_n,
    inout  wire         pSltIorq_n,
    inout  wire         pSltWait_n,
    output wire         pSltBdir_n  // external transceiver direction
);

    generate
        if (SLOT_ENABLE) begin : g_on
            // FPGA is bus master: drive address/strobes outward; release the
            // AD bus during the read data phase so an external slave can drive.
            wire drive_ad = sync_n ? 1'b0 : din_n;   // address phase or write

            assign pSltAdr    = drive_ad ? ad_n : 16'hZZZZ;
            assign pSltMerq_n = sync_n;
            assign pSltRd_n   = din_n;
            assign pSltWr_n   = dout_n;
            assign pSltIorq_n = wtbt_n;

            // External slave's reply (WAIT, open-collector) -> internal RPLY.
            assign rply_n     = pSltWait_n ? 1'bZ : 1'b0;
            // Inbound read data from the slot -> internal AD when reading.
            assign ad_n       = drive_ad ? 16'hZZZZ : pSltAdr;

            // Transceiver direction: 0 = FPGA drives the slot data bus.
            assign pSltBdir_n = drive_ad ? 1'b0 : 1'b1;
        end
        else begin : g_off
            // Disabled: release every slot pin and the internal bus.
            assign pSltAdr    = 16'hZZZZ;
            assign pSltMerq_n = 1'bZ;
            assign pSltRd_n   = 1'bZ;
            assign pSltWr_n   = 1'bZ;
            assign pSltIorq_n = 1'bZ;
            assign pSltWait_n = 1'bZ;
            assign pSltBdir_n = 1'bZ;
            assign ad_n       = 16'hZZZZ;
            assign rply_n     = 1'bZ;
        end
    endgenerate

endmodule
