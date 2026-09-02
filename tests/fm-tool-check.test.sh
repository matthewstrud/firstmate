#!/usr/bin/env bash
# tests/fm-tool-check.test.sh - unit tests for the PATH and --version presence
# report (bin/fm-tool-check.sh). Drives the script's public CLI through a
# fakebin PATH, so no real tool versions are needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tool-check)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

# goodtool: exists and answers --version cleanly on stdout.
cat > "$FAKEBIN/goodtool" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'goodtool 1.2.3\n'
  exit 0
fi
exit 0
SH
chmod +x "$FAKEBIN/goodtool"

# errtool: exists and answers --version cleanly, but on stderr only.
cat > "$FAKEBIN/errtool" <<'SH'
#!/usr/bin/env bash
printf 'errtool 9.9\n' >&2
exit 0
SH
chmod +x "$FAKEBIN/errtool"

# novertool: exists but rejects --version with a nonzero exit.
cat > "$FAKEBIN/novertool" <<'SH'
#!/usr/bin/env bash
echo "novertool: unrecognized option '--version'" >&2
exit 2
SH
chmod +x "$FAKEBIN/novertool"

# slowtool: exists but hangs on any invocation.
cat > "$FAKEBIN/slowtool" <<'SH'
#!/usr/bin/env bash
sleep 10
SH
chmod +x "$FAKEBIN/slowtool"

# silenttool: exists and answers --version with nothing, exit 0.
fm_fake_exit0 "$FAKEBIN" silenttool

# --- a tool that exists and reports a version ---------------------------------

out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-tool-check.sh" goodtool)
rc=$?
expect_code 0 "$rc" "a found tool must exit 0"
[ "$out" = "found: goodtool path=$FAKEBIN/goodtool version=goodtool 1.2.3" ] \
  || fail "the found line must carry the resolved path and the first version line exactly: $out"
pass "a tool that exists and reports a version is reported on one exact line with its resolved path"

# A version printed to stderr must be captured too (the report merges both
# streams, matching the ad-hoc pattern it replaces).
out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-tool-check.sh" errtool)
rc=$?
expect_code 0 "$rc" "a stderr-only version answer must still exit 0"
[ "$out" = "found: errtool path=$FAKEBIN/errtool version=errtool 9.9" ] \
  || fail "a stderr-only version must be reported: $out"
pass "a version printed to stderr is captured into the report"

# --- a tool that does not exist on PATH ----------------------------------------

# A PATH reduced to the fakebin plus the real bash's own directory proves the
# tool is absent while the shebang's env still resolves bash. The missing path
# uses no external command, so the reduced PATH cannot disturb the script's
# own machinery.
BASH_DIR=$(dirname "$(command -v bash)")
out=$(env PATH="$FAKEBIN:$BASH_DIR" "$ROOT/bin/fm-tool-check.sh" fm-not-a-real-tool)
rc=$?
expect_code 1 "$rc" "a missing tool must exit 1"
[ "$out" = "missing: fm-not-a-real-tool" ] \
  || fail "the missing line must name the tool and nothing else: $out"
pass "a tool that is not on PATH is reported missing and exits 1"

# --- a tool that exists but does not support --version cleanly -----------------

out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-tool-check.sh" novertool)
rc=$?
expect_code 0 "$rc" "a tool whose --version exits nonzero is still present, so the exit must be 0"
[ "$out" = "found: novertool path=$FAKEBIN/novertool version=unavailable" ] \
  || fail "a failing --version must report found with version=unavailable, never missing: $out"
pass "a tool that exists but rejects --version is reported found with version=unavailable"

out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-tool-check.sh" silenttool)
rc=$?
expect_code 0 "$rc" "a tool whose --version prints nothing is still present, so the exit must be 0"
[ "$out" = "found: silenttool path=$FAKEBIN/silenttool version=unavailable" ] \
  || fail "an empty --version answer must report version=unavailable: $out"
pass "a tool whose --version prints nothing is reported found with version=unavailable"

# A hung --version must hit the probe bound instead of hanging the check, and
# must still report the tool as present.
out=$(env PATH="$FAKEBIN:$PATH" FM_TOOL_CHECK_PROBE_SECS=1 "$ROOT/bin/fm-tool-check.sh" slowtool)
rc=$?
expect_code 0 "$rc" "a hung --version probe must not fail the presence check"
[ "$out" = "found: slowtool path=$FAKEBIN/slowtool version=unavailable" ] \
  || fail "a hung --version must report found with version=unavailable: $out"
pass "a hung --version hits the probe bound and is reported found with version=unavailable"

# --- a name that resolves in the shell rather than to a file on disk -----------

