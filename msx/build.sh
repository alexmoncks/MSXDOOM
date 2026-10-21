#!/bin/bash
# build.sh - builds the MSX DOOM cartridge (WSL / Linux: z80asm 1.8, python3)
#   out/MSXDOOM_98.ROM  V9968 at 98h (openMSX V9968 fork: -machine ... -ext geo3d)
#   out/MSXDOOM_88.ROM  V9968 cartridge at 88h next to the internal VDP (real hardware)
# 256 KB ASCII16 MegaROMs. The data comes from tools/gen_data.py (run when
# out/inc is missing or older than the tools, the map or the art, or with
# --data). Also writes out/labels_98.txt (z80asm label list, read by the
# tests) and prints the free space of bank 0 and the RAM use.
set -e
cd "$(dirname "$0")"
mkdir -p out/inc
ref=out/inc/tables.asm
if [ "$1" = --data ] || [ ! -f $ref ] || [ ! -f out/tex.bin ] || \
   [ -n "$(find tools -name '*.py' -newer $ref)" ] || [ ../js/game.js -nt $ref ] || \
   [ -n "$(find ../assets/msx \( -name '*.idx' -o -name '*.pal' \) -newer $ref)" ]; then
  (cd tools && python3 gen_data.py)
fi
# z80asm 1.8 reads a name that starts with a register and "_" as that register
# in an 8-bit operand ("ld a, E_SIZE" = "ld a, e"): no such names here
if grep -n -E "^[^;]*[ ,(]([ABCDEHLIRabcdehlir]|[Ii][XYxy]|[Ss][Pp])_[A-Za-z0-9_]*" src/*.asm | grep -v -E "^\S+:\s*;" ; then
  echo "a name starting with a register and '_' is read as the register: rename it"; exit 1
fi
# ... and after call / jp / jr, a name that starts with a condition and "_"
# ("call nc_vtx" = "call nc, _vtx")
if grep -n -i -E "^[^;]*(call|jp|jr) +(nz|z|nc|c|po|pe|p|m)_" src/*.asm; then
  echo "a jump target starting with a condition and '_' is read as the condition: rename it"; exit 1
fi
banks=$(grep "^ROM_BANKS:" out/inc/const.asm | sed 's/.*equ //')
for p in 98 88; do
  echo "PORT_BASE: equ 0x$p" > out/ports.asm
  if ! z80asm -o out/msxdoom_$p.bin -L src/main.asm 2> out/labels_$p.txt; then
    grep -v "^[A-Za-z_0-9]*:	equ" out/labels_$p.txt | head -40
    exit 1
  fi
  head -c $((banks * 16384)) out/msxdoom_$p.bin > out/MSXDOOM_$p.ROM
  size=$(stat -c %s out/MSXDOOM_$p.ROM)
  [ "$size" = $((banks * 16384)) ] || { echo "ROM size $size, expected $((banks * 16384))"; exit 1; }
  rm -f out/msxdoom_$p.bin
done
lab() { grep "^$1:" out/labels_98.txt | head -1 | sed 's/.*\$//'; }
printf 'bank 0 code: %d bytes free, bank 1 data: %d bytes free, bank 2: %d bytes free\n' \
  $((0x8000 - 0x$(lab bank0_end))) $((0xC000 - 0x$(lab bank1_end))) $((0xC000 - 0x$(lab bank2_end)))
printf 'RAM C000h-%sh (%d bytes); the init clears C000h-E7FFh\n' "$(lab ram_end)" $((0x$(lab ram_end) - 0xC000))
[ $((0x$(lab ram_end))) -le $((0xE800)) ] || { echo "RAM map too big"; exit 1; }
mkdir -p release
cp out/MSXDOOM_98.ROM out/MSXDOOM_88.ROM release/
ls -l release/MSXDOOM_98.ROM release/MSXDOOM_88.ROM
