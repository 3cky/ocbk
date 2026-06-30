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

.PHONY: all compile collect sim clean distclean flash

all: compile collect

# --- simulation regressions (no Quartus required) -------------------------
sim:
	./sim/bk10/run.sh
	./sim/run_cosim.sh

# --- FPGA build -----------------------------------------------------------
compile: mem/bk10_prog.hex
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

mem/bk10_prog.hex: mem/gen_mem.py
	cd mem && python3 gen_mem.py bk10_prog.hex

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
