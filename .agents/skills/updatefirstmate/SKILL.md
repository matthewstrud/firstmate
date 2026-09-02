---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from each checkout's update remote - the canonical `upstream` when the fork carries nothing of its own, else the fork's own `origin`.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Fast-forwards this firstmate repo's default branch and every local or remote secondmate through its guarded update path (never forced, never disruptive), then re-reads AGENTS.md and nudges each updated secondmate to do the same, so the whole tree runs the latest bin/ and instructions.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

The pull comes from **the canonical firstmate repo, not the user's own fork**.
Firstmate is a shared template, so a real install is usually a fork: `origin` is the user's fork - their push target, where their PRs go - and `upstream` is the canonical repo.
Updating such an install from `origin` would deliver whatever that fork was last synced to and still report success, so each checkout fast-forwards from `upstream` when the fork carries nothing of its own - `origin`'s default branch is itself an ancestor of `upstream`'s - and HEAD is an ancestor of `upstream` too.
Both conditions must hold; otherwise the pull comes from `origin`.
That resolution is per checkout and needs no configuration, because `upstream` already means "the canonical repo I forked" by universal git convention.
The question is asked of the REMOTES rather than of each checkout's own HEAD, and that is what keeps a fleet coherent: every pull here is fast-forward only, so deciding from each HEAD would let a primary sitting on a fork-local commit follow `origin` while a home leased at an older, purely-canonical commit followed `upstream`, and the two would never re-converge.
Reading the remotes also stops a checkout from latching onto `upstream` and silently never receiving the captain's own merged PRs, which live only on the fork.
A fork carrying its own commits - merged PRs, or the merge commits GitHub's "Sync fork" button creates - quietly falls back to its own `origin` and still reports an ordinary `updated` or `already current`, never a skip.
Be clear about what that fallback is: it tracks the FORK, which drifts behind the canonical repo whenever the fork stops being synced, so it is not a way of staying current with `upstream`.
Nothing needs to be reconfigured to leave that state - the moment the fork's default branch stops carrying anything of its own, `upstream` tracking resumes by itself.
An install with no `upstream` remote keeps pulling from `origin` exactly as before, and an install with no `origin` remote at all is skipped rather than quietly switched to `upstream`.

The update is **fast-forward only** - the same sanctioned self-write as the fleet sync firstmate already runs.
For a remote route, it updates the configured Firstmate code root on that host the same way, then guardedly fast-forwards the persistent home to that code-root commit.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch from the update remote resolved above, then updates every registered local or remote secondmate home through its placement-specific guarded path.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `nudge-secondmates: fm-<id>...|none`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a real `@AGENTS.md` pointer to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

3. **Nudge each updated live secondmate.**
   For every target listed on the `nudge-secondmates:` line (do nothing when it says `none`), send a one-line re-read nudge so that secondmate picks up its new instructions too:
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` is already set to the active firstmate home.
   This is a gentle steer, not an interruption: the secondmate already got a safe tracked-files fast-forward, and the nudge never forces, tears down, or discards its work.
   A secondmate that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

4. **Report to the captain in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without firstmate's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Captain, firstmate and both second mates are now on the latest."
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Secondmates are never disrupted.**
  A local or remote secondmate gets a tracked-files fast-forward only when its own checkout is safe to advance, plus a gentle re-read nudge when it changed.
  It is never torn down, interrupted, or forced.
