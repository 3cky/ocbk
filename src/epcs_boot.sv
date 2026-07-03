// epcs_boot - Phase-5 boot-time ROM loader: EPCS config flash -> SDRAM.
//
// After SDRAM init (start), reads the boot blob (built by mem/gen_boot_blob.py)
// from the EPCS4 serial flash at FLASH_ADDR with the plain READ (0x03) command
// and streams it as 16-bit words into the SDRAM ROM region (words ROM_BASE_W+)
// through a generic write port. The port is muxed onto sdram_arbiter port 0
// externally (the "boot-writer mux" reserved in sdram_arbiter.sv) - the CPU is
// still in DCLO while this runs, so port 0 is otherwise idle.
//
// Flash bit order (hardware-verified): quartus_cpf bit-reverses hex_block bytes
// into the POF/RPD (the RPD is in RBF/LSB-first bit order - its Page_0 equals
// the .rbf verbatim), and quartus_pgm -m AS bit-reverses AGAIN when programming
// the EPCS. The two reversals cancel: the physical flash holds the Intel-HEX
// bytes verbatim as seen by an MSB-first SPI READ, so gen_boot_blob.py emits
// true bytes and this loader is a plain MSB-first shift, matching the
// behavioural sim/epcs_model.sv. (A first attempt pre-reversed the HEX on the
// mistaken belief RPD = physical bytes; on the board the loader then read
// rev(blob) and parked in the checksum-fail fallback.)
//
// SPI: mode 0, DCLK = clk/8 (12.08 MHz at the 96.65 MHz sys_clk - EPCS4 plain
// READ is only rated to ~20-25 MHz). MOSI advances at the DCLK fall, MISO is
// sampled late in the DCLK-high phase. The whole 32.7 KB load takes ~22 ms.
// The 1801ВМ1 reset stays held (Step-5 sequencer) until boot_done.
//
// Blob: u16 magic 0x4B42 ("BK"), u16 length (words), u16 checksum (16-bit sum
// of data words), u16 zero, then length data words - all little-endian (low
// byte first in the flash stream). Bad magic / length / checksum -> boot_ok=0
// (the top level then falls back to the on-chip test ROM).
module epcs_boot #(
    parameter int          ADDR_BITS  = 24,
    parameter logic [23:0] FLASH_ADDR = 24'h040000,  // blob offset in the EPCS
    parameter logic [23:0] ROM_BASE_W = 24'h004000,  // SDRAM word addr of BK 100000
    parameter int          MAX_WORDS  = 16320        // ROM window 100000-177577
) (
    input  logic                 clk,        // sys_clk
    input  logic                 rst_n,
    input  logic                 start,      // level; begin once high (after init_done)

    // ---- SPI master (to cyclone_asmiblock at the top level) --------------
    output logic                 spi_dclk,
    output logic                 spi_ncs,
    output logic                 spi_mosi,   // -> sdoin (ASDO)
    input  logic                 spi_miso,   // <- data0out (DATA0)

    // ---- SDRAM write port (boot-writer mux onto arbiter port 0) ----------
    output logic                 bw_req,
    output logic [ADDR_BITS-1:0] bw_addr,
    output logic [15:0]          bw_wdata,
    input  logic                 bw_gnt,

    // ---- status -----------------------------------------------------------
    output logic                 boot_active, // owns the port-0 mux while high
    output logic                 boot_done,   // load finished (either way)
    output logic                 boot_ok      // blob valid and fully written
);

    localparam logic [15:0] MAGIC = 16'h4B42;

    typedef enum logic [2:0] {
        B_IDLE, B_CMD, B_STREAM, B_FINISH, B_DONE
    } bstate_t;
    bstate_t state;

    // DCLK divider: /8 -> low for div 0..3, high for div 4..7 (mode 0).
    logic [2:0]  div;
    wire         bit_launch = (div == 3'd0);   // DCLK-fall phase: advance MOSI
    wire         bit_sample = (div == 3'd7);   // late DCLK-high: sample MISO

    logic [31:0] sh_out;      // command + address shifter (MSB first)
    logic [5:0]  out_left;    // bits left to launch in B_CMD
    logic [7:0]  sh_in;       // input byte shifter (MSB first)
    logic [2:0]  in_bits;     // bits collected in the current byte
    logic [15:0] cur_lo;      // low byte of the word being assembled
    logic        have_lo;

    // byte stream book-keeping: 8 header bytes, then 2*length data bytes
    logic [17:0] byte_idx;
    logic [15:0] blob_len;    // words
    logic [15:0] blob_sum;    // expected checksum (header)
    logic [15:0] calc_sum;    // running data-word sum
    logic [15:0] word_idx;
    logic        hdr_bad;

    assign boot_active = (state != B_IDLE) && (state != B_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= B_IDLE;
            spi_dclk <= 1'b0;
            spi_ncs  <= 1'b1;
            spi_mosi <= 1'b0;
            div      <= '0;
            bw_req   <= 1'b0;
            boot_done <= 1'b0;
            boot_ok   <= 1'b0;
            hdr_bad   <= 1'b0;
            have_lo   <= 1'b0;
            in_bits   <= '0;
            byte_idx  <= '0;
            word_idx  <= '0;
            calc_sum  <= '0;
        end else begin
            if (bw_gnt) bw_req <= 1'b0;        // served-mask contract

            case (state)
                B_IDLE: if (start) begin
                    sh_out   <= {8'h03, FLASH_ADDR};
                    out_left <= 6'd32;
                    spi_ncs  <= 1'b0;
                    div      <= '0;
                    state    <= B_CMD;
                end

                // shift out READ + 24-bit address, MSB first
                B_CMD: begin
                    div <= div + 1'b1;
                    spi_dclk <= (div >= 3'd3) && (div != 3'd7);
                    if (bit_launch) begin
                        if (out_left == 0) begin
                            in_bits <= '0;
                            state   <= B_STREAM;
                        end else begin
                            spi_mosi <= sh_out[31];
                            sh_out   <= {sh_out[30:0], 1'b0};
                            out_left <= out_left - 1'b1;
                        end
                    end
                end

                // stream bytes in, MSB first; parse header, write data words
                B_STREAM: begin
                    div <= div + 1'b1;
                    spi_dclk <= (div >= 3'd3) && (div != 3'd7);
                    if (bit_sample) begin
                        sh_in   <= {sh_in[6:0], spi_miso};
                        in_bits <= in_bits + 1'b1;
                        if (in_bits == 3'd7) begin : got_byte
                            logic [7:0] b;
                            b = {sh_in[6:0], spi_miso};
                            byte_idx <= byte_idx + 1'b1;
                            if (!byte_idx[0]) begin
                                cur_lo  <= {8'h00, b};
                                have_lo <= 1'b1;
                            end else begin : got_word
                                logic [15:0] w;
                                w = {b, cur_lo[7:0]};
                                have_lo <= 1'b0;
                                case (byte_idx[17:1])
                                    17'd0: if (w != MAGIC) hdr_bad <= 1'b1;
                                    17'd1: begin
                                        blob_len <= w;
                                        if (w == 0 || w > MAX_WORDS) hdr_bad <= 1'b1;
                                    end
                                    17'd2: blob_sum <= w;
                                    17'd3: ;                        // spare
                                    default: begin                  // data word
                                        if (!hdr_bad) begin
                                            bw_addr  <= ROM_BASE_W + word_idx;
                                            bw_wdata <= w;
                                            bw_req   <= 1'b1;
                                            calc_sum <= calc_sum + w;
                                            word_idx <= word_idx + 1'b1;
                                            if (word_idx == blob_len - 1)
                                                state <= B_FINISH;
                                        end else
                                            state <= B_FINISH;
                                    end
                                endcase
                            end
                        end
                    end
                end

                // wait for the last write grant, then verdict
                B_FINISH: begin
                    spi_dclk <= 1'b0;
                    spi_ncs  <= 1'b1;
                    if (!bw_req) begin
                        boot_ok   <= !hdr_bad && (calc_sum == blob_sum);
                        boot_done <= 1'b1;
                        state     <= B_DONE;
                    end
                end

                B_DONE: ;                       // park (until next power cycle)

                default: state <= B_IDLE;
            endcase
        end
    end

endmodule
