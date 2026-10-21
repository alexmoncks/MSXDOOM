; ============================================================================
; math.asm - fixed point helpers (tools/sim.py has the same functions)
; ============================================================================

; HL = (DE * BC) >> 14, signed: the product of the magnitudes, the sign put
; back after (so it rounds toward zero). Keeps IX, IY.
mulq14:
        ld a, d
        xor b
        push af                     ; bit 7: the result is negative
        bit 7, d
        jr z, mq_1
        xor a
        sub e
        ld e, a
        sbc a, a
        sub d
        ld d, a
mq_1:   bit 7, b
        jr z, mq_2
        xor a
        sub c
        ld c, a
        sbc a, a
        sub b
        ld b, a
mq_2:   call mulu16                 ; DE:HL = DE * BC
        add hl, hl
        rl e
        rl d
        add hl, hl
        rl e
        rl d                        ; DE = product >> 14
        ex de, hl
        pop af
        ret p
; HL = -HL
neg_hl: xor a
        sub l
        ld l, a
        sbc a, a
        sub h
        ld h, a
        ret

; DE:HL = DE * BC, unsigned
mulu16:
        ld hl, 0
        ld a, 16
mu_1:   add hl, hl
        rl e
        rl d
        jr nc, mu_2
        add hl, bc
        jr nc, mu_2
        inc de
mu_2:   dec a
        jr nz, mu_1
        ret

; A = floor(256 * HL / DE) for 0 <= HL < DE < 16384
frac8:
        ld b, 8
fr_1:   add hl, hl
        or a
        sbc hl, de
        jr nc, fr_2
        add hl, de                  ; (sets carry)
fr_2:   ccf
        rl c
        djnz fr_1
        ld a, c
        ret

; HL = |HL|
abs_hl: bit 7, h
        ret z
        jr neg_hl

; A = angle (1/256 turn) -> HL = sin in Q2.14
sin_a:  ld l, a
        ld h, 0
        add hl, hl
        ld de, sin_tab
        add hl, de
        ld a, (hl)
        inc hl
        ld h, (hl)
        ld l, a
        ret

; HL = |dx|, DE = |dz| -> HL = distance, about (max + 3/8 min)
dist_approx:
        or a
        sbc hl, de
        add hl, de
        jr nc, da_1                 ; HL >= DE
        ex de, hl
da_1:   srl d
        rr e                        ; min / 2
        add hl, de
        srl d
        rr e
        srl d
        rr e                        ; min / 8
        or a
        sbc hl, de
        ret

; A = an 8-bit pseudo random number
rand:   push hl
        ld hl, (rnd)
        ld a, h
        rrca
        rrca
        rrca
        xor l
        ld h, l
        ld l, a
        ld a, r
        add a, l
        ld l, a
        ld (rnd), hl
        pop hl
        ret
