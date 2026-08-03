#!/usr/bin/env bash
# eurouter-autoheal.sh — silently re-apply the EU Router provider patches if
# they're missing, safe to call unattended before every `hermes` invocation.
#
# WHY THIS EXISTS
# ----------------
# `install-eurouter-provider.sh` does the actual work (fetch + cherry-pick),
# but it's built for INTERACTIVE use: it refuses a dirty target tree outright,
# and leaves a real conflict in the normal mid-cherry-pick state for a human
# to resolve. Neither behaviour is safe to call from a shell shim that runs
# before every single `hermes` command — a dirty tree is the COMMON case (any
# uncommitted local WIP), and an unattended conflict must never be left
# half-applied where nothing is watching to fix it.
#
# This script wraps it for that unattended context:
#   1. Fast, local, no-network check: is EU Router already registered? If so,
#      exit immediately — the common case costs nothing.
#   2. If missing and the tree is dirty, stash everything (including
#      untracked files) so the install script's own dirty-tree guard passes.
#   3. Run the install script. On ANY failure (network, real conflict, syntax
#      check) abort a stuck cherry-pick if one is in progress, so the repo
#      never sits half-applied.
#   4. ALWAYS restore the stash afterwards, success or failure — a user's own
#      uncommitted work must never be silently held hostage by this script.
#   5. Print exactly one status line either way; full output goes to a log
#      file for troubleshooting, not the caller's terminal.
#
# USAGE
#   scripts/eurouter-autoheal.sh [TARGET_DIR]
#   TARGET_DIR defaults to ~/.hermes/hermes-agent. Meant to be called from a
#   shell shim wrapping the real `hermes` binary — see the fork's README for
#   the exact shim snippet. Always exits 0 (never blocks the caller) unless
#   invoked with --strict.

set -uo pipefail

FORK_URL="https://github.com/oliverhees/hermes-agent.git"
BRANCH="eurouter-provider"

STRICT=0
if [ "${1:-}" = "--strict" ]; then
  STRICT=1
  shift
fi

TARGET_DIR="${1:-$HOME/.hermes/hermes-agent}"
LOG_FILE="${TMPDIR:-/tmp}/hermes-eurouter-autoheal.log"

fail() {
  echo "$*" >>"$LOG_FILE" 2>&1
  if [ "$STRICT" -eq 1 ]; then
    echo "[hermes] EU Router auto-heal failed — see $LOG_FILE" >&2
    exit 1
  fi
  exit 0
}

[ -d "$TARGET_DIR/.git" ] || exit 0

cd "$TARGET_DIR" || exit 0

# Already registered — nothing to do, no network touched.
if grep -q '"eurouter": HermesOverlay' hermes_cli/providers.py 2>/dev/null; then
  exit 0
fi

{
  echo ""
  echo "=== eurouter-autoheal $(date -Iseconds 2>/dev/null || date) ==="
} >>"$LOG_FILE" 2>&1

stashed=0
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  if git stash push -u -m "eurouter-autoheal auto-stash" >>"$LOG_FILE" 2>&1; then
    stashed=1
  else
    fail "could not stash local changes — leaving tree untouched"
  fi
fi

restore() {
  if [ "$stashed" -eq 1 ]; then
    # A failed run may have left a cherry-pick in progress — clear it before
    # popping, or the pop itself can conflict on top of a half-merged tree.
    git cherry-pick --abort >>"$LOG_FILE" 2>&1 || true
    if ! git stash pop >>"$LOG_FILE" 2>&1; then
      echo "[hermes] EU Router auto-heal: could not restore your stashed changes automatically — run 'git stash list' / 'git stash pop' by hand (see $LOG_FILE)." >&2
    fi
  fi
}

INSTALL_SCRIPT="$TARGET_DIR/scripts/install-eurouter-provider.sh"
if [ ! -f "$INSTALL_SCRIPT" ]; then
  INSTALL_SCRIPT="${TMPDIR:-/tmp}/eurouter-install-$$.sh"
  if ! curl -fsSL --max-time 8 \
    "https://raw.githubusercontent.com/oliverhees/hermes-agent/$BRANCH/scripts/install-eurouter-provider.sh" \
    -o "$INSTALL_SCRIPT" 2>>"$LOG_FILE"; then
    restore
    fail "could not fetch install script (offline?)"
  fi
fi

if bash "$INSTALL_SCRIPT" "$TARGET_DIR" >>"$LOG_FILE" 2>&1; then
  restore
  echo "[hermes] EU Router provider was missing (likely wiped by 'hermes update') — reapplied automatically." >&2
  exit 0
fi

restore
fail "install script failed — EU Router provider still missing"
