#!/usr/bin/env bash
# fm-work-ledger-lib.sh - the append side of the per-card work ledger.
#
# This file is the single owner of the ledger row format and of the rule that
# capture never costs a turn. bin/fm-work-ledger.sh owns the read side: the copy
# into the primary home, the cursor, and the three edges it may report.
#
# WHERE
#   <state>/work-ledger/<task-id>.events, one append-only file per task id, in
#   the home that spawned the task. It sits outside every worktree, so returning
#   a worktree to its pool cannot lose it, and teardown removes state/<id>.* by
#   name, so a subdirectory survives the task. Both incarnations of a relaunched
#   task land in the same file because the key is the task id and each turn row
#   carries its own gen.
#
# ROWS
#   Every row is one line of space-separated key=value tokens, written with a
#   single short write under O_APPEND:
#
#     v1 ts=<epoch> id=<task-id> row=<kind> <fields...>
#
#   row=arm|turn|retire  gen=<gen> seq=<n> state=<busy|idle|unknown|retired>
#                        source=<s> event=<e>
#       Written only by bin/fm-busy-event.sh, inside its per-task lock and after
#       the busy-state record write succeeded, so seq here is the record's seq.
#       An event from a superseded gen is refused before it reaches the append.
#   row=spawn            harness= model= kind= parent= capture=supported|unsupported
#                        rating= rater= blind= rated_at= rating_read=ok|failed
#       Written by bin/fm-spawn.sh once per launch, relaunches included. Only
#       the FIRST spawn row of a task is its frozen rating; a rating that shows
#       up on a later row was given after work began and is never the anchor.
#       rating=none means unrated, which the reader counts and never drops.
#       capture=unsupported means this harness reports no turn boundaries, so
#       the card is unmeasured - never zero minutes.
#   row=pr-ready         pr=<url>      written by bin/fm-pr-check.sh
#   row=merged           pr=<url>      written by bin/fm-merge-outcome-lib.sh
#       Both are stamped by firstmate's clock when firstmate observes them.
#
# FAILURE
#   fm_work_ledger_append always returns 0 and prints nothing. A failed append
#   adds one line to <state>/work-ledger/.errors, which is created with the
#   directory so it stays appendable after the directory itself stops accepting
#   new files, and is otherwise dropped; the reader detects the missing row from
#   the seq gap or from the live record running ahead, and marks the card
#   incomplete.
#
# Sourced by bin/fm-busy-event.sh, bin/fm-spawn.sh, bin/fm-pr-check.sh,
# bin/fm-merge-outcome-lib.sh, and bin/fm-work-ledger.sh. No side effects on
# source.

FM_WORK_LEDGER_DIRNAME=work-ledger

fm_work_ledger_dir() { printf '%s/%s\n' "$1" "$FM_WORK_LEDGER_DIRNAME"; }

# Reduce a value to one ledger token. Anything outside the token alphabet
# becomes `_`, and an empty value becomes `-`, so a row always splits cleanly on
# spaces and `=` no matter what a backlog title or a model name contained.
fm_work_ledger_token() {
  local value=${1-}
  value=${value//[!A-Za-z0-9._:+@\/-]/_}
  [ -n "$value" ] || value=-
  printf '%s\n' "${value:0:200}"
}

# fm_work_ledger_harness_capture <harness> <busy-gen>
# A harness is measured exactly when spawn armed the busy-state contract for it,
# because the arm is what its adapter wiring reports turn boundaries against.
# Reading the armed gen rather than re-listing harness names keeps this in step
# with bin/fm-spawn.sh's own arm decision.
fm_work_ledger_harness_capture() {
  if [ -n "${2-}" ]; then
    printf 'supported\n'
  else
    printf 'unsupported\n'
  fi
}

# fm_work_ledger_title_field <title> <name>
# Print the value of a `(<name>: <value>)` field carried in a backlog title.
# Returns 1 when the field is absent.
fm_work_ledger_title_field() {
  local title=$1 name=$2 rest
  case "$title" in
    *"($name: "*) ;;
    *) return 1 ;;
  esac
  rest=${title#*"($name: "}
  case "$rest" in
    *")"*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${rest%%)*}"
}

# fm_work_ledger_rating_fields <title>
# Print `rating=<v> rater=<v> blind=<v> rated_at=<v>` from a title carrying
#   (rating: <value> by=<rater> blind=<yes|no> at=<when>)
# A title with no rating field, or a rating that is not a plain number, prints
# the unrated record. by=, blind= and at= are each optional.
fm_work_ledger_rating_fields() {
  local title=$1 record value rater=- blind=- at=- word
  if ! record=$(fm_work_ledger_title_field "$title" rating); then
    printf 'rating=none rater=- blind=- rated_at=-\n'
    return 0
  fi
  value=${record%% *}
  case "$value" in
    ''|*[!0-9.]*|.|*.*.*) printf 'rating=none rater=- blind=- rated_at=-\n'; return 0 ;;
  esac
  for word in $record; do
    case "$word" in
      by=*) rater=$(fm_work_ledger_token "${word#by=}") ;;
      blind=*) blind=$(fm_work_ledger_token "${word#blind=}") ;;
      at=*) at=$(fm_work_ledger_token "${word#at=}") ;;
    esac
  done
  printf 'rating=%s rater=%s blind=%s rated_at=%s\n' "$value" "$rater" "$blind" "$at"
}

# fm_work_ledger_append <state-dir> <task-id> <row-kind> <fields>
fm_work_ledger_append() {
  local state=${1-} id=${2-} kind=${3-} fields=${4-} dir old_umask
  [ -n "$state" ] && [ -n "$id" ] && [ -n "$kind" ] || return 0
  case "$id" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  dir=$(fm_work_ledger_dir "$state")
  old_umask=$(umask)
  umask 077
  {
    { [ -d "$dir" ] || { mkdir -p "$dir" && : >> "$dir/.errors"; }; } &&
      [ ! -L "$dir" ] && [ ! -L "$dir/$id.events" ] &&
      printf 'v1 ts=%s id=%s row=%s %s\n' "$(date +%s)" "$id" "$kind" "$fields" >> "$dir/$id.events"
  } 2>/dev/null || {
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ ! -L "$dir/.errors" ] &&
      printf '%s %s %s\n' "$(date +%s)" "$id" "$kind" >> "$dir/.errors"
  } 2>/dev/null || true
  umask "$old_umask"
  return 0
}
