#!/usr/bin/env bash
# fm-work-ledger.sh - the read side of the per-card work ledger: copy every
# local home's ledger into this home's durable store, and tell firstmate about
# three edges and nothing else.
#
# Usage:
#   fm-work-ledger.sh [check]
#   fm-work-ledger.sh copy [--home <path> --lane <name>]
#   fm-work-ledger.sh arm
#   fm-work-ledger.sh disarm
#   fm-work-ledger.sh --help
#
# bin/fm-work-ledger-lib.sh owns the row format and the capture side. This
# script never writes into a home it reads.
#
# STORE
#   <data>/work-ledger/<lane>/<task-id>.events, where <lane> is `@primary` for
#   this home and the registry id for each LOCAL secondmate in
#   data/secondmates.md. A remote secondmate's state is on another host, so its
#   lane is unmeasured and is not listed. The copy appends the source's complete
#   lines the store does not already hold, so it is idempotent, ignores a
#   trailing partial line, and runs under one store lock so a sweep and a
#   retirement copy cannot interleave.
#
# CHECK
#   `check` composes with the watcher's state-check contract: it prints a line
#   only when firstmate should wake. The watcher does not deduplicate, so every
#   line is an EDGE recorded in <data>/work-ledger/.cursor before it is printed,
#   and a run in which nothing crossed an edge prints nothing at all. There is
#   no periodic summary and no timer: elapsed time alone never produces output.
#   A line is printed only after its cursor landed, so a store that cannot be
#   written stays silent here and surfaces through the home's existing alarms
#   instead of repeating every sweep.
#
#   over-budget   A rated, measured card's worker-active minutes crossed 3x, and
#                 later 6x, of (median minutes per point x rating). Once per
#                 level per card, and only while the card has a worker in
#                 flight, so a changed median never re-reports finished work; a
#                 card that crosses both inside one sweep reports only 6x.
#                 Minutes are the UNION of open turns across the card's
#                 incarnations and its sub-cards (tasks naming it as `parent`),
#                 and an open turn counts up to now only while its incarnation
#                 is still the live one. The median starts at
#                 FM_WORK_LEDGER_MEDIAN_MIN_PER_POINT (default 9.9) and is
#                 replaced by the store's own once 13 rated, complete, merged
#                 cards exist. Both are post hoc and the line says so.
#   capture dead  In some home, every in-flight task's ledger has trailed its
#                 live busy-state record for 2 consecutive sweeps, or the
#                 ledger directory stopped accepting writes while tasks are in
#                 flight. Once per episode; it re-arms when capture recovers.
#   digest        5 more rated cards merged in a lane. At most one per lane per
#                 sweep. It carries pace (points per worker-active hour), active
#                 share, mean rating and points per wall hour, each against the
#                 previous digest, plus counts of what was left out.
#   check error   The evaluation itself failed. Once per distinct failure.
#
#   Nothing is reported per merge, per harness, per model, or per agent.
#
# MEASUREMENT RULES
#   A card with a seq gap, a live record ahead of its ledger, a turn-closing
#   event with no turn open, or a turn left open by an incarnation that is gone
#   is INCOMPLETE. A card launched on a harness with no turn capture is
#   UNMEASURED. A card whose first spawn row carries no rating is UNRATED. None
#   of the three enters pace, none is imputed or read as zero, and each is
#   counted in the digest.
#   These are turn-bracketed minutes. They are a different measurement from
#   transcript-gap minutes and the two series must not be joined.
#
# `arm` writes state/work-ledger.check.sh and binds it with
# fm-check-register.sh; it refuses in a secondmate home, because the lane being
# measured must not be the one reading its own pace. `disarm` retires the shim.
# Secondmate retirement calls `copy --home <path> --lane <id>` and refuses to
# remove the home when it fails.
#
# Each check run touches <data>/work-ledger/.last-run so a check that stopped
# running is visible by its age.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STORE="$DATA/work-ledger"
CURSOR="$STORE/.cursor"
STORE_LOCK="$STORE/.lock"
PRIMARY_LANE=@primary
SUB_HOME_MARKER=.fm-secondmate-home
CHECK_ID=work-ledger
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"

# shellcheck source=bin/fm-work-ledger-lib.sh
. "$SCRIPT_DIR/fm-work-ledger-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() {
  cat <<'EOF'
