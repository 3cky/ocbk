PROJECT  := ocbk

QUARTUS_HOME ?= /opt/altera/11.0/quartus
QUARTUS_BIN  := $(QUARTUS_HOME)/bin

QUARTUS_MAP  := $(QUARTUS_BIN)/quartus_map
QUARTUS_FIT  := $(QUARTUS_BIN)/quartus_fit
QUARTUS_ASM  := $(QUARTUS_BIN)/quartus_asm
QUARTUS_STA  := $(QUARTUS_BIN)/quartus_sta
QUARTUS_CPF  := $(QUARTUS_BIN)/quartus_cpf

QUARTUS_PGM  := $(QUARTUS_BIN)/quartus_pgm
PGM_CABLE    := USB-Blaster

.PHONY: all compile sim clean distclean flash blob-check

all: compile

# --- simulation regressions (no Quartus required) -------------------------
sim:
	./sim/run_clkgen.sh
	./sim/run_mapper.sh
	./sim/raminit/run.sh
	./sim/evnt/run.sh
	./sim/bk10/run.sh
	./sim/bk11/run.sh
	./sim/smk/run.sh
	./sim/ide/run.sh
	./sim/ide/run_soc.sh
	./sim/ide/run_sd.sh
	./sim/romwr/run.sh
	./sim/ref037/run.sh
	./sim/ref014/run.sh
	./sim/run_ps2.sh
	./sim/run_audio.sh
	./sim/ts/run.sh
	./sim/covox/run.sh
	./sim/joystick/run.sh
	./sim/run_sdram_arbiter.sh
	./sim/run_sdram_cosim.sh
	./sim/run_video.sh
	./sim/run_epcs_boot.sh

# --- FPGA build -----------------------------------------------------------
compile: mem/ram_test.hex mem/boot_blob.hex mem/boot_blob11.hex
	@echo ">> Phase 1 - Analysis & Synthesis"
	$(QUARTUS_MAP) $(PROJECT).qpf
	@echo ">> Phase 2 - Fitter (Place & Route)"
	$(QUARTUS_FIT) $(PROJECT).qpf
	@[ -f $(PROJECT).fit.summary ] || { \
		echo "   Fitter failed, retrying (attempt 2)..."; \
		$(QUARTUS_MAP) $(PROJECT).qpf && $(QUARTUS_FIT) $(PROJECT).qpf; }
	@[ -f $(PROJECT).fit.summary ] || { \
		echo "   Fitter failed, retrying (final attempt)..."; \
		$(QUARTUS_MAP) $(PROJECT).qpf && $(QUARTUS_FIT) $(PROJECT).qpf; }
	@[ -f $(PROJECT).fit.summary ] || { echo "ERROR: Fitter failed after 3 attempts"; exit 1; }
	@echo ">> Phase 3 - Timing Analysis"
	$(QUARTUS_STA) $(PROJECT).qpf
	@echo ">> Phase 4 - Assembler"
	$(QUARTUS_ASM) $(PROJECT).qpf
	@echo ">> Phase 5 - Convert Programming Files"
	$(QUARTUS_CPF) -c $(PROJECT).cof
	@echo ">> Done! Firmware in $(PROJECT).pof"

mem/ram_test.hex: mem/gen_mem.py
	cd mem && python3 gen_mem.py ram_test.hex

# EPCS boot blobs: Phase-5 bk10 (BK-0010.01 MONITOR + BASIC Vilnius) at flash
# offset 0x40000 + Phase-7 bk11 (BASIC/EXT window banks, BOS, MSTD) at
# 0x48000, both appended to the POF as ocbk.cof hex_block pages. One script
# run generates both.
mem/boot_blob.hex: mem/gen_boot_blob.py mem/roms/monit10.rom \
		mem/roms/basic10_1.rom mem/roms/basic10_2.rom mem/roms/basic10_3.rom \
		mem/roms/basic11m_0.rom mem/roms/basic11m_1.rom mem/roms/ext11m.rom \
		mem/roms/bos11m.rom mem/roms/mstd11m.rom mem/roms/smk512_v205.rom
	cd mem && python3 gen_boot_blob.py

mem/boot_blob11.hex: mem/boot_blob.hex ;

clean:
	rm -rf db/ greybox_tmp/ incremental_db/
	rm -f *.done *.map.* *.pin *.rpt *.sta.* *.qmsg

distclean: clean
	rm -f $(PROJECT).pof $(PROJECT).sof $(PROJECT).rbf $(PROJECT).rpd

flash: $(PROJECT).pof
	$(QUARTUS_PGM) -c "$(PGM_CABLE)" -m AS -o "PV;$(PROJECT).pof"

# Verify the ROM blob inside the flashable POF: convert to RPD and compare the
# hex_block page at 0x40000 against boot_blob.bin. The RPD is in RBF/LSB-first
# bit order, NOT physical-flash order: quartus_cpf bit-reverses hex_block bytes
# into it and quartus_pgm -m AS reverses again onto the chip (verified: RPD
# Page_0 equals ocbk.rbf verbatim) - so the RPD page must hold rev(blob), and
# the PHYSICAL flash then holds the blob verbatim for the loader's MSB-first
# SPI read.
blob-check: $(PROJECT).pof mem/boot_blob.hex
	$(QUARTUS_CPF) -c $(PROJECT).pof $(PROJECT).rpd
	python3 -c "import sys; \
	  rev = bytes(int(format(i,'08b')[::-1],2) for i in range(256)); \
	  rpd = open('$(PROJECT).rpd','rb').read(); \
	  ok = True; \
	  blob = open('mem/boot_blob.bin','rb').read(); \
	  ok &= rpd[0x40000:0x40000+len(blob)] == bytes(rev[b] for b in blob); \
	  blob11 = open('mem/boot_blob11.bin','rb').read(); \
	  ok &= rpd[0x48000:0x48000+len(blob11)] == bytes(rev[b] for b in blob11); \
	  sys.exit(0 if ok else 'blob-check: MISMATCH (0x40000 or 0x48000)')"
	@echo ">> blob-check: POF hex_block pages hold rev(blob) = blobs on flash"
