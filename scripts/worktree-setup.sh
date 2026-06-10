#!/usr/bin/env bash
# Idempotently prepare a git worktree for development.
#
# Handles the per-worktree steps that devbox init_hook and dev.sh don't cover
# when a worktree is created outside of an interactive devbox shell:
#   1. Copy .env from the main worktree (avoids the interactive gcloud auth prompt)
#   2. Ensure .env.local exists
#   3. Assign a deterministic port based on branch name, write to .devbox/worktree-port
#      and set PORT= in .env.local so dev.sh picks it up immediately
#   4. pnpm install (fast — pnpm's content-addressable store is shared across worktrees)
#   5. Build shared @gcai/* packages (turbo cache makes this ~10s on warm cache)
#
# Usage:
#   bash scripts/devbox/worktree-setup.sh
#   bash scripts/devbox/worktree-setup.sh /path/to/main/worktree
#
# When run from a worktree directory, the main worktree path is auto-detected
# via `git worktree list`. The optional argument overrides that detection.
#
# Safe to re-run — all steps are idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
step() { echo ""; echo "── $*"; }

# ── locate main worktree ──────────────────────────────────────────────────────
MAIN_WORKTREE="${1:-}"
if [ -z "$MAIN_WORKTREE" ]; then
  MAIN_WORKTREE=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
fi

if [ "$REPO_ROOT" = "$MAIN_WORKTREE" ]; then
  echo "Already in the main worktree — nothing to set up."
  exit 0
fi

echo "Setting up worktree: $REPO_ROOT"
echo "Main worktree:       $MAIN_WORKTREE"

# ── .env ─────────────────────────────────────────────────────────────────────
step "Dev secrets (.env)"
if [ -s "$REPO_ROOT/.env" ]; then
  ok ".env already present"
elif [ -s "$MAIN_WORKTREE/.env" ]; then
  cp "$MAIN_WORKTREE/.env" "$REPO_ROOT/.env"
  ok "Copied .env from main worktree"
else
  warn ".env missing in both worktrees — run devbox run env:setup in the main worktree first"
  exit 1
fi

# ── .env.local ───────────────────────────────────────────────────────────────
step ".env.local"
if [ ! -f "$REPO_ROOT/.env.local" ]; then
  # Seed from main worktree if it exists, otherwise create empty
  if [ -f "$MAIN_WORKTREE/.env.local" ]; then
    cp "$MAIN_WORKTREE/.env.local" "$REPO_ROOT/.env.local"
    ok "Copied .env.local from main worktree"
  else
    touch "$REPO_ROOT/.env.local"
    ok "Created empty .env.local"
  fi
else
  ok ".env.local already present"
fi

# ── port assignment ───────────────────────────────────────────────────────────
step "Port assignment"
BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || basename "$REPO_ROOT")

# Deterministic base port from branch name hash (range 3100-3999).
# python3 hashlib.md5 is stable across runs and platforms.
BASE_PORT=$(python3 -c "
import hashlib, sys
h = int(hashlib.md5(sys.argv[1].encode()).hexdigest()[:8], 16)
print(3100 + h % 900)
" "$BRANCH")

# Walk forward from the base port until we find one that isn't listening.
FINAL_PORT="$BASE_PORT"
while (echo > "/dev/tcp/localhost/$FINAL_PORT") >/dev/null 2>&1; do
  FINAL_PORT=$((FINAL_PORT + 1))
done

if [ "$FINAL_PORT" != "$BASE_PORT" ]; then
  warn "Port $BASE_PORT is taken — using $FINAL_PORT"
else
  ok "Assigned port $FINAL_PORT (branch: $BRANCH)"
fi

# Persist so worktree-landscape agent and dev.sh can read it without re-probing.
mkdir -p "$REPO_ROOT/.devbox"
echo "$FINAL_PORT" > "$REPO_ROOT/.devbox/worktree-port"

# Set PORT= in .env.local so dev.sh picks it up as the starting point for
# find_free_port (meaning it won't scan from 3000 and steal our port).
if grep -q "^PORT=" "$REPO_ROOT/.env.local" 2>/dev/null; then
  # macOS-safe in-place edit via python3
  python3 -c "
import re, sys
path = sys.argv[1]; port = sys.argv[2]
text = open(path).read()
text = re.sub(r'^PORT=.*', f'PORT={port}', text, flags=re.MULTILINE)
open(path, 'w').write(text)
" "$REPO_ROOT/.env.local" "$FINAL_PORT"
else
  echo "PORT=$FINAL_PORT" >> "$REPO_ROOT/.env.local"
fi
ok "PORT=$FINAL_PORT written to .env.local"

# ── pnpm install ──────────────────────────────────────────────────────────────
step "pnpm install"
pnpm install --dir "$REPO_ROOT"
ok "Dependencies ready (shared content-addressable store)"

# ── build shared packages ────────────────────────────────────────────────────
step "Build shared packages"
pnpm --dir "$REPO_ROOT" turbo build --filter='./packages/*'
date +%s > "$REPO_ROOT/.devbox/last-pnpm-build"
ok "Shared packages built (turbo cache applies)"

# ── done ─────────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────"
echo "  Worktree ready."
echo "  Start dev server: cd $REPO_ROOT && devbox run dev"
echo "  Dev server URL:   http://localhost:$FINAL_PORT"
echo "──────────────────────────────────────────────"
