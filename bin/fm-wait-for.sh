#!/usr/bin/env bash
# fm-wait-for.sh - wait for work to FINISH without ever asking "is a process
# matching X still alive?".
#
# Usage:
#   fm-wait-for.sh --pid <n> [--timeout <s>] [--interval <s>] [--quiet]
#   fm-wait-for.sh --marker <string> --file <path> [--timeout <s>] ...
#   fm-wait-for.sh --pid <n> --marker <string> --file <path> [...]
#
# Exit status: 0 the condition happened, 1 gave up waiting (timeout),
# 2 usage error. A waiter that cannot tell success from timeout recreates the
# fault this script exists to remove, so those two are never merged.
#
# WHY THIS SCRIPT OFFERS NO PATTERN MODE
# -------------------------------------
# `pgrep -f "X"` run inside a shell whose own command line contains X matches
# ITSELF, so the wait loop never breaks and every later check reports a phantom
# process. On 2026-09-03 that shape cost three separate crews about an hour of
# dead waiting in one morning: one waited out a full timeout after its work had
# already finished, and a test watcher would have reported the suite running
# forever after it had exited.
#
# The "clever" bracket idiom `pgrep -f "[X]..."` was tried as an earlier fix and
# was defeated too. It only stops pgrep matching its own command line, and a
# supervising agent's command line can quote a whole command inside a task
# prompt, so a third process matches anyway. No pattern is safe, because the
# pattern space is shared with anything that can quote it. The fix is therefore
# to remove the mode, not to warn about it: this script accepts no pattern flag
# and no positional argument, and refuses anything it does not recognise.
#
# THE TWO HONEST CHECKS, AND THEIR LIMITS
# ---------------------------------------
#   --pid <n>      `kill -0 <n>`: ask the kernel about ONE process by identity,
#                  with no pattern anywhere. Satisfied when that pid is gone.
#                  Limits, stated rather than hidden: it is only valid for a pid
#                  you launched and still own. The kernel recycles pids, so a
#                  long wait can be answered by an unrelated process that
#                  inherited the number. A pid owned by another user reads as
#                  gone, because the permission error is indistinguishable here
#                  from "no such process". Prefer --marker for anything long.
#   --marker <s>   wait for a fixed string the work writes to --file when it is
#     --file <p>   DONE. This watches the ARTIFACT rather than the process, so it
#                  survives the process dying, restarting under a new pid, or
#                  being wrapped in layers of shell. Limits: the work has to
#                  actually write the marker, a stale marker left by an earlier
#                  run satisfies the wait immediately, and a file that does not
#                  exist yet counts as not finished rather than as an error.
#
# Give both and the wait is satisfied only when the pid has exited AND the
# marker is present, which is the honest condition for "the work finished, and
# finished properly".
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die_usage() {
  printf 'fm-wait-for.sh: %s\n' "$1" >&2
  printf 'Wait with --pid <n> (one process by identity) and/or --marker <string> --file <path>\n' >&2
  printf '(a fixed string the work writes when done). There is deliberately no pattern mode:\n' >&2
  printf 'a process-name pattern matches the very shell doing the waiting, so the wait never\n' >&2
  printf 'ends. Run fm-wait-for.sh --help for the full reason.\n' >&2
  exit 2
}

positive_int() {
  case ${1-} in
    '' | *[!0-9]*) return 1 ;;
    *) [ "$1" -gt 0 ] ;;
  esac
}

PID=""
FILE=""
MARKER=""
TIMEOUT=3600
INTERVAL=5
QUIET=0
FILE_SET=0

while [ "$#" -gt 0 ]; do
  case $1 in
    --help | -h)
      usage
      exit 0
      ;;
    --pid)
      [ "$#" -gt 1 ] || die_usage "--pid requires a process id"
      PID=$2
      shift 2
      ;;
    --file)
      [ "$#" -gt 1 ] || die_usage "--file requires a path"
      FILE=$2
      FILE_SET=1
      shift 2
      ;;
    --marker)
      [ "$#" -gt 1 ] || die_usage "--marker requires a string"
      MARKER=$2
      shift 2
      ;;
    --timeout)
      [ "$#" -gt 1 ] || die_usage "--timeout requires whole seconds"
      TIMEOUT=$2
      shift 2
      ;;
    --interval)
      [ "$#" -gt 1 ] || die_usage "--interval requires whole seconds"
      INTERVAL=$2
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    *)
      # Everything unrecognised is refused, including a bare positional. A
      # positional fallback is exactly how a process-name pattern would get back
      # in, so there is none.
      die_usage "unknown argument '$1'"
      ;;
  esac
done

if [ -z "$PID" ] && [ -z "$MARKER" ]; then
  die_usage "nothing to wait for"
fi
if [ -n "$PID" ] && ! positive_int "$PID"; then
  die_usage "--pid must be a positive process id, not '$PID'"
fi
if [ -n "$MARKER" ] && [ "$FILE_SET" -eq 0 ]; then
  die_usage "--marker needs --file naming the file the marker is written to"
fi
if [ "$FILE_SET" -eq 1 ] && [ -z "$MARKER" ]; then
  die_usage "--file needs --marker naming the fixed string to wait for"
fi
case $TIMEOUT in
  '' | *[!0-9]*) die_usage "--timeout must be whole seconds, not '$TIMEOUT'" ;;
esac
positive_int "$INTERVAL" || die_usage "--interval must be whole seconds above zero, not '$INTERVAL'"

# grep -F: the marker is a fixed string, never a pattern. -s: a file that does
# not exist yet is "not finished", not an error.
marker_present() {
  grep -qsF -- "$MARKER" "$FILE"
}

STARTED=$(date +%s)
while :; do
  satisfied=1
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    satisfied=0
  fi
  if [ -n "$MARKER" ] && ! marker_present; then
    satisfied=0
  fi
  if [ "$satisfied" -eq 1 ]; then
    [ "$QUIET" -eq 1 ] || printf 'fm-wait-for: satisfied after %ss\n' "$(( $(date +%s) - STARTED ))"
    exit 0
  fi
  if [ "$(( $(date +%s) - STARTED ))" -ge "$TIMEOUT" ]; then
    printf 'fm-wait-for: TIMED OUT after %ss\n' "$TIMEOUT" >&2
    if [ -n "$PID" ]; then
      if kill -0 "$PID" 2>/dev/null; then
        printf '  pid %s still alive\n' "$PID" >&2
      else
        printf '  pid %s has exited\n' "$PID" >&2
      fi
    fi
    if [ -n "$MARKER" ]; then
      if marker_present; then
        printf '  marker present in %s\n' "$FILE" >&2
      else
        printf '  marker ABSENT in %s\n' "$FILE" >&2
      fi
    fi
    exit 1
  fi
  sleep "$INTERVAL"
done
