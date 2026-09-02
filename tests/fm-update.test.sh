#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from this
#     install's update remote; a leased secondmate home (detached HEAD on the
#     default branch) fast-forwards the same way.
#   - That update remote is `upstream` when the fork carries nothing of its own
#     AND the checkout is an ancestor of upstream, and `origin` otherwise. The
#     question is asked of the REMOTES, so every target sharing a remote set
#     resolves identically however far apart their HEADs sit: a forked install
#     follows the canonical repo rather than whatever its own fork was last
#     synced to, an unforked one is unchanged, and a fork carrying its own
#     commits quietly keeps following its own origin and still receives them.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - A target that cannot resolve a base at all reports the specific reason, and
#     one fetch per remote serves every target sharing an object store.
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

# A `git` shim that records the remote of every `git fetch <remote>` before
# handing the call straight to the real git, so one run's fetches can be counted
# per remote through an observable side effect rather than by reading source.
install_fetch_counting_git() {
  local fakebin=$1 log=$2 real_git
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
set -eu
prev=""
for arg in "\$@"; do
  if [ "\$prev" = fetch ]; then
    printf '%s\n' "\$arg" >> '$log'
    break
  fi
  prev="\$arg"
done
exec '$real_git' "\$@"
SH
  chmod +x "$fakebin/git"
}

# How many times <log> records a fetch of <remote>.
fetch_count() {
  grep -cx "$2" "$1" 2>/dev/null || true
}

# Advance origin by a commit the canonical repo does not have: a fork-only file
# plus a distinguishable AGENTS.md, so a target that took upstream instead is
# visible in the working tree and not only in the SHA. This is the shape of the
# captain's own merged PR - it lives on the fork's default branch and nowhere else.
bump_origin_fork_only() {
  local w=$1
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'echo fork-only\n' > "$w/seed/bin/fork-only.sh"
  printf 'fork-v2\n' > "$w/seed/AGENTS.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm fork-only
  git -C "$w/seed" push -q origin main
}

# Land a fork-local commit on the firstmate checkout, so the checkout carries a
# commit the canonical repo lacks and its update falls back to its own origin.
land_fork_local_commit() {
  local w=$1
  bump_origin "$w" readme
  git -C "$w/main" fetch -q origin
  git -C "$w/main" merge --ff-only -q origin/main
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
  # The primary's fork carries nothing of its own: origin's commit is in upstream
  # too, so the primary's remotes resolve to upstream while the standalone clone,
  # which has no upstream remote, still follows its own origin.
  git -C "$w/seed" push -q "$w/upstream.git" main
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
  assert_not_contains "$(cat "$err")" "firstmate: skipped" "quiet origin fallback reported a skip on stderr"
  assert_not_contains "$(cat "$err")" "warning:" "quiet origin fallback warned on stderr"

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

# --- T16: one fetch per remote serves every target sharing an object store --
# A linked-worktree secondmate shares the primary's object store, so a single
# fetch already refreshes it. The fork-local commit makes BOTH remotes get
# consulted in the same run - upstream for the ancestry test, origin as the base -
# so this pins the dedup key as (remote, object store), not just "fetched once".
test_fetch_deduped_across_targets_sharing_an_object_store() {
  local w out fakebin log
  w=$(new_world t16)
  add_upstream "$w" yes
  land_fork_local_commit "$w"
  add_sm "$w" sm1
  bump_upstream "$w" instr
  bump_origin "$w" instr

  fakebin=$(fm_fakebin "$w")
  log="$w/fetches.log"
  : > "$log"
  install_fetch_counting_git "$fakebin" "$log"

  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null)

  assert_contains "$out" "firstmate: updated " "primary did not update"
  assert_contains "$out" "secondmate sm1: updated " "worktree secondmate did not update"
  [ "$(fetch_count "$log" upstream)" -eq 1 ] \
    || fail "upstream fetched $(fetch_count "$log" upstream) times for 2 targets sharing an object store, expected 1"
  [ "$(fetch_count "$log" origin)" -eq 1 ] \
    || fail "origin fetched $(fetch_count "$log" origin) times for 2 targets sharing an object store, expected 1"
  pass "T16 one fetch per remote serves every target sharing an object store"
}

