#!/usr/bin/env bash
# 2048 in bash.
#
# Keeps going after 2048 (4096, 8192, ...). Has score, undo, saved games,
# a saved high score, statistics and sliding tile animations.
#
# Keys: arrows / WASD / hjkl = move, u = undo, t = statistics,
#       v = change animation speed (normal, fast, off, slow),
#       n = new game, q = save and quit.
#
# Saves and stats go in ~/.local/share/bash2048 (set BASH2048_DIR to change).
# Needs bash 4+ and a 256-color terminal, at least 80x25.
# On bash 5+ the slide always takes the same time. On bash 4 it uses a
# fixed number of frames instead.

MAX_UNDO=20
ANIM_STEPS=5          # slide frames on bash < 5 (no EPOCHREALTIME)

DATA_DIR=${BASH2048_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash2048}
SAVE_FILE=$DATA_DIR/save.dat
STATS_FILE=$DATA_DIR/stats.dat
mkdir -p "$DATA_DIR" 2>/dev/null

# Screen position of the board's top-left corner (1-based). A tile is 3 rows
# by 7 columns, with a 1 row / 1 column gap between tiles.
BOARD_ROW=5
BOARD_COL=3

declare -a board=() undo_stack=()
declare -a a_src=() a_dst=() a_val=() a_merged=()   # tile paths from the last move, for animation
declare -A stats=()
score=0
gmax=0             # highest tile made this game (undo does not lower it)
gmoves=0           # moves made this game
message=""
game_over=0
have_game=0
spawn_idx=-1
spawn_val=0
full_clear=1
alt=0
buf=""
grid_buf=""
last_flush=$SECONDS

# ---------- terminal handling ----------
leave_alt() { ((alt)) && printf '\033[?1049l'; alt=0; }
cleanup() { printf '\033[?25h\033[0m'; leave_alt; stty echo 2>/dev/null; }
trap cleanup EXIT
trap 'quit_game' INT TERM
printf '\033[?1049h\033[?25l'   # switch to alternate screen, hide cursor
alt=1

# ---------- statistics ----------
stat_inc() { stats[$1]=$(( ${stats[$1]:-0} + ${2:-1} )); }

load_stats() {
  [[ -f $STATS_FILE ]] || return 0
  local k v
  while read -r k v; do
    [[ $k =~ ^[a-z_0-9]+$ && $v =~ ^[0-9]+$ ]] && stats[$k]=$v
  done < "$STATS_FILE"
}

save_stats() {
  local now=$SECONDS k
  stat_inc play_time $((now - last_flush))
  last_flush=$now
  {
    for k in "${!stats[@]}"; do echo "$k ${stats[$k]}"; done
  } > "$STATS_FILE.tmp" 2>/dev/null && mv "$STATS_FILE.tmp" "$STATS_FILE"
}

fmt_time() {
  local t=$1
  printf '%dh %02dm %02ds' $((t / 3600)) $((t % 3600 / 60)) $((t % 60))
}

show_stats() {
  local fin=${stats[games_finished]:-0} started=${stats[games_started]:-0}
  local avg=0 p k t any
  ((fin > 0)) && avg=$(( ${stats[total_final_score]:-0} / fin ))
  local ptime=$(( ${stats[play_time]:-0} + SECONDS - last_flush ))
  while true; do
    printf '\033[H\033[J'
    printf '\033[1m  2048 - Statistics\033[0m\n\n'
    printf '  \033[1;36mHigh score\033[0m        %d\n'  "${stats[best_score]:-0}"
    printf '  \033[1;36mHighest tile\033[0m      %d\n'  "${stats[highest_tile]:-0}"
    printf '  Games started       %d\n' "$started"
    printf '  Games finished      %d   (no moves left)\n' "$fin"
    printf '  Average final score %d\n' "$avg"
    printf '  Total moves         %d\n' "${stats[total_moves]:-0}"
    printf '  Total undos         %d\n' "${stats[total_undos]:-0}"
    printf '  Time played         %s\n\n' "$(fmt_time "$ptime")"
    printf '  \033[1mGames that reached tile\033[0m\n'
    any=0
    for ((p = 7; p <= 20; p++)); do
      t=$((1 << p))
      if ((${stats[reached_$t]:-0} > 0)); then
        printf '    %-8d %d\n' "$t" "${stats[reached_$t]}"
        any=1
      fi
    done
    ((any)) || printf '    (nothing 128+ yet)\n'
    printf '\n  \033[1mCurrent game\033[0m\n'
    printf '    Score %d   Moves %d   Highest tile %d\n\n' "$score" "$gmoves" "$gmax"
    printf '  Press any key to return, or R to reset all statistics. '
    IFS= read -rsn1 k
    if [[ $k == r || $k == R ]]; then
      printf '\n  Reset ALL statistics and high score? (y/N) '
      IFS= read -rsn1 k
      if [[ $k == y || $k == Y ]]; then
        stats=()
        last_flush=$SECONDS
        save_stats
        message="Statistics reset."
        break
      fi
    else
      break
    fi
  done
  full_clear=1
}

