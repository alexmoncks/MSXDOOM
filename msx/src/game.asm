; ============================================================================
; game.asm - the game loop, the player, the shot, the medkits
;
; Time: the frame rate follows the picture, so everything moves by `dt`, the
; number of vertical blanks (1/60 s) the last frame took, 1 to 8.
; Positions are 16 bits, 256 units a cell: the high byte is the cell.
; A frame (frame): palette; the faces to geo3d while the frame before waits
; for its vertical blank; background, RUN; while geo3d and the V9968 draw,
; the game logic of the next frame; then the overlays, the status bar and
; the request to show the page. The Z80 only waits when it is ahead.
; ============================================================================

ST_PLAY:    equ 0
ST_DEAD:    equ 1
ST_WON:     equ 2

PL_RADIUS:  equ 56              ; 0.22 cell
EN_RADIUS:  equ 72              ; 0.28 cell
IN_GO:      equ 0x90            ; IN_FIRE | IN_START

game_run:
        call game_init
gr_1:   call frame
        ld a, (g_state)
        or a
        jr z, gr_1
        ld a, (g_end)
        cp 110
        jr c, gr_1
        call flip_sync
        jp end_screen

game_init:
        ld hl, g_state
        ld de, g_state + 1
        ld bc, ram_end - g_state - 1
        ld (hl), 0
        ldir
        ld hl, START_X
        ld (p_x), hl
        ld hl, START_Z
        ld (p_z), hl
        ld h, START_YAW
        ld l, 0
        ld (p_yawf), hl
        ld hl, EYE
        ld (p_eye), hl
        ld a, 100
        ld (p_hp), a
        ld a, 0xFF
        ld (p_cell), a
        ld (st_cell), a
        ld a, 3
        ld (hud_full), a
        ld a, 96
        ld (gun_x), a
        ; the monsters
        ld hl, spawn_enemies
        ld ix, enemies
        ld b, NENEMY
gi_1:   push bc
        ld a, (hl)
        inc hl
        ld (ix + EN_TYPE), a
        ld e, a
        ld d, 0
        push hl
        ld hl, et_hp
        add hl, de
        ld a, (hl)
        ld (ix + EN_HP), a
        pop hl
        ld a, (hl)
        inc hl
        ld (ix + EN_X), a
        ld a, (hl)
        inc hl
        ld (ix + EN_X + 1), a
        ld b, a
        ld a, (hl)
        inc hl
        ld (ix + EN_Z), a
        ld a, (hl)
        inc hl
        ld (ix + EN_Z + 1), a
        ld c, a
        push hl
        call cell_at
        ld (ix + EN_CELL), a
        xor a
        call en_frame
        pop hl
        ld de, EN_SIZE
        add ix, de
        pop bc
        djnz gi_1
        ; the medkits
        ld hl, spawn_items
        ld ix, items
        ld b, NITEM
gi_2:   ld a, (hl)
        inc hl
        ld (ix + IT_X), a
        ld a, (hl)
        inc hl
        ld (ix + IT_X + 1), a
        ld a, (hl)
        inc hl
        ld (ix + IT_Z), a
        ld a, (hl)
        inc hl
        ld (ix + IT_Z + 1), a
        ld de, IT_SIZE
        add ix, de
        djnz gi_2
        di
        ld hl, (vcount)
        call eiop
        ld (frm_v0), hl
        ret

; ---------------------------------------------------------------- a frame
frame:
        di
        ld hl, (vcount)
        call eiop
        ld de, (frm_v0)
        ld (frm_v0), hl
        or a
        sbc hl, de
        ld a, h
        or a
        jr nz, fm_cap
        ld a, l
        cp 9
        jr c, fm_1
fm_cap: ld a, 8
fm_1:   or a
        jr nz, fm_2
        inc a
fm_2:   ld (dt), a
        ld (st_ticks), a
        call pal_update
        ; the geometry goes to geo3d's RAM while the last frame waits for its
        ; vertical blank (nothing is drawn yet)
        call cell_update
        call st_check
        call cam_setup
        call near_emit
        call sprites_emit
        call flip_sync              ; the last frame is on show: draw the other page
        call bg_draw
        call wait_ce
        call geo_run
        call logic                  ; (geo3d and the V9968 draw meanwhile)
        call geo_wait
        call wait_ce
        call ov_draw
        call hud_update
        call flip_ask
        ld hl, (st_frames)
        inc hl
        ld (st_frames), hl
        ret

