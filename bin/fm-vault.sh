#!/usr/bin/env bash
# Companion to obsidian-axi for the captain's Locusmark vault (~/vault, built
# with Quartz, deployed to docs.locusmark.com). obsidian-axi already owns
# read/search/write/link; this script owns only what it does not: triggering
# the Quartz build+deploy on demand, and wholesale-copying an existing
# project's docs into the vault.
# Usage: fm-vault.sh publish
#        fm-vault.sh import <source-dir> [--dest <folder>] [--force]
set -euo pipefail

VAULT="${FM_VAULT_PATH:-$HOME/vault}"
QUARTZ_DIR="${FM_QUARTZ_DIR:-$HOME/quartz}"

usage() {
  cat <<'EOF'
Usage: fm-vault.sh <command> [flags]

Commands:
  publish                    Build and deploy the vault to docs.locusmark.com now,
                              instead of waiting for the hourly watchdog.
  import <source-dir>        Wholesale-copy an existing project's docs into the
                              vault, for a project that already has its own
                              documentation.
    --dest <folder>          Destination folder under the vault root.
                              Defaults to the source directory's own name.
    --force                  Overwrite an existing destination folder instead
                              of refusing.

Env overrides: FM_VAULT_PATH (default ~/vault), FM_QUARTZ_DIR (default ~/quartz).
EOF
}

cmd_publish() {
  if [[ ! -x "$QUARTZ_DIR/deploy.sh" ]]; then
    echo "error: deploy script not found or not executable: $QUARTZ_DIR/deploy.sh" >&2
    exit 1
  fi
  bash "$QUARTZ_DIR/deploy.sh"
}

cmd_import() {
  local source="" dest="" force=0
  [[ $# -gt 0 && "$1" != -* ]] && { source="$1"; shift; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dest) dest="$2"; shift 2 ;;
      --force) force=1; shift ;;
      -*) echo "error: unknown flag: $1" >&2; exit 2 ;;
      *) echo "error: unexpected argument: $1" >&2; exit 2 ;;
    esac
  done

  if [[ -z "$source" ]]; then
    echo "error: source directory required" >&2
    exit 2
  fi
  if [[ ! -d "$source" ]]; then
    echo "error: source is not a directory: $source" >&2
    exit 1
  fi
  if [[ -z "$dest" ]]; then
    dest="$(basename "$(cd "$source" && pwd)")"
  fi

  local dest_path="$VAULT/$dest"
  if [[ -e "$dest_path" && "$force" -ne 1 ]]; then
    local existing
    existing="$(find "$dest_path" -mindepth 1 -print -quit 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
      echo "error: $dest already exists in the vault and is non-empty; pass --force to overwrite" >&2
      exit 1
    fi
  fi

  mkdir -p "$dest_path"
  local copied
  if command -v rsync >/dev/null 2>&1; then
    # --ignore-times is load-bearing, not a tuning knob. rsync's default quick
    # check skips any file whose size AND mtime both match the destination, so a
    # real content change under an unchanged size and timestamp is silently not
    # transferred and import reports a success it did not perform. The fallback
    # branch below empties the destination and re-copies, so it always
    # overwrites; without --ignore-times this command would mean one thing on a
    # machine with rsync and another on a machine without it.
    rsync -a --delete --ignore-times \
      --exclude '.git' --exclude 'node_modules' --exclude '.DS_Store' \
      "$(cd "$source" && pwd)/" "$dest_path/"
  else
    find "$dest_path" -mindepth 1 -delete
    cp -r "$source/." "$dest_path/"
    rm -rf "$dest_path/.git" "$dest_path/node_modules"
  fi
  copied="$(find "$dest_path" -type f | wc -l | tr -d ' ')"

  echo "imported $copied files to $dest"
  echo "next: obsidian-axi ls $dest -r   |   fm-vault.sh publish to go live"
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

case "$1" in
  --help|-h) usage; exit 0 ;;
  publish) shift; cmd_publish "$@" ;;
  import) shift; cmd_import "$@" ;;
  *)
    echo "error: unknown command: $1" >&2
    usage >&2
    exit 2
    ;;
esac
