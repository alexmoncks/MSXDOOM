; ============================================================================
; ram.asm - the RAM map (C000h up; the init clears C000h-E7FFh)
; ============================================================================
        org 0xC000
ram_start:
eiop:       ds 2            ; EI, RET (NOP, RET during init)
vcount:     ds 2            ; vertical blanks (interrupt handler)
flip_req:   ds 1            ; 1: show flip_r2 at the next blank
flip_r2:    ds 1
flip_pend:  ds 1            ; 1: a page was asked for and buf not swapped yet
in_cur:     ds 1            ; IN_* bits
dbg_in:     ds 1            ; tests: keys held from outside
dbg_freeze: ds 1            ; tests: 1 = no input, no monster logic, no bobbing
buf:        ds 1            ; the hidden page, being drawn (0, 1)
pal_cur:    ds 1
st_geo:     ds 1            ; 0: geo3d did not answer in time
rnd:        ds 2
sv_ptr:     ds 4            ; the two sound voices
psg_mix:    ds 1
txt_font:   ds 2
txt_page:   ds 1
txt_fg:     ds 1
txt_bg:     ds 1
txt_scale:  ds 1
tx_str:     ds 2
tx_xy:      ds 2            ; x, y
tx_row:     ds 1
hud_f:      ds 1
hud_w:      ds 1

; ---- VDP command buffer: R#32..R#46
cmdbuf:
cmd_sx:     ds 2
cmd_sy:     ds 2
cmd_dx:     ds 2
cmd_dy:     ds 2
cmd_nx:     ds 2
cmd_ny:     ds 2
cmd_clr:    ds 1
cmd_arg:    ds 1
cmd_op:     ds 1

; ---- the player and the camera
p_x:        ds 2            ; 256 units a cell
p_z:        ds 2
p_yawf:     ds 1            ; fraction of p_yaw
p_yaw:      ds 1            ; 1/256 turn: 0 north (-z), 64 east (+x)
p_eye:      ds 2
p_cx:       ds 1
p_cz:       ds 1
p_cell:     ds 1            ; free cell number
p_hp:       ds 1
cam_fx:     ds 2            ; forward and right vectors, Q2.14
cam_fz:     ds 2
cam_rx:     ds 2
cam_rz:     ds 2
cambuf:     ds 24           ; geo3d index 00h: M00..M22, TX, TY, TZ

; ---- the geometry in geo3d
st_cell:    ds 1            ; the far faces loaded: for this cell (FFh: none)
st_yaw:     ds 1            ; and this yaw
st_nv:      ds 1            ; the static vertices and faces: near strips, then far faces
st_nf:      ds 1
near_nv:    ds 1            ; the near strips' share of them
near_nf:    ds 1
st_bank:    ds 1            ; the cell's list: its bank, its far part
st_farp:    ds 2
ncorner:    ds 16           ; corner around the cell (i + 4 j) -> its top vertex
nwall:      ds 160          ; per near wall: the top vertices at 0, 64, 128, 192, 256
nw_ptr:     ds 2
dn_v:       ds 1            ; the frame's vertices and faces (far + near + billboards)
dn_f:       ds 1
near_n:     ds 1
far_n:      ds 1
nearbuf:    ds 64           ; the cell's near entries (2 bytes each)
visrow:     ds 32           ; the cell's row of vis_tab
nsrow:      ds 64           ; the cell's row of nextstep
cornermap:  ds CORNERS      ; grid corner -> its top vertex (FFh: none yet)
zgrid:      ds 32           ; Z * 32 of the 4 x 4 corners around the player
ne_ia:      ds 1
tmp:        ds 8
ne_row:     ds 2
ne_sx:      ds 2
ne_sz:      ds 2
ne_pa:      ds 2
ne_za:      ds 2
ne_zb:      ds 2
ne_dir:     ds 1
ne_o:       ds 2
ne_e:       ds 2
ne_cut:     ds 10
ne_nc:      ds 1
ne_ax:      ds 2
ne_az:      ds 2
ne_vx:      ds 2
ne_vz:      ds 2
ne_u:       ds 1
fc_a:       ds 1            ; a face: top vertices (the bottom ones follow them)
fc_b:       ds 1
fc_ny:      ds 2
fc_u0:      ds 1
fc_u1:      ds 1
fc_v0:      ds 1
fc_v1:      ds 1
bb_x:       ds 2
bb_z:       ds 2
bb_hw:      ds 2            ; the half width bb_ox, bb_oz are for (0: none)
bb_ox:      ds 2
bb_oz:      ds 2
bb_y0:      ds 2
bb_y1:      ds 2

; ---- the game (game_init clears from here to ram_end)
g_state:    ds 1            ; 0 playing, 1 dead, 2 won
g_end:      ds 1            ; ticks since the end
dt:         ds 1            ; ticks (1/60 s) the last frame took, 1..8
frm_v0:     ds 2
fire_cd:    ds 1            ; seven timers, run down by logic: this order
muzzle_t:   ds 1
recoil:     ds 1
hurt_t:     ds 1
pick_t:     ds 1
msg_t:      ds 1
puff_t:     ds 1
msg_id:     ds 1
puff_x:     ds 2
puff_z:     ds 2
bob:        ds 1
moving:     ds 1
gun_x:      ds 1
gun_y:      ds 1
kills:      ds 1
hud_dirty:  ds 1            ; old fields (HF_*): page 0's in bits 0-2, page 1's in bits 4-6
hud_full:   ds 1            ; bit n: page n has no status bar yet
mv_fx:      ds 2
mv_fz:      ds 2
mv_s:       ds 1
mv_fs:      ds 2            ; forward, right (1, 0, -1)
mv_x:       ds 2
mv_z:       ds 2
bk_x:       ds 2
bk_z:       ds 2
bk_r:       ds 1
bk_c:       ds 4            ; cx0, cx1, cz0, cz1
sh_x:       ds 2
sh_z:       ds 2
sh_sx:      ds 2
sh_sz:      ds 2
sh_wall:    ds 2
sh_best:    ds 2
sh_hit:     ds 2
en_d:       ds 2
en_tx:      ds 2
en_tz:      ds 2
en_step:    ds 1
en_awake:   ds 1            ; a monster left the idle state: they may bump into each other
numbuf:     ds 6
st_frames:  ds 2            ; statistics, read by the tests
st_ticks:   ds 1
st_nvert:   ds 1
st_nface:   ds 1
st_builds:  ds 2

EN_TYPE:     equ 0           ; 0 fiend, 1 zombie
EN_STATE:    equ 1
EN_X:        equ 2
EN_Z:        equ 4
EN_HP:       equ 6
EN_T:        equ 7           ; ticks in this state
EN_ANIM:     equ 8
EN_FRAME:    equ 9
EN_FLAGS:    equ 10          ; bit 0 struck, bit 1 walk frame
EN_CELL:     equ 11
EN_SIZE:     equ 16
enemies:    ds NENEMY * EN_SIZE
IT_X:        equ 0
IT_Z:        equ 2
IT_TAKEN:    equ 4
IT_SIZE:     equ 5
items:      ds NITEM * IT_SIZE
ram_end:
