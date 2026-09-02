#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from this
#     install's update remote; a leased secondmate home (detached HEAD on the
#     default branch) fast-forwards the same way.
#   - That update remote is `upstream` when `upstream` is an ancestor of the
#     checkout and `origin` otherwise, resolved per target: a forked install
#     follows the canonical repo rather than whatever its own fork was last
#     synced to, an unforked one is unchanged, and a fork that has moved ahead of
#     the canonical repo quietly keeps following its own origin.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

# Give a world the canonical `upstream` bare repo a fork topology implies, seeded
# from the same c1 commit that origin holds. wire=yes also adds the `upstream`
# remote to the firstmate repo, exactly as a real forked install has it; wire=no
# leaves the checkout knowing only its own origin.
add_upstream() {
  local w=$1 wire=$2
  git init -q --bare "$w/upstream.git"
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main
  git -C "$w/seed" push -q "$w/upstream.git" main
  git clone -q "$w/upstream.git" "$w/upstream-seed" 2>/dev/null
  if [ "$wire" = yes ]; then
    git -C "$w/main" remote add upstream "$w/upstream.git"
  fi
}

# Advance the canonical upstream repo by one commit, leaving origin behind.
# Modes match bump_origin; the content differs from bump_origin's so a target
# that took the wrong base is visible in the tree, not just in the SHA.
bump_upstream() {
  local w=$1 mode=$2
  git -C "$w/upstream-seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'u-%s\n' "$mode" >> "$w/upstream-seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'upstream-v2\n' > "$w/upstream-seed/AGENTS.md"
    printf 'echo upstream-b\n' > "$w/upstream-seed/bin/tool.sh"
    printf 'upstream-s2\n' > "$w/upstream-seed/.agents/skills/note.md"
  fi
  git -C "$w/upstream-seed" add -A
  git -C "$w/upstream-seed" commit -qm "upstream-bump-$mode"
  git -C "$w/upstream-seed" push -q origin main
}

