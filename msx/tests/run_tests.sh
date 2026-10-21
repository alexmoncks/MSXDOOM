#!/bin/bash
# run_tests.sh - runs the cartridge in openMSX (the V9968 + geo3d fork) and checks it
#
#   run_tests.sh [scenario ...]     default: poses combat medkit death win
#     poses    freezes the game at a list of poses and compares the page geo3d
#              painted with tools/sim.py (geo3d's reference model), byte by byte
#     combat   shoots the first zombie dead: the shot, the monsters' logic, the HUD
#     medkit   a hurt player walks over a medkit
#     death    stands among monsters until dead, then restarts from the end screen
#     win      kills the last monster: the end screen, back to the title
#     tour     SHOT=1: screenshots of a walk through the level (no checks)
#   PROFILE=88 runs the 88h ROM on a machine with the V9968 cartridge
#   (-ext HRA_V9968 -ext geo3d88); MACHINE=... picks another machine.
#   SHOT=1 opens a window, runs in real time and saves the `shot` pictures.
# From WSL the Windows build of the emulator is used (OPENMSX=...openmsx.exe,
# its arguments become Windows paths); a Linux build works the same way.
# Writes out/test/<scenario>/ (log.txt, page dumps, PNGs). Exit 1 on a failure.
cd "$(dirname "$0")/.."
OPENMSX=${OPENMSX:-/mnt/c/Projects/mmsoft/openmsx-geo3d/openmsx.exe}
PROFILE=${PROFILE:-98}
[ -f out/MSXDOOM_$PROFILE.ROM ] || { echo "build first (build.sh)"; exit 2; }
if [ "$PROFILE" = 88 ]; then
  args="-machine ${MACHINE:-C-BIOS_MSX2+} -ext HRA_V9968 -ext geo3d88"; export VDPNAME=V9968
else
  args="-machine ${MACHINE:-C-BIOS_V9968_JP} -ext geo3d"; export VDPNAME=VDP
fi
case "$OPENMSX" in
  *.exe) w() { wslpath -m "$(realpath "$1")"; } ;;
  *)     w() { realpath "$1"; }; export SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-dummy} SDL_AUDIODRIVER=dummy ;;
esac
export SHOT=${SHOT:-0}

POSES=${POSES:-"2.5:2.5:64 2.5:3.5:64 7.5:3.5:64 9.3:4.6:40 13.5:7.5:0 20.5:3.3:200 3.3:11.2:100 2.25:2.25:224 10.5:8.5:128 5.7:3.5:70 19.2:3.5:70 6.2:2.6:60 1.3:1.3:32 21.75:13.7:160 1.25:13.75:96 12.5:11.5:192 16.4:1.3:140 7.5:10.5:250"}

