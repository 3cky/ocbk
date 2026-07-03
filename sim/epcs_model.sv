// epcs_model - behavioural EPCS4-class SPI flash for the epcs_boot cosim.
//
// Implements only what the loader uses: the plain READ (0x03) command, SPI
// mode 0 (data shifted out on the DCLK falling edge, MSB first, continuous
// sequential read while nCS stays low). The 512 KB array is X-filled; the tb
// loads the blob at the flash offset with
//     $readmemh("../mem/boot_blob_flash.hex", u_flash.flash, 'h40000);
// (boot_blob_flash.hex holds the TRUE blob bytes - see gen_boot_blob.py for
// the quartus_cpf bit-order story; a real EPCS programmed from the POF holds
// exactly these bytes).
//
`timescale 1ns / 1ps

module epcs_model (
    input  wire dclk,
    input  wire ncs,
    input  wire mosi,
    output wire miso
);

    reg [7:0] flash [0:(1<<19)-1];      // 512 KB (EPCS4 = 4 Mbit)

    reg [31:0] sh_in;                   // command + address collector
    integer    in_bits;
    reg [23:0] rd_addr;
    reg [7:0]  out_sh;
    integer    out_bits;
    reg        reading;
    reg        miso_r;

    assign miso = (!ncs && reading) ? miso_r : 1'bz;

    always @(posedge ncs) begin
        in_bits  = 0;
        out_bits = 0;
        reading  = 1'b0;
    end
    initial begin
        in_bits = 0; out_bits = 0; reading = 1'b0;
    end

    // command/address capture on the rising edge (mode 0)
    always @(posedge dclk) begin
        if (!ncs && !reading) begin
            sh_in   = {sh_in[30:0], mosi};
            in_bits = in_bits + 1;
            if (in_bits == 32) begin
                if (sh_in[31:24] == 8'h03) begin
                    rd_addr  = sh_in[23:0];
                    reading  = 1'b1;
                    out_bits = 0;
                end
            end
        end
    end

    // data shift-out on the falling edge, MSB first, auto-incrementing
    always @(negedge dclk) begin
        if (!ncs && reading) begin
            if (out_bits == 0) begin
                out_sh  = flash[rd_addr[18:0]];
                rd_addr = rd_addr + 1;
            end
            miso_r   = out_sh[7];
            out_sh   = {out_sh[6:0], 1'b0};
            out_bits = (out_bits == 7) ? 0 : out_bits + 1;
        end
    end

endmodule
