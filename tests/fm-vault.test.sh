#!/usr/bin/env bash
# Behavior tests for fm-vault.sh: publish wraps the Quartz deploy script
# verbatim (no reimplemented build logic to drift from it), and import copies
# a source directory wholesale into a destination under the vault, refusing
# to clobber an existing non-empty destination unless --force is passed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-vault-tests)

new_source() {
  local n=$1 dir="$TMP_ROOT/src-$1"
  mkdir -p "$dir/docs"
  printf '# hello %s\n' "$n" > "$dir/docs/readme.md"
  printf '%s\n' "$dir"
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
test_import_missing_source_errors
test_publish_wraps_deploy_script_verbatim
test_publish_missing_deploy_script_errors
test_unknown_command_errors