script_of() {
  case $1 in
    poses)
      s="freeze 1;start"
      i=0
      for p in $POSES; do
        IFS=: read -r x z yaw <<< "$p"
        s="$s;pose $x $z $yaw;frames 4;dump pose_$i;shot pose_$i"
        i=$((i + 1))
      done
      echo "$s" ;;
    combat)   # the zombie of the first hall, two cells ahead
      echo "freeze 1;start;pose 5.5 2.5 64;frames 3;freeze 0;shot combat_0;keys 16;wait 0.1;psg 8 > 0;shot combat_1;wait 3;keys 0;wait 1;shot combat_2;expect kills == 1;expect g_state == 0;expect16 st_frames > 20;log combat" ;;
    medkit)   # hurt, one cell before the medkit at (7.5, 5.5)
      echo "freeze 1;start;pose 7.5 4.3 128;frames 3;poke p_hp 40;freeze 0;keys 1;wait 1.2;keys 0;wait 0.3;shot medkit;expect p_hp == 65;log medkit" ;;
    death)    # next to a fiend, doing nothing; then the trigger at the end screen
      echo "freeze 1;start;pose 19.5 3.5 64;frames 3;poke p_hp 20;freeze 0;wait 4;shot death_0;expect p_hp == 0;expect g_state == 1;wait 3;shot death_1;keys 16;wait 0.3;keys 0;wait 1;shot death_2;log title;keys 16;wait 0.3;keys 0;wait 1.5;expect p_hp == 100;expect g_state == 0;expect kills == 0;expect16 st_frames > 5;expect pal_cur == 0;log restarted" ;;
    win)      # eight monsters already counted: the ninth is the zombie of the first hall
      echo "freeze 1;start;pose 5.5 2.5 64;frames 3;poke kills 8;freeze 0;keys 16;wait 3.2;keys 0;expect g_state == 2;shot win_0;wait 3;shot win_1;log win;keys 16;wait 0.3;keys 0;wait 1;shot win_2;expect16 st_frames < 400" ;;
    flash)    # the shot's flash held on (pictures only)
      echo "freeze 1;start;pose 5.5 2.5 64;frames 3;poke muzzle_t 250;wait 1.5;shot flash;poke muzzle_t 0;poke hurt_t 250;wait 1.5;shot hurt" ;;
    docs)     # pictures for the README (SHOT=1)
      echo "wait 1;shot title;freeze 1;start;pose 19.2 3.5 70;wait 1.5;shot fiend;pose 13.5 7.5 0;wait 1.5;shot corridor;pose 5.5 2.5 64;poke muzzle_t 250;wait 1.5;shot shot;poke muzzle_t 0;pose 21.6 11.5 64;wait 1.5;shot rock" ;;
    title)
      echo "wait 1;shot title;wait 0.5;shot title2" ;;
    prof)     # where a frame's time goes: standing, walking and turning, a fight
      echo "start;wait 0.3;log standing;prof 2;keys 1;log walking;prof 1.5;keys 9;log walk+turn;prof 3;keys 25;log walk+turn+fire;prof 3;keys 0" ;;
    tour)
      echo "start;wait 0.5;shot tour_0;keys 1;wait 1.5;shot tour_1;keys 9;wait 0.6;shot tour_2;keys 1;wait 1.5;shot tour_3;keys 17;wait 2;shot tour_4;keys 5;wait 1;shot tour_5;keys 16;wait 2;shot tour_6;keys 0;wait 1;shot tour_7" ;;
    *) echo "unknown scenario $1" >&2; exit 2 ;;
  esac
}

rc=0
for scen in ${@:-poses combat medkit death win}; do
  dir=out/test/${scen}${TAG:+_$TAG}
  rm -rf "$dir"
  mkdir -p "$dir"
  awk -F'[:\t$ ]+' '/^[A-Za-z_0-9]+:\tequ \$/ { printf "set ::A(%s) 0x%s\n", $1, $NF }' \
    out/labels_$PROFILE.txt > "$dir/labels.tcl"
  export LABELS="$(w "$dir/labels.tcl")" OUTDIR="$(w "$dir")"
  export SCRIPT="$(script_of $scen)"
  export WSLENV=LABELS:OUTDIR:SCRIPT:SHOT:VDPNAME
  rom="$(w out/MSXDOOM_$PROFILE.ROM)"
  script="$(w tests/run.tcl)"
  (cd "$(dirname "$OPENMSX")" && timeout 900 "./$(basename "$OPENMSX")" $args \
     -cart "$rom" -romtype ASCII16 -script "$script" > /dev/null 2>&1)
  echo "== $scen ($PROFILE h)"
  if ! grep -q " END" "$dir/log.txt" 2>/dev/null; then echo "FAIL: the run did not end"; rc=1; continue; fi
  grep -E " E | L | PROF" "$dir/log.txt"
  grep -q " E FAIL" "$dir/log.txt" && rc=1
  if [ "$scen" = poses ]; then
    python3 tests/compare.py "$dir" || rc=1
  fi
done
[ $rc = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $rc