; the palette the moment asks for: hurt (and dead) red, pickup green, the
; shot's flash
pal_update:
        ld b, 0
        ld a, (muzzle_t)
        or a
        jr z, pu_a
        ld b, 3
pu_a:   ld a, (pick_t)
        or a
        jr z, pu_b
        ld b, 2
pu_b:   ld a, (hurt_t)
        or a
        jr z, pu_c
        ld b, 1
pu_c:   ld a, (g_state)
        cp ST_DEAD
        jr nz, pu_d
        ld b, 1
pu_d:   ld a, (pal_cur)
        cp b
        ret z
        ld a, b
        jp pal_load

; monsters and medkits in cells the player's cell sees, and the shot's puff
sprites_emit:
        ld hl, 0
        ld (bb_hw), hl
        ld ix, enemies
        ld b, NENEMY
se_1:   push bc
        ld a, (ix + EN_CELL)
        call cell_seen
        jr z, se_2
        ld e, (ix + EN_X)
        ld d, (ix + EN_X + 1)
        ld l, (ix + EN_Z)
        ld h, (ix + EN_Z + 1)
        ld a, (ix + EN_FRAME)
        push ix
        call bb_emit
        pop ix
se_2:   ld de, EN_SIZE
        add ix, de
        pop bc
        djnz se_1
        ld ix, items
        ld b, NITEM
se_3:   push bc
        ld a, (ix + IT_TAKEN)
        or a
        jr nz, se_4
        ld b, (ix + IT_X + 1)
        ld c, (ix + IT_Z + 1)
        call cell_at
        call cell_seen
        jr z, se_4
        ld e, (ix + IT_X)
        ld d, (ix + IT_X + 1)
        ld l, (ix + IT_Z)
        ld h, (ix + IT_Z + 1)
        ld a, FR_MEDKIT
        push ix
        call bb_emit
        pop ix
se_4:   ld de, IT_SIZE
        add ix, de
        pop bc
        djnz se_3
        ld a, (puff_t)
        or a
        ret z
        ld de, (puff_x)
        ld hl, (puff_z)
        ld a, FR_MUZZLE_FLASH
        jp bb_emit

; ---------------------------------------------------------------- logic
logic:
        ; the timers run down
        ld a, (dt)
        ld c, a
        ld hl, fire_cd
        ld b, 7
lg_1:   ld a, (hl)
        sub c
        jr nc, lg_2
        xor a
lg_2:   ld (hl), a
        inc hl
        djnz lg_1
        ld a, (g_state)
        or a
        jr nz, lg_end
        ld a, (dbg_freeze)
        or a
        ret nz
        call player_update
        call enemies_update
        call items_update
        jp gun_update
lg_end: ld a, (dt)
        ld b, a
        ld a, (g_end)
        add a, b
        jr nc, lg_3
        ld a, 255
lg_3:   ld (g_end), a
        ld a, (g_state)
        cp ST_DEAD
        ret nz
        ; dead: the eye sinks, the pistol drops
        ld a, (dt)
        add a, a
        add a, a
        ld b, a
        ld a, (p_eye)
        sub b
        cp 36
        jr nc, lg_4
        ld a, 36
lg_4:   ld (p_eye), a
        ld a, (gun_y)
        add a, b
        cp 68
        jr c, lg_5
        ld a, 68
lg_5:   ld (gun_y), a
        ret

; the pistol's place: it bobs while the player walks and kicks at a shot
gun_update:
        ld bc, 0                    ; B = bob x, C = bob y
        ld a, (moving)
        or a
        jr z, gu_1
        ld a, (dt)
        ld e, a
        add a, a
        add a, e                    ; 3 dt: about 0.7 turn a second
        ld hl, bob
        add a, (hl)
        ld (hl), a
        call sin_a
        ld a, h                     ; sin * 64
        call gu_3
        ld b, a
        push bc
        ld a, (bob)
        add a, 64
        call sin_a
        call abs_hl
        ld a, h
        call gu_3
        pop bc
        ld c, a
gu_1:   ld a, b
        add a, 96
        ld (gun_x), a
        ld a, (recoil)
        add a, c
        ld (gun_y), a
        ret
