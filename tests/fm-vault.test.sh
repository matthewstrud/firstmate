#!/usr/bin/env bash
# Behavior tests for fm-vault.sh: publish wraps the Quartz deploy script
# verbatim (no reimplemented build logic to drift from it), and import copies
# a source directory wholesale into a destination under the vault, refusing
# to clobber an existing non-empty destination unless --force is passed.
#
# import's copy step has two implementations, chosen by whether rsync is on
# PATH, and they must mean the same thing. A case that runs only whichever
# branch the host happens to provide cannot see them diverge, which is how
# --force reached main silently keeping the old content on rsync hosts. The
# helpers below drive both branches from one host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-vault-tests)

# Every source carries one file of identical size at an identical pinned mtime,
# so a later --force import always presents rsync's default quick check with the
# size-and-mtime match that makes it skip a real content change. Leaving the
# mtime to the clock would arm that trap only when both sources happened to land
# in the same tick, which is a coin toss, not a regression test.
FM_VAULT_PINNED_MTIME=202001010000.00

new_source() {
  local n=$1 dir="$TMP_ROOT/src-$1"
  mkdir -p "$dir/docs"
  printf '# hello %s\n' "$n" > "$dir/docs/readme.md"
  touch -t "$FM_VAULT_PINNED_MTIME" "$dir/docs/readme.md"
  printf '%s\n' "$dir"
}

# The tools fm-vault.sh's import needs once rsync is taken away. bash is here
# because the script's own #!/usr/bin/env bash shebang resolves it through PATH.
FM_VAULT_TOOLS=(bash find mkdir cp rm wc tr basename cat)

# fm_vault_build_norsync_path: build a PATH on which rsync is genuinely absent,
# so the fallback copy branch runs even on a host that has rsync installed, and
# refuse to continue if rsync survives it - a shim that still exposes rsync
# would quietly turn every "fallback branch" case into a second run of the rsync
# branch. Sets FM_VAULT_NORSYNC_PATH rather than echoing, because `fail` inside a
# command substitution would only kill the subshell and leave the caller running
# with an empty PATH.
FM_VAULT_NORSYNC_PATH=""

fm_vault_build_norsync_path() {
  local shim="$TMP_ROOT/norsync-bin" tool src
  mkdir -p "$shim"
  for tool in "${FM_VAULT_TOOLS[@]}"; do
    src=$(type -P "$tool") || fail "test setup: $tool is not on PATH, so the rsync-free PATH cannot be built"
    ln -sf "$src" "$shim/$tool"
  done
  if env PATH="$shim" bash -c 'command -v rsync >/dev/null 2>&1'; then
    fail "test setup: rsync is still reachable on the rsync-free PATH, so the fallback copy branch would never run"
  fi
  FM_VAULT_NORSYNC_PATH="$shim"
}

# fm_vault_build_rsync_probe_path: build a PATH whose rsync records that it ran
# and then execs the real one, so a case can prove it took the rsync branch
# instead of assuming it from rsync being installed. Returns non-zero when the
# host has no rsync at all, leaving the caller to say so rather than compare the
# fallback branch against itself and call that agreement.
FM_VAULT_RSYNC_PROBE_PATH=""
FM_VAULT_RSYNC_PROBE_LOG=""

fm_vault_build_rsync_probe_path() {
  local shim="$TMP_ROOT/rsync-probe-bin" real
  real=$(type -P rsync) || return 1
  mkdir -p "$shim"
  FM_VAULT_RSYNC_PROBE_LOG="$TMP_ROOT/rsync-probe.log"
  rm -f "$FM_VAULT_RSYNC_PROBE_LOG"
  cat > "$shim/rsync" <<EOF
#!/usr/bin/env bash
printf 'ran\n' >> "$FM_VAULT_RSYNC_PROBE_LOG"
exec "$real" "\$@"
EOF
  chmod +x "$shim/rsync"
  FM_VAULT_RSYNC_PROBE_PATH="$shim"
}

test_import_fresh_destination_copies_files() {
  local vault="$TMP_ROOT/vault-fresh" src out
  mkdir -p "$vault"
  src=$(new_source fresh)
  out=$(FM_VAULT_PATH="$vault" "$ROOT/bin/fm-vault.sh" import "$src" --dest proj 2>&1)
  expect_code 0 "$?" "import into a fresh destination exits 0"
  assert_present "$vault/proj/docs/readme.md" "import copied the source file into the vault"
  assert_contains "$out" "imported 1 files to proj" "import reports the file count and destination"
  pass "import into a fresh destination copies files wholesale"
}

test_import_default_dest_uses_source_basename() {
  local vault="$TMP_ROOT/vault-defaultdest" src
  mkdir -p "$vault"
  src=$(new_source defaultdest)
  FM_VAULT_PATH="$vault" "$ROOT/bin/fm-vault.sh" import "$src" >/dev/null
  assert_present "$vault/$(basename "$src")/docs/readme.md" "import defaulted the destination to the source directory's own name"
  pass "import with no --dest uses the source directory's own name"
}

test_import_refuses_nonempty_destination_without_force() {
  local vault="$TMP_ROOT/vault-noclobber" src out code
  mkdir -p "$vault"
  src=$(new_source noclobber)
  FM_VAULT_PATH="$vault" "$ROOT/bin/fm-vault.sh" import "$src" --dest proj >/dev/null
  out=$(FM_VAULT_PATH="$vault" "$ROOT/bin/fm-vault.sh" import "$src" --dest proj 2>&1); code=$?
  expect_code 1 "$code" "re-importing onto a non-empty destination without --force fails"
  assert_contains "$out" "pass --force to overwrite" "refusal names the --force escape hatch"
  pass "import refuses to clobber an existing non-empty destination without --force"
}

test_import_force_overwrites_existing_destination() {
  local vault="$TMP_ROOT/vault-force" src1 src2
  mkdir -p "$vault"
  src1=$(new_source force1)
  src2=$(new_source force2)
  FM_VAULT_PATH="$vault" "$ROOT/bin/fm-vault.sh" import "$src1" --dest proj >/dev/null
  FM_VAULT_PATH="$vault" "$ROOT/bin/fm-vault.sh" import "$src2" --dest proj --force >/dev/null
  expect_code 0 "$?" "import --force over an existing destination exits 0"
  assert_grep "hello force2" "$vault/proj/docs/readme.md" "import --force replaced the old content with the new source's content"
  pass "import --force overwrites an existing destination"
}

test_import_force_overwrites_without_rsync() {
  local vault="$TMP_ROOT/vault-force-norsync" src1 src2
  mkdir -p "$vault"
  fm_vault_build_norsync_path
  src1=$(new_source norsync1)
  src2=$(new_source norsync2)
  PATH="$FM_VAULT_NORSYNC_PATH" FM_VAULT_PATH="$vault" "$ROOT/bin/fm-vault.sh" import "$src1" --dest proj >/dev/null
  PATH="$FM_VAULT_NORSYNC_PATH" FM_VAULT_PATH="$vault" "$ROOT/bin/fm-vault.sh" import "$src2" --dest proj --force >/dev/null
  expect_code 0 "$?" "import --force over an existing destination exits 0 with no rsync installed"
  assert_grep "hello norsync2" "$vault/proj/docs/readme.md" "import --force replaced the old content with no rsync installed"
  pass "import --force overwrites an existing destination on a host without rsync"
}

