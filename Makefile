PROJECT  := ocbk
PARKING  := fw

QUARTUS_HOME ?= /opt/altera/11.0/quartus
QUARTUS_BIN  := $(QUARTUS_HOME)/bin

QUARTUS_MAP  := $(QUARTUS_BIN)/quartus_map
QUARTUS_FIT  := $(QUARTUS_BIN)/quartus_fit
QUARTUS_ASM  := $(QUARTUS_BIN)/quartus_asm
QUARTUS_STA  := $(QUARTUS_BIN)/quartus_sta
QUARTUS_CPF  := $(QUARTUS_BIN)/quartus_cpf

QUARTUS_PGM  := $(QUARTUS_BIN)/quartus_pgm
PGM_CABLE    := USB-Blaster

.PHONY: all compile collect sim clean distclean flash blob-check

all: compile collect

# --- simulation regressions (no Quartus required) -------------------------
sim:
	./sim/run_clkgen.sh
	./sim/run_mapper.sh
	./sim/bk10/run.sh
	./sim/bk11/run.sh
	./sim/ref037/run.sh
	./sim/ref014/run.sh
	./sim/run_ps2.sh
	./sim/run_audio.sh
	./sim/run_sdram_arbiter.sh
	./sim/run_sdram_cosim.sh
	./sim/run_video.sh
	./sim/run_epcs_boot.sh

# --- FPGA build -----------------------------------------------------------
compile: mem/ram_test.hex mem/boot_blob.hex
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
	mv -f $(PROJECT).pof recovery.pof

mem/ram_test.hex: mem/gen_mem.py
	cd mem && python3 gen_mem.py ram_test.hex

# Phase-5 EPCS boot blob (BK-0010.01 MONITOR + BASIC Vilnius), appended to the
# POF as an ocbk.cof hex_block page at flash offset 0x40000.
mem/boot_blob.hex: mem/gen_boot_blob.py mem/roms/monit10.rom \
		mem/roms/basic10_1.rom mem/roms/basic10_2.rom mem/roms/basic10_3.rom
	cd mem && python3 gen_boot_blob.py

collect:
	mkdir -p $(PARKING)
	-mv -f recovery.pof $(PARKING)/
	-cp $(PROJECT).fit.summary $(PARKING)/fit_summary.log
	@echo ">> Done! Firmware in $(PARKING)/"

clean:
	rm -rf db/ greybox_tmp/ incremental_db/
	rm -f *.done *.map.* *.pin *.rpt *.sta.* *.qmsg

distclean: clean
	rm -f $(PROJECT).pof $(PROJECT).sof $(PROJECT).rbf recovery.pof
	rm -rf $(PARKING)/

flash: $(PARKING)/recovery.pof
	$(QUARTUS_PGM) -c "$(PGM_CABLE)" -m AS -o "PV;$(PARKING)/recovery.pof"

# Verify the ROM blob inside the flashable POF: convert to RPD and compare the
# hex_block page at 0x40000 against boot_blob.bin. The RPD is in RBF/LSB-first
# bit order, NOT physical-flash order: quartus_cpf bit-reverses hex_block bytes
# into it and quartus_pgm -m AS reverses again onto the chip (verified: RPD
# Page_0 equals ocbk.rbf verbatim) - so the RPD page must hold rev(blob), and
# the PHYSICAL flash then holds the blob verbatim for the loader's MSB-first
# SPI read.
blob-check: $(PARKING)/recovery.pof mem/boot_blob.hex
	$(QUARTUS_CPF) -c $(PARKING)/recovery.pof $(PARKING)/recovery.rpd
	python3 -c "import sys; \
	  rev = bytes(int(format(i,'08b')[::-1],2) for i in range(256)); \
	  rpd = open('$(PARKING)/recovery.rpd','rb').read(); \
	  blob = open('mem/boot_blob.bin','rb').read(); \
	  got = rpd[0x40000:0x40000+len(blob)]; \
	  sys.exit(0 if got == bytes(rev[b] for b in blob) \
	           else 'blob-check: MISMATCH at 0x40000')"
	@echo ">> blob-check: POF hex_block page holds rev(blob) = blob on flash"
