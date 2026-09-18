---
name: work-ledger
description: >-
  Agent-only procedure for the per-card work ledger's wakes.
  Use on any `check: work-ledger:` wake: an over-budget card, capture dead in a
  home, a lane digest, or a check error.
  Also use before writing a card's rating or parent into its backlog title.
  Owns what each wake asks firstmate to do, what must never be done with the
  numbers, and the title fields the ledger reads at dispatch.
user-invocable: false
metadata:
  internal: true
---

# work-ledger

Load this on any `check: work-ledger:` wake, and before writing a card's rating or parent into its backlog title.

The ledger exists to show, while the work is still happening, that a card is taking far longer than its difficulty warrants.
It is a problem finder, never a score: nothing here ranks a harness, a model, or an agent, and no number from it is ever shown to a worker.
`bin/fm-work-ledger-lib.sh` owns what is recorded and `bin/fm-work-ledger.sh` owns the store, the edges, and the measurement rules; read their headers rather than restating them.

## The wakes

The check reports an edge once and is silent otherwise, so a wake is never a repeat of one already handled.

- **`over-budget <card> in <lane>`** - look at that card's current state and its worker, then record exactly one of three as a keyed status note in that lane: continue, with the reason; re-scope, which goes to the captain as a decision; or re-rate, which is a blind re-rate by a session that has not seen the card's cost and never replaces the frozen rating.
  The thresholds are post hoc and the line says so, so treat the wake as a prompt to look, not as proof of a problem.
  Never interrupt, relaunch, or re-scope a card on the strength of the wake alone.
- **`capture dead in <lane>`** - capture stopped for a whole home, which is the one ledger failure that needs a person.
  Find the cause in that home's `state/work-ledger/` - disk, permissions, or a writer regression - and check its `.errors` file.
  A single card with a gap never wakes anyone; it is counted in the next digest.
- **`digest <lane>`** - relay the one line to the captain at the next natural reply, in plain language.
  Name any factor that moved by 2x or more against the previous digest.
  Take no other action: fewer than 20 cards cannot support a trend claim, so never present a digest as a trend alarm.
- **`check error`** - the evaluation itself failed; fix the named cause, because a broken check is otherwise silent.
  `data/work-ledger/.last-run` shows when the check last ran.

## Reading the numbers honestly

An unmeasured card ran on a worker runtime that reports no turn boundaries; it is unmeasured, never zero minutes.
An incomplete or unrated card is left out of pace and counted in the digest rather than estimated.
These are turn-bracketed minutes, a different measurement from minutes rebuilt out of transcripts, so never compare the two series or join them, and never backfill the ledger from history.

## Rating and parent fields

Spawn reads two optional fields from the card's backlog title at dispatch: `(rating: <number> by=<rater> blind=<yes|no> at=<when>)` and `(parent: <card-id>)`.
Write them before the `(kind: ...)` field so the backlog tool keeps them as part of the title.
Only the rating present at the card's first dispatch is its frozen rating; a rating added later is recorded on later launches and is never the anchor.
A card dispatched without one is recorded as unrated, which is visible in the digest, so rate before dispatch rather than after.
Sub-cards of a split card name the original as `parent` so their time folds into it.