; A (-64..64) -> A * 3 / 64
gu_3:   sra a
        ld e, a
        add a, a
        add a, e
        sra a
        sra a
        sra a
        sra a
        sra a
        ret

; ---------------------------------------------------------------- the player
player_update:
        ld a, (in_cur)
        ld c, a
        ; turn: 417 / 256 of a step per tick (2.4 rad/s)
        ld a, (dt)
        ld b, a
        ld hl, 0
        ld de, 417
py_1:   add hl, de
        djnz py_1
        ex de, hl
        ld hl, (p_yawf)
        bit IN_LEFT, c
        jr z, py_2
        or a
        sbc hl, de
py_2:   bit IN_RIGHT, c
        jr z, py_3
        add hl, de
py_3:   ld (p_yawf), hl
        ; the view vector of the new yaw
        ld a, h
        call sin_a
        ld (mv_fx), hl
        ld a, (p_yaw)
        add a, 64
        call sin_a
        call neg_hl
        ld (mv_fz), hl
        ; walk: 3.2 cells/s = 13.65 units per tick
        xor a
        ld (moving), a
        ld hl, 0
        ld (mv_x), hl
        ld (mv_z), hl
        ld a, (in_cur)
        ld c, a
        ld e, 0                     ; E = forward (1, 0, -1)
        bit IN_UP, c
        jr z, py_4
        inc e
py_4:   bit IN_DOWN, c
        jr z, py_5
        dec e
py_5:   ld d, 0                     ; D = to the right
        bit IN_SR, c
        jr z, py_6
        inc d
py_6:   bit IN_SL, c
        jr z, py_7
        dec d
py_7:   ld a, e
        or d
        jp z, py_fire
        ld a, 1
        ld (moving), a
        push de
        ld a, (dt)
        ld b, a
        ld hl, 0
        ld de, 3494
py_8:   add hl, de
        djnz py_8
        pop de
        ld b, h                     ; B = the step
        ld a, e
        or a
        jr z, py_9
        ld a, d
        or a
        jr z, py_9
        ld a, b                     ; both ways: 0.69 of the step each
        srl a
        srl a
        ld l, a
        srl a
        srl a
        add a, l
        ld l, a
        ld a, b
        sub l
        ld b, a
py_9:   ld a, b
        ld (mv_s), a
        ld (mv_fs), de
        ld a, e
        or a
        jr z, py_10
        call py_amt                 ; HL = +- step
        push hl
        ex de, hl
        ld bc, (mv_fx)
        call mulq14
        ld (mv_x), hl
        pop de
        ld bc, (mv_fz)
        call mulq14
        ld (mv_z), hl
py_10:  ld a, (mv_fs + 1)
        or a
        jr z, py_11
        call py_amt
        push hl
        ex de, hl                   ; right = (-fz, fx)
        ld bc, (mv_fz)
        call mulq14
        call neg_hl
        ld de, (mv_x)
        add hl, de
        ld (mv_x), hl
        pop de
        ld bc, (mv_fx)
        call mulq14
        ld de, (mv_z)
        add hl, de
        ld (mv_z), hl
py_11:  ld hl, (p_x)
        ld (tmp), hl
        ld hl, (p_z)
        ld (tmp + 2), hl
        ld a, PL_RADIUS
        ld (bk_r), a
        ld hl, (p_x)
        ld de, (mv_x)
        add hl, de
        ld (bk_x), hl
        ld hl, (p_z)
        ld (bk_z), hl
        call blocked
        jr nz, py_12
        ld hl, (bk_x)
        ld (p_x), hl
py_12:  ld hl, (p_x)
        ld (bk_x), hl
        ld hl, (p_z)
        ld de, (mv_z)
        add hl, de
        ld (bk_z), hl
        call blocked
        jr nz, py_13
        ld hl, (bk_z)
        ld (p_z), hl
py_13:  call enemy_near             ; living monsters are solid
        jr z, py_fire
        ld hl, (tmp)
        ld (p_x), hl
        ld hl, (tmp + 2)
        ld (p_z), hl
py_fire:
        ld a, (in_cur)
        bit IN_FIRE, a
        ret z
        ld a, (fire_cd)
        or a
        ret nz
        jp fire

