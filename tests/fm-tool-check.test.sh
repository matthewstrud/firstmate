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

# --- a PATH executable shadowed by a same-named shell builtin ------------------

# echo, printf, pwd, test, kill, and time are all bash builtins that also
# exist as real files on PATH, and the file is what this helper exists to
# report. A shadowbin of its own keeps the shadowing tools out of the fakebin
# every other case puts on PATH.
SHADOWBIN="$TMP_ROOT/shadowbin"
mkdir -p "$SHADOWBIN"
for shadowed in echo printf; do
  cat > "$SHADOWBIN/$shadowed" <<SH
#!/usr/bin/env bash
printf 'shadowed-$shadowed 7.7.7\\n'
exit 0
SH
  chmod +x "$SHADOWBIN/$shadowed"
done

# Regression: the lookup used to answer with the shell builtin in preference
# to the executable, reporting `found: echo not-a-file` and withholding a path
# and a version that both exist. Asserting the exit code alone would not have
# caught it -- the broken output was exit 0 too.
out=$(PATH="$SHADOWBIN:$PATH" "$ROOT/bin/fm-tool-check.sh" echo printf)
rc=$?
expect_code 0 "$rc" "a tool found on PATH must exit 0"
expected=$(printf 'found: echo path=%s/echo version=shadowed-echo 7.7.7\nfound: printf path=%s/printf version=shadowed-printf 7.7.7' "$SHADOWBIN" "$SHADOWBIN")
[ "$out" = "$expected" ] \
  || fail "a PATH executable must win over a same-named shell builtin: $out"
assert_not_contains "$out" "not-a-file" "a name with a real executable on PATH must never report not-a-file"
pass "a PATH executable wins over a same-named shell builtin and reports its path and version"

# The same must hold for the real system tools, not just for fixtures: these
# names are builtins, and each still has to report the absolute path of the
# installed file.
out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-tool-check.sh" printf pwd)
rc=$?
expect_code 0 "$rc" "real builtin-shadowed system tools must exit 0"
assert_not_contains "$out" "not-a-file" "an installed system tool must never report not-a-file"
while read -r line; do
  case "$line" in
    "found: "*" path=/"*) : ;;
    *) fail "a builtin-shadowed system tool must report an absolute resolved path: $line" ;;
  esac
done <<EOF
$out
EOF
pass "builtin-shadowed system tools report the absolute path of the installed file"

# --- a name that exists only inside the shell ----------------------------------

# shopt and declare are bash builtins with no executable of that name on PATH,
# so there is no path to report and no file to probe. They must still be
# reported found, never silently dropped and never given invented fields.
out=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-tool-check.sh" shopt declare)
rc=$?
expect_code 0 "$rc" "a builtin with no PATH executable still resolves, so the exit must be 0"
expected=$(printf 'found: shopt not-a-file\nfound: declare not-a-file')
[ "$out" = "$expected" ] \
  || fail "a shell-only builtin must be reported found with neither field claimed: $out"
assert_not_contains "$out" "path=" "a shell-only builtin must never be given a path"
assert_not_contains "$out" "version=" "a shell-only builtin must never be given a version"
pass "a builtin with no PATH executable is reported found with no path and no version claimed"

# --- a shell function is not an installed tool ---------------------------------

# Regression: the lookup used to answer with any shell resolution, so this
# script's OWN function names came back as found tools at exit 0 -- reporting
# something no caller could ever install as present. A function is not a tool,
# whether it is defined inside this script or exported into its environment.
out=$(env PATH="$FAKEBIN:$BASH_DIR" "$ROOT/bin/fm-tool-check.sh" usage tool_version_line)
rc=$?
expect_code 1 "$rc" "a name that is not an installed tool must exit 1"
expected=$(printf 'missing: usage\nmissing: tool_version_line')
[ "$out" = "$expected" ] \
  || fail "a function defined inside the script must be reported missing, not found: $out"
assert_not_contains "$out" "found:" "the script's own function names must never be reported as found tools"
pass "a function defined inside the script is reported missing, not mistaken for a tool"

# An exported function must not shadow the real tool it wraps either: the
# report has to answer with the executable on PATH, not with the wrapper.
out=$(PATH="$SHADOWBIN:$PATH" bash -c 'echo() { :; }; export -f echo; "$1/bin/fm-tool-check.sh" echo' _ "$ROOT")
rc=$?
expect_code 0 "$rc" "an exported wrapper must not change the answer for a real tool"
[ "$out" = "found: echo path=$SHADOWBIN/echo version=shadowed-echo 7.7.7" ] \
  || fail "an exported function must not shadow the PATH executable it wraps: $out"
pass "an exported shell function does not shadow the PATH executable of the same name"

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
