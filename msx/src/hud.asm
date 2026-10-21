; ============================================================================
; hud.asm - text, the status bar, the title and the end screens
;
; Text is written straight into VRAM (1 byte a pixel) from the MSX's own
; 8 x 8 font (CGTABL), each dot 1 or 2 pixels wide and high (txt_scale), in
; txt_fg on txt_bg, on page txt_page. That takes about 0.2 ms a character,
; too slow for the game loop, so the status bar's digits and messages are
; drawn once (hud_prep) in the rows of page 0 that are never shown (212 up)
; and copied from there by the V9968 (HMMM) when a number changes:
;   rows 212..227  "0123456789% " 16 x 16, red
;   rows 228..235  "0123456789" 8 x 8, grey
;   rows 236..251  the four messages, 80 x 8 each
; Boxes are HMMV fills. Nothing here may run while geo3d is drawing.
; The status bar is rows 180..211 of both pages: hud_full marks the pages
; that still need all of it; hud_dirty has the fields (HF_*) that are old,
; page 0's in the low nibble and page 1's in the high one.
; ============================================================================

HF_HP:      equ 1
HF_KILLS:   equ 2
HF_MSG:     equ 4

; HL -> text (0 ends), E = x, D = y
txt_put:
        ld (tx_str), hl
        ld (tx_xy), de
        xor a
        ld (tx_row), a
tp_row: ld a, (txt_scale)
        ld b, a
tp_rep: push bc
        ld a, (txt_page)
        ld c, a
        ld hl, (tx_xy)
        call vaddr_w
        ld hl, (tx_str)
tp_ch:  ld a, (hl)
        or a
        jr z, tp_eol
        inc hl
        push hl
        ld l, a
        ld h, 0
        add hl, hl
        add hl, hl
        add hl, hl
        ld de, (txt_font)
        add hl, de
        ld a, (tx_row)
        ld e, a
        ld d, 0
        add hl, de
        ld d, (hl)                  ; the glyph's row
        ld hl, (txt_fg)             ; L = ink, H = paper
        ld b, 8
        ld a, (txt_scale)
        dec a
        jr nz, tp_w
tp_n:   rlc d
        ld a, h
        jr nc, tp_n1
        ld a, l
tp_n1:  out (VDP_DATA), a
        djnz tp_n
        jr tp_cn
tp_w:   rlc d
        ld a, h
        jr nc, tp_w1
        ld a, l
tp_w1:  out (VDP_DATA), a
        out (VDP_DATA), a
        djnz tp_w
tp_cn:  pop hl
        jr tp_ch
tp_eol: pop bc
        ld hl, tx_xy + 1
        inc (hl)
        djnz tp_rep
        ld hl, tx_row
        inc (hl)
        ld a, (hl)
        cp 8
        jr nz, tp_row
        ret

; HL -> db x, y, colour, scale, text, 0 -> HL after it
txt_at: ld e, (hl)
        inc hl
        ld d, (hl)
        inc hl
        ld a, (hl)
        inc hl
        ld (txt_fg), a
        ld a, (hl)
        inc hl
        ld (txt_scale), a
        push hl
        call txt_put
        pop hl
ta_1:   ld a, (hl)
        inc hl
        or a
        jr nz, ta_1
        ret

; HL -> B texts for txt_at
txt_list:
        push bc
        call txt_at
        pop bc
        djnz txt_list
        ret

; HL -> db x, y, dw width, db height, colour: a filled box on txt_page
; -> HL after it
box:    ld a, (hl)
        inc hl
        ld (cmd_dx), a
        xor a
        ld (cmd_dx + 1), a
        ld a, (hl)
        inc hl
        ld (cmd_dy), a
        ld a, (txt_page)
        ld (cmd_dy + 1), a
        ld a, (hl)
        inc hl
        ld (cmd_nx), a
        ld a, (hl)
        inc hl
        ld (cmd_nx + 1), a
        ld a, (hl)
        inc hl
        ld (cmd_ny), a
        xor a
        ld (cmd_ny + 1), a
        ld a, (hl)
        inc hl
        push hl
        call fill
        pop hl
        ret

; HL -> B boxes
box_list:
        push bc
        call box
        pop bc
        djnz box_list
        ret

; A -> numbuf: 3 characters, leading zeros as spaces, then 0
num3:   ld hl, numbuf
        ld c, 0
        ld b, 100
        call nm_dig
        ld b, 10
        call nm_dig
        add a, '0'
        ld (hl), a
        inc hl
        ld (hl), 0
        ret
nm_dig: ld d, '0' - 1
nm_1:   inc d
        sub b
        jr nc, nm_1
        add a, b
        ld e, a
        ld a, d
        cp '0'
        jr nz, nm_2
        ld a, c
        or a
        ld a, ' '
        jr z, nm_3
        ld a, '0'
        jr nm_3
nm_2:   ld c, 1
nm_3:   ld (hl), a
        inc hl
        ld a, e
        ret

