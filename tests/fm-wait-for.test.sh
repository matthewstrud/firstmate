#!/usr/bin/env bash
# Behavior tests for bin/fm-wait-for.sh, the shared pattern-free waiter.
#
# The waiter exists because `pgrep -f "X"` run inside a shell whose own command
# line contains X matches ITSELF, so the wait loop never breaks. These tests
# therefore care about two things the original fault got wrong:
#
#   1. The waiter must be able to say NO. A waiter that is satisfied while the
#      work is still running is the dangerous direction: it hands a half-written
#      artifact to everything downstream.
#   2. Success and timeout must stay distinguishable. Collapsing them recreates
#      the original fault in a new place.
#
# There is no assertion on the script's source text here. "It offers no pattern
# mode" is checked the only way that survives a refactor: by handing it
# pattern-shaped arguments through its real interface and requiring a refusal.
#
# PROVEN-FAILING PERTURBATIONS
# ----------------------------
# A check that cannot be shown failing is not a check. Rather than perturbing by
# hand once in a scratch file, this suite carries its perturbations: after the
# clean run it copies the waiter, applies each recorded break to the copy, re-runs
# the one case that break is supposed to defeat, and FAILS if that case still
# passes. Every run therefore re-proves that each case can fail. The anchors
# couple to the waiter's source, so a refactor that moves them fails loudly with
# a maintenance message rather than quietly turning the mutation into a no-op.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wait-for)
WAITER="$ROOT/bin/fm-wait-for.sh"
MARKER='all checks passed'

# run_waiter <args...>: run the waiter under test, echo "<rc>|<combined output>".
run_waiter() {
  local out rc
  out=$(bash "$WAITER" "$@" 2>&1)
  rc=$?
  printf '%s|%s\n' "$rc" "$out"
}

rc_of() { printf '%s\n' "${1%%|*}"; }
out_of() { printf '%s\n' "${1#*|}"; }

CURRENT_CASE=""

# fail_case <message>: an assertion belonging to the case under test failed, as
# distinct from fixture setup dying early. The attribution line names the case,
# and the perturbation harness requires it before crediting a break with a kill.
fail_case() {
  printf 'not ok - %s\n' "$1" >&2
  printf 'case-assertion-failed %s\n' "$CURRENT_CASE" >&2
  exit 1
}

# spawn_sleeper: start a long-lived process we own and echo its pid.
# The redirects matter: without them the sleeper inherits the command
# substitution's pipe and $(spawn_sleeper) blocks until the sleeper exits.
spawn_sleeper() {
  sleep 300 > /dev/null 2>&1 < /dev/null &
  printf '%s\n' "$!"
}

# The sleeper is started inside a command substitution, so it is not a child of
# this shell and cannot be waited on; poll until the kernel has reaped it so a
# following --pid wait sees a genuinely gone process.
reap() {
  local deadline
  kill "$1" 2>/dev/null || true
  deadline=$(( $(date +%s) + 10 ))
  while kill -0 "$1" 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "could not reap fixture process $1"
    sleep 0.1
  done
}

# --- cases ------------------------------------------------------------------
#
# Each case is a function so the perturbation harness below can re-run exactly
# one of them against a deliberately broken copy of the waiter.

case_refuses_pattern_shaped_arguments() {
  local dead r
  dead=$(spawn_sleeper)
  reap "$dead"

  local arg
  for arg in --pattern --match --name --process --proc; do
    r=$(run_waiter --pid "$dead" "$arg" pytest)
    [ "$(rc_of "$r")" = 2 ] ||
      fail_case "$arg alongside a satisfiable --pid must be refused, got rc=$(rc_of "$r")"
  done
  pass "pattern-shaped flags are refused even when another condition would succeed"

  r=$(run_waiter --pid "$dead" pytest)
  [ "$(rc_of "$r")" = 2 ] ||
    fail_case "a bare positional must be refused, not treated as a pattern (rc=$(rc_of "$r"))"
  pass "there is no positional fallback a pattern could arrive through"

  r=$(run_waiter --match pytest)
  case $(out_of "$r") in
    *--pid*--marker* | *--marker*--pid*) ;;
    *) fail_case "the refusal must name --pid and --marker: $(out_of "$r")" ;;
  esac
  case $(out_of "$r") in
    *"deliberately no pattern mode"*) ;;
    *) fail_case "the refusal must say no pattern mode is offered: $(out_of "$r")" ;;
  esac
  case $(out_of "$r") in
    *"matches the very shell doing the waiting"*) ;;
    *) fail_case "the refusal must explain WHY patterns are not offered: $(out_of "$r")" ;;
  esac
  pass "the refusal names the two supported modes and explains why patterns are absent"
}

