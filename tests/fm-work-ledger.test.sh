#!/usr/bin/env bash
# Tests for the per-card work ledger: the rows bin/fm-busy-event.sh appends at
# every turn boundary (bin/fm-work-ledger-lib.sh), and the copy, cursor, and
# edge-only reporting in bin/fm-work-ledger.sh.
#
# The property that matters most is silence. The watcher turns any output of a
# registered check into a wake and never deduplicates, so a check that repeats
# itself wakes firstmate every sweep forever. Every reporting case therefore
# runs the check a second time and asserts it prints nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUSY="$ROOT/bin/fm-busy-event.sh"
LEDGER="$ROOT/bin/fm-work-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-work-ledger)

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

run_check() {  # <home>
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$1" "$LEDGER" check
}

events() { printf '%s/state/work-ledger/%s.events\n' "$1" "$2"; }

# write_rows <home> <id>: append rows given on stdin as `<ts> <row> <fields>`.
write_rows() {
  local home=$1 id=$2 ts row fields
  mkdir -p "$home/state/work-ledger"
  while read -r ts row fields; do
    [ -n "$ts" ] || continue
    printf 'v1 ts=%s id=%s row=%s %s\n' "$ts" "$id" "$row" "$fields" >> "$(events "$home" "$id")"
  done
}

SPAWN_RATED='harness=claude model=opus kind=ship parent=- capture=supported rating=2 rater=fresh blind=yes rated_at=2026-09-18 rating_read=ok'

test_turn_rows_follow_the_record() {
  local home gen out
  home=$(make_home rows)
  gen=$("$BUSY" arm "$home/state" t1)
  "$BUSY" apply "$home/state" t1 idle --gen "$gen" --source claude-hook --event stop
  "$BUSY" apply "$home/state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit
  out=$(cat "$(events "$home" t1)")
  assert_equals 3 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one row per arm and apply"
  assert_contains "$out" "row=arm gen=$gen seq=1 state=busy source=fm-spawn event=launch-brief" "arm row"
  assert_contains "$out" "row=turn gen=$gen seq=2 state=idle source=claude-hook event=stop" "close row"
  assert_contains "$out" "row=turn gen=$gen seq=3 state=busy" "open row carries the record's seq"
  assert_grep "seq=3 " "$home/state/t1.busy-state" "the record and the ledger agree on seq"
  pass "arm and apply append one row each, numbered like the record"
}

test_stale_incarnation_is_not_appended() {
  local home old new before
  home=$(make_home stale)
  old=$("$BUSY" arm "$home/state" t1)
  new=$("$BUSY" arm "$home/state" t1)
  before=$(wc -l < "$(events "$home" t1)")
  if "$BUSY" apply "$home/state" t1 idle --gen "$old" --source claude-hook --event stop 2>/dev/null; then
    fail "a superseded incarnation's event was accepted"
  fi
  assert_equals "$before" "$(wc -l < "$(events "$home" t1)")" "a refused event must not reach the ledger"
  assert_no_grep "gen=$old seq=2" "$(events "$home" t1)" "stale row present"
  [ "$old" != "$new" ] || fail "arming twice minted the same gen"
  pass "a stale incarnation is refused before the append"
}

test_relaunch_keeps_both_incarnations_in_one_file() {
  local home first second
  home=$(make_home relaunch)
  first=$("$BUSY" arm "$home/state" t1)
  "$BUSY" apply "$home/state" t1 idle --gen "$first" --source claude-hook --event stop
  "$BUSY" retire "$home/state" t1 --gen "$first"
  second=$("$BUSY" arm "$home/state" t1)
  "$BUSY" apply "$home/state" t1 idle --gen "$second" --source pi-ext --event agent_settled
  assert_grep "row=retire gen=$first seq=3 state=retired" "$(events "$home" t1)" "retire row missing"
  assert_grep "row=arm gen=$first seq=1" "$(events "$home" t1)" "first incarnation lost"
  assert_grep "row=arm gen=$second seq=1" "$(events "$home" t1)" "second incarnation missing"
  assert_grep "gen=$second seq=2 state=idle source=pi-ext" "$(events "$home" t1)" "second incarnation's turn missing"
  pass "a relaunch keeps both incarnations in one file"
}