; ---------------------------------------------------------------- status bar
; the digits and the messages, once, in the hidden rows of page 0
hud_prep:
        xor a
        ld (txt_page), a
        ld a, 1
        ld (txt_bg), a
        ld hl, prep_texts
        ld b, 6
        jp txt_list
prep_texts:
        db 0, 212, 3, 2
        db "0123456789% ", 0
        db 0, 228, 5, 1
        db "0123456789", 0
        db 0, 236, 4, 1
        db "MSX DOOM  ", 0
        db 80, 236, 4, 1
        db "ABATIDO!  ", 0
        db 160, 236, 4, 1
        db "+25 VIDA  ", 0
        db 0, 244, 4, 1
        db "AREA LIMPA", 0
msg_src:                            ; where each message is: x, y
        db 0, 236, 80, 236, 160, 236, 0, 244

; A = fields (HF_*): they are old on both pages
hud_mark:
        ld b, a
        rlca
        rlca
        rlca
        rlca
        or b
        ld hl, hud_dirty
        or (hl)
        ld (hl), a
        ret

hud_update:
        ld a, (msg_t)
        or a
        jr nz, hu_1
        ld a, (msg_id)
        or a
        jr z, hu_1
        cp 3
        jr z, hu_1                  ; the last message stays
        xor a
        ld (msg_id), a
        ld a, HF_MSG
        call hud_mark
hu_1:   ld a, (buf)
        ld (txt_page), a
        or a
        jr nz, hu_p1
        ld a, (hud_dirty)
        ld c, a
        and 0xF0
        ld (hud_dirty), a
        ld b, 1
        jr hu_2
hu_p1:  ld a, (hud_dirty)
        ld c, a
        and 0x0F
        ld (hud_dirty), a
        ld a, c
        rrca
        rrca
        rrca
        rrca
        ld c, a
        ld b, 2
hu_2:   ; C = this page's old fields, B = its bit in hud_full
        ld a, (hud_full)
        and b
        jr z, hu_3
        ld a, (hud_full)
        xor b
        ld (hud_full), a
        jr hud_bar
hu_3:   ld a, c
        and 7
        ret z
        jr hud_fields

; the whole bar on txt_page
hud_bar:
        ld hl, bar_boxes
        ld b, 5
        call box_list
        ld a, 1
        ld (txt_bg), a
        ld hl, bar_texts
        ld b, 3
        call txt_list
        ld a, 7
        ; fall through

; A = the fields to draw (HF_*)
hud_fields:
        ld (hud_f), a
        ld hl, 16
        ld (cmd_nx), hl
        ld (cmd_ny), hl
        ld a, (hud_f)
        and HF_HP
        jr z, hf_2
        ; health: three big digits and the "%"
        ld a, (p_hp)
        call num3
        ld a, (numbuf)
        ld e, 10
        call big_glyph
        ld a, (numbuf + 1)
        ld e, 26
        call big_glyph
        ld a, (numbuf + 2)
        ld e, 42
        call big_glyph
        ld a, '0' + 10
        ld e, 58
        call big_glyph
        ; its bar: 64 pixels at 100
        ld a, (p_hp)
        ld e, a
        ld d, 0
        ld bc, 164
        call mulu16
        ld a, h
        ld (hud_w), a
        or a
        jr z, hf_1
        ld l, a
        ld h, 0
        ld (cmd_nx), hl
        ld hl, 10
        ld (cmd_dx), hl
        call hf_row
        ld a, 3
        call fill
hf_1:   ld a, (hud_w)
        cp 64
        jr nc, hf_2
        ld b, a
        add a, 10
        ld l, a
        ld h, 0
        ld (cmd_dx), hl
        ld a, 64
        sub b
        ld l, a
        ld h, 0
        ld (cmd_nx), hl
        call hf_row
        ld a, 7
        call fill
hf_2:   ld a, (hud_f)
        and HF_KILLS
        jr z, hf_3
        ; monsters left: two big digits
        ld hl, 16
        ld (cmd_nx), hl
        ld (cmd_ny), hl
        ld a, (kills)
        ld b, a
        ld a, NENEMY
        sub b
        call num3
        ld a, (numbuf + 1)
        ld e, 196
        call big_glyph
        ld a, (numbuf + 2)
        ld e, 212
        call big_glyph
        ; kills: a small digit after "ABATES "
        ld hl, 8
        ld (cmd_nx), hl
        ld (cmd_ny), hl
        ld a, (kills)
        add a, a
        add a, a
        add a, a
        ld b, a
        ld c, 228
        ld de, 185 * 256 + 144
        call hud_cp
hf_3:   ld a, (hud_f)
        and HF_MSG
        ret z
        ld hl, 80
        ld (cmd_nx), hl
        ld hl, 8
        ld (cmd_ny), hl
        ld a, (msg_id)
        add a, a
        ld e, a
        ld d, 0
        ld hl, msg_src
        add hl, de
        ld b, (hl)
        inc hl
        ld c, (hl)
        ld de, 198 * 256 + 88
        jr hud_cp

