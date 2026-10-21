# run.tcl - openMSX driver for the MSX DOOM tests (started by tests/run_tests.sh)
#
# Env: LABELS (Tcl file: set ::A(name) addr, from the assembler's label list),
#      OUTDIR, SHOT (1: a window, real time and screenshots),
#      VDPNAME ("VDP" on 98h, "V9968" on the 88h profile),
#      SCRIPT: steps separated by ";"
#   start             leave the title screen (holds the trigger for a moment)
#   freeze N          dbg_freeze: 1 = no input, no monster logic
#   pose X Z YAW      put the player there (cells, 1/256 turn), reload the faces
#   keys MASK         hold keys through dbg_in: 1 up 2 down 4 left 8 right
#                     16 fire 32 strafe left 64 strafe right 128 RETURN
#   frames N          wait until the game has shown N more frames
#   wait SECONDS      emulated seconds
#   dump NAME         the page on show -> NAME.bin (256 x 212 bytes), log POSE
#   shot NAME         screenshot NAME.png (with SHOT=1)
#   poke LABEL VALUE  a byte of RAM; poke16 for a word
#   expect LABEL OP VALUE   log "E PASS|FAIL ..." (a byte; expect16 for a word)
#   psg REG OP VALUE        the same for a PSG register
#   prof SECONDS      time between the steps of a frame, average and worst
#   log TEXT
# Log (log.txt): "<time> <event>" lines; "END" last.
set throttle off
set mute on
set ::shots [expr {[info exists ::env(SHOT)] && $::env(SHOT) eq "1"}]
if {!$::shots} { set renderer none }

source $::env(LABELS)
set ::dir $::env(OUTDIR)
set ::vdp VDP
if {[info exists ::env(VDPNAME)] && $::env(VDPNAME) ne ""} { set ::vdp $::env(VDPNAME) }
set ::log [open "$::dir/log.txt" w]
fconfigure $::log -buffering line

proc t {} { format %.3f [machine_info time] }
proc rd {name {o 0}} { debug read memory [expr {$::A($name) + $o}] }
proc rd16 {name {o 0}} { expr {[rd $name $o] | ([rd $name [expr {$o + 1}]] << 8)} }
proc wr {name v {o 0}} { debug write memory [expr {$::A($name) + $o}] [expr {$v & 255}] }
proc wr16 {name v} { wr $name $v; wr $name [expr {$v >> 8}] 1 }
proc say {s} { puts $::log "[t] $s" }
proc finish {} { say END; close $::log; exit }

proc status {} {
  set s "frames=[rd16 st_frames] ticks=[rd st_ticks] nvert=[rd st_nvert] nface=[rd st_nface]"
  append s " builds=[rd16 st_builds] state=[rd g_state] hp=[rd p_hp] kills=[rd kills]"
  append s " x=[rd16 p_x] z=[rd16 p_z] yaw=[rd p_yaw] cell=[rd p_cell]"
  return $s
}

# the page on show -> file (256 x 212 bytes, SCREEN 8). The fork's "physical
# VRAM" keeps SCREEN 8 interleaved: logical address a is at (a >> 1) | ((a & 1) << 16).
proc dump_page {name} {
  set page [expr {([debug read "$::vdp regs" 2] >> 5) & 1}]
  set f [open "$::dir/$name.bin" wb]
  fconfigure $f -translation binary
  if {$::vdp eq "VDP"} {
    puts -nonewline $f [debug read_block VRAM [expr {$page * 65536}] 54272]
  } else {
    set even [debug read_block "physical $::vdp VRAM" [expr {$page * 32768}] 27136]
    set odd [debug read_block "physical $::vdp VRAM" [expr {65536 + $page * 32768}] 27136]
    binary scan $even c* e
    binary scan $odd c* o
    set out {}
    foreach a $e b $o { lappend out $a $b }
    puts -nonewline $f [binary format c* $out]
  }
  close $f
}

proc af_poll {} {
  set d [expr {([rd16 st_frames] - $::af_target) & 0xFFFF}]
  if {$d < 0x8000} { step_next } else { after time 0.02 af_poll }
}

