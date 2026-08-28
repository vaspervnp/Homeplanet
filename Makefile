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

# All eight classes of Homeplanet.md section 8. Two of them (interceptor,
# frigate) live in bank 4 and travel inside DISC.BIN; the other six are banks
# 5-7 and go on the DISC as raw sectors, because DISC.BIN has about 2 KB of
# headroom under AMSDOS's workspace and one packed library is nearly 4.
# Which bank a class is in is decided in src/main.asm; this list only says
# which projects get converted.
SHIP_CLASSES := interceptor frigate mothership harvester scout bomber \
                salvage destroyer
SPRITES := $(patsubst %,$(GEN_DIR)/spr_%.asm,$(SHIP_CLASSES))

MAIN   := $(SRC_DIR)/main.asm
DISC   := $(SRC_DIR)/disc.asm
TABLES := $(GEN_DIR)/tables.asm $(GEN_DIR)/zoom.asm

# The two standalone music programs. They are NOT part of the game: each is a
# whole piece plus a copy of the player, assembled on its own and dropped on
# the disc as MUSIC1.BIN / MUSIC2.BIN. That is the order tools/genmusic.py and
# src/musicplay.asm were built in on purpose -- a player with no game around
# it proves the converter and the AY writes before either has to share a
# machine with a battle.
MUSIC_TUNES := tranquility morninglight
MUSIC_GEN   := $(patsubst %,$(GEN_DIR)/mus_full_%.asm,$(MUSIC_TUNES)) \
               $(patsubst %,$(GEN_DIR)/mus_loop_%.asm,$(MUSIC_TUNES))
MUSIC_BIN   := $(BUILD_DIR)/music1.bin $(BUILD_DIR)/music2.bin

DSK      := $(BUILD_DIR)/homeplanet.dsk
GAME_RAW := $(BUILD_DIR)/home.raw
SPRITE_RAW := $(BUILD_DIR)/sprites.raw
SPRITE_RLE := $(BUILD_DIR)/sprites.rle
DISC_RAW := $(BUILD_DIR)/disc.raw
SYM      := $(BUILD_DIR)/homeplanet.sym
DISC_SYM := $(BUILD_DIR)/disc.sym

# The three extended banks lib_load reads off the disc at boot. They are NOT
# part of DISC.BIN -- see src/sys/libload.asm.
LIB_RAW  := $(BUILD_DIR)/bank5.raw $(BUILD_DIR)/bank6.raw $(BUILD_DIR)/bank7.raw
BANKED   := $(BUILD_DIR)/.banks-written

# -I src -I .  include paths: src/ for sources, . so disc.asm can INCBIN build/
# -eo          overwrite files already present in the .dsk
# -s -sa -ec   export every symbol for the tests (RASM upper-cases them anyway)
RASMFLAGS := -I $(SRC_DIR) -I . -eo

ASM_SOURCES := $(shell find $(SRC_DIR) -name '*.asm' -not -path '$(GEN_DIR)/*')

.PHONY: all tables ships music test run clean dsk-list

all: $(BANKED)

# Two stages, and the order matters: disc.asm INCBINs the game blob, so the
# game has to exist first. See src/disc.asm for why the game cannot simply be
# loaded at #0040 and run.
#
# rasmoutput.cpr is a side effect of the BANK directive -- RASM writes a
# cartridge whenever a source uses banks, and there is no flag to say no.
# Nothing reads it.
$(GAME_RAW) $(SPRITE_RAW) $(LIB_RAW) $(SYM) &: $(ASM_SOURCES) $(TABLES) $(SPRITES) | $(BUILD_DIR)
	$(RASM) $(MAIN) $(RASMFLAGS) -s -sa -ec -os $(SYM)
	rm -f rasmoutput.cpr

# Packing the library is what keeps DISC.BIN under AMSDOS's workspace;
# tools/packsprites.py explains the format.
$(SPRITE_RLE): $(SPRITE_RAW) tools/packsprites.py
	$(PYTHON) tools/packsprites.py $(SPRITE_RAW) $(SPRITE_RLE)

# The rm is not tidiness. RASM's -eo writes the file INTO an existing .dsk,
# and DISC.BIN grows with every feature -- overwriting in place left the image
# holding a mixture of builds, so `boot_disc` and anyone running the real disc
# got code that no longer matched build/disc.raw or the symbol file. It shows
# up as data three bytes out of place and nothing in the source to explain it.
# Always mint a fresh image.
$(DISC_RAW) $(DSK) $(DISC_SYM) &: $(GAME_RAW) $(SPRITE_RLE) $(DISC)
	rm -f $(DSK)
	$(RASM) $(DISC) $(RASMFLAGS) -s -sa -ec -os $(DISC_SYM)

# ...and then the three sprite banks go on as raw sectors, after AMSDOS has
# laid DISC.BIN down. This step must come last and must be redone every time
# the .dsk is minted -- the `rm -f` above throws the previous copy away with
# everything else on the image. The stamp file is what makes that a make
# dependency rather than a thing to remember.
# The splash screen and its loader. HOME.BAS is ASCII so BASIC can RUN it
# straight off the disc without tokenising; the .scr is a headerless Mode 0
# screen and needs its load address given explicitly, or AMSDOS has no way to
# know where 16K of pixels belongs. The palette lives in assets/revive8b.txt
# and is written out as INK statements inside HOME.BAS.
SPLASH_SCR := assets/revive8b.scr
SPLASH_BAS := assets/home.bas

$(BANKED): $(DSK) $(LIB_RAW) $(SYM) tools/discbanks.py $(SPLASH_SCR) $(SPLASH_BAS) $(MUSIC_BIN)
	$(PYTHON) tools/discbanks.py $(DSK) $(SYM) $(LIB_RAW)
	$(IDSK) $(DSK) -i $(SPLASH_BAS) -t 0
	$(IDSK) $(DSK) -i $(SPLASH_SCR) -c C000 -e C000 -t 1
	$(IDSK) $(DSK) -i $(BUILD_DIR)/music1.bin -c 4000 -e 4000 -t 1
	$(IDSK) $(DSK) -i $(BUILD_DIR)/music2.bin -c 4000 -e 4000 -t 1
	touch $@

# The note streams. Analysing four and a half minutes of ogg takes about half
# a minute, so this is a real dependency on the source audio rather than
# something rerun every build.
$(MUSIC_GEN) &: tools/genmusic.py musicsamples/Tranquility.ogg musicsamples/MorningLight.ogg
	$(PYTHON) tools/genmusic.py

music:
	$(PYTHON) tools/genmusic.py

$(BUILD_DIR)/music%.bin: $(SRC_DIR)/music%.asm $(SRC_DIR)/musicplay.asm $(MUSIC_GEN) | $(BUILD_DIR)
	$(RASM) $< -I $(SRC_DIR) -I . -o $(basename $@)

$(GEN_DIR)/tables.asm $(GEN_DIR)/zoom.asm &: tools/gentables.py
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

test: $(BANKED)
	$(PYTHON) -m tests.run

run: $(BANKED)
	$(PYTHON) tools/run.py

# What AMSDOS actually sees on the disc.
dsk-list: $(DSK)
	$(IDSK) $(DSK) -l

clean:
	rm -rf $(BUILD_DIR) $(GEN_DIR) rasmoutput.cpr

#  A recorded round, straight out of the emulator through ffmpeg. Boots from
#  the .dsk like a user would, so it exercises the real loader.
demo: all
	python3 tools/record.py build/homeplanet-demo.mp4
.PHONY: demo
