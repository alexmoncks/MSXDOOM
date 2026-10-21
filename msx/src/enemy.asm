; ============================================================================
; enemy.asm - the monsters
;
; States: idle (stands until it sees the player or hears a shot), chase,
; attack (strikes 16 ticks in, if still in reach), pain, dying, dead.
; The chase needs no search: nsrow, the player's cell's row of the
; `nextstep` table (tools/gen_data.py), gives each cell's next step toward
; the player, 2 bits. A monster walks to the middle of that cell, or
; straight at the player when it is in his cell or the next one is.
; ============================================================================

ES_IDLE:    equ 0
ES_CHASE:   equ 1
ES_ATTACK:  equ 2
ES_PAIN:    equ 3
ES_DYING:   equ 4
ES_DEAD:    equ 5

; per type (0 fiend, 1 zombie)
et_hp:      db 40, 30
et_dmg:     db 14, 9
et_reach:   db 243, 230             ; 0.95 and 0.90 cell
et_anim:    db 12, 21               ; ticks per walk frame
et_speed:   dw 2512, 1420           ; units per tick * 256 (2.3 and 1.3 cells/s)

enemies_update:
        xor a
        ld (en_awake), a
        ld ix, enemies
        ld b, NENEMY
eu_1:   push bc
        call enemy_tick
        ld de, EN_SIZE
        add ix, de
        pop bc
        djnz eu_1
        ld a, (en_awake)            ; nobody moves: nobody to push apart
        or a
        ret z
        jp enemies_apart

; IX -> monster: HL = its distance to the player
en_dist:
        ld e, (ix + EN_X)
        ld d, (ix + EN_X + 1)
        ld l, (ix + EN_Z)
        ld h, (ix + EN_Z + 1)
        jp dist_xz

; A = frame of the type (0 walk1, 1 walk2, 2 attack, 3 pain, 4 dying, 5 dead)
en_frame:
        ld c, a
        ld a, (ix + EN_TYPE)
        add a, a
        ld b, a
        add a, a
        add a, b
        add a, c
        ld (ix + EN_FRAME), a
        ret

; HL -> a byte table per type -> A = the monster's entry
en_byte:
        ld e, (ix + EN_TYPE)
        ld d, 0
        add hl, de
        ld a, (hl)
        ret

; idle -> chase, with a growl
en_alert:
        ld a, (ix + EN_STATE)
        or a
        ret nz
        ld (ix + EN_STATE), ES_CHASE
        ld (ix + EN_T), 0
        ld a, (ix + EN_TYPE)
        add a, SFX_GROWL_F
        jp sfx_play

; A = damage
hurt_enemy:
        ld b, a
        ld a, (ix + EN_HP)
        sub b
        jr c, he_dead
        jr z, he_dead
        ld (ix + EN_HP), a
        ld (ix + EN_STATE), ES_PAIN
        ld (ix + EN_T), 0
        ld a, SFX_PAIN
        jp sfx_play
he_dead:
        ld (ix + EN_HP), 0
        ld (ix + EN_STATE), ES_DYING
        ld (ix + EN_T), 0
        ld a, SFX_DEATH
        call sfx_play
        ld hl, kills
        inc (hl)
        ld a, (hl)
        cp NENEMY
        jr z, he_won
        ld a, 1
        ld b, 72
        jp msg_set
he_won: ld a, ST_WON
        ld (g_state), a
        xor a
        ld (g_end), a
        ld a, 3
        ld b, 255
        jp msg_set

; A = damage
hurt_player:
        ld b, a
        ld a, (g_state)
        or a
        ret nz
        ld a, (p_hp)
        sub b
        jr nc, hpl_1
        xor a
hpl_1:  ld (p_hp), a
        ld a, 20
        ld (hurt_t), a
        ld a, HF_HP
        call hud_mark
        ld a, SFX_HURT
        call sfx_play
        ld a, (p_hp)
        or a
        ret nz
        ld a, ST_DEAD
        ld (g_state), a
        xor a
        ld (g_end), a
        ret

; ---------------------------------------------------------------- one monster
enemy_tick:
        ld a, (ix + EN_STATE)
        cp ES_DEAD
        ret z
        or a
        jr nz, et_0
        ; idle and out of sight of the player's cell: nothing to do (as
        ; Wolfenstein 3D's DoActor skips the actors of unconnected areas)
        ld a, (ix + EN_CELL)
        call cell_seen
        ret z
        jr et_2
et_0:   ld a, 1
        ld (en_awake), a
et_2:   ld a, (dt)
        add a, (ix + EN_T)
        jr nc, et_1
        ld a, 255
et_1:   ld (ix + EN_T), a
        ld a, (ix + EN_STATE)
        or a
        jr z, es_idle
        dec a
        jp z, es_chase
        dec a
        jr z, es_attack
        dec a
        jr z, es_pain
        ; dying
        ld a, 4
        call en_frame
        ld a, (ix + EN_T)
        cp 19
        ret c
        ld (ix + EN_STATE), ES_DEAD
        ld a, 5
        jp en_frame