test_import_force_means_the_same_with_and_without_rsync() {
  local rsync_vault="$TMP_ROOT/vault-parity-rsync" fallback_vault="$TMP_ROOT/vault-parity-fallback" src1 src2
  mkdir -p "$rsync_vault" "$fallback_vault"
  src1=$(new_source parity1)
  src2=$(new_source parity2)

  fm_vault_build_norsync_path
  PATH="$FM_VAULT_NORSYNC_PATH" FM_VAULT_PATH="$fallback_vault" "$ROOT/bin/fm-vault.sh" import "$src1" --dest proj >/dev/null
  PATH="$FM_VAULT_NORSYNC_PATH" FM_VAULT_PATH="$fallback_vault" "$ROOT/bin/fm-vault.sh" import "$src2" --dest proj --force >/dev/null
  assert_grep "hello parity2" "$fallback_vault/proj/docs/readme.md" "import --force delivered the new content on the fallback copy branch"

  if ! fm_vault_build_rsync_probe_path; then
    pass "import --force delivered the new content; rsync is not installed on this host, so only the fallback copy branch was checked"
    return 0
  fi

  PATH="$FM_VAULT_RSYNC_PROBE_PATH:$PATH" FM_VAULT_PATH="$rsync_vault" "$ROOT/bin/fm-vault.sh" import "$src1" --dest proj >/dev/null
  PATH="$FM_VAULT_RSYNC_PROBE_PATH:$PATH" FM_VAULT_PATH="$rsync_vault" "$ROOT/bin/fm-vault.sh" import "$src2" --dest proj --force >/dev/null
  assert_present "$FM_VAULT_RSYNC_PROBE_LOG" "the rsync-branch run must actually have invoked rsync, or this case is comparing the fallback branch with itself"
  assert_grep "hello parity2" "$rsync_vault/proj/docs/readme.md" "import --force delivered the new content on the rsync copy branch"
  diff -r "$rsync_vault/proj" "$fallback_vault/proj" >/dev/null ||
    fail "import --force produced different vault content depending on whether rsync is installed"
  pass "import --force means the same thing with and without rsync installed"
}

test_import_missing_source_errors() {
  local vault="$TMP_ROOT/vault-missingsrc" out code
  mkdir -p "$vault"
  out=$(FM_VAULT_PATH="$vault" "$ROOT/bin/fm-vault.sh" import "$TMP_ROOT/does-not-exist" 2>&1); code=$?
  expect_code 1 "$code" "import of a missing source directory exits 1"
  assert_contains "$out" "is not a directory" "import names the missing source in its error"
  pass "import of a missing source directory fails loudly"
}

test_publish_wraps_deploy_script_verbatim() {
  local quartz="$TMP_ROOT/quartz-ok" out
  mkdir -p "$quartz"
  cat > "$quartz/deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo "deployed 3 files to /fake/dest"
EOF
  chmod +x "$quartz/deploy.sh"
  out=$(FM_QUARTZ_DIR="$quartz" "$ROOT/bin/fm-vault.sh" publish 2>&1)
  expect_code 0 "$?" "publish exits 0 when the deploy script succeeds"
  assert_contains "$out" "deployed 3 files to /fake/dest" "publish relays the deploy script's own output verbatim"
  pass "publish runs the Quartz deploy script and relays its output"
}

test_publish_missing_deploy_script_errors() {
  local quartz="$TMP_ROOT/quartz-missing" out code
  mkdir -p "$quartz"
  out=$(FM_QUARTZ_DIR="$quartz" "$ROOT/bin/fm-vault.sh" publish 2>&1); code=$?
  expect_code 1 "$code" "publish exits 1 when the deploy script is absent"
  assert_contains "$out" "deploy script not found" "publish names the missing deploy script"
  pass "publish fails loudly when the Quartz deploy script is missing"
}

test_unknown_command_errors() {
  local out code
  out=$("$ROOT/bin/fm-vault.sh" bogus 2>&1); code=$?
  [ "$code" -ne 0 ] || fail "an unknown command must not exit 0"
  assert_contains "$out" "unknown command" "an unknown command names itself in the error"
  pass "an unknown command fails loudly instead of doing nothing"
}

test_import_fresh_destination_copies_files
test_import_default_dest_uses_source_basename
test_import_refuses_nonempty_destination_without_force
test_import_force_overwrites_existing_destination
test_import_force_overwrites_without_rsync
test_import_force_means_the_same_with_and_without_rsync
test_import_missing_source_errors
test_publish_wraps_deploy_script_verbatim
test_publish_missing_deploy_script_errors
test_unknown_command_errors