; A = a digit, '0' + 10 for "%" or a space; E = x: the 16 x 16 glyph at
; (E, 192) of txt_page
big_glyph:
        cp ' '
        jr nz, bg_g1
        ld a, '0' + 11
bg_g1:  sub '0'
        add a, a
        add a, a
        add a, a
        add a, a
        ld b, a
        ld c, 212
        ld d, 192
        ; fall through

; copy cmd_nx x cmd_ny pixels from (B, C) of page 0 to (E, D) of txt_page
hud_cp: ld a, b
        ld (cmd_sx), a
        ld a, c
        ld (cmd_sy), a
        xor a
        ld (cmd_sx + 1), a
        ld (cmd_sy + 1), a
        ld (cmd_dx + 1), a
        ld (cmd_clr), a
        ld (cmd_arg), a
        ld a, e
        ld (cmd_dx), a
        ld a, d
        ld (cmd_dy), a
        ld a, (txt_page)
        ld (cmd_dy + 1), a
        ld a, HMMM
        ld (cmd_op), a
        jp cmd_all

; the health bar's rows
hf_row: ld a, (txt_page)
        ld h, a
        ld l, 208
        ld (cmd_dy), hl
        ld hl, 2
        ld (cmd_ny), hl
        ret

bar_boxes:
        db 0, 180
        dw 256
        db 32, 1                    ; the panel
        db 0, 180
        dw 256
        db 1, 2                     ; its top edge
        db 0, 211
        dw 256
        db 1, 9
        db 82, 181
        dw 1
        db 30, 2                    ; separators
        db 173, 181
        dw 1
        db 30, 2
bar_texts:
        db 10, 183, 5, 1
        db "VIDA", 0
        db 180, 183, 5, 1
        db "INIMIGOS", 0
        db 88, 185, 5, 1
        db "ABATES  /", '0' + NENEMY, 0

; ---------------------------------------------------------------- screens
; the title on the hidden page, shown; waits for the trigger
title_screen:
        xor a
        call pal_load
        ld a, (buf)
        ld (txt_page), a
        ld hl, title_boxes
        ld b, 1
        call box_list
        xor a
        ld (txt_bg), a
        ld hl, title_texts
        ld b, 7
        call txt_list
        ; a monster on each side of the title (LMMM + TIMP from the texture area)
        ld hl, 96
        ld (cmd_sx), hl
        ld hl, TEXY + 384
        ld (cmd_sy), hl
        ld hl, 8
        call ts_mon
        ld hl, 96
        ld (cmd_sx), hl
        ld hl, TEXY + 448
        ld (cmd_sy), hl
        ld hl, 200
        call ts_mon
        call flip
        ; fall through

; wait for the trigger (or RETURN) to be released, then pressed
wait_fire:
        ld a, (in_cur)
        and IN_GO
        jr nz, wait_fire
wf_1:   ld a, (in_cur)
        and IN_GO
        jr z, wf_1
        ret

; a 48 x 64 frame from (cmd_sx, cmd_sy) to x = HL, y = 4 of txt_page
ts_mon: ld (cmd_dx), hl
        ld a, (txt_page)
        ld h, a
        ld l, 4
        ld (cmd_dy), hl
        ld hl, 48
        ld (cmd_nx), hl
        ld hl, 64
        ld (cmd_ny), hl
        jp ov_copy

title_boxes:
        db 0, 0
        dw 256
        db 212, 0
title_texts:
        db 64, 20, 3, 2
        db "MSX DOOM", 0
        db 76, 46, 4, 1
        db "V9968 + GEO3D", 0
        db 16, 92, 5, 1
        db "CURSORES  ANDAR E GIRAR", 0
        db 16, 106, 5, 1
        db "Z  X      PASSO LATERAL", 0
        db 16, 120, 5, 1
        db "ESPACO    ATIRAR", 0
        db 16, 134, 5, 1
        db "JOYSTICK  A ATIRA  B LATERAL", 0
        db 64, 176, 6, 1
        db "PRESSIONE ESPACO", 0

; the end: a box over the picture on show, then the trigger
end_screen:
        call wait_ce
        ld a, (buf)
        xor 1
        ld (txt_page), a
        ld hl, end_boxes
        ld b, 2
        call box_list
        ld a, 1
        ld (txt_bg), a
        ld hl, end_dead
        ld a, (g_state)
        cp 1
        jr z, eds_1
        ld hl, end_won
eds_1:  call txt_at
        ld hl, end_again
        call txt_at
        call wait_ce
        jp wait_fire

end_boxes:
        db 30, 58
        dw 196
        db 64, 2
        db 32, 60
        dw 192
        db 60, 1
end_dead:
        db 40, 70, 3, 2
        db "VOCE MORREU", 0
end_won:
        db 48, 70, 8, 2
        db "AREA LIMPA", 0
end_again:
        db 68, 100, 5, 1
        db "ESPACO: DE NOVO", 0
