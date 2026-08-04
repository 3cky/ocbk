// LOCAL HOOK (ocbk): the microcode image path is a parameter instead of a
// literal, so the Quartus build finds it under mem/ (project-root relative)
// while a testbench overrides it with its own relative path. Same idiom as
// qbus_sdram.sv's MEMFILE. Everything else is upstream verbatim.
module usb_hid_host_rom #(parameter ROMFILE = "mem/usb_hid_host_rom.hex")
                        (clk, adr, data);
    input clk;
    input [13:0] adr;
    output [3:0] data;
    reg [3:0] data;
    reg [3:0] mem [0:535];
    initial $readmemh(ROMFILE, mem);
    always @(posedge clk) data <= mem[adr];
endmodule
