// LOCAL HOOK H1 (ocbk): the microcode image path is a parameter instead of a
// literal, so the Quartus build finds it under mem/ (project-root relative)
// while a testbench overrides it with its own relative path. Same idiom as
// qbus_sdram.sv's MEMFILE.
//
// LOCAL HOOK H7 (ocbk): the depth is 668, not upstream's 536 - the image is no
// longer upstream's. It is assembled from mem/usb_hid_host_rom.s (upstream's
// ukp.s plus microcode hook F1, SET_PROTOCOL) by mem/gen_usb_rom.py, and THIS
// NUMBER MUST EQUAL THE NIBBLE COUNT THAT SCRIPT PRINTS - it reads short and
// the microcode falls off the end into x. One M4K holds 1024, so there is room;
// the script fails the build past that. Everything else is upstream verbatim.
module usb_hid_host_rom #(parameter ROMFILE = "mem/usb_hid_host_rom.hex")
                        (clk, adr, data);
    input clk;
    input [13:0] adr;
    output [3:0] data;
    reg [3:0] data;
    reg [3:0] mem [0:667];
    initial $readmemh(ROMFILE, mem);
    always @(posedge clk) data <= mem[adr];
endmodule