case_refuses_a_wait_with_no_condition() {
  local r
  r=$(run_waiter --timeout 1)
  [ "$(rc_of "$r")" = 2 ] ||
    fail_case "no --pid and no --marker must be a usage error, not a silent success (rc=$(rc_of "$r"))"

  r=$(run_waiter --marker "$MARKER" --timeout 1)
  [ "$(rc_of "$r")" = 2 ] ||
    fail_case "--marker without --file must be a usage error (rc=$(rc_of "$r"))"

  r=$(run_waiter --file "$TMP_ROOT/anything.log" --timeout 1)
  [ "$(rc_of "$r")" = 2 ] ||
    fail_case "--file without --marker must be a usage error (rc=$(rc_of "$r"))"
  pass "a wait with nothing to wait for is refused rather than satisfied instantly"
}

case_live_pid_times_out_and_exited_pid_satisfies() {
  local pid r
  pid=$(spawn_sleeper)
  r=$(run_waiter --pid "$pid" --timeout 1 --interval 1)
  [ "$(rc_of "$r")" = 1 ] ||
    fail_case "a live pid must time out (rc=1), got rc=$(rc_of "$r"): $(out_of "$r")"
  case $(out_of "$r") in
    *"still alive"*) ;;
    *) fail_case "the timeout must say the pid is still alive: $(out_of "$r")" ;;
  esac
  reap "$pid"

  r=$(run_waiter --pid "$pid" --timeout 5 --interval 1)
  [ "$(rc_of "$r")" = 0 ] ||
    fail_case "an exited pid must satisfy the wait (rc=0), got rc=$(rc_of "$r"): $(out_of "$r")"
  pass "--pid tells a running process from an exited one, and timeout from success"
}

case_absent_marker_times_out_and_written_marker_satisfies() {
  local log r
  log="$TMP_ROOT/not-created-yet.$$.log"
  rm -f "$log"
  r=$(run_waiter --marker "$MARKER" --file "$log" --timeout 1 --interval 1)
  [ "$(rc_of "$r")" = 1 ] ||
    fail_case "a file that does not exist yet must read as unfinished, got rc=$(rc_of "$r")"
  case $(out_of "$r") in
    *"No such file"*) fail_case "a missing file must not spew a grep error: $(out_of "$r")" ;;
  esac

  printf 'pass A\nstill going\n' > "$log"
  r=$(run_waiter --marker "$MARKER" --file "$log" --timeout 1 --interval 1)
  [ "$(rc_of "$r")" = 1 ] ||
    fail_case "an unfinished log must time out rather than satisfy, got rc=$(rc_of "$r")"
  case $(out_of "$r") in
    *ABSENT*) ;;
    *) fail_case "the timeout must report the marker absent: $(out_of "$r")" ;;
  esac

  printf '%s\n' "$MARKER" >> "$log"
  r=$(run_waiter --marker "$MARKER" --file "$log" --timeout 5 --interval 1)
  [ "$(rc_of "$r")" = 0 ] ||
    fail_case "the written marker must satisfy the wait, got rc=$(rc_of "$r"): $(out_of "$r")"
  pass "--marker watches the artifact and tells unfinished from finished"
}