usage:
  fm-work-ledger.sh [check]   copy local ledgers, then print only new edges (silent otherwise)
  fm-work-ledger.sh copy [--home <path> --lane <name>]
                              copy every local home's ledger, or one named home's, into this home's store
  fm-work-ledger.sh arm       write and register state/work-ledger.check.sh (primary home only)
  fm-work-ledger.sh disarm    retire the check shim and its trust binding
  fm-work-ledger.sh --help    print this help
See the header comment for the store, the edges, and the measurement rules.
EOF
}

die_usage() {
  printf 'fm-work-ledger: %s\n' "$1" >&2
  usage >&2
  exit 2
}

if [ "$(uname)" = Darwin ]; then
  file_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

store_prepare() {
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || return 1
  if [ ! -d "$STORE" ]; then
    (umask 077; mkdir -p "$STORE") 2>/dev/null || return 1
  fi
  [ ! -L "$STORE" ]
}

STORE_LOCK_HELD=0
store_lock() {
  local tries=0 now mtime
  while ! mkdir "$STORE_LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 100 ]; then
      now=$(date +%s)
      mtime=$(file_mtime "$STORE_LOCK" || true)
      case "$mtime" in ''|*[!0-9]*) mtime=$now ;; esac
      if [ $((now - mtime)) -ge "${FM_WORK_LEDGER_LOCK_STALE_SECS:-120}" ]; then
        rmdir "$STORE_LOCK" 2>/dev/null || true
        mkdir "$STORE_LOCK" 2>/dev/null && break
      fi
      return 1
    fi
    sleep 0.05
  done
  STORE_LOCK_HELD=1
  return 0
}
store_unlock() {
  [ "$STORE_LOCK_HELD" = 1 ] || return 0
  rmdir "$STORE_LOCK" 2>/dev/null || true
  STORE_LOCK_HELD=0
}

lane_valid() {
  case "$1" in
    "$PRIMARY_LANE") return 0 ;;
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Print `<lane><TAB><home>` for this home and every local registered secondmate.
local_homes() {
  local reg="$DATA/secondmates.md" line
  printf '%s\t%s\n' "$PRIMARY_LANE" "$FM_HOME"
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || continue
    lane_valid "$SECONDMATE_REGISTRY_ID" || continue
    [ "$SECONDMATE_REGISTRY_ID" != "$PRIMARY_LANE" ] || continue
    printf '%s\t%s\n' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME"
  done < "$reg"
}

