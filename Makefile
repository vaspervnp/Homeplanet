# ============================================================================
#  HOMEPLANET -- Amstrad CPC 6128
# ============================================================================
#  make          assemble -> build/homeplanet.dsk + build/home.bin
#  make tables   regenerate the lookup tables
#  make test     assemble, then run the emulator test suite
#  make run      assemble and screenshot the running game
#  make clean
# ----------------------------------------------------------------------------

RASM    := rasm
IDSK    := iDSK
PYTHON  := python3

SRC_DIR   := src
GEN_DIR   := $(SRC_DIR)/gen
BUILD_DIR := build

MAIN   := $(SRC_DIR)/main.asm
DISC   := $(SRC_DIR)/disc.asm
TABLES := $(GEN_DIR)/tables.asm

DSK      := $(BUILD_DIR)/homeplanet.dsk
GAME_RAW := $(BUILD_DIR)/home.raw
DISC_RAW := $(BUILD_DIR)/disc.raw
SYM      := $(BUILD_DIR)/homeplanet.sym

# -I src -I .  include paths: src/ for sources, . so disc.asm can INCBIN build/
# -eo          overwrite files already present in the .dsk
# -s -sa -ec   export every symbol for the tests (RASM upper-cases them anyway)
RASMFLAGS := -I $(SRC_DIR) -I . -eo

ASM_SOURCES := $(shell find $(SRC_DIR) -name '*.asm' -not -path '$(GEN_DIR)/*')

.PHONY: all tables test run clean dsk-list

all: $(DISC_RAW)

# Two stages, and the order matters: disc.asm INCBINs the game blob, so the
# game has to exist first. See src/disc.asm for why the game cannot simply be
# loaded at #0040 and run.
$(GAME_RAW) $(SYM): $(ASM_SOURCES) $(TABLES) | $(BUILD_DIR)
	$(RASM) $(MAIN) $(RASMFLAGS) -s -sa -ec -os $(SYM)

$(DISC_RAW) $(DSK): $(GAME_RAW) $(DISC)
	$(RASM) $(DISC) $(RASMFLAGS)

$(TABLES): tools/gentables.py
	$(PYTHON) tools/gentables.py

tables:
	$(PYTHON) tools/gentables.py

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

test: $(DISC_RAW)
	$(PYTHON) -m tests.run

run: $(DISC_RAW)
	$(PYTHON) tools/run.py

# What AMSDOS actually sees on the disc.
dsk-list: $(DSK)
	$(IDSK) $(DSK) -l

clean:
	rm -rf $(BUILD_DIR) $(GEN_DIR)