test_capture_never_fails_a_turn() {
  local home gen rc=0
  home=$(make_home failopen)
  gen=$("$BUSY" arm "$home/state" t1)
  # A ledger path that cannot take the row: the record must still advance and
  # the writer must still exit 0 with nothing on stdout or stderr.
  rm -f "$(events "$home" t1)"
  mkdir "$(events "$home" t1)"
  out=$("$BUSY" apply "$home/state" t1 idle --gen "$gen" --source claude-hook --event stop 2>&1) || rc=$?
  expect_code 0 "$rc" "apply with an unwritable ledger"
  assert_equals "" "$out" "a failed append must be silent"
  assert_grep "seq=2 state=idle" "$home/state/t1.busy-state" "the busy record must still be written"
  assert_grep " t1 turn" "$home/state/work-ledger/.errors" "the failed append must be counted"
  pass "a failed append is swallowed, counted, and never fails the turn"
}

test_concurrent_appends_do_not_interleave() {
  local home gen i pids=() bad
  home=$(make_home concurrent)
  gen=$("$BUSY" arm "$home/state" t1)
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    "$BUSY" apply "$home/state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i" || fail "a concurrent apply failed"; done
  assert_equals 13 "$(wc -l < "$(events "$home" t1)" | tr -d ' ')" "every append landed as its own line"
  bad=$(grep -cv "^v1 ts=[0-9]* id=t1 row=[a-z]* gen=$gen seq=[0-9]* state=busy source=[a-z-]* event=[a-z-]*\$" "$(events "$home" t1)" || true)
  assert_equals 0 "$bad" "no row was torn or merged with another"
  assert_equals "$(seq 1 13 | tr '\n' ' ')" \
    "$(sed -n 's/.* seq=\([0-9]*\) .*/\1/p' "$(events "$home" t1)" | tr '\n' ' ')" \
    "rows are in seq order with none missing or repeated"
  pass "concurrent appends neither interleave nor skip a seq"
}

test_check_is_silent_when_nothing_changed() {
  local home gen out
  home=$(make_home silent)
  out=$(run_check "$home")
  assert_equals "" "$out" "an empty home must be silent"
  gen=$("$BUSY" arm "$home/state" t1)
  "$BUSY" apply "$home/state" t1 idle --gen "$gen" --source claude-hook --event stop
  write_rows "$home" t1 <<EOF
$(date +%s) spawn $SPAWN_RATED
EOF
  for _ in 1 2 3; do
    out=$(run_check "$home")
    assert_equals "" "$out" "a healthy, in-budget card must never produce output"
  done
  assert_present "$home/data/work-ledger/@primary/t1.events" "the ledger was not copied into the store"
  assert_present "$home/data/work-ledger/.last-run" "the run marker is missing"
  pass "the check prints nothing when no edge was crossed, however often it runs"
}

test_copy_is_idempotent_and_ignores_a_partial_line() {
  local home store
  home=$(make_home copy)
  write_rows "$home" t1 <<EOF
100 spawn $SPAWN_RATED
EOF
  printf 'v1 ts=200 id=t1 row=turn gen=g1 seq=' >> "$(events "$home" t1)"
  FM_HOME="$home" "$LEDGER" copy || fail "copy failed"
  FM_HOME="$home" "$LEDGER" copy || fail "second copy failed"
  store="$home/data/work-ledger/@primary/t1.events"
  assert_equals 1 "$(wc -l < "$store" | tr -d ' ')" "copy repeated a row or took a partial line"
  printf '2 state=busy source=x event=y\n' >> "$(events "$home" t1)"
  FM_HOME="$home" "$LEDGER" copy || fail "third copy failed"
  assert_equals 2 "$(wc -l < "$store" | tr -d ' ')" "the completed line was not copied"
  pass "copy is idempotent and waits for a complete line"
}

