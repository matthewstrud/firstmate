#!/usr/bin/env bash
# fm-secondmate-report.sh - optional helper to append a correlated parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh).
#
# The write destination is mechanical: this helper never takes a status path.
# It resolves the parent channel through fm_parent_channel_destination
# (bin/fm-parent-channel-lib.sh): a local mate writes the parent home's
# state/<id>.status, and a remote mate writes this home's
# state/parent-replies.status. Call it from the secondmate home with FM_HOME
# set to that home.
#
# Usage:
#   fm-secondmate-report.sh [--key <key>] <verb> <corr_id> <note...>
#   fm-secondmate-report.sh [--key <key>] --doc <verb> <corr_id> <doc-path> <note...>
#
# Examples:
#   fm-secondmate-report.sh done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --key api-shape blocked abcdef0123456789 "needs the wall shape"
#   fm-secondmate-report.sh --doc done abcdef0123456789 data/x/report.md "see report"
#
# When --key <key> is given the status line carries [key=<key>] at the note
# head (immediately after the colon), which is the only bracket position
# bin/fm-classify-lib.sh reads as a decision key via _fm_key_at_note_head.
# The corr token stays in the leading bracket as [corr=<id>], so
# fm_pending_reply_extract_corr and the pending-reply contract
# (bin/fm-pending-reply-lib.sh) still correlate the reply. A [key=<key>]
# placed anywhere else in the note is silently ignored by the fold, so this
# helper is the sanctioned way to put one in the only position that works.
# A call with no key writes the historical [corr=<id>] bracket shape
# byte-for-byte, so existing callers and their tests are unchanged.
set -eu

CALLER_FM_HOME=${FM_HOME:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-secondmate-report.sh [--key <key>] <verb> <corr_id> <note...>
  fm-secondmate-report.sh [--key <key>] --doc <verb> <corr_id> <doc-path> <note...>
EOF
  exit 2
}

KEY=
DOC_MODE=0
KEY_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --key)
      KEY_SET=1
      [ $# -ge 2 ] || { echo "error: --key requires an argument" >&2; exit 1; }
      KEY=$2
      shift 2
      ;;
    --doc)
      DOC_MODE=1
      shift
      ;;
    *) break ;;
  esac
done

if [ "$KEY_SET" = 1 ]; then
  case "$KEY" in
    ''|*[!A-Za-z0-9._-]*|-*)
      echo "error: --key '$KEY' is not a valid decision key (nonempty, A-Z a-z 0-9 . _ -, and not starting with -)" >&2
      exit 1
      ;;
  esac
fi

[ $# -ge 2 ] || usage
VERB=$1
CORR=$2
shift 2
if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] && [ -n "$1" ] || usage
else
  [ $# -ge 1 ] && [ -n "$*" ] || usage
fi

case "$CORR" in
  corr=*) CORR=${CORR#corr=} ;;
esac
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    exit 1
    ;;
esac

HOME_DIR=$CALLER_FM_HOME
case "$HOME_DIR" in
  '')
    echo "error: FM_HOME is required so the helper can resolve the parent channel" >&2
    exit 1
    ;;
esac
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"

DESTINATION=
DEST_RC=0
DESTINATION=$(fm_parent_channel_destination "$HOME_DIR" "$STATE_DIR") || DEST_RC=$?
if [ "$DEST_RC" -ne 0 ] || [ -z "$DESTINATION" ]; then
  echo "error: cannot resolve the parent channel from this home (not a seeded secondmate?)" >&2
  exit 1
fi
mkdir -p "$(dirname "$DESTINATION")" 2>/dev/null || true
if [ ! -d "$(dirname "$DESTINATION")" ]; then
  echo "error: cannot create parent directory for status file '$DESTINATION'" >&2
  exit 1
fi

token=$(fm_pending_reply_corr_token "$CORR")
if [ -n "$KEY" ]; then
  KEY_PREFIX="[key=$KEY] "
else
  KEY_PREFIX=""
fi
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf '%s [%s]: %s%s (%s via-helper)\n' "$VERB" "$token" "$KEY_PREFIX" "$NOTE" "$DOC_PATH" >> "$DESTINATION"
  else
    printf '%s [%s]: %s%s (via-helper)\n' "$VERB" "$token" "$KEY_PREFIX" "$DOC_PATH" >> "$DESTINATION"
  fi
else
  NOTE=$*
  printf '%s [%s]: %s%s (via-helper)\n' "$VERB" "$token" "$KEY_PREFIX" "$NOTE" >> "$DESTINATION"
fi