# `command -v echo` resolves the shell builtin and hands back the bare name
# `echo`, which is neither a path to report nor a file to probe. Regression:
# the report used to print `found: echo path=echo version=--version` at exit 0
# -- both fields false, because it probed the bare name and the builtin simply
# echoed the flag back. Asserting the exit code alone would not have caught it.
out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-tool-check.sh" echo printf)
rc=$?
expect_code 0 "$rc" "a name that resolves as a shell builtin is still present, so the exit must be 0"
expected=$(printf 'found: echo not-a-file\nfound: printf not-a-file')
[ "$out" = "$expected" ] \
  || fail "a shell builtin must be reported found with neither field claimed: $out"
assert_not_contains "$out" "path=echo" "a bare builtin name must never be reported as a resolved path"
assert_not_contains "$out" "path=printf" "a bare builtin name must never be reported as a resolved path"
assert_not_contains "$out" "version=--version" "the flag echoed back by a builtin must never be reported as a version"
pass "a shell builtin is reported found with no path and no version claimed"

# --- a tool name that begins with a dash ---------------------------------------

# The presence lookup passes `--`, so bash's own `command` builtin does not
# parse a leading-dash tool name as one of its options and leak
# `command: --: invalid option` plus its usage text onto stderr.
dash_err="$TMP_ROOT/dash.err"
out=$(env PATH="$FAKEBIN:$BASH_DIR" "$ROOT/bin/fm-tool-check.sh" --version 2>"$dash_err")
rc=$?
expect_code 1 "$rc" "a leading-dash name that does not resolve must still exit 1"
[ "$out" = "missing: --version" ] \
  || fail "a leading-dash name must be reported missing like any other: $out"
[ ! -s "$dash_err" ] \
  || fail "a leading-dash name must not leak shell internals to stderr: $(cat "$dash_err")"
pass "a tool name beginning with a dash is reported missing with a clean stderr"

# --- multiple tools, argument order, mixed exit --------------------------------

out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-tool-check.sh" goodtool fm-not-a-real-tool novertool)
rc=$?
expect_code 1 "$rc" "any missing tool must make the exit 1"
expected=$(printf 'found: goodtool path=%s/goodtool version=goodtool 1.2.3\nmissing: fm-not-a-real-tool\nfound: novertool path=%s/novertool version=unavailable' "$FAKEBIN" "$FAKEBIN")
[ "$out" = "$expected" ] \
  || fail "multiple tools must report one line each, in argument order: $out"
pass "multiple tools report one line each in argument order, exiting 1 when any is missing"

# --- usage handling -------------------------------------------------------------

out=$("$ROOT/bin/fm-tool-check.sh" --help 2>&1)
rc=$?
expect_code 0 "$rc" "--help must exit 0"
assert_contains "$out" "usage: fm-tool-check.sh" "--help must print the usage line"
pass "--help prints usage and exits 0"

out=$("$ROOT/bin/fm-tool-check.sh" 2>&1)
rc=$?
expect_code 2 "$rc" "no arguments must be a usage error"
assert_contains "$out" "usage: fm-tool-check.sh" "the usage error must print usage"
pass "no arguments is a usage error with exit 2"

out=$(env FM_TOOL_CHECK_PROBE_SECS=banana PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-tool-check.sh" goodtool 2>&1)
rc=$?
expect_code 2 "$rc" "an invalid FM_TOOL_CHECK_PROBE_SECS must be a usage error"
pass "an invalid FM_TOOL_CHECK_PROBE_SECS is rejected with a usage error"

# The range guard is the only thing standing between a caller and an unbounded
# probe: bin/fm-timeout-lib.sh states that a non-positive bound is not a bound,
# because `timeout 0` and the perl fallback's `alarm 0` both disable the
# deadline, so callers must reject 0 before calling.
for probe_secs in 0 31; do
  out=$(env FM_TOOL_CHECK_PROBE_SECS="$probe_secs" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-tool-check.sh" goodtool 2>&1)
  rc=$?
  expect_code 2 "$rc" "an out-of-range FM_TOOL_CHECK_PROBE_SECS ($probe_secs) must be a usage error"
  assert_contains "$out" "FM_TOOL_CHECK_PROBE_SECS must be an integer between 1 and 30" \
    "the range error must name the accepted range (got probe seconds $probe_secs)"
  assert_not_contains "$out" "found: goodtool" \
    "an out-of-range bound must be rejected before any tool is probed (got probe seconds $probe_secs)"
done
pass "an out-of-range FM_TOOL_CHECK_PROBE_SECS (0 and 31) is rejected before any probe runs"

echo "# fm-tool-check.test.sh: all assertions passed"