test_over_budget_reports_each_level_once() {
  local home gen now out
  home=$(make_home budget)
  now=$(date +%s)
  gen=$("$BUSY" arm "$home/state" t1)
  # Rated 2 at the inherited 9.9 min/pt gives a 19.8 minute budget. One turn
  # open for 70 minutes is 3.5x.
  : > "$(events "$home" t1)"
  write_rows "$home" t1 <<EOF
$((now - 4200)) spawn $SPAWN_RATED
$((now - 4200)) arm gen=$gen seq=1 state=busy source=fm-spawn event=launch-brief
EOF
  out=$(run_check "$home")
  assert_contains "$out" "work-ledger: over-budget t1 in @primary (rated 2, rater fresh)" "3x crossing not reported"
  assert_contains "$out" "crossed 3x" "level missing"
  assert_contains "$out" "post hoc inherited median 9.9" "the threshold must be labelled post hoc"
  assert_contains "$out" "capture complete" "completeness missing"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "exactly one line per edge"
  out=$(run_check "$home")
  assert_equals "" "$out" "the same crossing must not be reported twice"
  # Same card, now 130 minutes open: 6.6x.
  sed -i.bak "s/ts=$((now - 4200)) /ts=$((now - 7800)) /" "$(events "$home" t1)"
  rm -f "$(events "$home" t1).bak" "$home/data/work-ledger/@primary/t1.events"
  out=$(run_check "$home")
  assert_contains "$out" "crossed 6x" "6x crossing not reported"
  out=$(run_check "$home")
  assert_equals "" "$out" "the 6x crossing must not repeat"
  pass "over-budget fires once at 3x and once at 6x, then stays silent"
}

test_sub_cards_aggregate_to_the_parent_as_a_union() {
  local home now ga gb out
  home=$(make_home parent)
  now=$(date +%s)
  ga=$("$BUSY" arm "$home/state" p1-a)
  gb=$("$BUSY" arm "$home/state" p1-b)
  : > "$(events "$home" p1-a)"
  : > "$(events "$home" p1-b)"
  # Two sub-cards each open for the SAME 40 minutes. Summed that is 80 minutes
  # and 4x the 19.8 minute budget; as a union it is 40 minutes and 2x.
  write_rows "$home" p1-a <<EOF
$((now - 2400)) spawn ${SPAWN_RATED/parent=-/parent=p1}
$((now - 2400)) arm gen=$ga seq=1 state=busy source=fm-spawn event=launch-brief
EOF
  write_rows "$home" p1-b <<EOF
$((now - 2400)) spawn ${SPAWN_RATED/parent=-/parent=p1}
$((now - 2400)) arm gen=$gb seq=1 state=busy source=fm-spawn event=launch-brief
EOF
  out=$(run_check "$home")
  assert_equals "" "$out" "overlapping sub-card time was summed instead of unioned"
  pass "sub-cards fold into their parent by union, not by sum"
}

test_unrated_and_unmeasured_cards_never_alarm() {
  local home now gen out
  home=$(make_home unrated)
  now=$(date +%s)
  gen=$("$BUSY" arm "$home/state" t1)
  : > "$(events "$home" t1)"
  write_rows "$home" t1 <<EOF
$((now - 90000)) spawn harness=claude model=opus kind=ship parent=- capture=supported rating=none rater=- blind=- rated_at=- rating_read=ok
$((now - 90000)) arm gen=$gen seq=1 state=busy source=fm-spawn event=launch-brief
EOF
  write_rows "$home" t2 <<EOF
$((now - 90000)) spawn harness=codex model=gpt kind=ship parent=- capture=unsupported rating=2 rater=fresh blind=yes rated_at=x rating_read=ok
EOF
  out=$(run_check "$home")
  assert_equals "" "$out" "an unrated or unmeasured card has no budget to cross"
  pass "unrated and unmeasured cards are never read as a budget"
}

