# ============================================================================
#  HOMEPLANET -- Amstrad CPC 6128
# ============================================================================
#  make          assemble -> build/homeplanet.dsk + build/home.bin
#  make tables   regenerate the lookup tables
#  make ships    re-render the ship sprites + contact sheets
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

# Sprite data the game links in. Adding a class here will overflow the low
# 16K until something pages the #4000 bank window.
SHIP_CLASSES := interceptor
SPRITES := $(patsubst %,$(GEN_DIR)/spr_%.asm,$(SHIP_CLASSES))

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

.PHONY: all tables ships test run clean dsk-list

all: $(DISC_RAW)

# Two stages, and the order matters: disc.asm INCBINs the game blob, so the
# game has to exist first. See src/disc.asm for why the game cannot simply be
# loaded at #0040 and run.
$(GAME_RAW) $(SYM): $(ASM_SOURCES) $(TABLES) $(SPRITES) | $(BUILD_DIR)
	$(RASM) $(MAIN) $(RASMFLAGS) -s -sa -ec -os $(SYM)

$(DISC_RAW) $(DSK): $(GAME_RAW) $(DISC)
	$(RASM) $(DISC) $(RASMFLAGS)

$(TABLES): tools/gentables.py
	$(PYTHON) tools/gentables.py

tables:
	$(PYTHON) tools/gentables.py

# art/*.retrotools.json is checked-in source; src/gen/spr_*.asm is derived from
# it and is not. Converting is cheap and pure, so it IS part of every build --
# unlike `make ships`, which re-renders the 3D models.
$(GEN_DIR)/spr_%.asm: art/%.retrotools.json tools/rt2sprite.py
	$(PYTHON) tools/rt2sprite.py $< --out $@

# Ship sprites. Not part of `all`: the projects in art/ are checked in, and
# re-rendering them is something you do when you have changed a model, not
# every build. Look at build/ships/*.png afterwards -- the 8x6 tier is the one
# that decides whether a class reads, and no test can tell you that.
ships:
	$(PYTHON) tools/mkships.py --contact-sheet
	$(PYTHON) tools/mkships.py --faction enemy --contact-sheet

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
