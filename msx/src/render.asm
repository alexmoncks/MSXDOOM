; ============================================================================
; render.asm - the frame: what the Z80 sends to geo3d and to the V9968
;
; World: 256 units a cell, walls 256 high, the eye at 128; x grows east, z
; south. Camera: yaw only, so the matrix is [rx 0 rz; 0 1 0; fx 0 fz] with
; the forward vector f = (sin yaw, -cos yaw) and the right one r = (cos yaw,
; sin yaw), and T = -(M * eye position). geo3d: F 128 (90 degrees), 256 x
; 180, ZNEAR 2, light (0, 1, 0), TIMP, textures at row 512, TSTRIDE 64.
;
; A face is four vertices seen clockwise (top left, top right, bottom
; right, bottom left), a normal (0, ny, 0) and four texture points. With the
; light straight up, ny picks geo3d's light level by itself, whatever the
; yaw, and the level picks the texture copy: ny_tab[n] gives level n. For
; a monster the "level" is just part of its frame's row in the texture area.
;
; Vertices go in pairs: top (y 256) at index n, bottom (y 0) at n + 1.
;
; What goes to geo3d:
;   near strips the walls of the 3 x 3 cells around the player, each as four
;               strips 64 units wide (less affine error where a wall runs
;               away from the eye). Sent when the player enters a cell
;               (st_build): vertices 0..near_nv-1, faces 0..near_nf-1.
;   far faces   the rest of the cell's list, filtered by bearing; sent after
;               the near strips, and again when the player turns more than
;               YAW_MARGIN (st_far). The closer ones go as two halves.
;   every frame geo3d drops a face with a vertex behind ZNEAR, so a near
;               strip that crosses the eye's plane vanishes. For each near
;               wall that crosses Z = 16 the Z80 adds ONE face, from the
;               crossing to the end of the strip it falls in (near_emit);
;               the strips farther along the wall are in front and stay.
;               Then the billboards: monsters, medkits, the shot's puff.
; So a frame costs the Z80 two multiplies and 16 adds for the depths of the
; corners around the player, a face for each wall that crosses the plane,
; and four vertices for each billboard. (Until the Wolfenstein 3D study,
; docs/wolf3d-engenharia-reversa.md, all the near walls were rebuilt in
; every frame.)
; tools/sim.py build_frame() is this file in Python.
; ============================================================================

geo_init:
        ld a, 0x18
        out (GEO_IDX), a
        ld hl, geo_cam
        ld bc, 12 * 256 + GEO_DAT
        otir                        ; F, CX, CY, ZNEAR, W, H
        ld a, 0x40
        out (GEO_IDX), a
        ld hl, geo_r40
        ld bc, 8 * 256 + GEO_DAT
        otir                        ; VADDR, EADDR, NVERT, NEDGE, COLOR, LOP, YPAGE
        ld a, 0x58
        out (GEO_IDX), a
        ld hl, geo_r58
        ld bc, 8 * 256 + GEO_DAT
        otir                        ; FADDR, NFACE, LX, LY, LZ
        ld a, 0x60
        out (GEO_IDX), a
        ld hl, geo_r60
        ld bc, 6 * 256 + GEO_DAT
        otir                        ; TEXX, TEXY, TSTRIDE, TADDR
        ld hl, 16384
        ld (cambuf + 8), hl         ; M11 = 1 (the other constant words are 0)
        ld a, 1
        ld (st_geo), a
        ret

geo_cam:
        dw G3_F, G3_CX, G3_CY, G3_ZNEAR, G3_W, G3_H
geo_r40:
        db 0, 0, 0, 0, 15, TIMP, 0, 0
geo_r58:
        db 0, 0
        dw 0, 16384, 0
geo_r60:
        dw 0, TEXY
        db TSTRIDE, 0

; wait for RUN busy = 0 (a stuck geo3d is given up after about 1 s)
geo_wait:
        ld bc, 0
gw_1:   in a, (GEO_IDX)
        rrca
        ret nc
        dec bc
        ld a, b
        or c
        jr nz, gw_1
        xor a
        ld (st_geo), a
        ret

