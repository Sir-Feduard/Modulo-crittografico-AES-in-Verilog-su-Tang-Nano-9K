# ------------------------------------------------------------------------------
# Toolchain software RISC-V
# ------------------------------------------------------------------------------
CROSS   := riscv64-unknown-elf
CC      := $(CROSS)-gcc
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump

CFLAGS  := -march=rv32i -mabi=ilp32 -O1 -g -Wall -nostdlib -nostartfiles
LDFLAGS := -T sw/link.ld -Wl,--gc-sections --specs=picolibc.specs
LIBS    := -lc -lm -lgcc

SW_SRCS := sw/start.S sw/syscalls.c sw/main.c
ELF     := sw/program.elf
BIN     := sw/program.bin
HEX     := sw/program.hex
LST     := sw/program.lst

# ------------------------------------------------------------------------------
# Toolchain FPGA (Gowin GW1NR-9 / Tang Nano 9K)
# ------------------------------------------------------------------------------
TOP    := fpga/top
DEVICE := GW1NR-LV9QN88PC6/I5
FAMILY := GW1N-9C

HW_SRCS := \
    hw/top.v        \
    hw/uart_tx.v    \
    hw/picorv32.v   \
    hw/my_pcpi.v    \
    hw/bootloader.v

# ------------------------------------------------------------------------------
# Simulazione
# ------------------------------------------------------------------------------
SIM_SRCS := hw/picorv32.v hw/my_pcpi.v hw/tb.v
SIM_BIN  := hw/sim
VCD      := hw/sim.vcd

.PHONY: all build sim fpga firmware program programf wave clean info

# Default: elenca i target disponibili
all:
	@echo "Target disponibili:"
	@echo "  make build    — compila il software, produce ELF, BIN e HEX"
	@echo "  make sim      — lancia la simulazione Icarus (richiede build)"
	@echo "  make fpga     — sintetizza per Tang Nano 9K"
	@echo "  make firmware — carica program.bin in flash esterna (richiede build)"
	@echo "  make program  — programma la FPGA in SRAM (richiede fpga)"
	@echo "  make programf — programma la FPGA in flash esterna (richiede fpga)"
	@echo "  make wave     — apre GTKWave sul .vcd"
	@echo "  make clean    — rimuove tutti i file generati"
	@echo "  make info     — verifica gli strumenti installati"

# ------------------------------------------------------------------------------
# Build software: sorgenti C/ASM → ELF → BIN + HEX
# ------------------------------------------------------------------------------
$(ELF): $(SW_SRCS) sw/link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SW_SRCS) $(LIBS)
	$(OBJDUMP) -d -S $@ > $(LST)

$(HEX): $(ELF)
	$(OBJCOPY) -O binary $< $(BIN)
	od -An -tx4 -v $(BIN) | awk '{for(i=1;i<=NF;i++) print $$i}' > $@

build: $(HEX)

# ------------------------------------------------------------------------------
# Simulazione con Icarus Verilog
# ------------------------------------------------------------------------------
sim: $(HEX) $(SIM_SRCS)
	iverilog -g2012 -o $(SIM_BIN) $(SIM_SRCS)
	cd hw && vvp sim

# ------------------------------------------------------------------------------
# Sintesi FPGA: yosys → nextpnr → gowin_pack
# ------------------------------------------------------------------------------
$(TOP).json: $(HW_SRCS)
	yosys -p "synth_gowin -top top -json $(TOP).json" $(HW_SRCS)

$(TOP).pack: $(TOP).json
	/usr/local/bin/nextpnr-himbaechel \
		--device $(DEVICE) \
		--vopt family=$(FAMILY) \
		--vopt cst=fpga/tang9k.cst \
		--json $(TOP).json \
		--write $(TOP).pack

$(TOP).fs: $(TOP).pack
	~/.local/bin/gowin_pack -d $(FAMILY) --mspi_as_gpio -o $(TOP).fs $(TOP).pack

fpga: $(TOP).fs

# ------------------------------------------------------------------------------
# Caricamento firmware (solo il binario software) in flash esterna
# ------------------------------------------------------------------------------
firmware: build
	openFPGALoader -b tangnano9k --external-flash -o 0x100000 $(BIN)

# Programmazione SRAM (volatile, si perde al riavvio)
program: fpga
	openFPGALoader -b tangnano9k $(TOP).fs

# Programmazione flash esterna (persistente)
programf: fpga
	openFPGALoader -b tangnano9k --external-flash $(TOP).fs

wave:
	gtkwave $(VCD) &

# ------------------------------------------------------------------------------
# Pulizia
# ------------------------------------------------------------------------------
clean:
	rm -f $(ELF) $(BIN) $(HEX) $(LST) $(SIM_BIN) $(VCD)
	rm -f $(TOP).json $(TOP).pack $(TOP).fs

# ------------------------------------------------------------------------------
# Verifica strumenti installati
# ------------------------------------------------------------------------------
info:
	@which $(CC)                               > /dev/null 2>&1 && echo "GCC RISC-V:     OK" || echo "GCC RISC-V:     NON trovato"
	@which iverilog                            > /dev/null 2>&1 && echo "Icarus:         OK" || echo "Icarus:         NON trovato"
	@which gtkwave                             > /dev/null 2>&1 && echo "GTKWave:        OK" || echo "GTKWave:        NON trovato"
	@which yosys                               > /dev/null 2>&1 && echo "Yosys:          OK" || echo "Yosys:          NON trovato"
	@which openFPGALoader                      > /dev/null 2>&1 && echo "openFPGALoader: OK" || echo "openFPGALoader: NON trovato"
	@test -x /usr/local/bin/nextpnr-himbaechel > /dev/null 2>&1 && echo "nextpnr:        OK" || echo "nextpnr:        NON trovato"
	@test -x ~/.local/bin/gowin_pack           > /dev/null 2>&1 && echo "gowin_pack:     OK" || echo "gowin_pack:     NON trovato"
	@dpkg -l picolibc-riscv64-unknown-elf 2>/dev/null | grep -q "^ii" && echo "picolibc:       OK" || echo "picolibc:       NON trovato"