# The default-branch tip of a bare repo.
bare_head() {
  git -C "$1" rev-parse refs/heads/main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

# --- T12: fork topology updates from upstream, not from the user's fork -----
# The expected topology for a real install: `origin` is the user's own fork and
# `upstream` is the canonical repo. The fork is left stale at c1 while upstream
# advances, which is exactly the state a user who forgot GitHub's "Sync fork" is
# in. Updating from origin there would report success while delivering c1.
test_fork_updates_from_upstream() {
  local w out
  w=$(new_world t12)
  add_upstream "$w" yes
  add_sm "$w" sm1
  bump_upstream "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded from upstream"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded from upstream"
  assert_contains "$out" "reread-firstmate: yes" "upstream instruction change triggers reread"

  # The base was upstream's head, and the stale fork's head was NOT delivered.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(bare_head "$w/upstream.git")" ] \
    || fail "firstmate HEAD is not at the canonical upstream head"
  [ "$(git -C "$w/main" rev-parse HEAD)" != "$(bare_head "$w/origin.git")" ] \
    || fail "firstmate updated from the stale fork instead of upstream"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(bare_head "$w/upstream.git")" ] \
    || fail "secondmate HEAD is not at the canonical upstream head"
  # Content, not just the SHA: the working tree holds upstream's instructions.
  grep -qx 'upstream-v2' "$w/main/AGENTS.md" \
    || fail "firstmate working tree does not hold upstream's AGENTS.md"
  pass "T12 forked install updates from upstream, not from its own stale fork"
}

# --- T13: no upstream remote keeps the unchanged origin behaviour -----------
# A canonical repo existing elsewhere is irrelevant to an install that has not
# wired it up: with no `upstream` remote the base is still origin/<default>.
test_origin_only_install_updates_from_origin() {
  local w out
  w=$(new_world t13)
  add_upstream "$w" no
  add_sm "$w" sm1
  bump_origin "$w" instr
  bump_upstream "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "origin-only firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "origin-only secondmate fast-forwarded"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(bare_head "$w/origin.git")" ] \
    || fail "origin-only firstmate HEAD is not at origin's head"
  [ "$(git -C "$w/main" rev-parse HEAD)" != "$(bare_head "$w/upstream.git")" ] \
    || fail "origin-only firstmate followed a repo it has no remote for"
  grep -qx 'v2' "$w/main/AGENTS.md" \
    || fail "origin-only firstmate working tree does not hold origin's AGENTS.md"
  pass "T13 install without an upstream remote still updates from origin"
}

# --- T14: the update remote is resolved per target --------------------------
# A standalone-clone secondmate home is not a worktree of the primary and can
# have its own remotes. It must follow its OWN update remote rather than
# inheriting the primary's, so a home cloned straight from the fork keeps
# tracking that fork instead of being pointed at a repo it has no remote for.
test_update_remote_resolves_per_target() {
  local w out standalone
  w=$(new_world t14)
  add_upstream "$w" yes
  standalone="$w/sm2"
  git clone -q "$w/origin.git" "$standalone"
  git -C "$standalone" checkout -q --detach HEAD
  printf 'sm2\n' > "$standalone/.fm-secondmate-home"
  printf -- '- sm2 - standalone (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$standalone" > "$w/home/data/secondmates.md"
  bump_origin "$w" readme
  bump_upstream "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "primary followed its upstream remote"
  assert_contains "$out" "secondmate sm2: updated " "standalone home followed its own origin"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(bare_head "$w/upstream.git")" ] \
    || fail "primary did not follow upstream"
  [ "$(git -C "$standalone" rev-parse HEAD)" = "$(bare_head "$w/origin.git")" ] \
    || fail "standalone secondmate did not follow its own origin"
  [ "$(git -C "$standalone" rev-parse HEAD)" != "$(git -C "$w/main" rev-parse HEAD)" ] \
    || fail "the two targets resolved the same base, so per-target resolution is untested"
  pass "T14 each target resolves its own update remote"
}

# --- T15: a fork ahead of upstream falls back to origin, quietly ------------
# The topology every long-lived fork reaches: its default branch carries commits
# the canonical repo lacks - its own merged PRs, or the merge commits GitHub's
# "Sync fork" button creates - while upstream has advanced too. These pulls are
# fast-forward only, so `upstream` can never be a base for such a checkout. It
# must fall back to its own origin as an ordinary successful update, not refuse
# with `skipped: diverged from upstream/main` forever.
test_fork_ahead_of_upstream_falls_back_to_origin() {
  local w out err fork_local
  w=$(new_world t15)
  add_upstream "$w" yes

  # A fork-local commit that upstream will never see, landed on the checkout.
  bump_origin "$w" readme
  git -C "$w/main" fetch -q origin
  git -C "$w/main" merge --ff-only -q origin/main
  fork_local=$(git -C "$w/main" rev-parse HEAD)

  # Both sides then advance independently, so origin and upstream truly diverge.
  bump_upstream "$w" instr
  bump_origin "$w" instr

  # Non-vacuity: the fork-local commit is genuinely absent from upstream, and
  # upstream is genuinely ahead of the merge base rather than behind it.
  git -C "$w/main" fetch -q upstream
  git -C "$w/main" merge-base --is-ancestor "$fork_local" upstream/main \
    && fail "fixture is vacuous: the fork-local commit is already in upstream"
  [ "$(git -C "$w/main" rev-parse upstream/main)" \
    != "$(git -C "$w/main" merge-base HEAD upstream/main)" ] \
    || fail "fixture is vacuous: upstream is not ahead of the merge base"

  err="$w/t15.stderr"
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>"$err")

  assert_contains "$out" "firstmate: updated " "fork ahead of upstream fast-forwarded from origin"
  assert_not_contains "$out" "firstmate: skipped" "fork ahead of upstream was refused"
  assert_not_contains "$out" "diverged" "quiet origin fallback reported a divergence"
  assert_not_contains "$(cat "$err")" "firstmate" "quiet origin fallback warned on stderr"

  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(bare_head "$w/origin.git")" ] \
    || fail "fork ahead of upstream did not end at its own origin head"
  [ "$(git -C "$w/main" rev-parse HEAD)" != "$(bare_head "$w/upstream.git")" ] \
    || fail "fork ahead of upstream ended at upstream head"
  git -C "$w/main" merge-base --is-ancestor "$fork_local" HEAD \
    || fail "the fork-local commit was dropped from the resulting history"
  grep -qx 'v2' "$w/main/AGENTS.md" \
    || fail "working tree does not hold origin's AGENTS.md"
  pass "T15 a fork ahead of upstream updates from origin without refusing"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_fork_updates_from_upstream
test_origin_only_install_updates_from_origin
test_update_remote_resolves_per_target
test_fork_ahead_of_upstream_falls_back_to_origin

echo "# all fm-update tests passed"