proc step_next {} {
  if {$::step_i >= [llength $::steps]} { finish; return }
  set st [string trim [lindex $::steps $::step_i]]
  incr ::step_i
  set a [lassign $st cmd]
  switch -- $cmd {
    start   { wr dbg_in 0x10; after time 0.3 { wr dbg_in 0; after time 0.6 step_next } }
    freeze  { wr dbg_freeze [lindex $a 0]; step_next }
    pose    {
      lassign $a x z yaw
      wr16 p_x [expr {int($x * 256)}]
      wr16 p_z [expr {int($z * 256)}]
      wr p_yaw $yaw
      wr p_yawf 0
      wr st_cell 255
      step_next
    }
    keys    { wr dbg_in [lindex $a 0]; step_next }
    frames  {
      set ::af_target [expr {([rd16 st_frames] + [lindex $a 0]) & 0xFFFF}]
      af_poll
    }
    wait    { after time [lindex $a 0] step_next }
    dump    { dump_page [lindex $a 0]; say "POSE [lindex $a 0] [status]"; step_next }
    shot    { if {$::shots} { catch {screenshot "$::dir/[lindex $a 0].png"} }; step_next }
    poke    { wr [lindex $a 0] [lindex $a 1]; step_next }
    poke16  { wr16 [lindex $a 0] [lindex $a 1]; step_next }
    expect  -
    expect16 {
      lassign $a name op val
      set got [expr {$cmd eq "expect" ? [rd $name] : [rd16 $name]}]
      say "E [expr {[expr "$got $op $val"] ? "PASS" : "FAIL"}] $name = $got (want $op $val)"
      step_next
    }
    psg     {
      lassign $a reg op val
      set got [debug read "PSG regs" $reg]
      say "E [expr {[expr "$got $op $val"] ? "PASS" : "FAIL"}] PSG R#$reg = $got (want $op $val)"
      step_next
    }
    log     { say "L $a [status]"; step_next }
    prof    { prof_start; after time [lindex $a 0] { prof_stop; step_next } }
    ""      { step_next }
    default { say "E FAIL unknown step: $st"; step_next }
  }
}

# prof SECONDS: emulated time between the steps of a frame (breakpoints at
# the routines frame calls), average and worst, in milliseconds
set ::prof_marks {frame cell_update cam_setup near_emit sprites_emit flip_sync bg_draw geo_run logic player_update enemies_update enemies_apart items_update gun_update geo_wait ov_draw hud_update flip_ask}
proc prof_start {} {
  set ::prof_bp {}
  set ::prof_last -1
  set ::prof_lastname ""
  array unset ::prof_sum
  array unset ::prof_max
  set ::prof_n 0
  set ::prof_f0 -1
  set ::prof_fsum 0
  set ::prof_fmax 0
  foreach m $::prof_marks {
    lappend ::prof_bp [debug set_bp $::A($m) {} "prof_hit $m"]
  }
}
proc prof_hit {m} {
  set now [machine_info time]
  if {$m eq "frame"} {
    if {$::prof_f0 >= 0} {
      set d [expr {$now - $::prof_f0}]
      set ::prof_fsum [expr {$::prof_fsum + $d}]
      if {$d > $::prof_fmax} { set ::prof_fmax $d }
      incr ::prof_n
    }
    set ::prof_f0 $now
  }
  if {$::prof_last >= 0 && $::prof_f0 >= 0} {
    set k $::prof_lastname
    set d [expr {$now - $::prof_last}]
    if {![info exists ::prof_sum($k)]} { set ::prof_sum($k) 0; set ::prof_max($k) 0 }
    set ::prof_sum($k) [expr {$::prof_sum($k) + $d}]
    if {$d > $::prof_max($k)} { set ::prof_max($k) $d }
  }
  set ::prof_last $now
  set ::prof_lastname $m
}
proc prof_stop {} {
  foreach b $::prof_bp { debug remove_bp $b }
  if {$::prof_n == 0} { say "PROF no frames"; return }
  say [format "PROF frames=%d frame avg=%.1f ms max=%.1f ms (%.1f fps)" $::prof_n        [expr {1000.0 * $::prof_fsum / $::prof_n}] [expr {1000.0 * $::prof_fmax}] [expr {$::prof_n / $::prof_fsum}]]
  foreach m $::prof_marks {
    if {[info exists ::prof_sum($m)]} {
      say [format "PROF   %-13s avg=%6.2f ms max=%6.2f ms" $m [expr {1000.0 * $::prof_sum($m) / $::prof_n}] [expr {1000.0 * $::prof_max($m)}]]
    }
  }
}

proc status_loop {} {
  say "S [status]"
  after time 1 status_loop
}

# the BIOS logo, the texture upload and the title take about 5 emulated seconds
after time 7 {
  say "BOOT [status]"
  status_loop
  if {$::shots} { set throttle on }
  set ::steps [split $::env(SCRIPT) ";"]
  set ::step_i 0
  step_next
}
after time 600 finish