; ---------------------------------------------------------------- the camera
cam_setup:
        ld a, (p_yaw)
        call sin_a
        ld (cam_fx), hl
        ld (cam_rz), hl
        ld (cambuf + 4), hl         ; M02 = rz
        ld (cambuf + 12), hl        ; M20 = fx
        ld a, (p_yaw)
        add a, 64
        call sin_a                  ; cos yaw
        ld (cam_rx), hl
        ld (cambuf), hl             ; M00 = rx
        call neg_hl
        ld (cam_fz), hl
        ld (cambuf + 16), hl        ; M22 = fz
        ; TX = -(rx px + rz pz)
        ld de, (cam_rx)
        ld bc, (p_x)
        call mulq14
        push hl
        ld de, (cam_rz)
        ld bc, (p_z)
        call mulq14
        pop de
        add hl, de
        call neg_hl
        ld (cambuf + 18), hl
        ; TY = -eye
        ld hl, (p_eye)
        call neg_hl
        ld (cambuf + 20), hl
        ; TZ = -(fx px + fz pz)
        ld de, (cam_fx)
        ld bc, (p_x)
        call mulq14
        push hl
        ld de, (cam_fz)
        ld bc, (p_z)
        call mulq14
        pop de
        add hl, de
        call neg_hl
        ld (cambuf + 22), hl
        ret

; ---------------------------------------------------------------- the map
; B = cx, C = cz -> HL = offset in map_grid / map_cellidx (keeps BC)
grid_ofs:
        ld l, c
        ld h, 0
        add hl, hl
        ld de, map_row
        add hl, de
        ld a, (hl)
        inc hl
        ld h, (hl)
        ld l, a
        ld e, b
        ld d, 0
        add hl, de
        ret

; B = cx, C = cz -> A = wall texture + 1, Z if the cell is free (keeps BC)
wall_at:
        call grid_ofs
        ld de, map_grid
        add hl, de
        ld a, (hl)
        or a
        ret

; B = cx, C = cz -> A = free cell number (FFh: wall) (keeps BC)
cell_at:
        call grid_ofs
        ld de, map_cellidx
        add hl, de
        ld a, (hl)
        ret