# Snapshot one home's in-flight incarnations as `<id> <gen> <seq>` lines, plus
# a `!unwritable` line when its ledger directory cannot take a new row. This is
# read BEFORE the ledger is copied: the writer updates the record first and the
# ledger second under one lock, so a ledger copied after this read can only be
# level with or ahead of what was snapshotted unless a row was really lost.
snapshot_live() {  # <home-state-dir> <dest-file>
  local state=$1 dest=$2 gen_file id gen rec line seq dir
  : > "$dest" || return 1
  [ -d "$state" ] || return 0
  for gen_file in "$state"/*.busy-gen; do
    [ -f "$gen_file" ] || continue
    id=$(basename "$gen_file" .busy-gen)
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    gen=$(fm_busy_current_gen "$state" "$id") || continue
    rec=$(fm_busy_record_path "$state" "$id")
    line=$(head -n 1 "$rec" 2>/dev/null || true)
    seq=0
    case "$line" in
      *" gen=$gen "*)
        seq=${line##* seq=}
        seq=${seq%% *}
        case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
        ;;
    esac
    printf '%s %s %s\n' "$id" "$gen" "$seq" >> "$dest" || return 1
  done
  dir=$(fm_work_ledger_dir "$state")
  if [ -s "$dest" ] && [ -e "$dir" ] && { [ ! -d "$dir" ] || [ ! -w "$dir" ]; }; then
    printf '!unwritable - 0\n' >> "$dest" || return 1
  fi
  return 0
}

# Append to the store every complete source line it does not already hold.
copy_file() {  # <src> <dest>
  local src=$1 dest=$2 lines
  [ -f "$src" ] && [ ! -L "$src" ] || return 0
  [ ! -L "$dest" ] || return 1
  lines=$(wc -l < "$src") || return 1
  lines=${lines//[!0-9]/}
  [ -n "$lines" ] && [ "$lines" -gt 0 ] || return 0
  [ -e "$dest" ] || (umask 077; : > "$dest") || return 1
  head -n "$lines" "$src" | awk -v dest="$dest" '
    BEGIN { while ((getline held < dest) > 0) seen[held] = 1; close(dest) }
    !($0 in seen) { seen[$0] = 1; print }
  ' >> "$dest"
}

copy_home() {  # <lane> <home>
  local lane=$1 home=$2 src dest file
  lane_valid "$lane" || return 1
  [ -d "$home" ] || return 0
  dest="$STORE/$lane"
  if [ ! -d "$dest" ]; then
    (umask 077; mkdir -p "$dest") 2>/dev/null || return 1
  fi
  [ ! -L "$dest" ] || return 1
  snapshot_live "$home/state" "$dest/.live.tmp.$$" || { rm -f -- "$dest/.live.tmp.$$"; return 1; }
  mv -f -- "$dest/.live.tmp.$$" "$dest/.live" || { rm -f -- "$dest/.live.tmp.$$"; return 1; }
  src=$(fm_work_ledger_dir "$home/state")
  [ -d "$src" ] || return 0
  [ -r "$src" ] && [ -x "$src" ] || return 1
  for file in "$src"/*.events; do
    [ -f "$file" ] || continue
    copy_file "$file" "$dest/$(basename "$file")" || return 1
  done
  return 0
}

copy_all() {
  local lane home status=0
  while IFS=$'\t' read -r lane home; do
    [ -n "$lane" ] || continue
    copy_home "$lane" "$home" || status=1
  done <<EOF
$(local_homes)
EOF
  return "$status"
}

action_copy() {
  local home='' lane='' status=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) home=${2:-}; shift 2 || die_usage "--home needs a path" ;;
      --lane) lane=${2:-}; shift 2 || die_usage "--lane needs a name" ;;
      *) die_usage "unknown copy argument: $1" ;;
    esac
  done
  if [ -n "$home" ] || [ -n "$lane" ]; then
    [ -n "$home" ] && [ -n "$lane" ] || die_usage "--home and --lane go together"
    lane_valid "$lane" || die_usage "invalid lane: $lane"
  fi
  store_prepare || { printf 'fm-work-ledger: the store %s is unavailable\n' "$STORE" >&2; return 1; }
  store_lock || { printf 'fm-work-ledger: the store %s is locked\n' "$STORE" >&2; return 1; }
  if [ -n "$home" ]; then
    copy_home "$lane" "$home" || status=1
  else
    copy_all || status=1
  fi
  store_unlock
  [ "$status" -eq 0 ] || printf 'fm-work-ledger: copy failed\n' >&2
  return "$status"
}

# Evaluate the whole store against the cursor. Prints the new cursor to
# <cursor-out> and the lines to report to <lines-out>.
evaluate() {  # <cursor-out> <lines-out>
  local cursor_out=$1 lines_out=$2 lane_dir
  local -a inputs=()
  [ ! -f "$CURSOR" ] || inputs+=("$CURSOR")
  for lane_dir in "$STORE"/*/; do
    [ -d "$lane_dir" ] || continue
    [ ! -f "${lane_dir}.live" ] || inputs+=("${lane_dir}.live")
    for file in "$lane_dir"*.events; do
      [ -f "$file" ] || continue
      inputs+=("$file")
    done
  done
  awk -v now="$(date +%s)" \
    -v seed_median="${FM_WORK_LEDGER_MEDIAN_MIN_PER_POINT:-9.9}" \
    -v own_median_cards="${FM_WORK_LEDGER_OWN_MEDIAN_CARDS:-13}" \
    -v digest_cards="${FM_WORK_LEDGER_DIGEST_CARDS:-5}" \
    -v cursor_path="$CURSOR" \
    -v cursor_out="$cursor_out" -v lines_out="$lines_out" '
    function field(name,    i, n, kv) {
      for (i = 1; i <= NF; i++) {
        n = index($i, "=")
        if (n && substr($i, 1, n - 1) == name) return substr($i, n + 1)
      }
      return ""
    }
    function interval(lane, card, from, to,    k) {
      if (to <= from) return
      k = ++icount[lane, card]
      istart[lane, card, k] = from
      iend[lane, card, k] = to
    }
    function mark_incomplete(m) { incomplete[m] = 1 }
    # Close whatever turn <m> has open at <at>. A turn closed this way ended
    # with its incarnation rather than with a close event, so the card is
    # incomplete.
    function abandon(m, at) {
      if (open_at[m] == "") return
      interval(mlane[m], m, open_at[m], at)
      open_at[m] = ""
      mark_incomplete(m)
    }
    # Minutes in the union of a lane/card interval set, clipped to [lo, hi].
    function union_minutes(lane, key, lo, hi,    n, i, j, s, e, cs, ce, total, a, b) {
      n = icount[lane, key]
      for (i = 1; i <= n; i++) { us[i] = istart[lane, key, i]; ue[i] = iend[lane, key, i] }
      for (i = 2; i <= n; i++) {
        s = us[i]; e = ue[i]
        for (j = i - 1; j >= 1 && us[j] > s; j--) { us[j + 1] = us[j]; ue[j + 1] = ue[j] }
        us[j + 1] = s; ue[j + 1] = e
      }
      total = 0; cs = ""; ce = ""
      for (i = 1; i <= n; i++) {
        a = us[i]; b = ue[i]
        if (hi != "" && b > hi) b = hi
        if (lo != "" && a < lo) a = lo
        if (b <= a) continue
        if (cs == "") { cs = a; ce = b }
        else if (a <= ce) { if (b > ce) ce = b }
        else { total += ce - cs; cs = a; ce = b }
      }
      if (cs != "") total += ce - cs
      return total / 60
    }
    function ratio(current, previous) {
      if (previous == "" || previous + 0 == 0 || current + 0 == 0) return ""
      if (current >= previous) return sprintf(", x%.2f", current / previous)
      return sprintf(", /%.2f", previous / current)
    }
    function versus(current, previous) {
      if (previous == "" || previous == "-") return ""
      return sprintf(" (prev %.2f%s)", previous, ratio(current, previous))
    }

    BEGIN {
      # Events that close exactly one turn, so one arriving with no turn open
      # means the open was never seen. Other idle events (a session end, an
      # interrupt, a repeated status) legitimately arrive while already idle.
      strict_close["stop"] = 1; strict_close["stop-failure"] = 1; strict_close["after-agent"] = 1
    }
    FILENAME == cursor_path {
      if ($1 == "budget") budget_level[$2, $3] = $4
      else if ($1 == "capture") { capture_streak[$2] = $3; capture_fired[$2] = $4 }
      else if ($1 == "digested") digested[$2, $3] = 1
      else if ($1 == "digest") { d_end[$2] = $3; d_pace[$2] = $4; d_share[$2] = $5; d_mean[$2] = $6; d_wall[$2] = $7 }
      next
    }
    {
      parts = split(FILENAME, path, "/")
      lane = path[parts - 1]
      name = path[parts]
      if (!(lane in lanes)) { lanes[lane] = 1; lane_order[++lane_count] = lane }
    }
    name == ".live" {
      if ($1 == "!unwritable") { unwritable[lane] = 1; next }
      live_count[lane]++
      live_id[lane, live_count[lane]] = $1
      live_gen[lane, $1] = $2
      live_seq[lane, $1] = $3
      next
    }
    $1 != "v1" { next }
    {
      id = name
      sub(/\.events$/, "", id)
      m = lane SUBSEP id
      if (!(m in mlane)) { mlane[m] = lane; mid[m] = id; member_order[++member_count] = m }
      ts = field("ts") + 0
      row = field("row")
    }
    row == "spawn" {
      if (!(m in spawned)) {
        spawned[m] = ts
        rating[m] = field("rating")
        rater[m] = field("rater")
        parent[m] = field("parent")
      }
      if (field("capture") != "supported") unmeasured[m] = 1
      next
    }
    row == "pr-ready" { if (!(m in ready_at)) ready_at[m] = ts; next }
    row == "merged" { if (!(m in merged_at)) merged_at[m] = ts; next }
    row == "arm" || row == "turn" || row == "retire" {
      gen = field("gen"); seq = field("seq") + 0; st = field("state")
      if (gen != cur_gen[m]) {
        abandon(m, last_ts[m])
        cur_gen[m] = gen
        if (seq != 1) mark_incomplete(m)
      } else if (seq != last_seq[m] + 1) mark_incomplete(m)
      last_seq[m] = seq
      last_ts[m] = ts
      if (st == "busy") {
        if (open_at[m] == "") open_at[m] = ts
      } else if (open_at[m] != "") {
        interval(lane, m, open_at[m], ts)
        open_at[m] = ""
      } else if (row == "turn" && st == "idle" && (field("event") in strict_close)) mark_incomplete(m)
      next
    }

    END {
      # Settle each member: a turn still open counts to now only while its
      # incarnation is the live one, and a live record ahead of the ledger
      # means rows were lost.
      for (x = 1; x <= member_count; x++) {
        m = member_order[x]; lane = mlane[m]; id = mid[m]
        is_live = ((lane, id) in live_gen)
        if (is_live && live_gen[lane, id] == cur_gen[m]) {
          if (live_seq[lane, id] > last_seq[m]) { mark_incomplete(m); lag[lane] += live_seq[lane, id] - last_seq[m]; lagging[lane]++ }
          if (open_at[m] != "") { interval(lane, m, open_at[m], now); open_at[m] = "" }
        } else if (is_live) {
          mark_incomplete(m); lag[lane] += live_seq[lane, id]; lagging[lane]++
          abandon(m, last_ts[m])
        } else abandon(m, last_ts[m])
        ledgered[lane, id] = 1
      }
      for (x = 1; x <= lane_count; x++) {
        lane = lane_order[x]
        for (y = 1; y <= live_count[lane]; y++) {
          id = live_id[lane, y]
          if (!((lane, id) in ledgered)) { lag[lane] += live_seq[lane, id]; lagging[lane]++ }
        }
      }

      # Fold members into cards. A member naming a parent belongs to that card;
      # the card takes its rating from its own ledger when it has one, and
      # otherwise from the first sub-card spawned.
      for (x = 1; x <= member_count; x++) {
        m = member_order[x]; lane = mlane[m]
        card = (parent[m] != "" && parent[m] != "-") ? parent[m] : mid[m]
        c = lane SUBSEP card
        if (!(c in clane)) { clane[c] = lane; cname[c] = card; card_order[++card_count] = c }
        members[c]++
        if (mid[m] != card) subcards[c]++
        for (k = 1; k <= icount[lane, m]; k++) {
          interval(lane, "card:" card, istart[lane, m, k], iend[lane, m, k])
          interval(lane, "lane", istart[lane, m, k], iend[lane, m, k])
        }
        if (incomplete[m]) c_incomplete[c] = 1
        if (unmeasured[m]) c_unmeasured[c] = 1
        if (m in spawned) {
          if (mid[m] == card) { c_own[c] = 1; c_rating[c] = rating[m]; c_rater[c] = rater[m] }
          else if (!c_own[c] && (c_first[c] == "" || spawned[m] < c_first[c])) { c_rating[c] = rating[m]; c_rater[c] = rater[m] }
          if (c_first[c] == "" || spawned[m] < c_first[c]) c_first[c] = spawned[m]
        } else c_incomplete[c] = 1
        if (m in merged_at) { if (merged_at[m] > c_merged[c]) c_merged[c] = merged_at[m] }
        else if ((m in ready_at) || ((lane, mid[m]) in live_gen)) c_pending[c] = 1
        if ((lane, mid[m]) in live_gen) c_live[c] = 1
      }
      for (x = 1; x <= card_count; x++) {
        c = card_order[x]
        c_min[c] = union_minutes(clane[c], "card:" cname[c], "", "")
        c_rated[c] = (c_rating[c] != "" && c_rating[c] != "none" && c_rating[c] + 0 > 0)
        c_done[c] = (c_merged[c] != "" && !c_pending[c])
        if (c_done[c] && c_rated[c] && !c_incomplete[c] && !c_unmeasured[c] && c_min[c] > 0)
          sample[++samples] = c_min[c] / c_rating[c]
      }
      median = seed_median + 0; median_source = "inherited"
      if (samples >= own_median_cards + 0) {
        for (i = 2; i <= samples; i++) {
          v = sample[i]
          for (j = i - 1; j >= 1 && sample[j] > v; j--) sample[j + 1] = sample[j]
          sample[j + 1] = v
        }
        median = (samples % 2) ? sample[(samples + 1) / 2] : (sample[samples / 2] + sample[samples / 2 + 1]) / 2
        median_source = "ledger"
      }

      # Edge 1: over budget.
      for (x = 1; x <= card_count; x++) {
        c = card_order[x]; lane = clane[c]; card = cname[c]
        level = budget_level[lane, card] + 0
        if (c_rated[c] && !c_unmeasured[c] && c_live[c] && median > 0) {
          multiple = c_min[c] / (median * c_rating[c])
          crossed = (multiple >= 6) ? 6 : ((multiple >= 3) ? 3 : 0)
          if (crossed > level) {
            level = crossed
            printf("work-ledger: over-budget %s in %s (rated %s, rater %s): %.0f worker-min = %.1fx budget, crossed %dx (post hoc %s median %.1f min/pt); %d sub-cards; capture %s\n", \
              card, lane, c_rating[c], (c_rater[c] == "" ? "-" : c_rater[c]), c_min[c], multiple, crossed, median_source, median, subcards[c] + 0, \
              (c_incomplete[c] ? "incomplete" : "complete")) > lines_out
          }
        }
        if (level > 0) printf("budget %s %s %d\n", lane, card, level) > cursor_out
      }

      # Edge 2: capture dead, per home.
      for (x = 1; x <= lane_count; x++) {
        lane = lane_order[x]
        dead = (live_count[lane] > 0 && (unwritable[lane] || lagging[lane] >= live_count[lane]))
        streak = dead ? capture_streak[lane] + 1 : 0
        fired = dead ? capture_fired[lane] + 0 : 0
        if (dead && streak >= 2 && !fired) {
          fired = 1
          printf("work-ledger: capture dead in %s: %d tasks, ledger %d rows behind busy-state%s\n", \
            lane, live_count[lane], lag[lane] + 0, (unwritable[lane] ? "; ledger directory not writable" : "")) > lines_out
        }
        if (streak > 0) printf("capture %s %d %d\n", lane, streak, fired) > cursor_out
      }

      # Edge 3: one digest per lane once enough rated cards have merged.
      for (x = 1; x <= lane_count; x++) {
        lane = lane_order[x]
        n = 0
        for (y = 1; y <= card_count; y++) {
          c = card_order[y]
          if (clane[c] != lane || !c_done[c] || !c_rated[c] || digested[lane, cname[c]]) continue
          due[++n] = c
        }
        for (i = 2; i <= n; i++) {
          v = due[i]
          for (j = i - 1; j >= 1 && c_merged[due[j]] > c_merged[v]; j--) due[j + 1] = due[j]
          due[j + 1] = v
        }
        if (n >= digest_cards + 0) {
          window_end = c_merged[due[digest_cards + 0]]
          window_start = d_end[lane]
          if (window_start == "") {
            for (i = 1; i <= digest_cards + 0; i++)
              if (window_start == "" || c_first[due[i]] < window_start) window_start = c_first[due[i]]
          }
          points = 0; all_points = 0; minutes = 0; n_incomplete = 0; n_unmeasured = 0; n_unrated = 0
          for (i = 1; i <= digest_cards + 0; i++) {
            c = due[i]
            digested[lane, cname[c]] = 1
            all_points += c_rating[c]
            if (c_unmeasured[c]) n_unmeasured++
            else if (c_incomplete[c]) n_incomplete++
            else { points += c_rating[c]; minutes += c_min[c] }
          }
          for (y = 1; y <= card_count; y++) {
            c = card_order[y]
            if (clane[c] != lane || !c_done[c] || c_rated[c] || digested[lane, cname[c]] || c_merged[c] > window_end) continue
            digested[lane, cname[c]] = 1
            n_unrated++
          }
          wall_hours = (window_end - window_start) / 3600
          pace = (minutes > 0) ? points / (minutes / 60) : 0
          share = (wall_hours > 0) ? union_minutes(lane, "lane", window_start, window_end) / 60 / wall_hours : 0
          mean = all_points / (digest_cards + 0)
          per_wall = (wall_hours > 0) ? all_points / wall_hours : 0
          printf("work-ledger: digest %s %s..%s (%d rated cards): pace %s pts/active-h%s; active share %.2f%s; mean rating %.2f%s; points/wall-h %.2f%s. Excluded from pace: %d unrated, %d incomplete, %d unmeasured\n", \
            lane, cname[due[1]], cname[due[digest_cards + 0]], digest_cards + 0, \
            (minutes > 0 ? sprintf("%.2f", pace) : "n/a"), (minutes > 0 ? versus(pace, d_pace[lane]) : ""), \
            share, versus(share, d_share[lane]), mean, versus(mean, d_mean[lane]), per_wall, versus(per_wall, d_wall[lane]), \
            n_unrated, n_incomplete, n_unmeasured) > lines_out
          d_end[lane] = window_end
          if (minutes > 0) d_pace[lane] = pace
          d_share[lane] = share; d_mean[lane] = mean; d_wall[lane] = per_wall
        }
        if (d_end[lane] != "")
          printf("digest %s %s %s %s %s %s\n", lane, d_end[lane], (d_pace[lane] == "" ? "-" : d_pace[lane]), d_share[lane], d_mean[lane], d_wall[lane]) > cursor_out
        for (y = 1; y <= card_count; y++) {
          c = card_order[y]
          if (clane[c] == lane && digested[lane, cname[c]]) printf("digested %s %s\n", lane, cname[c]) > cursor_out
        }
      }
    }
  ' ${inputs[@]+"${inputs[@]}"} < /dev/null
}

