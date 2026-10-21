; ============================================================================
; MSX DOOM - a first-person shooter for the MSX with the V9968 + geo3d
;
; MSX MegaROM, ASCII16 mapper, 256 KB:
;   bank 0   page 1 (4000h-7FFFh), fixed: the code and the tables every
;            routine and the interrupt handler may need (sines, map, sounds)
;   bank 1   page 2 (8000h-BFFFh) by default: palettes, cell visibility,
;            the pointers to the face lists, texts
;   bank 2   the enemies' paths (2 bits per pair of cells)
;   bank 3+  the face lists of every cell (tools/gen_data.py)
;   then     8 banks: the texture area, copied to VRAM pages 2 and 3 at boot
; Ports come from out/ports.asm (build.sh): PORT_BASE 98h (openMSX: the
; V9968 is the machine's VDP) or 88h (the V9968 cartridge next to the
; internal VDP). geo3d sits at PORT_BASE + 5 (index/status) and + 7 (data).
;
; The picture: SCREEN 8 (256 x 212, 1 byte a pixel) with the V9968's
; extended palette (256 entries of 15 bits), two pages flipped in the
; vertical blank. Every frame the hidden page gets
;   1. the ceiling and the floor: 16 HMMV bands (no texture: see README)
;   2. the walls and the monsters: ONE geo3d RUN of textured faces. geo3d
;      projects, sorts far to near and sends one LRMM per row to the V9968,
;      with TIMP so texel 0 is a hole (the monsters are faces too)
;   3. the pistol, its flash and the crosshair: LMMM + TIMP from the texture
;      area; the status bar when a number changed
; What the Z80 does for the picture is in render.asm; tools/sim.py is the
; same arithmetic on the PC and tests/ compares the two pixel by pixel.
; ============================================================================

        include "out/ports.asm"         ; PORT_BASE (build.sh)
        include "out/inc/const.asm"     ; tools/gen_data.py

VDP_DATA:   equ PORT_BASE
VDP_CTRL:   equ PORT_BASE + 1
VDP_PAL:    equ PORT_BASE + 2
VDP_IND:    equ PORT_BASE + 3
VDP_P4:     equ PORT_BASE + 4
GEO_IDX:    equ PORT_BASE + 5
GEO_DAT:    equ PORT_BASE + 7

PPI_B:      equ 0xA9
PPI_C:      equ 0xAA
PSG_A:      equ 0xA0
PSG_W:      equ 0xA1
PSG_R:      equ 0xA2

ENASLT:     equ 0x0024
RSLREG:     equ 0x0138
CGTABL:     equ 0x0004
EXPTBL:     equ 0xFCC1
RG1SAV:     equ 0xF3E0
HKEYI:     equ 0xFD9A
BANK1_SEL:  equ 0x6000          ; ASCII16: bank of 4000h-7FFFh
BANK2_SEL:  equ 0x7000          ; ASCII16: bank of 8000h-BFFFh

HMMV:       equ 0xC0
HMMM:       equ 0xD0
LMMM:       equ 0x90
TIMP:       equ 0x08

; in_cur bits
IN_UP:      equ 0
IN_DOWN:    equ 1
IN_LEFT:    equ 2
IN_RIGHT:   equ 3
IN_FIRE:    equ 4
IN_SL:      equ 5               ; strafe left
IN_SR:      equ 6
IN_START:   equ 7

; ============================================================================
; bank 0
; ============================================================================
        org 0x4000
        db "AB"
        dw init
        dw 0, 0, 0
        ds 6, 0
        db "ROM_AS16"                   ; 4010h: ROM type signature (MSXgl): ASCII16
        include "src/mapper_tag_ascii16.asm"    ; never run: for mapper guessers

init:
        di
        ld sp, 0xF300
        ; page 2 -> this cartridge's slot (the slot of page 1)
        call RSLREG
        rrca
        rrca
        and 3
        ld c, a
        ld b, 0
        ld hl, EXPTBL
        add hl, bc
        ld a, (hl)
        and 0x80
        or c
        ld c, a
        inc hl
        inc hl
        inc hl
        inc hl
        ld a, (hl)
        and 0x0C
        or c
        ld h, 0x80
        call ENASLT
        di
        xor a
        ld (BANK1_SEL), a
        ld a, 1
        ld (BANK2_SEL), a
        ; clear RAM C000h-E7FFh
        ld hl, 0xC000
        ld de, 0xC001
        ld bc, 0x27FF
        ld (hl), 0
        ldir
        ld hl, 0xC900               ; NOP, RET: interrupts stay off during init
        ld (eiop), hl
        ld hl, (CGTABL)
        ld (txt_font), hl
        call psg_init
        if PORT_BASE == 0x88
        ; the internal VDP: no interrupts (its BIOS keyboard scan is not needed)
        ld a, (RG1SAV)
        and 0xDF
        out (0x99), a
        ld a, 0x81
        out (0x99), a
        in a, (0x99)
        endif
        call vdp_init
        xor a
        call pal_load
        in a, (GEO_IDX)
        cp 0xFF
        jp z, no_geo
        call tex_upload
        call geo_init
        call hud_prep
        ; the interrupt handler (H.KEYI: every interrupt, before the BIOS)
        ld a, 0xC3
        ld (HKEYI), a
        ld hl, isr
        ld (HKEYI + 1), hl
        ld hl, 0xC9FB               ; EI, RET
        ld (eiop), hl
        ld a, 0x60                  ; display on, IE0
        ld b, 1
        call wreg                   ; (interrupts on from here: eiop)

main_loop:
        call title_screen
        call game_run
        jr main_loop

; no geo3d at PORT_BASE + 5: say so and stop
no_geo:
        ld a, 0x40                  ; display on, no interrupt
        ld b, 1
        call wreg
        xor a
        ld (txt_page), a
        ld a, 3
        ld (txt_fg), a
        xor a
        ld (txt_bg), a
        ld a, 1
        ld (txt_scale), a
        ld hl, s_nogeo
        ld de, 96 * 256 + 48
        call txt_put
ng_1:   jr ng_1
s_nogeo:
        db "GEO3D NAO ENCONTRADO", 0

        include "src/vdp.asm"
        include "src/math.asm"
        include "src/isr.asm"
        include "src/render.asm"
        include "src/hud.asm"
        include "src/game.asm"
        include "src/enemy.asm"
        include "out/inc/tables.asm"

bank0_end:
        ds 0x8000 - $, 0xFF

; ============================================================================
; bank 1: data
; ============================================================================
        org 0x8000
palettes:
        incbin "out/palettes.bin"
vis_tab:
        incbin "out/vis.bin"
pvsptr:
        incbin "out/pvsptr.bin"
bank1_end:
        ds 0xC000 - $, 0xFF

; ============================================================================
; bank 2: the enemies' next step
; ============================================================================
        org 0x8000
nextstep:
        incbin "out/nextstep.bin"
bank2_end:
        ds 0xC000 - $, 0xFF

        include "out/inc/banks.asm"

; ============================================================================
; RAM (addresses only: build.sh cuts the image at the ROM size)
; ============================================================================
        include "src/ram.asm"