case_pid_and_marker_together_require_both() {
  local log pid r
  log="$TMP_ROOT/both.$$.log"
  printf '%s\n' "$MARKER" > "$log"
  pid=$(spawn_sleeper)
  r=$(run_waiter --pid "$pid" --marker "$MARKER" --file "$log" --timeout 1 --interval 1)
  [ "$(rc_of "$r")" = 1 ] ||
    fail_case "marker present but process still alive must not satisfy, got rc=$(rc_of "$r")"
  reap "$pid"

  r=$(run_waiter --pid "$pid" --marker "$MARKER" --file "$log" --timeout 5 --interval 1)
  [ "$(rc_of "$r")" = 0 ] ||
    fail_case "pid exited and marker present must satisfy, got rc=$(rc_of "$r"): $(out_of "$r")"
  pass "given both, the wait needs the process gone AND the artifact finished"
}

# The regression the waiter was written for: a caller whose own command line
# contains the very text being waited on. That is what defeats every pattern
# check, including the `[X]` bracket idiom, because a supervising process can
# quote a whole command inside a prompt.
case_immune_to_a_self_matching_caller() {
  local token log phantoms r
  token="fm-wait-for-selfmatch-$$"
  log="$TMP_ROOT/selfmatch.$$.log"
  rm -f "$log"

  # Fixture validity first: from a shell whose command line embeds the token,
  # a pattern check reports processes that are not the work. Without this the
  # case below could pass vacuously against a harmless fixture.
  if command -v pgrep > /dev/null 2>&1; then
    phantoms=$(bash -c "pgrep -f 'fm-wait-for-selfmatch-$$' 2>/dev/null | wc -l | tr -d ' '")
    [ "${phantoms:-0}" -ge 1 ] ||
      fail "fixture is not reproducing the fault: a pattern check found no phantom"
    pass "fixture confirmed: a pattern check from this caller reports $phantoms phantom process(es)"
  fi

  # Same self-matching caller, the pattern-free waiter: it must still tell the
  # truth in both directions, because it never looks at a command line.
  printf 'working on fm-wait-for-selfmatch-%s\n' "$$" > "$log"
  r=$(bash -c "bash '$WAITER' --marker 'fm-wait-for-selfmatch-$$-done' --file '$log' --timeout 1 --interval 1 2>&1; printf '%s' \$?")
  case $r in
    *1) ;;
    *) fail_case "unfinished work must still time out for a self-matching caller: $r" ;;
  esac

  printf 'fm-wait-for-selfmatch-%s-done\n' "$$" >> "$log"
  r=$(bash -c "bash '$WAITER' --marker 'fm-wait-for-selfmatch-$$-done' --file '$log' --timeout 5 --interval 1 --quiet 2>&1; printf '%s' \$?")
  [ "$r" = 0 ] ||
    fail_case "finished work must satisfy the wait for a self-matching caller: $r"
  pass "a caller whose own command line contains the waited-on text gets the truth"
}

# An empty value is the same fault the waiter exists to remove, arriving through
# a shell expansion instead of a pattern: --pid "$WORKER_PID" where WORKER_PID
# was set in a subshell silently drops that half of the condition.
case_refuses_empty_flag_values() {
  local dead log r
  dead=$(spawn_sleeper)
  reap "$dead"
  log="$TMP_ROOT/empty-value.$$.log"
  printf '%s\n' "$MARKER" > "$log"

  r=$(run_waiter --marker '' --pid "$dead" --timeout 0)
  [ "$(rc_of "$r")" = 2 ] ||
    fail_case "an empty --marker must be refused, not dropped beside a satisfiable --pid (rc=$(rc_of "$r"))"

  r=$(run_waiter --pid '' --marker "$MARKER" --file "$log" --timeout 0)
  [ "$(rc_of "$r")" = 2 ] ||
    fail_case "an empty --pid must be refused, not dropped beside a satisfiable --marker (rc=$(rc_of "$r"))"

  r=$(run_waiter --marker "$MARKER" --file '' --timeout 0)
  [ "$(rc_of "$r")" = 2 ] ||
    fail_case "an empty --file must be refused (rc=$(rc_of "$r"))"
  pass "an empty flag value is a usage error, never a condition silently dropped"
}