es_pain:
        ld a, 3
        call en_frame
        ld a, (ix + EN_T)
        cp 13
        ret c
es_to_chase:
        ld (ix + EN_STATE), ES_CHASE
        ld (ix + EN_T), 0
        ret

es_idle:
        xor a
        call en_frame
        ld a, (ix + EN_CELL)
        call cell_seen
        ret z
        call en_dist
        ld a, h
        cp 9
        ret nc                      ; farther than 9 cells
        jp en_alert

es_attack:
        ld a, 2
        call en_frame
        bit 0, (ix + EN_FLAGS)
        jr nz, ea_1
        ld a, (ix + EN_T)
        cp 16
        jr c, ea_1
        set 0, (ix + EN_FLAGS)
        call en_dist
        ld (en_d), hl
        ld hl, et_reach
        call en_byte
        ld l, a
        ld h, 0
        ld de, 77                   ; reach + 0.3 cell
        add hl, de
        ex de, hl
        ld hl, (en_d)
        or a
        sbc hl, de
        jr nc, ea_1
        ld hl, et_dmg
        call en_byte
        call hurt_player
ea_1:   ld a, (ix + EN_T)
        cp 36
        ret c
        jr es_to_chase

es_chase:
        ; in reach: strike
        call en_dist
        ld (en_d), hl
        ld hl, et_reach
        call en_byte
        ld e, a
        ld d, 0
        ld hl, (en_d)
        or a
        sbc hl, de
        jr nc, ec_0
        ld (ix + EN_STATE), ES_ATTACK
        ld (ix + EN_T), 0
        res 0, (ix + EN_FLAGS)
        ld a, 2
        jp en_frame
ec_0:   ; where to: the player, or the middle of the next cell of the path
        ld a, (ix + EN_CELL)
        ld c, a
        ld hl, p_cell
        cp (hl)
        jr z, ec_player
        rrca
        rrca
        and 63
        ld e, a
        ld d, 0
        ld hl, nsrow
        add hl, de
        ld b, (hl)
        ld a, c
        and 3
        jr z, ec_2
ec_1:   srl b
        srl b
        dec a
        jr nz, ec_1
ec_2:   ld a, b
        and 3                       ; 0 +x, 1 -x, 2 +z, 3 -z
        ld b, (ix + EN_X + 1)
        ld c, (ix + EN_Z + 1)
        or a
        jr z, ec_px
        dec a
        jr z, ec_mx
        dec a
        jr z, ec_pz
        dec c
        jr ec_3
ec_px:  inc b
        jr ec_3
ec_mx:  dec b
        jr ec_3
ec_pz:  inc c
ec_3:   ld a, (p_cx)
        cp b
        jr nz, ec_cell
        ld a, (p_cz)
        cp c
        jr z, ec_player
ec_cell:
        ld h, b
        ld l, 128
        ld (en_tx), hl
        ld h, c
        ld (en_tz), hl
        jr ec_move
ec_player:
        ld hl, (p_x)
        ld (en_tx), hl
        ld hl, (p_z)
        ld (en_tz), hl
ec_move:
        ; the step: speed * dt
        ld a, (ix + EN_TYPE)
        add a, a
        ld e, a
        ld d, 0
        ld hl, et_speed
        add hl, de
        ld e, (hl)
        inc hl
        ld d, (hl)
        ld a, (dt)
        ld b, a
        ld hl, 0
ec_4:   add hl, de
        djnz ec_4
        ld a, h
        or a
        jr nz, ec_5
        inc a
ec_5:   ld (en_step), a
        ; the way there, each axis at most a step (3/4 of it on a diagonal)
        ld hl, (en_tx)
        ld e, (ix + EN_X)
        ld d, (ix + EN_X + 1)
        or a
        sbc hl, de
        ld (mv_x), hl
        ld hl, (en_tz)
        ld e, (ix + EN_Z)
        ld d, (ix + EN_Z + 1)
        or a
        sbc hl, de
        ld (mv_z), hl
        call abs_hl
        ld a, (en_step)
        ld e, a
        ld d, 0
        or a
        sbc hl, de
        jr c, ec_6                  ; |dz| < step
        ld hl, (mv_x)
        call abs_hl
        or a
        sbc hl, de
        jr c, ec_6
        ld a, (en_step)
        ld b, a
        srl a
        srl a
        ld c, a
        ld a, b
        sub c
        ld (en_step), a
ec_6:   ld hl, (mv_x)
        ld a, (en_step)
        call clamp_s
        ld (mv_x), hl
        ld hl, (mv_z)
        ld a, (en_step)
        call clamp_s
        ld (mv_z), hl
        call en_move
        ; the walk animation
        ld hl, et_anim
        call en_byte
        ld b, a
        ld a, (dt)
        add a, (ix + EN_ANIM)
        cp b
        jr c, ec_7
        sub b
        ld c, a
        ld a, (ix + EN_FLAGS)
        xor 2
        ld (ix + EN_FLAGS), a
        ld a, c