; A = 1 or -1 -> HL = +- mv_s
py_amt: ld b, a
        ld a, (mv_s)
        ld l, a
        ld h, 0
        bit 7, b
        ret z
        jp neg_hl

; bk_x, bk_z, bk_r: NZ if a circle there touches a wall
blocked:
        ld a, (bk_r)
        ld e, a
        ld d, 0
        ld hl, (bk_x)
        or a
        sbc hl, de
        ld a, h
        ld (bk_c), a
        ld hl, (bk_x)
        add hl, de
        ld a, h
        ld (bk_c + 1), a
        ld hl, (bk_z)
        or a
        sbc hl, de
        ld a, h
        ld (bk_c + 2), a
        ld hl, (bk_z)
        add hl, de
        ld a, h
        ld (bk_c + 3), a
        ld a, (bk_c)
        ld b, a
        ld a, (bk_c + 2)
        ld c, a
        call wall_at
        ret nz
        ld a, (bk_c + 1)
        ld b, a
        call wall_at
        ret nz
        ld a, (bk_c + 3)
        ld c, a
        call wall_at
        ret nz
        ld a, (bk_c)
        ld b, a
        jp wall_at

; DE = x, HL = z -> HL = distance to the player (dist_approx)
dist_xz:
        push hl
        ex de, hl
        ld de, (p_x)
        or a
        sbc hl, de
        call abs_hl
        ex (sp), hl
        ld de, (p_z)
        or a
        sbc hl, de
        call abs_hl
        pop de
        jp dist_approx

; NZ if a living monster is closer than 0.45 cell to the player
enemy_near:
        ld ix, enemies
        ld b, NENEMY
en_1:   ld a, (ix + EN_STATE)
        cp ES_DYING
        jr nc, en_2
        ld a, (p_x + 1)             ; two cells away or more: not near
        sub (ix + EN_X + 1)
        inc a
        cp 3
        jr nc, en_2
        ld a, (p_z + 1)
        sub (ix + EN_Z + 1)
        inc a
        cp 3
        jr nc, en_2
        push bc
        call en_dist
        pop bc
        ld a, h
        or a
        jr nz, en_2
        ld a, l
        cp 115
        jr c, en_3
en_2:   ld de, EN_SIZE
        add ix, de
        djnz en_1
        xor a
        ret
en_3:   or 1
        ret

; ---------------------------------------------------------------- the shot
; A ray in steps of 32 units to the first wall, then the nearest living
; monster closer than that wall and within 0.3 cell of the line
fire:
        ld a, 19
        ld (fire_cd), a
        ld a, 4
        ld (muzzle_t), a
        ld a, 8
        ld (recoil), a
        ld a, SFX_SHOT
        call sfx_play
        ; positions times 8, step = f * 32 units = (f >> 6) of those
        ld hl, (p_x)
        add hl, hl
        add hl, hl
        add hl, hl
        ld (sh_x), hl
        ld hl, (p_z)
        add hl, hl
        add hl, hl
        add hl, hl
        ld (sh_z), hl
        ld hl, (mv_fx)
        call sra6
        ld (sh_sx), hl
        ld hl, (mv_fz)
        call sra6
        ld (sh_sz), hl
        ld hl, 0
        ld (sh_wall), hl
        ld b, 96
fi_1:   push bc
        ld hl, (sh_x)
        ld de, (sh_sx)
        add hl, de
        ld (sh_x), hl
        ld a, h
        rrca
        rrca
        rrca
        and 31
        ld b, a
        ld hl, (sh_z)
        ld de, (sh_sz)
        add hl, de
        ld (sh_z), hl
        ld a, h
        rrca
        rrca
        rrca
        and 31
        ld c, a
        call wall_at
        pop bc
        jr nz, fi_2
        ld hl, (sh_wall)
        ld de, 32
        add hl, de
        ld (sh_wall), hl
        djnz fi_1
fi_2:   ld hl, (sh_wall)
        ld (sh_best), hl
        ld hl, 0
        ld (sh_hit), hl
        ld ix, enemies
        ld b, NENEMY
