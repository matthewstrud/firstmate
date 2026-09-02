#!/usr/bin/env bash
# fm-tool-check.sh - a one-shot presence report for the tools named on its
# command line: whether each one resolves, its resolved path, and the first
# line of its --version output. Its similarly named neighbour
# bin/fm-tool-update-check.sh does an unrelated job - it polls a configured
# set of watched tools for available UPDATES on the watcher's cadence, with
# its own arm/disarm lifecycle.
#
# Replaces the ad-hoc pattern
#   command -v <tool> 2>/dev/null && <tool> --version 2>&1 || echo "<tool> not found on PATH"
# The version attempt is deliberately decoupled from presence: a nonzero
# exit, empty output, or a hit probe bound reports the tool as found with
# version=unavailable, never as not found.
#
# Usage:
#   fm-tool-check.sh <tool> [<tool>...]
#
# Prints one line per tool, in argument order:
#   found: <tool> path=<resolved path> version=<first line of --version>
#   found: <tool> path=<resolved path> version=unavailable
#   found: <tool> not-a-file
#   missing: <tool>
#
# The not-a-file line reports a name that resolves inside the shell rather
# than to an executable file on disk - a builtin, keyword, function, or alias
# such as echo, printf, or pwd. Such a name has no path to report and no file
# to probe, so neither field is claimed rather than being filled with a value
# that is not true. It still resolves, so it is not missing and does not make
# the exit 1.
#
# Exits 0 when every named tool resolves, 1 when any does not, and 2 on a
# usage error. The version probe runs the resolved path rather than the bare
# name, so the file reported is the file probed. It is fed /dev/null on stdin
# and hard-bound by FM_TOOL_CHECK_PROBE_SECS (default 5, valid 1..30) so a
# hung tool cannot hang the check.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-tool-check.sh <tool> [<tool>...]

One-shot presence report for the named tools, one line each in argument order
(not fm-tool-update-check.sh, which polls watched tools for available updates):
  found: <tool> path=<resolved path> version=<first line of --version>
  found: <tool> path=<resolved path> version=unavailable
  found: <tool> not-a-file   resolves in the shell (builtin, keyword, function,
                             alias), so no path or version is claimed
  missing: <tool>

Exits 0 when every named tool resolves, 1 when any does not, 2 on a usage error.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -ge 1 ] || { usage; exit 2; }

PROBE_SECS=${FM_TOOL_CHECK_PROBE_SECS:-5}
case "$PROBE_SECS" in
  ''|*[!0-9]*) echo "error: FM_TOOL_CHECK_PROBE_SECS must be an integer between 1 and 30, got: $PROBE_SECS" >&2; exit 2 ;;
esac
if [ "$PROBE_SECS" -lt 1 ] || [ "$PROBE_SECS" -gt 30 ]; then
  echo "error: FM_TOOL_CHECK_PROBE_SECS must be an integer between 1 and 30, got: $PROBE_SECS" >&2
  exit 2
fi

# True when a `command -v` resolution names an executable file on disk. A
# builtin, keyword, function, or alias resolves to a bare name with no slash
# in it, which is neither a path to report nor a file to probe.
resolution_is_file() {
  case "$1" in
    */*) [ -f "$1" ] && [ -x "$1" ] ;;
    *) return 1 ;;
  esac
}

# Print the first line of <path> --version, trimmed, or nothing. The probe is
# hard-bound and fed /dev/null on stdin, so a tool that rejects --version,
# exits nonzero, prints nothing, or hangs reports no version instead of
# failing the presence check.
tool_version_line() {
  local path=$1 out line rc=0
  out=$(fm_run_timed "$PROBE_SECS" "$path" --version </dev/null 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || return 0
  line=${out%%$'\n'*}
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s' "$line"
}

missing=0
for tool in "$@"; do
  if ! path=$(command -v -- "$tool"); then
    printf 'missing: %s\n' "$tool"
    missing=1
    continue
  fi
  if ! resolution_is_file "$path"; then
    printf 'found: %s not-a-file\n' "$tool"
    continue
  fi
  version=$(tool_version_line "$path")
  if [ -n "$version" ]; then
    printf 'found: %s path=%s version=%s\n' "$tool" "$path" "$version"
  else
    printf 'found: %s path=%s version=unavailable\n' "$tool" "$path"
  fi
done
[ "$missing" -eq 0 ] || exit 1