test_capture_dead_needs_two_sweeps_and_fires_once() {
  local home gen out
  home=$(make_home dead)
  gen=$("$BUSY" arm "$home/state" t1)
  "$BUSY" apply "$home/state" t1 idle --gen "$gen" --source claude-hook --event stop
  # Lose the last row: the live record now runs ahead of the ledger.
  sed -i.bak '$d' "$(events "$home" t1)"
  rm -f "$(events "$home" t1).bak"
  out=$(run_check "$home")
  assert_equals "" "$out" "one lagging sweep is not yet an edge"
  out=$(run_check "$home")
  assert_contains "$out" "work-ledger: capture dead in @primary: 1 tasks, ledger 1 rows behind busy-state" "capture dead not reported"
  out=$(run_check "$home")
  assert_equals "" "$out" "capture dead must fire once per episode"
  # Capture recovers, then dies again: a new episode is a new edge.
  printf 'v1 ts=%s id=t1 row=turn gen=%s seq=2 state=idle source=claude-hook event=stop\n' "$(date +%s)" "$gen" >> "$(events "$home" t1)"
  out=$(run_check "$home")
  assert_equals "" "$out" "recovery is not an edge"
  "$BUSY" apply "$home/state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit
  sed -i.bak '$d' "$(events "$home" t1)"
  rm -f "$(events "$home" t1).bak"
  out=$(run_check "$home"; run_check "$home")
  assert_contains "$out" "work-ledger: capture dead in @primary" "a second episode must be reported again"
  pass "capture dead needs two lagging sweeps and reports once per episode"
}

test_seq_gap_marks_the_card_incomplete() {
  local home now out i
  home=$(make_home gap)
  now=$(date +%s)
  # Five rated cards merge, which is a digest. One of them has a seq gap, so it
  # is counted as excluded rather than entering pace.
  for i in 1 2 3 4 5; do
    write_rows "$home" "c$i" <<EOF
$((now - 7200)) spawn $SPAWN_RATED
$((now - 7200)) arm gen=g$i seq=1 state=busy source=fm-spawn event=launch-brief
$((now - 6000)) turn gen=g$i seq=$([ "$i" = 3 ] && echo 3 || echo 2) state=idle source=claude-hook event=stop
$((now - 5900)) retire gen=g$i seq=$([ "$i" = 3 ] && echo 4 || echo 3) state=retired source=fm-retire event=retire
$((now - 3600 + i)) merged pr=https://example.invalid/pr/$i
EOF
  done
  out=$(run_check "$home")
  assert_contains "$out" "work-ledger: digest @primary c1..c5 (5 rated cards)" "digest not reported"
  assert_contains "$out" "1 incomplete" "the seq gap was not detected"
  assert_contains "$out" "0 unrated" "unrated count missing"
  # Four complete cards: 8 points over 4 x 20 minutes = 6.00 pts/active-h.
  assert_contains "$out" "pace 6.00 pts/active-h" "pace must leave the incomplete card out"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one digest line"
  out=$(run_check "$home")
  assert_equals "" "$out" "a digest must not repeat"
  pass "a seq gap excludes the card from pace and is counted in the digest"
}

test_digest_waits_for_five_rated_cards() {
  local home now out i
  home=$(make_home digestwait)
  now=$(date +%s)
  for i in 1 2 3 4; do
    write_rows "$home" "c$i" <<EOF
$((now - 7200)) spawn $SPAWN_RATED
$((now - 7200)) arm gen=g$i seq=1 state=busy source=fm-spawn event=launch-brief
$((now - 6000)) turn gen=g$i seq=2 state=idle source=claude-hook event=stop
$((now - 3600 + i)) merged pr=https://example.invalid/pr/$i
EOF
  done
  out=$(run_check "$home")
  assert_equals "" "$out" "four merged cards are not a digest, and a merge alone is never reported"
  pass "no per-merge output, and no digest before five rated cards"
}