# --- T17: a target that cannot resolve a base reports WHY -------------------
# The skip reason is the only diagnostic a captain gets when /updatefirstmate
# cannot reach a base, so the no-remote and the offline cases must stay
# distinguishable instead of collapsing into a bare `skipped: `.
test_unresolvable_base_reports_a_specific_reason() {
  local w out before
  w=$(new_world t17)
  add_upstream "$w" yes
  land_fork_local_commit "$w"
  bump_upstream "$w" instr
  # Upstream is unusable as a base (the checkout carries what it lacks) and the
  # fallback remote is gone, so no base can be resolved at all.
  git -C "$w/main" remote remove origin
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: no origin remote" "missing fallback remote did not report its own reason"
  assert_contains "$out" "reread-firstmate: no" "no reread when the base was unresolvable"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "HEAD moved despite an unresolvable base"

  # The offline case must read differently from the no-remote case.
  w=$(new_world t17b)
  git -C "$w/main" remote set-url origin "$w/gone.git"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: fetch failed" "an unreachable remote did not report a fetch failure"
  pass "T17 an unresolvable base reports a specific reason, never a bare skip"
}

# --- T18: a fork's own merged commits are never stranded --------------------
# The checkout sits at a commit upstream DOES contain, while the fork's default
# branch carries the captain's own merged PR. Deciding from HEAD alone would take
# upstream here and report success forever without ever delivering that commit.
# The remotes say the fork carries something of its own, so the base is origin.
test_fork_local_commit_is_delivered_not_stranded() {
  local w out before
  w=$(new_world t18)
  add_upstream "$w" yes
  bump_upstream "$w" instr
  bump_origin_fork_only "$w"
  before=$(git -C "$w/main" rev-parse HEAD)

  # Non-vacuity: this is exactly the latch condition - HEAD IS an ancestor of
  # upstream, and the two remotes are genuinely diverged.
  git -C "$w/main" fetch -q origin
  git -C "$w/main" fetch -q upstream
  git -C "$w/main" merge-base --is-ancestor HEAD upstream/main \
    || fail "fixture is vacuous: HEAD is not an ancestor of upstream, so nothing would latch"
  git -C "$w/main" merge-base --is-ancestor origin/main upstream/main \
    && fail "fixture is vacuous: the fork carries nothing of its own"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "fork with its own commits did not update"
  assert_not_contains "$out" "firstmate: skipped" "fork with its own commits was refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(bare_head "$w/origin.git")" ] \
    || fail "checkout did not follow the fork that carries its own commits"
  [ "$(git -C "$w/main" rev-parse HEAD)" != "$(bare_head "$w/upstream.git")" ] \
    || fail "checkout latched onto upstream and skipped the fork's own commit"
  [ "$(git -C "$w/main" rev-parse HEAD)" != "$before" ] || fail "HEAD did not move"
  # Content, not the SHA: the fork-local commit was actually DELIVERED.
  [ -f "$w/main/bin/fork-only.sh" ] \
    || fail "the fork's own merged commit was never delivered to the checkout"
  grep -qx 'fork-v2' "$w/main/AGENTS.md" \
    || fail "working tree does not hold the fork's AGENTS.md"

  # It stays delivered: a second run must not flip back to upstream.
  out=$(run_update "$w")
  assert_contains "$out" "firstmate: already current" "second run was not a no-op"
  [ -f "$w/main/bin/fork-only.sh" ] \
    || fail "a later run took the fork's own commit back off the checkout"
  pass "T18 a fork carrying its own commits receives them instead of latching onto upstream"
}