# Report an evaluation failure once per distinct failure, never per sweep. The
# marker is what makes it an edge, so a failure that cannot be recorded is not
# printed.
check_error() {  # <message>
  local message=$1 marker="$STATE/.work-ledger-check-error"
  [ "$(cat "$marker" 2>/dev/null || true)" != "$message" ] || return 0
  (umask 077; printf '%s\n' "$message" > "$marker") 2>/dev/null || return 0
  printf 'work-ledger: check error: %s\n' "$message"
}

action_check() {
  local cursor_tmp lines_tmp
  store_prepare || { check_error "the store $STORE is unavailable"; return 0; }
  store_lock || { check_error "the store $STORE stayed locked"; return 0; }
  (umask 077; : > "$STORE/.last-run") 2>/dev/null || true
  # A home whose ledger cannot be copied is not a check error by itself: the
  # capture-dead edge below is what reports a home that stopped recording.
  copy_all || true
  cursor_tmp=$(umask 077; mktemp "$STORE/.cursor.XXXXXX" 2>/dev/null) || {
    store_unlock; check_error "the cursor in $STORE cannot be written"; return 0
  }
  lines_tmp=$(umask 077; mktemp "$STORE/.lines.XXXXXX" 2>/dev/null) || {
    rm -f -- "$cursor_tmp"; store_unlock; check_error "the cursor in $STORE cannot be written"; return 0
  }
  if ! evaluate "$cursor_tmp" "$lines_tmp" 2>/dev/null; then
    rm -f -- "$cursor_tmp" "$lines_tmp"
    store_unlock
    check_error "the ledger in $STORE could not be evaluated"
    return 0
  fi
  if ! mv -f -- "$cursor_tmp" "$CURSOR"; then
    rm -f -- "$cursor_tmp" "$lines_tmp"
    store_unlock
    check_error "the cursor in $STORE cannot be written"
    return 0
  fi
  rm -f -- "$STATE/.work-ledger-check-error" 2>/dev/null || true
  cat "$lines_tmp"
  rm -f -- "$lines_tmp"
  store_unlock
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-work-ledger.sh - work ledger poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-work-ledger.sh") check"
}