; the player's cell; when it changes, its rows of vis_tab and nextstep go
; to RAM (the monsters' logic then needs no bank switch)
cell_update:
        ld a, (p_x + 1)
        ld (p_cx), a
        ld b, a
        ld a, (p_z + 1)
        ld (p_cz), a
        ld c, a
        call cell_at
        ld hl, p_cell
        cp (hl)
        ret z
        ld (hl), a
        ; visrow = vis_tab + VIS_ROW * cell (bank 1)
        ld e, a
        ld d, 0
        ld bc, VIS_ROW
        call mulu16                 ; (DE:HL = cell * row length)
        push hl
        ld de, vis_tab
        add hl, de
        ld de, visrow
        ld bc, VIS_ROW
        ldir
        ; nsrow = nextstep + NS_ROW * cell (bank 2)
        ld a, (p_cell)
        ld e, a
        ld d, 0
        ld bc, NS_ROW
        call mulu16
        ld de, nextstep
        add hl, de
        ld a, 2
        ld (BANK2_SEL), a
        ld de, nsrow
        ld bc, NS_ROW
        ldir
        ld a, 1
        ld (BANK2_SEL), a
        pop hl
        ret

; A = free cell number -> NZ if the player's cell sees it
cell_seen:
        ld c, a
        rrca
        rrca
        rrca
        and 31
        ld e, a
        ld d, 0
        ld hl, visrow
        add hl, de
        ld a, c
        and 7
        ld e, a
        ld a, (hl)
        ld hl, bit_tab
        add hl, de
        and (hl)
        ret
bit_tab:
        db 1, 2, 4, 8, 16, 32, 64, 128

; ---------------------------------------------------------------- static faces
; new cell: the near strips and the far faces; turned too far: the far faces
st_check:
        ld a, (p_cell)
        ld hl, st_cell
        cp (hl)
        jr nz, st_build
        ld a, (p_yaw)
        ld hl, st_yaw
        sub (hl)
        jp p, sc_1
        neg
sc_1:   cp YAW_MARGIN + 1
        ret c
        jp st_far

; The list (bank PVS_BANK0 up): db near count, 2 bytes each: i | j << 2 |
; direction << 4 (corner A, in the 4 x 4 corners around the cell), texture |
; level << 4 ; db far count, 5 bytes each: corner A x, z ; direction |
; texture << 2 | level << 4 | 80h (two halves) ; a0, lim: in view when
; ((yaw - a0) & 255) <= lim.
st_build:
        ld hl, (st_builds)
        inc hl
        ld (st_builds), hl
        ld a, (p_cell)
        ld (st_cell), a
        ld l, a
        ld h, 0
        ld e, l
        ld d, h
        add hl, hl
        add hl, de
        ld de, pvsptr
        add hl, de
        ld a, (hl)
        inc hl
        ld (st_bank), a
        ld e, (hl)
        inc hl
        ld d, (hl)
        ex de, hl                   ; HL -> the list, A = its bank
        ld (BANK2_SEL), a
        ld a, (hl)
        inc hl
        ld (near_n), a
        add a, a
        jr z, sb_1
        ld c, a
        ld b, 0
        ld de, nearbuf
        ldir
sb_1:   ld (st_farp), hl
        ld a, 1
        ld (BANK2_SEL), a
        ; the near strips: vertices and faces from 0
        ld hl, ncorner
        ld b, 16
        ld a, 0xFF
sb_2:   ld (hl), a
        inc hl
        djnz sb_2
        xor a
        ld (st_nv), a
        ld (st_nf), a
        call st_ptrs
        ld a, (near_n)
        or a
        jr z, sb_4
        ld b, a
        ld iy, nearbuf
        ld hl, nwall
sb_3:   push bc
        push hl
        call ns_wall
        pop hl
        ld de, 5
        add hl, de
        inc iy
        inc iy
        pop bc
        djnz sb_3
sb_4:   ld a, (st_nv)
        ld (near_nv), a
        ld a, (st_nf)
        ld (near_nf), a
        ; fall through

; the far faces for this yaw, after the near strips
st_far: ld a, (p_yaw)
        ld (st_yaw), a
        ld hl, cornermap
        ld de, cornermap + 1
        ld bc, CORNERS - 1
        ld (hl), 0xFF
        ldir
        ld a, (near_nv)
        ld (st_nv), a
        ld a, (near_nf)
        ld (st_nf), a
        call st_ptrs
        ld a, (st_bank)
        ld (BANK2_SEL), a
        ld hl, (st_farp)
        ld a, (hl)
        inc hl
        or a
        jr z, sb_done
        ld b, a
        push hl
        pop ix
sb_loop:
        push bc
        ld a, (st_yaw)
        sub (ix + 3)
        ld c, a
        ld a, (ix + 4)
        cp c
        jr c, sb_next               ; lim < yaw - a0: out of view
        ld a, (st_nv)
        cp VMAX_STATIC - 5
        jr nc, sb_stop
        ld a, (st_nf)
        cp FMAX_STATIC - 1
        jr nc, sb_stop
        call sb_face
sb_next:
        ld de, 5
        add ix, de
        pop bc
        djnz sb_loop
        jr sb_done
sb_stop:
        pop bc
sb_done:
        ld a, 1
        ld (BANK2_SEL), a
        ret

; geo3d's write pointers: vertices at st_nv, faces and texture points at st_nf
st_ptrs:
        ld a, 0x40
        out (GEO_IDX), a
        ld a, (st_nv)
        out (GEO_DAT), a            ; VADDR
        ld a, 0x58
        out (GEO_IDX), a
        ld a, (st_nf)
        out (GEO_DAT), a            ; FADDR
        ld a, 0x65
        out (GEO_IDX), a
        ld a, (st_nf)
        out (GEO_DAT), a            ; TADDR
        ret

; IY -> a near entry, HL -> its record in nwall (the top vertices at 0, 64,
; 128, 192 and 256 units along the wall): its two corners (shared with the
; other near walls through ncorner), three pairs inside, four faces
ns_wall:
        ld (nw_ptr), hl
        ld a, (iy + 0)
        and 15
        ld (ne_ia), a
        call ncv_get
        ld hl, (nw_ptr)
        ld (hl), a
        ld a, (iy + 0)
        rrca
        rrca
        rrca
        rrca
        and 3
        ld (ne_dir), a
        ld e, a
        ld d, 0
        ld hl, ncv_ofs
        add hl, de
        ld a, (ne_ia)
        add a, (hl)
        call ncv_get
        ld hl, (nw_ptr)
        ld de, 4
        add hl, de
        ld (hl), a
        call ne_world
        ld hl, 256
        ld (bb_y1), hl
        ld hl, 0
        ld (bb_y0), hl
        ld a, 0x50
        out (GEO_IDX), a
        ld b, 3
        ld hl, (nw_ptr)
nsw_1:  inc hl
        push bc
        push hl
        ld de, 64
        call ne_step
        call vtx_pair
        pop hl
        ld a, (st_nv)
        ld (hl), a
        add a, 2
        ld (st_nv), a
        pop bc
        djnz nsw_1
        ld a, (iy + 1)
        rrca
        rrca
        rrca
        rrca
        and 15
        call ny_get
        ld a, (iy + 1)
        and 3
        rrca
        rrca
        ld (fc_u0), a               ; 64 * texture
        xor a
        ld (fc_v0), a
        ld a, 63
        ld (fc_v1), a
        ld b, 4
        ld hl, (nw_ptr)
nsw_2:  push bc
        ld a, (hl)
        ld (fc_a), a
        inc hl
        ld a, (hl)
        ld (fc_b), a
        push hl
        ld a, (fc_u0)
        add a, 15
        ld (fc_u1), a
        call face_out
        ld a, (fc_u0)
        add a, 16
        ld (fc_u0), a
        ld hl, st_nf
        inc (hl)
        pop hl
        pop bc
        djnz nsw_2
        ret

ncv_ofs: db 1, 255, 4, 252           ; corner B in ncorner: +x, -x, +z, -z

; A = i + 4 j, a corner around the cell -> A = its top vertex (new ones go
; to geo3d)
ncv_get: ld e, a
        ld d, 0
        ld hl, ncorner
        add hl, de
        ld a, (hl)
        cp 0xFF
        ret nz
        ld a, (st_nv)
        ld (hl), a
        add a, 2
        ld (st_nv), a
        ld a, e
        and 3
        ld b, a
        ld a, (p_cx)
        dec a
        add a, b
        ld b, a
        ld a, e
        rrca
        rrca
        and 3
        ld c, a
        ld a, (p_cz)
        dec a
        add a, c
        ld c, a
        ld e, (hl)
        jp cv_emit

; IY -> a near entry: corner A in the world -> ne_ax, ne_az, ne_vx, ne_vz
ne_world:
        ld a, (iy + 0)
        and 3
        ld b, a
        ld a, (p_cx)
        dec a
        add a, b
        ld h, a
        ld l, 0
        ld (ne_ax), hl
        ld (ne_vx), hl
        ld a, (iy + 0)
        rrca
        rrca
        and 3
        ld b, a
        ld a, (p_cz)
        dec a
        add a, b
        ld h, a
        ld l, 0
        ld (ne_az), hl
        ld (ne_vz), hl
        ret

; (ne_vx, ne_vz) += DE units along the wall (ne_dir)
ne_step:
        ld a, (ne_dir)
        or a
        jr z, nst_px
        dec a
        jr z, nst_mx
        dec a
        jr z, nst_pz
        ld hl, (ne_vz)
        or a
        sbc hl, de
        ld (ne_vz), hl
        ret
nst_px: ld hl, (ne_vx)
        add hl, de
        ld (ne_vx), hl
        ret
nst_mx: ld hl, (ne_vx)
        or a
        sbc hl, de
        ld (ne_vx), hl
        ret
nst_pz: ld hl, (ne_vz)
        add hl, de
        ld (ne_vz), hl
        ret

; IX -> a far entry: its two corners' vertices (new ones go to geo3d), the
; face and its texture points
sb_face:
        ld b, (ix + 0)
        ld c, (ix + 1)
        call corner_vtx
        ld (fc_a), a
        ld b, (ix + 0)
        ld c, (ix + 1)
        ld a, (ix + 2)
        and 3
        jr z, sf_px
        dec a
        jr z, sf_mx
        dec a
        jr z, sf_pz
        dec c
        jr sf_b
sf_px:  inc b
        jr sf_b
sf_mx:  dec b
        jr sf_b
sf_pz:  inc c
sf_b:   call corner_vtx
        ld (fc_b), a
        ld a, (ix + 2)
        rrca
        rrca
        rrca
        rrca
        and 7
        call ny_get
        ld a, (ix + 2)
        and 0x0C
        rlca
        rlca
        rlca
        rlca                        ; texture * 64
        ld (fc_u0), a
        add a, 63
        ld (fc_u1), a
        xor a
        ld (fc_v0), a
        ld a, 63
        ld (fc_v1), a
        bit 7, (ix + 2)
        jr nz, sf_two
        call face_out
        ld hl, st_nf
        inc (hl)
        ret
; two halves: a pair of vertices in the middle of the wall
sf_two: ld h, (ix + 0)
        ld l, 0
        ld (ne_vx), hl
        ld h, (ix + 1)
        ld (ne_vz), hl
        ld de, 128
        ld a, (ix + 2)
        and 3
        jr z, st_px
        dec a
        jr z, st_mx
        dec a
        jr z, st_pz
        ld hl, (ne_vz)
        or a
        sbc hl, de
        ld (ne_vz), hl
        jr st_m
st_px:  ld hl, (ne_vx)
        add hl, de
        ld (ne_vx), hl
        jr st_m
st_mx:  ld hl, (ne_vx)
        or a
        sbc hl, de
        ld (ne_vx), hl
        jr st_m
st_pz:  ld hl, (ne_vz)
        add hl, de
        ld (ne_vz), hl
st_m:   ld hl, 256
        ld (bb_y1), hl
        ld hl, 0
        ld (bb_y0), hl
        ld a, 0x50
        out (GEO_IDX), a
        call vtx_pair
        ld a, (fc_b)
        ld (tmp), a                 ; corner B
        ld a, (st_nv)
        ld (fc_b), a                ; the middle
        add a, 2
        ld (st_nv), a
        ld a, (fc_u0)
        add a, 31
        ld (fc_u1), a
        call face_out               ; A .. middle: u 0..31
        ld a, (fc_b)
        ld (fc_a), a
        ld a, (tmp)
        ld (fc_b), a
        ld a, (fc_u0)
        add a, 32
        ld (fc_u0), a
        add a, 31
        ld (fc_u1), a
        call face_out               ; middle .. B: u 32..63
        ld hl, st_nf
        inc (hl)
        inc (hl)
        ret

; A = light level -> fc_ny
ny_get: add a, a
        ld e, a
        ld d, 0
        ld hl, ny_tab
        add hl, de
        ld a, (hl)
        inc hl
        ld h, (hl)
        ld l, a
        ld (fc_ny), hl
        ret

; B = corner x, C = corner z -> A = its top vertex (a new pair goes to geo3d)
corner_vtx:
        ld l, c
        ld h, 0
        add hl, hl
        ld de, corner_row
        add hl, de
        ld a, (hl)
        inc hl
        ld h, (hl)
        ld l, a
        ld e, b
        ld d, 0
        add hl, de
        ld de, cornermap
        add hl, de
        ld a, (hl)
        cp 0xFF
        ret nz
        ld a, (st_nv)
        ld (hl), a
        ld e, a
        add a, 2
        ld (st_nv), a
; B = corner x, C = corner z, E = vertex: the pair goes to geo3d -> A = E
cv_emit:
        ld a, 0x50
        out (GEO_IDX), a
        xor a
        out (GEO_DAT), a            ; x = 256 * B
        ld a, b
        out (GEO_DAT), a
        xor a
        out (GEO_DAT), a            ; y = 256 (WALL_H)
        inc a
        out (GEO_DAT), a
        xor a
        out (GEO_DAT), a            ; z = 256 * C
        ld a, c
        out (GEO_DAT), a
        xor a
        out (GEO_DAT), a
        ld a, b
        out (GEO_DAT), a
        xor a
        out (GEO_DAT), a            ; y = 0
        out (GEO_DAT), a
        out (GEO_DAT), a
        ld a, c
        out (GEO_DAT), a
        ld a, e
        ret

; the face (fc_a, fc_b, fc_b + 1, fc_a + 1), normal (0, fc_ny, 0), textured,
; and its texture points (fc_u0, fc_v0) .. (fc_u1, fc_v1)
face_out:
        ld a, 0x52
        out (GEO_IDX), a
        ld a, (fc_a)
        out (GEO_DAT), a
        ld a, (fc_b)
        out (GEO_DAT), a
        inc a
        out (GEO_DAT), a
        ld a, (fc_a)
        inc a
        out (GEO_DAT), a
        xor a
        out (GEO_DAT), a
        out (GEO_DAT), a            ; NX
        ld a, (fc_ny)
        out (GEO_DAT), a
        ld a, (fc_ny + 1)
        out (GEO_DAT), a            ; NY
        xor a
        out (GEO_DAT), a
        out (GEO_DAT), a            ; NZ
        ld a, 0x80
        out (GEO_DAT), a            ; BASE: textured
        ld a, 0x53
        out (GEO_IDX), a
        ld a, (fc_u0)
        out (GEO_DAT), a
        ld a, (fc_v0)
        out (GEO_DAT), a
        ld a, (fc_u1)
        out (GEO_DAT), a
        ld a, (fc_v0)
        out (GEO_DAT), a
        ld a, (fc_u1)
        out (GEO_DAT), a
        ld a, (fc_v1)
        out (GEO_DAT), a
        ld a, (fc_u0)
        out (GEO_DAT), a
        ld a, (fc_v1)
        out (GEO_DAT), a
        ret

; ---------------------------------------------------------------- near faces
; zgrid[i + 4 j] = 32 * camera Z of the grid corner (cx - 1 + i, cz - 1 + j):
; two multiplies for the first one, then adds (a cell east adds fx / 2, a
; cell south fz / 2).
near_emit:
        ld a, (p_x)
        ld l, a
        ld h, 1                     ; 256 + the fraction of x
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        call neg_hl
        ex de, hl                   ; DE = 32 * (corner x - player x)
        ld bc, (cam_fx)
        call mulq14
        push hl
        ld a, (p_z)
        ld l, a
        ld h, 1
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        call neg_hl
        ex de, hl
        ld bc, (cam_fz)
        call mulq14
        pop de
        add hl, de
        ld (ne_row), hl
        ld hl, (cam_fx)
        sra h
        rr l
        ld (ne_sx), hl
        ld hl, (cam_fz)
        sra h
        rr l
        ld (ne_sz), hl
        ld ix, zgrid
        ld c, 4
gf_j:   ld hl, (ne_row)
        ld de, (ne_sx)
        ld b, 4
gf_i:   ld (ix + 0), l
        ld (ix + 1), h
        inc ix
        inc ix
        add hl, de
        djnz gf_i
        ld hl, (ne_row)
        ld de, (ne_sz)
        add hl, de
        ld (ne_row), hl
        dec c
        jr nz, gf_j
        ; this frame's vertices and faces go after the static ones
        call st_ptrs
        ld a, (st_nv)
        ld (dn_v), a
        ld a, (st_nf)
        ld (dn_f), a
        ld a, (near_n)
        or a
        ret z
        ld b, a
        ld iy, nearbuf
        ld hl, nwall
ne_loop:
        push bc
        push hl
        ld (nw_ptr), hl
        call ne_wall
        pop hl
        ld de, 5
        add hl, de
        inc iy
        inc iy
        pop bc
        djnz ne_loop
        ret

ne_ofs: db 2, 254, 8, 248           ; corner B in zgrid: +x, -x, +z, -z

; HL -> grid, A = byte offset -> HL = the word there
grid_get:
        ld e, a
        ld d, 0
        add hl, de
        ld a, (hl)
        inc hl
        ld h, (hl)
        ld l, a
        ret

; IY -> a near entry, nw_ptr -> its record: if the wall crosses Z = ZCLIP,
; the face from the crossing to the end of the strip it falls in
ne_wall:
        ld a, (iy + 0)
        and 15
        add a, a
        ld (ne_ia), a
        ld hl, zgrid
        call grid_get
        ld (ne_za), hl
        ld a, (iy + 0)
        rrca
        rrca
        rrca
        rrca
        and 3
        ld (ne_dir), a
        ld e, a
        ld d, 0
        ld hl, ne_ofs
        add hl, de
        ld a, (ne_ia)
        add a, (hl)
        ld hl, zgrid
        call grid_get
        ld (ne_zb), hl
        ; which ends are behind the cut plane (bit 7 of Z - ZCLIP32)
        ld de, 0 - ZCLIP32
        add hl, de
        ld a, h
        and 0x80
        ld b, a
        ld hl, (ne_za)
        add hl, de
        ld a, h
        and 0x80
        ld c, a
        xor b
        ret z                       ; all in front, or all behind
        ld a, (dn_v)
        cp 254
        ret nc
        ld a, (dn_f)
        cp 255
        ret nc
        push bc
        call ne_world
        ld a, (iy + 1)
        rrca
        rrca
        rrca
        rrca
        and 15
        call ny_get
        ld a, (iy + 1)
        and 3
        rrca
        rrca
        ld (ne_u), a
        xor a
        ld (fc_v0), a
        ld a, 63
        ld (fc_v1), a
        ld hl, 256
        ld (bb_y1), hl
        ld hl, 0
        ld (bb_y0), hl
        pop bc
        ld a, c
        or a
        jr z, nw_b
        ; A behind: the wall shows from o = frac(ZCLIP - za, zb - za) + 1 on
        ld hl, (ne_zb)
        ld de, (ne_za)
        or a
        sbc hl, de
        push hl
        ld hl, ZCLIP32
        or a
        sbc hl, de
        pop de
        call frac8
        inc a
        ret z                       ; nothing left
        ld (ne_o), a
        ld e, a
        ld d, 0
        call ne_step
        ld a, 0x50
        out (GEO_IDX), a
        call vtx_pair
        ld a, (dn_v)
        ld (fc_a), a                ; the crossing ..
        add a, 2
        ld (dn_v), a
        ld a, (ne_o)
        rlca
        rlca
        and 3
        ld c, a                     ; the strip: o / 64
        ld hl, (nw_ptr)
        ld e, a
        ld d, 0
        add hl, de
        inc hl
        ld a, (hl)
        ld (fc_b), a                ; .. to the strip's far end
        ld a, (ne_o)
        srl a
        srl a
        ld b, a
        ld a, (ne_u)
        add a, b
        ld (fc_u0), a
        ld a, c
        add a, a
        add a, a
        add a, a
        add a, a
        add a, 15
        ld b, a
        ld a, (ne_u)
        add a, b
        ld (fc_u1), a
        jr nw_f
nw_b:   ; B behind: it shows up to e = 255 - frac(ZCLIP - zb, za - zb)
        ld hl, (ne_za)
        ld de, (ne_zb)
        or a
        sbc hl, de
        push hl
        ld hl, ZCLIP32
        or a
        sbc hl, de
        pop de
        call frac8
        cpl
        or a
        ret z
        ld (ne_o), a
        ld e, a
        ld d, 0
        call ne_step
        ld a, 0x50
        out (GEO_IDX), a
        call vtx_pair
        ld a, (dn_v)
        ld (fc_b), a                ; .. to the crossing
        add a, 2
        ld (dn_v), a
        ld a, (ne_o)
        dec a
        ld b, a
        rlca
        rlca
        and 3
        ld c, a                     ; the strip: (e - 1) / 64
        ld hl, (nw_ptr)
        ld e, a
        ld d, 0
        add hl, de
        ld a, (hl)
        ld (fc_a), a                ; from the strip's near end ..
        ld a, c
        add a, a
        add a, a
        add a, a
        add a, a
        ld d, a
        ld a, (ne_u)
        add a, d
        ld (fc_u0), a
        ld a, b
        srl a
        srl a
        ld d, a
        ld a, (ne_u)
        add a, d
        ld (fc_u1), a
nw_f:   call face_out
        ld hl, dn_f
        inc (hl)
        ret

; (ne_vx, bb_y1, ne_vz) and (ne_vx, bb_y0, ne_vz) -> the vertex stream
; (index 50h already selected)
vtx_pair:
        ld hl, (ne_vx)
        ld de, (ne_vz)
        ld c, GEO_DAT
        out (c), l
        out (c), h
        ld a, (bb_y1)
        out (c), a
        ld a, (bb_y1 + 1)
        out (c), a
        out (c), e
        out (c), d
        out (c), l
        out (c), h
        ld a, (bb_y0)
        out (c), a
        ld a, (bb_y0 + 1)
        out (c), a
        out (c), e
        out (c), d
        ret

; ---------------------------------------------------------------- billboards
; A = frame (frame_tab), DE = x, HL = z: a face turned to the camera
bb_emit:
        ld (bb_x), de
        ld (bb_z), hl
        ld b, a
        ld a, (dn_v)
        cp 252
        ret nc
        ld a, (dn_f)
        cp 255
        ret nc
        ld l, b
        ld h, 0
        add hl, hl
        add hl, hl
        ld e, l
        ld d, h
        add hl, hl
        add hl, de                  ; 12 bytes a frame
        ld de, frame_tab
        add hl, de
        push hl
        pop ix
        ld a, (ix + 0)
        ld (fc_u0), a
        add a, (ix + 2)
        ld (fc_u1), a
        ld a, (ix + 1)
        ld (fc_v0), a
        add a, (ix + 3)
        ld (fc_v1), a
        ld l, (ix + 4)
        ld h, (ix + 5)
        ld (fc_ny), hl
        ld l, (ix + 8)
        ld h, (ix + 9)
        ld (bb_y0), hl
        ld l, (ix + 10)
        ld h, (ix + 11)
        ld (bb_y1), hl
        ld e, (ix + 6)
        ld d, (ix + 7)              ; half the width
        ld hl, (bb_hw)
        or a
        sbc hl, de
        jr z, bb_1                  ; the same as the last one this frame
        ld (bb_hw), de
        push de
        ld bc, (cam_rx)
        call mulq14
        ld (bb_ox), hl
        pop de
        ld bc, (cam_rz)
        call mulq14
        ld (bb_oz), hl
bb_1:   ld a, 0x50
        out (GEO_IDX), a
        ld hl, (bb_x)
        ld de, (bb_ox)
        or a
        sbc hl, de
        ld (ne_vx), hl
        ld hl, (bb_z)
        ld de, (bb_oz)
        or a
        sbc hl, de
        ld (ne_vz), hl
        call vtx_pair               ; the left side
        ld hl, (bb_x)
        ld de, (bb_ox)
        add hl, de
        ld (ne_vx), hl
        ld hl, (bb_z)
        ld de, (bb_oz)
        add hl, de
        ld (ne_vz), hl
        call vtx_pair               ; the right side
        ld a, (dn_v)
        ld (fc_a), a
        add a, 2
        ld (fc_b), a
        add a, 2
        ld (dn_v), a
        call face_out
        ld hl, dn_f
        inc (hl)
        ret

; ---------------------------------------------------------------- RUN
; the counts, the page, the camera, RUN (faces, textures)
geo_run:
        ld a, 0x42
        out (GEO_IDX), a
        ld a, (dn_v)
        out (GEO_DAT), a            ; NVERT
        ld (st_nvert), a
        ld a, 0x59
        out (GEO_IDX), a
        ld a, (dn_f)
        out (GEO_DAT), a            ; NFACE
        ld (st_nface), a
        ld a, 0x46
        out (GEO_IDX), a
        xor a
        out (GEO_DAT), a
        ld a, (buf)
        out (GEO_DAT), a            ; YPAGE = 256 * buf
        xor a
        out (GEO_IDX), a
        ld hl, cambuf
        ld bc, 24 * 256 + GEO_DAT
        otir
        ld a, 0x48
        out (GEO_IDX), a
        ld a, 7
        out (GEO_DAT), a
        ret

; ---------------------------------------------------------------- background
; the ceiling and the floor: NBANDS fills of the hidden page, their 11
; command bytes (R#36..R#46) ready in bg_cmds for each page
bg_draw:
        ld hl, bg_cmds
        ld a, (buf)
        or a
        jr z, bg_0
        ld hl, bg_cmds + NBANDS * 11
bg_0:   ld b, NBANDS
bg_1:   push bc
        push hl
        call wait_ce
        ld a, 36
        ld b, 17
        call wreg
        pop hl
        ld bc, 11 * 256 + VDP_IND
        otir
        pop bc
        djnz bg_1
        ret

; ---------------------------------------------------------------- overlays
; over the 3D picture, from the texture area with TIMP: the muzzle flash,
; the pistol (lower when it recoils, bobs or the player is dead), the
; crosshair
ov_draw:
        ld a, (g_state)
        cp 1
        jr z, ov_gun                ; dead: no flash, no crosshair
        ld a, (muzzle_t)
        or a
        jr z, ov_gun
        ld hl, FLASH_U
        ld (cmd_sx), hl
        ld hl, FLASH_V
        ld (cmd_sy), hl
        ld hl, 112
        ld (cmd_dx), hl
        ld a, (buf)
        ld h, a
        ld l, 92
        ld (cmd_dy), hl
        ld hl, 32
        ld (cmd_nx), hl
        ld (cmd_ny), hl
        call ov_copy
ov_gun: ld a, (gun_y)
        cp 68
        jr nc, ov_cross             ; out of sight
        ld hl, PISTOL_U
        ld (cmd_sx), hl
        ld hl, PISTOL_V
        ld (cmd_sy), hl
        ld a, (gun_x)
        ld l, a
        ld h, 0
        ld (cmd_dx), hl
        ld a, (gun_y)
        add a, G3_H - 68
        ld l, a
        ld a, (buf)
        ld h, a
        ld (cmd_dy), hl
        ld hl, 64
        ld (cmd_nx), hl
        ld a, (gun_y)
        ld b, a
        ld a, 68
        sub b
        ld l, a
        ld h, 0
        ld (cmd_ny), hl
        call ov_copy
ov_cross:
        ld a, (g_state)
        or a
        ret nz
        ld hl, 240
        ld (cmd_sx), hl
        ld hl, TEXY + 384
        ld (cmd_sy), hl
        ld hl, G3_CX - 4
        ld (cmd_dx), hl
        ld a, (buf)
        ld h, a
        ld l, G3_CY - 4
        ld (cmd_dy), hl
        ld hl, 9
        ld (cmd_nx), hl
        ld (cmd_ny), hl
        ; fall through
ov_copy:
        xor a
        ld (cmd_clr), a
        ld (cmd_arg), a
        ld a, LMMM + TIMP
        ld (cmd_op), a
        jp cmd_all

; ---------------------------------------------------------------- the flip
; flip_ask: show the page just drawn at the next vertical blank. flip_sync:
; wait for that and take the other page for drawing. Between the two the
; Z80 may do anything but draw (Wolfenstein 3D never waits for the screen:
; it has a third page; here the next frame's geometry is worked out).
flip:   call flip_ask
        ; fall through
flip_sync:
        ld a, (flip_pend)
        or a
        ret z
        xor a
        ld (flip_pend), a
        ld bc, 0                    ; (no interrupt in about 1 s: flip here)
fl_1:   ld a, (flip_req)
        or a
        jr z, fl_2
        dec bc
        ld a, b
        or c
        jr nz, fl_1
        ld (flip_req), a
        ld a, (flip_r2)
        ld b, 2
        call wreg
        jr fl_2
flip_ask:
        call wait_ce
        ld a, (buf)
        rrca
        rrca
        rrca
        or 0x1F
        ld (flip_r2), a
        ld a, 1
        ld (flip_pend), a
        ld (flip_req), a
        ret
fl_2:   ld a, (buf)
        xor 1
        ld (buf), a
        ret