test_secondmate_lane_is_copied_without_writing_to_it() {
  local home mate before out
  home=$(make_home primary)
  mate=$(make_home mate-a)
  printf '%s\n' "- mate-a - cards lane (home: $mate; scope: cards; projects: none; added 2026-09-18)" > "$home/data/secondmates.md"
  write_rows "$mate" m1 <<EOF
100 spawn $SPAWN_RATED
EOF
  before=$(find "$mate" | sort)
  out=$(run_check "$home")
  assert_equals "" "$out" "copying a lane is not an edge"
  assert_present "$home/data/work-ledger/mate-a/m1.events" "the secondmate lane was not copied"
  assert_equals "$before" "$(find "$mate" | sort)" "the check wrote into the home it reads"
  pass "a local secondmate's ledger is copied read-only into its own lane"
}

test_arm_is_primary_only_and_registers_the_shim() {
  local home mate out rc=0
  home=$(make_home arm)
  out=$(FM_HOME="$home" "$LEDGER" arm) || fail "arm failed: $out"
  assert_contains "$out" "armed: state/work-ledger.check.sh" "arm output"
  assert_present "$home/state/work-ledger.check-trust" "the shim was not registered"
  out=$("$home/state/work-ledger.check.sh")
  assert_equals "" "$out" "the armed shim must be silent on an empty home"
  FM_HOME="$home" "$LEDGER" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/work-ledger.check.sh" "disarm left the shim"
  mate=$(make_home arm-mate)
  printf 'mate-x\n' > "$mate/.fm-secondmate-home"
  out=$(FM_HOME="$mate" "$LEDGER" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm in a secondmate home"
  assert_absent "$mate/state/work-ledger.check.sh" "a secondmate home must never hold the check"
  pass "arm registers the shim in a primary home and refuses a secondmate home"
}

test_retirement_copy_fails_closed() {
  local home mate rc=0
  home=$(make_home retire)
  mate=$(make_home retire-mate)
  write_rows "$mate" m1 <<EOF
100 spawn $SPAWN_RATED
EOF
  FM_HOME="$home" "$LEDGER" copy --home "$mate" --lane mate-r || fail "retirement copy failed"
  assert_present "$home/data/work-ledger/mate-r/m1.events" "retirement copy did not land"
  chmod 500 "$home/data/work-ledger/mate-r"
  write_rows "$mate" m2 <<EOF
100 spawn $SPAWN_RATED
EOF
  FM_HOME="$home" "$LEDGER" copy --home "$mate" --lane mate-r 2>/dev/null || rc=$?
  chmod 700 "$home/data/work-ledger/mate-r"
  [ "$(id -u)" = 0 ] || expect_code 1 "$rc" "a copy that cannot land must fail"
  pass "the retirement copy step reports failure instead of losing rows"
}

test_turn_rows_follow_the_record
test_stale_incarnation_is_not_appended
test_relaunch_keeps_both_incarnations_in_one_file
test_capture_never_fails_a_turn
test_concurrent_appends_do_not_interleave
test_check_is_silent_when_nothing_changed
test_copy_is_idempotent_and_ignores_a_partial_line
test_over_budget_reports_each_level_once
test_sub_cards_aggregate_to_the_parent_as_a_union
test_unrated_and_unmeasured_cards_never_alarm
test_capture_dead_needs_two_sweeps_and_fires_once
test_seq_gap_marks_the_card_incomplete
test_digest_waits_for_five_rated_cards
test_secondmate_lane_is_copied_without_writing_to_it
test_arm_is_primary_only_and_registers_the_shim
test_retirement_copy_fails_closed
