# Modulo-crittografico-AES-in-Verilog-su-Tang-Nano-9K


Progetto per l'implementazione di un modulo hardware per la cifratura AES per soft-core RISC-V su FPGA Gowin tang nano 9k, utilizzando una toolchain completamente open-source (Yosys + nextpnr + openFPGALoader) su sistema Ubuntu 25.10.

---

## Indice

- [Requisiti](#requisiti)
- [Dipendenze e Installazione](#dipendenze-e-installazione)
- [Struttura del Progetto](#struttura-del-progetto)
- [Modifiche Hardware](#modifiche-hardware)
- [Utilizzo](#utilizzo)
  

---

## Requisiti

- Ubuntu 22.04 o superiore
- Python 3.10+
- CMake 3.20+
- Git
- Scheda FPGA Gowin tang nano 9k

---

## Dipendenze e Installazione

### 1. Toolchain FPGA (Yosys + openFPGALoader)

Strumenti per la sintesi RTL e la programmazione del bitstream.

```bash
sudo apt install yosys openfpgaloader
```

| Strumento | Ruolo |
|---|---|
| `yosys` | Sintesi RTL (Verilog → netlist) |
| `openfpgaloader` | Programmazione dell'FPGA via USB |

---

### 2. Cross-Compiler RISC-V

Toolchain GCC bare-metal con target `riscv64-unknown-elf`.

```bash
sudo apt install gcc-riscv64-unknown-elf
```

---

### 3. Picolibc (libreria C per bare-metal)

Libreria C leggera per target RISC-V embedded.

```bash
sudo apt install picolibc-riscv64-unknown-elf
```

---

### 4. Strumenti di Simulazione

Simulatore Verilog e visualizzatore di forme d'onda.

```bash
sudo apt install iverilog gtkwave
```

| Strumento | Ruolo |
|---|---|
| `iverilog` | Simulazione Verilog/SystemVerilog |
| `gtkwave` | Visualizzatore di forme d'onda (VCD/FST) |

---

### 5. Apicula (supporto dispositivi Gowin)

Libreria Python che fornisce il database dei dispositivi Gowin per nextpnr.

```bash
pip3 install apycula --break-system-packages
```

---

### 6. nextpnr (Place & Route per Gowin)

nextpnr va compilato dai sorgenti con il backend Himbaechel e il supporto per l'architettura Gowin, è necessario per la riuscita della compilazione aver completato il punto 5.

```bash
# Clona il repository
git clone --recursive https://github.com/YosysHQ/nextpnr.git --branch main
cd nextpnr/

# Configurazione
cmake -B build \
  -DARCH=himbaechel \
  -DHIMBAECHEL_UARCH=gowin \
  -DCMAKE_BUILD_TYPE=Release \
  -DPython3_EXECUTABLE=$(which python3)

# Compilazione (utilizza tutti i core disponibili)
cmake --build build -j$(nproc)

# Installazione di sistema
sudo cmake --install build
```


## Struttura del Progetto

```
.
├── hw/              # Sorgenti Verilog/SystemVerilog e testbench con il suo output
├── sw/              # Firmware RISC-V (C) e file compilati            
├── fpga/            # File di vincoli pin (.cst) e output sintesi
├── Makefile         # Script di compilazione, sintesi, simulazione e flash
└── README.md
```
## Modifiche hardware
Il progetto è stato sviluppato sfruttando la flash esterna  puya della tang nano 9k per salvare sia il bitstream che il firmware. Per fare leggere al chip gw il bitstream da flash esterna al boot è necessario portare il pin MODE1(87) alto. Per fare ciò è sufficiente rimuovere la resistenza R17 da 4.7K ohm collegata a ground, non è necessario sostituirla dato che sul pin è presente un pull-up interno.
## Utilizzo

Tutte le funzionalità vengono gestite tramite Makefile, lanciando il comando make vengono visualizzate tutti i target di compilazione, simulazione, sintesi e flash.

```bash
#Stampa tutte le opzioni con relativa spiegazione
make
```
