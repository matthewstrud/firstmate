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
# Lookup is PATH-first, so a real executable always wins: echo, printf, and
# pwd report their /usr/bin file and its version even though the shell also
# has a builtin of that name.
#
# The not-a-file line reports a name that exists only inside the shell - a
# builtin or keyword with no executable of that name anywhere on PATH, such as
# shopt, declare, or export. Such a name has no path to report and no file to
# probe, so neither field is claimed rather than being filled with a value
# that is not true. It still resolves, so it is not missing and does not make
# the exit 1.
#
# A shell function or alias is not an installed tool, so it is reported
# missing rather than found. Nothing a caller could not install is ever
# claimed as present, including this script's own function names.
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
  found: <tool> not-a-file   a builtin or keyword with no executable of that
                             name on PATH, so no path or version is claimed
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

# `type -P` searches PATH alone, ignoring the builtins, keywords, functions,
# and aliases that `command -v` would answer with in preference to a real
# executable, and it rejects a directory or a non-executable file.
missing=0
for tool in "$@"; do
  path=$(type -P -- "$tool" 2>/dev/null) || path=
  if [ -z "$path" ]; then
    case "$(type -t -- "$tool" 2>/dev/null || true)" in
      builtin|keyword)
        printf 'found: %s not-a-file\n' "$tool"
        ;;
      *)
        printf 'missing: %s\n' "$tool"
        missing=1
        ;;
    esac
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