# ---------- save / load ----------
save_game() {
  {
    echo "$score $gmax $gmoves"
    echo "${board[*]}"
    ((${#undo_stack[@]})) && printf '%s\n' "${undo_stack[@]}"
  } > "$SAVE_FILE.tmp" 2>/dev/null && mv "$SAVE_FILE.tmp" "$SAVE_FILE"
}

load_game() {
  [[ -f $SAVE_FILE ]] || return 1
  local -a lines=() h=() b=() stack=()
  mapfile -t lines < "$SAVE_FILE"
  ((${#lines[@]} >= 2)) || return 1
  read -ra h <<< "${lines[0]}"
  read -ra b <<< "${lines[1]}"
  ((${#h[@]} == 3 && ${#b[@]} == 16)) || return 1
  local x line
  for x in "${h[@]}" "${b[@]}"; do [[ $x =~ ^[0-9]+$ ]] || return 1; done
  for line in "${lines[@]:2}"; do
    [[ -z $line ]] && continue
    [[ $line =~ ^[0-9]+(\ [0-9]+){16}$ ]] || return 1
    stack+=("$line")
  done
  score=${h[0]}; gmax=${h[1]}; gmoves=${h[2]}
  board=("${b[@]}")
  undo_stack=("${stack[@]}")
  trim_undo
  have_game=1
  spawn_idx=-1
  can_move && game_over=0 || game_over=1
  return 0
}

# ---------- game state ----------
board_max() { local m=0 v; for v in "${board[@]}"; do ((v > m)) && m=$v; done; echo "$m"; }

# Count a finished game (no moves left) once, when the player leaves it.
finalize_game() {
  if ((have_game && game_over)); then
    stat_inc games_finished
    stat_inc total_final_score "$score"
    rm -f "$SAVE_FILE"
  fi
  have_game=0
}

new_game() {
  finalize_game
  board=(); undo_stack=(); score=0; gmoves=0; message=""; game_over=0
  for ((i = 0; i < 16; i++)); do board[i]=0; done
  spawn; spawn
  spawn_idx=-1
  gmax=$(board_max)
  have_game=1
  stat_inc games_started
  ((gmax > ${stats[highest_tile]:-0})) && stats[highest_tile]=$gmax
  save_game; save_stats
}

spawn() {
  local empty=() i
  spawn_idx=-1
  for ((i = 0; i < 16; i++)); do ((board[i] == 0)) && empty+=("$i"); done
  ((${#empty[@]} == 0)) && return
  local pick=${empty[RANDOM % ${#empty[@]}]}
  if ((RANDOM % 10 == 0)); then spawn_val=4; else spawn_val=2; fi
  board[pick]=$spawn_val
  spawn_idx=$pick
}

push_undo() {   # $1 = score, rest = board snapshot
  undo_stack+=("$*")
  trim_undo
}

# Keep only the newest MAX_UNDO entries. Also run after loading a save.
trim_undo() {
  if ((${#undo_stack[@]} > MAX_UNDO)); then
    undo_stack=("${undo_stack[@]: -MAX_UNDO}")
  fi
}

undo() {
  local n=${#undo_stack[@]}
  if ((n == 0)); then message="Nothing to undo."; return 1; fi
  local state=${undo_stack[n-1]}
  unset 'undo_stack[n-1]'
  undo_stack=("${undo_stack[@]}")
  local arr
  read -ra arr <<< "$state"
  score=${arr[0]}
  board=("${arr[@]:1:16}")
  spawn_idx=-1
  message="Undid last move."
  return 0
}

# Slide and merge in direction $1 (left, right, up or down). Returns 0 if the
# board changed. Also records where each tile started and ended (a_src, a_dst,
# a_val) so animate_move can draw it.
move() {
  local dir=$1 line j k n moved=0 v dest
  local snap_score=$score
  local -a snap=("${board[@]}")
  a_src=(); a_dst=(); a_val=(); a_merged=()
  for ((line = 0; line < 4; line++)); do
    local -a idx=() vals=() srcs=() out=()
    for ((j = 0; j < 4; j++)); do
      case $dir in
        left)  idx+=($((line * 4 + j))) ;;
        right) idx+=($((line * 4 + 3 - j))) ;;
        up)    idx+=($((j * 4 + line))) ;;
        down)  idx+=($(((3 - j) * 4 + line))) ;;
      esac
    done
    for k in "${idx[@]}"; do
      if ((board[k] != 0)); then vals+=("${board[k]}"); srcs+=("$k"); fi
    done
    n=${#vals[@]}
    for ((j = 0; j < n; j++)); do
      dest=${idx[${#out[@]}]}
      if ((j + 1 < n && vals[j] == vals[j+1])); then
        v=$((vals[j] * 2))
        ((score += v))
        out+=("$v")
        a_src+=("${srcs[j]}" "${srcs[j+1]}")
        a_dst+=("$dest" "$dest")
        a_val+=("${vals[j]}" "${vals[j+1]}")
        a_merged+=("$dest")
        if ((v > gmax)); then
          gmax=$v
          ((v >= 128)) && stat_inc "reached_$v"
          ((v > ${stats[highest_tile]:-0})) && stats[highest_tile]=$v
          if ((v == 2048)); then
            message="You made 2048! Keep going."
          elif ((v > 2048)); then
            message="New tile: $v!"
          fi
        fi
        ((j++))
      else
        out+=("${vals[j]}")
        a_src+=("${srcs[j]}"); a_dst+=("$dest"); a_val+=("${vals[j]}")
      fi
    done
    while ((${#out[@]} < 4)); do out+=(0); done
    for ((j = 0; j < 4; j++)); do
      if ((board[idx[j]] != out[j])); then moved=1; fi
      board[idx[j]]=${out[j]}
    done
  done
  if ((moved)); then
    push_undo "$snap_score" "${snap[@]}"
    ((score > ${stats[best_score]:-0})) && stats[best_score]=$score
    return 0
  fi
  return 1
}

can_move() {
  local r c i
  for ((i = 0; i < 16; i++)); do ((board[i] == 0)) && return 0; done
  for ((r = 0; r < 4; r++)); do
    for ((c = 0; c < 4; c++)); do
      i=$((r * 4 + c))
      ((c < 3 && board[i] == board[i+1])) && return 0
      ((r < 3 && board[i] == board[i+4])) && return 0
    done
  done
  return 1
}

quit_game() {
  if ((game_over)); then finalize_game; else ((have_game)) && save_game; fi
  save_stats
  leave_alt
  echo "Thanks for playing! Score: $score   High score: ${stats[best_score]:-0}"
  ((!game_over && have_game)) && echo "Game saved. Run again to continue."
  exit 0
}

# ---------- rendering ----------
# Each frame is built up in $buf and written with a single printf. It uses
# absolute cursor positions and never clears the screen, so it doesn't flicker.
palette=(250 223 215 209 203 197 227 221 215 179 172 99 135 171 207 45 38 34 70)

# tile_style <value>: sets TBG (background) and TFG (text color)
tile_style() {
  local v=$1 e=0
  if ((v == 0)); then TBG=238; TFG=250; return; fi
  while ((v > 1)); do ((v >>= 1, e++)); done
  TBG=${palette[(e - 1) % ${#palette[@]}]}
  # dark text on the light tiles (2, 4, 128, 256), white on the rest
  if ((e <= 2 || e == 7 || e == 8)); then TFG=235; else TFG=231; fi
}

# sprite <top> <left> <height> <width> <value> [flash-bg-color]
# Adds a colored rectangle to $buf. Position is relative to the board, 0-based.
sprite() {
  local top=$1 left=$2 h=$3 w=$4 v=$5 flash=${6:-0} i row col l r piece
  tile_style "$v"
  if ((flash)); then TBG=$flash; TFG=235; fi
  col=$((BOARD_COL + left))
  for ((i = 0; i < h; i++)); do
    row=$((BOARD_ROW + top + i))
    if ((v != 0 && i == h / 2 && ${#v} <= w)); then
      l=$(((w - ${#v}) / 2)); r=$((w - ${#v} - l))
      printf -v piece '\033[%d;%dH\033[48;5;%sm\033[38;5;%sm\033[1m%*s%s%*s\033[0m' \
        "$row" "$col" "$TBG" "$TFG" "$l" "" "$v" "$r" ""
    else
      printf -v piece '\033[%d;%dH\033[48;5;%sm%*s\033[0m' "$row" "$col" "$TBG" "$w" ""
    fi
    buf+=$piece
  done
}

# Builds a string that blanks the board area and draws the 16 empty slots.
build_grid() {
  local r c piece
  buf=""
  for ((r = 0; r < 15; r++)); do
    printf -v piece '\033[%d;%dH\033[0m%*s' "$((BOARD_ROW + r))" "$BOARD_COL" 31 ""
    buf+=$piece
  done
  for ((r = 0; r < 4; r++)); do
    for ((c = 0; c < 4; c++)); do sprite $((r * 4)) $((c * 8)) 3 7 0; done
  done
  grid_buf=$buf
}

# Draw the tiles on the board. $1 is a cell index to skip, if any.
board_tiles() {
  local skip=${1:--1} flash_list=${2:-} flash_bg=${3:-0} i v fl
  for ((i = 0; i < 16; i++)); do
    v=${board[i]}
    ((v == 0 || i == skip)) && continue
    fl=0
    [[ -n $flash_list && $flash_list == *" $i "* ]] && fl=$flash_bg
    sprite $((i / 4 * 4)) $((i % 4 * 8)) 3 7 "$v" "$fl"
  done
}

draw() {
  local hdr
  buf=""
  if ((full_clear)); then buf+=$'\033[2J'; full_clear=0; fi
  printf -v hdr '\033[1;1H  \033[1m2048\033[0m   (keeps going past 2048)\033[K'
  buf+=$hdr
  printf -v hdr '\033[3;1H  Score: \033[1;33m%d\033[0m   High score: \033[1;36m%d\033[0m   Moves: %d   Undos left: %d\033[K' \
    "$score" "${stats[best_score]:-0}" "$gmoves" "${#undo_stack[@]}"
  buf+=$hdr
  buf+=$grid_buf
  board_tiles
  buf+=$'\033[21;1H\033[K  Move: arrows/WASD/hjkl  Undo: u  Stats: t  New: n  Speed: v  Save&Quit: q'
  buf+=$'\033[22;1H\033[K  (saved after every move)'
  buf+=$'\033[23;1H\033[K'
  [[ -n $message ]] && buf+="  "$'\033[1;32m'"$message"$'\033[0m'
  buf+=$'\033[24;1H\033[K'
  if ((game_over)); then
    printf -v hdr '  \033[1;31mGame over!\033[0m Final score: %d. Press u to undo or n for a new game.' "$score"
    buf+=$hdr
  fi
  buf+=$'\033[25;1H\033[J'
  flush_frame
}

# Write $buf as one frame. The two codes around it turn on synchronized output
# in terminals that support it (kitty, WezTerm, iTerm2, Windows Terminal and
# others), which avoids tearing. Other terminals ignore them.
flush_frame() { printf '\033[?2026h%s\033[?2026l' "$buf"; }

# Animation speed: 0 = off, 1 = slow, 2 = normal, 3 = fast. Saved in stats.
speed_names=(off slow normal fast)
set_anim_params() {
  case ${stats[anim_speed]:-2} in
    1) SLIDE_US=220000; POP_SLEEP=0.060 ;;
    3) SLIDE_US=60000;  POP_SLEEP=0.020 ;;
    *) SLIDE_US=110000; POP_SLEEP=0.035 ;;
  esac
}

# Draw one slide frame. $1 is how far along the move is, 0 to 100 (percent).
slide_frame() {
  local e=$1 i n=${#a_src[@]} r1 c1 r2 c2
  buf=$grid_buf
  for ((i = 0; i < n; i++)); do
    r1=$((a_src[i] / 4)); c1=$((a_src[i] % 4))
    r2=$((a_dst[i] / 4)); c2=$((a_dst[i] % 4))
    sprite $((r1 * 4 + (r2 - r1) * 4 * e / 100)) \
           $((c1 * 8 + (c2 - c1) * 8 * e / 100)) 3 7 "${a_val[i]}" 0
  done
  flush_frame
}

# Ease-out: fast at the start, slowing down at the end. Maps 0..100 to 0..100.
ease_out() { echo_e=$((100 - (100 - $1) * (100 - $1) / 100)); }

# Slide, then merge flash, then the new tile popping in.
# Skipped when animations are off or another key is already waiting, so
# holding down a key doesn't lag.
animate_move() {
  local speed=${stats[anim_speed]:-2}
  ((speed == 0)) && return 0
  read -rt 0 && return 0
  set_anim_params
  local f p start now r1 c1 stage
  if [[ -n $EPOCHREALTIME ]]; then
    # the slide always lasts SLIDE_US microseconds
    start=${EPOCHREALTIME/[.,]/}
    while :; do
      now=${EPOCHREALTIME/[.,]/}
      p=$(((now - start) * 100 / SLIDE_US)); ((p > 100)) && p=100
      ease_out "$p"; slide_frame "$echo_e"
      ((p >= 100)) && break
      sleep 0.016      # about 60 fps
    done
  else
    for ((f = 1; f <= ANIM_STEPS; f++)); do
      ease_out $((f * 100 / ANIM_STEPS)); slide_frame "$echo_e"
      sleep 0.012
    done
  fi
  # merged tiles flash white, then light gray, while the new tile grows
  local merged=" ${a_merged[*]} " flash_col
  for stage in 0 1; do
    buf=$grid_buf
    if ((stage == 0)); then flash_col=231; else flash_col=252; fi
    board_tiles "$spawn_idx" "$merged" "$flash_col"
    if ((spawn_idx >= 0)); then
      r1=$((spawn_idx / 4)); c1=$((spawn_idx % 4))
      if ((stage == 0)); then
        sprite $((r1 * 4 + 1)) $((c1 * 8 + 2)) 1 3 "$spawn_val" 0
      else
        sprite $((r1 * 4)) $((c1 * 8 + 1)) 3 5 "$spawn_val" 0
      fi
    fi
    flush_frame
    sleep "$POP_SLEEP"
  done
}

# ---------- input ----------
read_key() {
  local k rest
  IFS= read -rsn1 k || { echo quit; return; }
  if [[ $k == $'\e' ]]; then
    IFS= read -rsn2 -t 0.05 rest
    k+=$rest
  fi
  case $k in
    $'\e[A'|w|W|k) echo up ;;
    $'\e[B'|s|S|j) echo down ;;
    $'\e[C'|d|D|l) echo right ;;
    $'\e[D'|a|A|h) echo left ;;
    u|U|z|Z) echo undo ;;
    t|T) echo stats ;;
    v|V) echo anim ;;
    n|N) echo new ;;
    q|Q) echo quit ;;
    c|C) echo continue ;;
    *) echo other ;;
  esac
}

# ---------- startup ----------
load_stats
build_grid
if load_game; then
  printf '\033[H\033[J'
  printf '\033[1m  2048\033[0m\n\n'
  printf '  Saved game found:  score \033[1;33m%d\033[0m, highest tile %d, %d moves.\n\n' \
    "$score" "$gmax" "$gmoves"
  printf '  [C] Continue    [N] New game    [Q] Quit\n'
  while true; do
    key=$(read_key)
    case $key in
      continue) break ;;
      new) new_game; break ;;
      quit) leave_alt; exit 0 ;;
    esac
  done
  full_clear=1
  message="Game restored."
else
  new_game
fi

# ---------- main loop ----------
while true; do
  draw
  message=""
  key=$(read_key)
  case $key in
    quit)  quit_game ;;
    new)   new_game; full_clear=1 ;;
    stats) save_stats; show_stats ;;
    anim)
      case ${stats[anim_speed]:-2} in
        2) stats[anim_speed]=3 ;;
        3) stats[anim_speed]=0 ;;
        0) stats[anim_speed]=1 ;;
        *) stats[anim_speed]=2 ;;
      esac
      message="Animation: ${speed_names[${stats[anim_speed]}]}"
      save_stats
      ;;
    undo)
      if undo; then
        stat_inc total_undos
        game_over=0
        save_game; save_stats
      fi
      ;;
    up|down|left|right)
      if ((!game_over)) && move "$key"; then
        ((gmoves++))
        stat_inc total_moves
        spawn
        can_move || game_over=1
        animate_move
        save_game; save_stats
      fi
      ;;
  esac
done
