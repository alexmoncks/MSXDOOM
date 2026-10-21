; ============================================================================
; vdp.asm - V9968 access: registers, status, VRAM address, commands, the
; init sequence, the palette and the texture upload.
;
; Interrupt rule (the handler reads S#0 at every interrupt and writes R#2):
; every two-byte control-port sequence runs with interrupts off and R#15 is
; 0 whenever they are on. `eiop` (RAM) is EI; RET once the handler is
; installed (NOP; RET during init), so these routines end with jp eiop.
; The data port, the palette port and the indirect port (R#17) are safe
; with interrupts on: the handler touches none of them.
; ============================================================================

; A = value, B = register
wreg:
        di
        out (VDP_CTRL), a
        ld a, b
        or 0x80
        out (VDP_CTRL), a
        jp eiop

; A = n -> A = S#n; R#15 back to 0
rd_status:
        di
        out (VDP_CTRL), a
        ld a, 0x8F
        out (VDP_CTRL), a
        in a, (VDP_CTRL)
        push af
        xor a
        out (VDP_CTRL), a
        ld a, 0x8F
        out (VDP_CTRL), a
        pop af
        jp eiop

; wait for the command engine (S#2 bit 0 = CE)
wait_ce:
        ld a, 2
        call rd_status
        rrca
        jr c, wait_ce
        ret

; C:HL = 18-bit VRAM address (C = A17..A16), set for writing
vaddr_w:
        di
        ld a, c
        add a, a
        add a, a
        ld b, a
        ld a, h
        rlca
        rlca
        and 3
        or b
        out (VDP_CTRL), a           ; R#14 = A17..A14
        ld a, 0x8E
        out (VDP_CTRL), a
        ld a, l
        out (VDP_CTRL), a
        ld a, h
        and 0x3F
        or 0x40
        out (VDP_CTRL), a
        jp eiop

; cmdbuf (15 bytes: SX, SY, DX, DY, NX, NY, CLR, ARG, CMD) -> R#32..R#46,
; when the engine is idle
cmd_all:
        call wait_ce
        ld a, 32
        ld b, 17
        call wreg
        ld hl, cmdbuf
        ld bc, 15 * 256 + VDP_IND
        otir
        ret

; the same without a source: cmd_dx.. -> R#36..R#46
cmd_dst:
        call wait_ce
        ld a, 36
        ld b, 17
        call wreg
        ld hl, cmd_dx
        ld bc, 11 * 256 + VDP_IND
        otir
        ret

; fill: cmd_dx, cmd_dy, cmd_nx, cmd_ny set, A = colour
fill:
        ld (cmd_clr), a
        xor a
        ld (cmd_arg), a
        ld a, HMMV
        ld (cmd_op), a
        jr cmd_dst

; ---------------------------------------------------------------- init
vdp_init:
        xor a
        out (VDP_P4), a             ; unlock R#20 / R#21 (PORT#4 bit 7 = 0)
        ld hl, init_regs
vi_1:   ld a, (hl)
        cp 0xFF
        jr z, vi_2
        ld b, a
        inc hl
        ld a, (hl)
        inc hl
        call wreg
        jr vi_1
vi_2:   ld a, 51
        ld b, 17
        call wreg
        ld hl, window_regs
        ld bc, 8 * 256 + VDP_IND
        otir                        ; R#51..58: command window = all the VRAM
        ; pages 0 and 1 black
        ld hl, 0
        ld (cmd_dx), hl
        ld (cmd_dy), hl
        ld hl, 256
        ld (cmd_nx), hl
        ld hl, 512
        ld (cmd_ny), hl
        xor a
        call fill
        jp wait_ce

init_regs:
        db 0, 0x0E                  ; GRAPHIC7 (SCREEN 8)
        db 1, 0x00                  ; display off while loading
        db 2, 0x1F                  ; page 0
        db 7, 0x00                  ; border: palette entry 0
        db 8, 0x0A                  ; sprites off
        db 9, 0x80                  ; 212 lines
        db 14, 0x00
        db 15, 0x00
        db 16, 0x00
        db 23, 0x00
        db 25, 0x00
        db 26, 0x00
        db 27, 0x00
        db 21, 0x00                 ; V9968 mode: LRMM, 256 KB
        db 20, 0x11                 ; high-speed commands, extended palette (EPAL)
        db 0xFF

window_regs:
        db 0, 0, 0, 0, 0xFF, 0x01, 0xFF, 0x07

; A = palette (0 normal, 1 hurt, 2 pickup, 3 muzzle flash): 256 entries of
; R, G, B (5 bits each) from bank 1
pal_load:
        ld (pal_cur), a
        ld hl, palettes
        or a
        jr z, pl_2
        ld de, 768
pl_1:   add hl, de
        dec a
        jr nz, pl_1
pl_2:   push hl
        xor a
        ld b, 16
        call wreg                   ; R#16 = 0: the first entry
        pop hl
        ld bc, VDP_PAL              ; B = 0: 256 bytes
        otir
        otir
        otir
        ret

; the texture area (TEX_BANKS banks) -> VRAM 20000h-3FFFFh (rows 512..1023)
tex_upload:
        ld a, TEX_BANK0
tu_1:   push af
        ld (BANK2_SEL), a
        add a, 8 - TEX_BANK0        ; R#14 = 8 + block: 16 KB blocks from 20000h
        di
        out (VDP_CTRL), a
        ld a, 0x8E
        out (VDP_CTRL), a
        xor a
        out (VDP_CTRL), a
        ld a, 0x40
        out (VDP_CTRL), a
        call eiop
        ld hl, 0x8000
        ld c, VDP_DATA
        ld d, 64
tu_2:   ld b, 0
        otir
        dec d
        jr nz, tu_2
        pop af
        inc a
        cp TEX_BANK0 + TEX_BANKS
        jr nz, tu_1
        ld a, 1
        ld (BANK2_SEL), a
        ret
