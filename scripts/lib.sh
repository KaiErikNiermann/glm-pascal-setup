#!/usr/bin/env bash
# Shared helpers. Sourced by every script -- no duplicated logic.
# shellcheck shell=bash

set -euo pipefail

_c() { if [ -t 2 ]; then printf '\033[%sm' "$1" >&2; fi; }
log()  { _c '0;36'; printf '==> %s\n' "$*" >&2; _c '0'; }
ok()   { _c '0;32'; printf '  ok  %s\n' "$*" >&2; _c '0'; }
warn() { _c '0;33'; printf '  !!  %s\n' "$*" >&2; _c '0'; }
die()  { _c '0;31'; printf 'ERROR: %s\n' "$*" >&2; _c '0'; exit 1; }

# need <command> [install hint]
need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found.${2:+ $2}"
}

# Locate and source settings.env, falling back to the example.
load_settings() {
  local here root
  here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  root="$(dirname "$here")"
  if [ -f "$root/config/settings.env" ]; then
    # shellcheck disable=SC1091
    . "$root/config/settings.env"
  elif [ -f "$root/config/settings.env.example" ]; then
    warn "config/settings.env not found -- using defaults from settings.env.example"
    # shellcheck disable=SC1091
    . "$root/config/settings.env.example"
  else
    die "no settings file found under $root/config/"
  fi
  REPO_ROOT="$root"
  BIN_DIR="${LLM_ROOT}/bin"
  MODEL_PATH="${LLM_ROOT}/models/${MODEL_FILE}"
  export REPO_ROOT BIN_DIR MODEL_PATH
}

# Bytes of free space on the filesystem holding $1, in GiB.
free_gib() { df -PB1 "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1073741824}'; }
