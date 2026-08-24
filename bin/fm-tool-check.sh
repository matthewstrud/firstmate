#!/usr/bin/env bash
# fm-tool-check.sh - report, one line per named tool, whether the command
# resolves (command -v semantics), its resolved path, and the first line of
# its --version output.
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
#   missing: <tool>
#
# Exits 0 when every named tool resolves, 1 when any does not, and 2 on a
# usage error. The version probe is fed /dev/null on stdin and hard-bound by
# FM_TOOL_CHECK_PROBE_SECS (default 5, valid 1..30) so a hung tool cannot
# hang the check.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  echo "usage: fm-tool-check.sh <tool> [<tool>...]" >&2
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

# Print the first line of <tool> --version, trimmed, or nothing. The probe is
# hard-bound and fed /dev/null on stdin, so a tool that rejects --version,
# exits nonzero, prints nothing, or hangs reports no version instead of
# failing the presence check.
tool_version_line() {
  local tool=$1 out line rc=0
  out=$(fm_run_timed "$PROBE_SECS" "$tool" --version </dev/null 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || return 0
  line=${out%%$'\n'*}
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s' "$line"
}

missing=0
for tool in "$@"; do
  if ! path=$(command -v "$tool"); then
    printf 'missing: %s\n' "$tool"
    missing=1
    continue
  fi
  version=$(tool_version_line "$tool")
  if [ -n "$version" ]; then
    printf 'found: %s path=%s version=%s\n' "$tool" "$path" "$version"
  else
    printf 'found: %s path=%s version=unavailable\n' "$tool" "$path"
  fi
done
[ "$missing" -eq 0 ] || exit 1