action_arm() {
  local home want device tmp
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    printf 'fm-work-ledger: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  if [ -e "$home/$SUB_HOME_MARKER" ]; then
    printf 'fm-work-ledger: %s is a secondmate home; the ledger check runs in the primary home only\n' "$home" >&2
    return 1
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { printf 'fm-work-ledger: state directory %s is unavailable\n' "$STATE" >&2; return 1; }
  if fm_custom_check_registered "$STATE" "$CHECK_ID" && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$(shim_content "$home")" ]; then
    printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
    return 0
  fi
  want=$(shim_content "$home")
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || {
    printf 'fm-work-ledger: %s is not a plain file this home owns\n' "$CHECK_SHIM" >&2
    return 1
  }
  tmp=$(umask 077; mktemp "$STATE/.fm-work-ledger-check.XXXXXX" 2>/dev/null) || return 1
  # An unregistered shim is not inert - the watcher rejects it every cycle and
  # wakes firstmate - so a failed or interrupted arm leaves no shim behind.
  trap 'rm -f -- "$tmp" "$CHECK_SHIM"; exit 1' HUP INT TERM
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM" \
    || ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    rm -f -- "$tmp" "$CHECK_SHIM"
    trap - HUP INT TERM
    printf 'fm-work-ledger: could not arm %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  if [ -e "$CHECK_SHIM" ] || [ -e "$STATE/$CHECK_ID.check-trust" ]; then
    FM_HOME="$FM_HOME" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null || {
      printf 'fm-work-ledger: could not retire %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

trap store_unlock EXIT

ACTION=${1:-check}
[ $# -eq 0 ] || shift
case "$ACTION" in
  check) action_check ;;
  copy) action_copy "$@" ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $ACTION" ;;
esac