ec_7:   ld (ix + EN_ANIM), a
        xor a
        bit 1, (ix + EN_FLAGS)
        jr z, ec_8
        inc a
ec_8:   jp en_frame

; IX -> monster: move it by (mv_x, mv_z) where no wall is in the way, each
; axis by itself (so it slides along walls); its cell follows
en_move:
        ld a, EN_RADIUS
        ld (bk_r), a
        ld l, (ix + EN_X)
        ld h, (ix + EN_X + 1)
        ld de, (mv_x)
        add hl, de
        ld (bk_x), hl
        ld l, (ix + EN_Z)
        ld h, (ix + EN_Z + 1)
        ld (bk_z), hl
        call blocked
        jr nz, em_1
        ld hl, (bk_x)
        ld (ix + EN_X), l
        ld (ix + EN_X + 1), h
em_1:   ld l, (ix + EN_X)
        ld h, (ix + EN_X + 1)
        ld (bk_x), hl
        ld l, (ix + EN_Z)
        ld h, (ix + EN_Z + 1)
        ld de, (mv_z)
        add hl, de
        ld (bk_z), hl
        call blocked
        jr nz, em_2
        ld hl, (bk_z)
        ld (ix + EN_Z), l
        ld (ix + EN_Z + 1), h
em_2:   ld b, (ix + EN_X + 1)
        ld c, (ix + EN_Z + 1)
        call cell_at
        ld (ix + EN_CELL), a
        ret

; HL = clamp(HL, -A, A)
clamp_s:
        ld e, a
        ld d, 0
        bit 7, h
        jr nz, cl_neg
        or a
        sbc hl, de
        add hl, de
        ret c                       ; HL < A
        ex de, hl
        ret
cl_neg: call neg_hl
        or a
        sbc hl, de
        add hl, de
        jr c, cl_1
        ld h, d
        ld l, e
cl_1:   jp neg_hl

; living monsters closer than 0.55 cell on both axes push each other apart
; along the axis where they are farther
enemies_apart:
        ld ix, enemies
        ld b, NENEMY - 1
ap_1:   push bc
        ld a, (ix + EN_STATE)
        cp ES_DYING
        jr nc, ap_next
        push ix
        pop iy
ap_2:   ld de, EN_SIZE
        add iy, de
        ld a, (iy + EN_STATE)
        cp ES_DYING
        jr nc, ap_3
        ld a, (iy + EN_X + 1)       ; more than a cell apart: nothing to do
        sub (ix + EN_X + 1)
        inc a
        cp 3
        jr nc, ap_3
        ld a, (iy + EN_Z + 1)
        sub (ix + EN_Z + 1)
        inc a
        cp 3
        jr nc, ap_3
        call ap_pair
ap_3:   djnz ap_2
ap_next:
        ld de, EN_SIZE
        add ix, de
        pop bc
        djnz ap_1
        ret

; IX, IY -> two living monsters (keeps B)
ap_pair:
        ld l, (iy + EN_X)
        ld h, (iy + EN_X + 1)
        ld e, (ix + EN_X)
        ld d, (ix + EN_X + 1)
        or a
        sbc hl, de
        ld (tmp), hl                ; dx = other - this
        call abs_hl
        ld a, h
        or a
        ret nz
        ld a, l
        cp 141
        ret nc
        ld (tmp + 4), a
        ld l, (iy + EN_Z)
        ld h, (iy + EN_Z + 1)
        ld e, (ix + EN_Z)
        ld d, (ix + EN_Z + 1)
        or a
        sbc hl, de
        ld (tmp + 2), hl            ; dz
        call abs_hl
        ld a, h
        or a
        ret nz
        ld a, l
        cp 141
        ret nc
        push bc
        ld c, a                     ; |dz|
        ; the push: 3 units per tick
        ld a, (dt)
        ld e, a
        add a, a
        add a, e
        ld l, a
        ld h, 0                     ; HL = push
        ld de, 0
        ld (mv_x), de
        ld (mv_z), de
        ld a, (tmp + 4)
        cp c
        jr c, ap_z                  ; |dx| < |dz|: along z
        ld a, (tmp + 1)
        rlca
        jr nc, ap_4
        call neg_hl                 ; the other is at lower x: it goes that way
ap_4:   ld (mv_x), hl
        jr ap_5
ap_z:   ld a, (tmp + 3)
        rlca
        jr nc, ap_6
        call neg_hl
ap_6:   ld (mv_z), hl
ap_5:   ; the other one moves by +push, this one by -push
        push ix
        push iy
        pop ix
        call en_move
        pop ix
        ld hl, (mv_x)
        call neg_hl
        ld (mv_x), hl
        ld hl, (mv_z)
        call neg_hl
        ld (mv_z), hl
        call en_move
        pop bc
        ret