# A whitespace-only marker is the empty-value fault wearing a disguise: it
# passes a non-empty test and then matches the first log line containing a
# space. Guarding it must not cost the primary use, a multi-word marker.
case_refuses_a_whitespace_only_marker_but_keeps_multi_word_markers() {
  local log r
  log="$TMP_ROOT/whitespace.$$.log"
  printf 'starting the run now\nstill going\n' > "$log"

  r=$(run_waiter --marker ' ' --file "$log" --timeout 0)
  [ "$(rc_of "$r")" = 2 ] ||
    fail_case "a space-only --marker must be refused, not matched against the first line with a space (rc=$(rc_of "$r"))"

  r=$(run_waiter --marker "$(printf '\t ')" --file "$log" --timeout 0)
  [ "$(rc_of "$r")" = 2 ] ||
    fail_case "a whitespace-only --marker must be refused whatever the whitespace is (rc=$(rc_of "$r"))"

  r=$(run_waiter --marker "$MARKER" --file "$log" --timeout 0)
  [ "$(rc_of "$r")" = 1 ] ||
    fail_case "a multi-word marker must stay accepted and read as unfinished, got rc=$(rc_of "$r"): $(out_of "$r")"

  printf '%s\n' "$MARKER" >> "$log"
  r=$(run_waiter --marker "$MARKER" --file "$log" --timeout 0)
  [ "$(rc_of "$r")" = 0 ] ||
    fail_case "a multi-word marker must still satisfy once written, got rc=$(rc_of "$r"): $(out_of "$r")"
  pass "only an entirely-whitespace marker is refused; a multi-word marker keeps working"
}

CASES=(
  case_refuses_pattern_shaped_arguments
  case_refuses_a_wait_with_no_condition
  case_refuses_empty_flag_values
  case_refuses_a_whitespace_only_marker_but_keeps_multi_word_markers
  case_live_pid_times_out_and_exited_pid_satisfies
  case_absent_marker_times_out_and_written_marker_satisfies
  case_pid_and_marker_together_require_both
  case_immune_to_a_self_matching_caller
)

if [ -n "${FM_WAIT_FOR_ONLY_CASE:-}" ]; then
  WAITER=${FM_WAIT_FOR_WAITER:-$WAITER}
  CURRENT_CASE=$FM_WAIT_FOR_ONLY_CASE
  "$FM_WAIT_FOR_ONLY_CASE"
  exit 0
fi

for c in "${CASES[@]}"; do
  CURRENT_CASE=$c
  "$c"
done

# --- proven-failing perturbations -------------------------------------------
#
# Each record: the case it must defeat, the exact anchor in the waiter, its
# replacement, and what the break means. A perturbed waiter whose case still
# passes means that case is not actually guarding what it claims.