fi_3:   push bc
        ld a, (ix + EN_STATE)
        cp ES_DYING
        jp nc, fi_5
        ld a, (ix + EN_CELL)
        call cell_seen
        jp z, fi_5
        ; along = v . f
        ld l, (ix + EN_X)
        ld h, (ix + EN_X + 1)
        ld de, (p_x)
        or a
        sbc hl, de
        ld (tmp), hl                ; vx
        ld l, (ix + EN_Z)
        ld h, (ix + EN_Z + 1)
        ld de, (p_z)
        or a
        sbc hl, de
        ld (tmp + 2), hl            ; vz
        ld de, (tmp)
        ld bc, (mv_fx)
        call mulq14
        push hl
        ld de, (tmp + 2)
        ld bc, (mv_fz)
        call mulq14
        pop de
        add hl, de
        ld (tmp + 4), hl
        bit 7, h
        jr nz, fi_5                 ; behind
        ld de, 26
        or a
        sbc hl, de
        jr c, fi_5                  ; too close to tell
        ld hl, (tmp + 4)
        ld de, (sh_best)
        or a
        sbc hl, de
        jr nc, fi_5                 ; behind the wall or a nearer monster
        ; across = v x f
        ld de, (tmp)
        ld bc, (mv_fz)
        call mulq14
        push hl
        ld de, (tmp + 2)
        ld bc, (mv_fx)
        call mulq14
        pop de
        ex de, hl
        or a
        sbc hl, de
        call abs_hl
        ld de, 77
        or a
        sbc hl, de
        jp nc, fi_5
        ld hl, (tmp + 4)
        ld (sh_best), hl
        push ix
        pop hl
        ld (sh_hit), hl
fi_5:   ld de, EN_SIZE
        add ix, de
        pop bc
        dec b
        jp nz, fi_3
        ; the noise wakes the monsters within 6 cells
        ld ix, enemies
        ld b, NENEMY
fi_6:   push bc
        ld a, (p_cx)
        sub (ix + EN_X + 1)
        jr nc, fi_7
        neg
fi_7:   cp 7
        jr nc, fi_9
        ld a, (p_cz)
        sub (ix + EN_Z + 1)
        jr nc, fi_8
        neg
fi_8:   cp 7
        jr nc, fi_9
        call en_alert
fi_9:   ld de, EN_SIZE
        add ix, de
        pop bc
        djnz fi_6
        ld hl, (sh_hit)
        ld a, h
        or l
        jr z, fi_miss
        push hl
        pop ix
        call rand
        and 7
        cp 6
        jr c, fi_10
        sub 4
fi_10:  add a, 10
        jp hurt_enemy
fi_miss:
        ; a puff on the wall, 16 units before it
        ld hl, (sh_wall)
        ld de, 0 - 16
        add hl, de
        bit 7, h
        ret nz
        push hl
        ex de, hl
        ld bc, (mv_fx)
        call mulq14
        ld de, (p_x)
        add hl, de
        ld (puff_x), hl
        pop de
        ld bc, (mv_fz)
        call mulq14
        ld de, (p_z)
        add hl, de
        ld (puff_z), hl
        ld a, 6
        ld (puff_t), a
        ret

; HL = HL >> 6, signed
sra6:   ld b, 6
sr_1:   sra h
        rr l
        djnz sr_1
        ret

; ---------------------------------------------------------------- medkits
items_update:
        ld ix, items
        ld b, NITEM
iu_1:   push bc
        ld a, (ix + IT_TAKEN)
        or a
        jr nz, iu_2
        ld a, (p_hp)
        cp 100
        jr nc, iu_2
        ld e, (ix + IT_X)
        ld d, (ix + IT_X + 1)
        ld l, (ix + IT_Z)
        ld h, (ix + IT_Z + 1)
        call dist_xz
        ld a, h
        or a
        jr nz, iu_2
        ld a, l
        cp 128
        jr nc, iu_2
        ld (ix + IT_TAKEN), 1
        ld a, (p_hp)
        add a, 25
        cp 100
        jr c, iu_3
        ld a, 100
iu_3:   ld (p_hp), a
        ld a, 12
        ld (pick_t), a
        ld a, 2
        ld b, 90
        call msg_set
        ld a, SFX_PICKUP
        call sfx_play
iu_2:   ld de, IT_SIZE
        add ix, de
        pop bc
        djnz iu_1
        ret

; A = message, B = ticks: show it in the status bar
msg_set:
        ld (msg_id), a
        ld a, b
        ld (msg_t), a
        ld a, HF_HP | HF_KILLS | HF_MSG
        jp hud_mark
