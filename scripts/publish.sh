#!/usr/bin/env bash
# Publish a refreshed jobs.json: validate, commit, push.
#
# WHERE THIS RUNS
# ---------------
# Inside the refresh container on the Linux VM (Proxmox guest 01-apps-vm),
# run directly by the refresh agent right after it writes
# public/data/jobs.json — or by hand. A systemd timer schedules the refresh;
# there is no separate watcher process and no logged-in GUI user, so this
# script must work fully non-interactively, using a git deploy key that is
# already available in the container (loaded in ssh-agent, or referenced via
# GIT_SSH_COMMAND / ~/.ssh/config).
#
# The preflight below still checks that the working tree actually supports
# writing and deleting files before anything touches git. That is a generic
# sanity check, not a workaround for a sandbox: it catches a read-only bind
# mount, a permissions problem, or a full disk early, before a commit gets
# partway through and leaves stranded lock files behind.

set -euo pipefail

# Minimal/non-interactive environments (systemd, containers) don't inherit a
# login shell's PATH; be explicit. /opt/homebrew/bin stays at the front for
# macOS/Homebrew compatibility: during the Phase 1 overlap this script still
# runs on the MacBook too, for the browser-bound sources. Harmless on Linux —
# the directory simply doesn't exist there, so it's skipped.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# No logged-in user to answer an SSH/credential prompt — fail fast instead of
# hanging.
export GIT_TERMINAL_PROMPT=0

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STALE_MIN=5
cd "$REPO"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] publish: $*"; }
die() { log "$*" >&2; exit "${2:-1}"; }

[ -d .git ] || die "$REPO is not a git repository" 1
command -v npm >/dev/null 2>&1 || die "npm not found on PATH ($PATH) — check Node.js is installed and reachable" 1

# ---------- 0. single instance ----------
# A manual run and a scheduled run could overlap. mkdir is atomic.
RUNLOCK="$REPO/.git/publish-running.lock"
if ! mkdir "$RUNLOCK" 2>/dev/null; then
  if [ -n "$(find "$RUNLOCK" -maxdepth 0 -mmin +$STALE_MIN 2>/dev/null)" ]; then
    log "removing stale run lock"
    rmdir "$RUNLOCK" 2>/dev/null || true
    mkdir "$RUNLOCK" 2>/dev/null || die "could not take run lock" 5
  else
    log "another publish run is in progress — exiting"
    exit 0
  fi
fi
trap 'rmdir "$RUNLOCK" 2>/dev/null || true' EXIT

# ---------- 1. preflight: can we actually delete files here? ----------
# Cheap up-front check: prove the working tree supports create-and-delete
# before git relies on it for index.lock, HEAD.lock and temp objects. A
# read-only mount or bad permissions here would otherwise surface mid-commit
# as a half-done state with stranded lock files — this is the check whose
# absence caused exactly that on 2026-07-28.
PROBE="$REPO/.git/.publish-preflight.$$"
: > "$PROBE" 2>/dev/null || die "cannot write inside .git — check permissions" 4
if ! rm -f "$PROBE" 2>/dev/null; then
  die "unlink is denied in this working tree (Operation not permitted).
       Check filesystem permissions and mount options (e.g. a read-only
       bind mount). Nothing was changed." 4
fi

# ---------- 2. stale git locks ----------
# Rare, but a crashed run can still leave one. Narrow and cautious: only this
# repo, only the known lock paths, only when older than STALE_MIN.
locks_live=0
for f in .git/HEAD.lock .git/index.lock .git/objects/maintenance.lock; do
  [ -e "$f" ] || continue
  if [ -n "$(find "$f" -maxdepth 0 -mmin +$STALE_MIN 2>/dev/null)" ]; then
    rm -f "$f" && log "removed stale $f"
  else
    log "$f is newer than ${STALE_MIN}m — assuming a live git process" >&2
    locks_live=$((locks_live + 1))
  fi
done
[ "$locks_live" -gt 0 ] && die "aborting, another git process may be running" 2
find .git/objects -name 'tmp_obj_*' -mmin +$STALE_MIN -delete 2>/dev/null || true

# ---------- 3. validate ----------
npm run --silent check

# ---------- 4. commit only if something changed ----------
# last-run.json rides along with the data: the Telegram workflow reads both from
# the same commit, so the narrative always matches the numbers it describes.
DATA_FILES="public/data/jobs.json"
[ -f public/data/last-run.json ] && DATA_FILES="$DATA_FILES public/data/last-run.json"

# shellcheck disable=SC2086
if git diff --quiet -- $DATA_FILES && git diff --cached --quiet -- $DATA_FILES; then
  log "data unchanged — nothing to commit"
else
  TOTAL=$(node -e "console.log(JSON.parse(require('fs').readFileSync('public/data/jobs.json','utf8')).jobs.length)")
  STAMP=$(date '+%Y-%m-%d %H:%M')
  # shellcheck disable=SC2086
  git add $DATA_FILES
  git commit -q -m "data: refresh ${STAMP} (${TOTAL} jobs)"
  log "committed $(git rev-parse --short HEAD)"
fi

# ---------- 5. push whatever is outstanding ----------
# Deliberately decoupled from step 4: a previous run may have committed but
# failed to push (offline, VPN, expired key). Without this, that commit would
# sit local forever because jobs.json no longer looks "changed".
git fetch --quiet origin main 2>/dev/null || log "fetch failed — offline? continuing"

AHEAD=$(git rev-list --count origin/main..main 2>/dev/null || echo 0)
if [ "$AHEAD" -eq 0 ]; then
  log "nothing to push — up to date with origin/main"
  exit 0
fi

BEHIND=$(git rev-list --count main..origin/main 2>/dev/null || echo 0)
if [ "$BEHIND" -gt 0 ]; then
  die "origin/main has $BEHIND commit(s) we do not have. Refusing to push or
       merge automatically — resolve by hand." 6
fi

log "pushing $AHEAD commit(s)"
if ! git push origin main; then
  die "push failed — the commit is local, it will be retried on the next run" 3
fi
log "pushed, Cloudflare will redeploy"