perturbations() {
  cat <<'RECORDS'
case_absent_marker_times_out_and_written_marker_satisfies
  if [ -n "$MARKER" ] && ! marker_present; then
  if false; then
the marker check can no longer say no, so a barely-started run satisfies the wait
--
case_live_pid_times_out_and_exited_pid_satisfies
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  if false; then
the waiter stops asking the kernel about the pid, so a live process reads as gone
--
case_refuses_a_wait_with_no_condition
if [ -z "$PID" ] && [ -z "$MARKER" ]; then
if false; then
a wait with no condition is admitted and then satisfied instantly and silently
--
case_refuses_pattern_shaped_arguments
      die_usage "unknown argument '$1'"
      shift
an unrecognised argument is skipped, so a caller's pattern is silently ignored
--
case_live_pid_times_out_and_exited_pid_satisfies
    exit 1
    exit 0
giving up waiting is reported as success, collapsing the distinction the waiter owes
--
case_pid_and_marker_together_require_both
  if [ "$satisfied" -eq 1 ]; then
  if [ "$satisfied" -eq 1 ] || { [ -n "$MARKER" ] && marker_present; }; then
the two conditions degrade from AND to OR, so a live process with a marker already written satisfies the wait
--
case_immune_to_a_self_matching_caller
  grep -qsF -- "$MARKER" "$FILE"
  pgrep -f "$MARKER" > /dev/null 2>&1
the marker check answers from the process table instead of the artifact, so a self-matching caller matches itself
--
case_refuses_empty_flag_values
      [ -n "$2" ] || die_usage "--pid requires a process id, not an empty value"
      :
an empty --pid is admitted again, so that half of the condition is dropped and never checked
--
case_refuses_empty_flag_values
      [ -n "$2" ] || die_usage "--file requires a path, not an empty value"
      :
an empty --file is admitted again, so the marker is looked for in a path that names nothing
--
case_refuses_empty_flag_values
      has_content "$2" || die_usage "--marker requires a string with content, not an empty or whitespace-only value"
      :
an empty --marker is admitted again, so that half of the condition is dropped and never checked
--
case_refuses_a_whitespace_only_marker_but_keeps_multi_word_markers
      has_content "$2" || die_usage "--marker requires a string with content, not an empty or whitespace-only value"
      :
a whitespace-only marker is admitted and then matches the first log line carrying a space
--
case_refuses_a_whitespace_only_marker_but_keeps_multi_word_markers
      has_content "$2" || die_usage "--marker requires a string with content, not an empty or whitespace-only value"
      case $2 in *[[:space:]]*) die_usage "--marker requires a string with content, not an empty or whitespace-only value" ;; esac
the guard widens from whitespace-only to whitespace-containing, refusing the multi-word markers that are the point
--
case_refuses_pattern_shaped_arguments
  printf 'Wait with --pid <n> (one process by identity) and/or --marker <string> --file <path>\n' >&2
  :
the refusal stops naming the two modes a caller should have used instead
--
case_refuses_pattern_shaped_arguments
  printf '(a fixed string the work writes when done). There is deliberately no pattern mode:\n' >&2
  :
the refusal stops stating that no pattern mode is offered at all
--
case_refuses_pattern_shaped_arguments
  printf 'a process-name pattern matches the very shell doing the waiting, so the wait never\n' >&2
  :
the refusal stops explaining why patterns are not offered, leaving a bare rejection
RECORDS
}

perturbed=0
while IFS= read -r case_name && IFS= read -r anchor && IFS= read -r replacement \
  && IFS= read -r meaning; do
  IFS= read -r _sep || true
  copy="$TMP_ROOT/perturbed.$perturbed.sh"
  cp "$ROOT/bin/fm-wait-for.sh" "$copy"
  grep -Fqx -- "$anchor" "$copy" ||
    fail "perturbation anchor no longer exists in bin/fm-wait-for.sh, so it would mutate nothing: $anchor"
  ANCHOR=$anchor REPLACEMENT=$replacement perl -i -pe '
    BEGIN { $a = $ENV{ANCHOR}; $r = $ENV{REPLACEMENT}; $n = 0 }
    if (!$n && $_ eq "$a\n") { $_ = "$r\n"; $n = 1 }
  ' "$copy"
  ! cmp -s "$copy" "$ROOT/bin/fm-wait-for.sh" ||
    fail "perturbation $perturbed did not change the waiter: $anchor"

  child_log="$TMP_ROOT/perturbed.$perturbed.log"
  if FM_WAIT_FOR_ONLY_CASE="$case_name" FM_WAIT_FOR_WAITER="$copy" \
    FM_TEST_SKIP_ORPHAN_REAP=1 bash "${BASH_SOURCE[0]}" > "$child_log" 2>&1; then
    fail "$case_name still passes with the waiter broken so that $meaning"
  fi
  grep -Fqx -- "case-assertion-failed $case_name" "$child_log" ||
    fail "$case_name exited nonzero without failing its own assertion under the break that $meaning, so the kill is unattributed: $(tr '\n' ' ' < "$child_log")"
  pass "$case_name fails its own assertion when $meaning"
  perturbed=$((perturbed + 1))
done < <(perturbations)

[ "$perturbed" -eq 15 ] ||
  fail "expected 15 perturbations to run, ran $perturbed"
pass "every case above is proven able to fail"