# --- T19: targets sharing a remote set never split ---------------------------
# A primary on a fork-local commit and a worktree home leased at an older,
# purely-canonical commit share one object store and one set of remotes. Deciding
# from each HEAD would send the primary to origin and the home to upstream, and
# they would never re-converge. Both must land on the SAME commit.
test_targets_sharing_remotes_resolve_the_same_base() {
  local w out primary_before sm_before
  w=$(new_world t19)
  add_upstream "$w" yes
  # Leased before the fork gained anything of its own, so its HEAD is a commit
  # upstream contains - the ordinary lease point, not a contrived one.
  add_sm "$w" sm1
  bump_upstream "$w" instr
  bump_origin_fork_only "$w"
  git -C "$w/main" fetch -q origin
  git -C "$w/main" merge --ff-only -q origin/main
  bump_origin "$w" readme

  primary_before=$(git -C "$w/main" rev-parse HEAD)
  sm_before=$(git -C "$w/sm1" rev-parse HEAD)
  # Non-vacuity: the two targets start at DIFFERENT commits, and each HEAD would
  # answer the per-HEAD question differently.
  [ "$primary_before" != "$sm_before" ] \
    || fail "fixture is vacuous: both targets already start at the same commit"
  git -C "$w/main" fetch -q upstream
  git -C "$w/main" merge-base --is-ancestor "$sm_before" upstream/main \
    || fail "fixture is vacuous: the leased home is not at a commit upstream contains"
  git -C "$w/main" merge-base --is-ancestor "$primary_before" upstream/main \
    && fail "fixture is vacuous: the primary is not on a fork-local commit"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "primary did not update"
  assert_contains "$out" "secondmate sm1: updated " "secondmate did not update"
  assert_not_contains "$out" "skipped" "a target was refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse HEAD)" ] \
    || fail "primary and secondmate landed on DIFFERENT commits, so the fleet split"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(bare_head "$w/origin.git")" ] \
    || fail "targets did not land on the fork that carries its own commits"
  [ "$(git -C "$w/main" rev-parse HEAD)" != "$(bare_head "$w/upstream.git")" ] \
    || fail "targets landed on upstream despite the fork carrying its own commits"
  [ -f "$w/main/bin/fork-only.sh" ] && [ -f "$w/sm1/bin/fork-only.sh" ] \
    || fail "the fork's own commit is missing from one of the two working trees"
  pass "T19 targets sharing one remote set land on the same commit, never a split fleet"
}

# --- T20: upstream tracking resumes on its own ------------------------------
# The fallback is not a latch in the other direction. The moment the fork's
# default branch stops carrying anything of its own - here because the commit
# lands upstream - the gate starts holding again with no configuration change.
test_upstream_tracking_resumes_once_the_fork_is_clean() {
  local w out
  w=$(new_world t20)
  add_upstream "$w" yes
  bump_origin_fork_only "$w"

  git -C "$w/main" fetch -q origin
  git -C "$w/main" fetch -q upstream
  git -C "$w/main" merge-base --is-ancestor origin/main upstream/main \
    && fail "fixture is vacuous: the fork carries nothing of its own to begin with"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "fork with its own commit did not update from origin"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(bare_head "$w/origin.git")" ] \
    || fail "phase 1 did not follow the fork"
  [ -f "$w/main/bin/fork-only.sh" ] || fail "phase 1 did not deliver the fork's own commit"

  # The fork-local commit is upstreamed, then upstream moves on. Nothing is
  # reconfigured; only the remotes' relationship changed.
  git -C "$w/seed" push -q "$w/upstream.git" main
  bump_upstream "$w" instr
  git -C "$w/main" fetch -q upstream
  git -C "$w/main" merge-base --is-ancestor origin/main upstream/main \
    || fail "fixture is vacuous: the fork still carries something of its own in phase 2"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "upstream tracking did not resume"
  assert_not_contains "$out" "firstmate: skipped" "resumed upstream tracking was refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(bare_head "$w/upstream.git")" ] \
    || fail "checkout did not resume following upstream once the fork went clean"
  [ "$(git -C "$w/main" rev-parse HEAD)" != "$(bare_head "$w/origin.git")" ] \
    || fail "phase 2 followed origin, so the transition is untested"
  grep -qx 'upstream-v2' "$w/main/AGENTS.md" \
    || fail "working tree does not hold upstream's AGENTS.md after the transition"
  [ -f "$w/main/bin/fork-only.sh" ] \
    || fail "resuming upstream tracking dropped the previously delivered fork commit"
  pass "T20 upstream tracking resumes by itself once the fork carries nothing of its own"
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
test_fetch_deduped_across_targets_sharing_an_object_store
test_unresolvable_base_reports_a_specific_reason
test_fork_local_commit_is_delivered_not_stranded
test_targets_sharing_remotes_resolve_the_same_base
test_upstream_tracking_resumes_once_the_fork_is_clean

echo "# all fm-update tests passed"
