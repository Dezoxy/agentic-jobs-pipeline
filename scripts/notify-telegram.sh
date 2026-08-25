#!/usr/bin/env bash
# Send the Telegram digest for the refresh that was just published.
#
# WHERE THIS RUNS
# ---------------
# Inside the refresh container on the Linux VM (Proxmox guest
# 01-apps-vm), called by scripts/refresh-run.sh (step 7b) immediately
# after scripts/publish.sh has committed and pushed — or by hand to
# re-send a digest that was lost.
#
# WHY THIS EXISTS ALONGSIDE .github/workflows/notify-telegram.yml
# ---------------------------------------------------------------
# The workflow does the same job on a GitHub-hosted runner, triggered by
# the push. It works, but it puts a metered, externally-owned dependency
# in front of a message this VM already holds every input for. On
# 2026-08-19 and 2026-08-20 five digests were lost outright: the jobs
# were refused before a runner ever picked them up ("recent account
# payments have failed or your spending limit needs to be increased").
# The data published normally each time, so nothing downstream noticed —
# the dashboard was current and the notification simply never arrived.
#
# The trade-off of sending from here: no GitHub Actions run log as an
# audit trail. That is why this script logs the full Telegram API
# response — the run journal on the VM becomes the record instead.
#
# THE TWO SENDERS MUST NEVER BOTH BE LIVE
# ---------------------------------------
# Otherwise every refresh notifies twice. The cutover is deliberate and
# manual, in this order:
#   1. put TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID in the container env
#   2. set JOBS_REFRESH_NOTIFY_ENABLED=true, confirm one run arrives
#   3. drop the `push:` trigger from the workflow (keep
#      `workflow_dispatch:` so it stays usable as a fallback)
# Until step 2 the workflow remains the only sender and this script is
# never called.
#
# ARGUMENTS
#   $1  git ref holding the PREVIOUS public/data/jobs.json (normally
#       HEAD~1), or "-" when there is no previous version — in which case
#       nothing is reported as new, exactly as on a first run.
#
# ENVIRONMENT
#   TELEGRAM_BOT_TOKEN   required
#   TELEGRAM_CHAT_ID     required
#
# EXIT CODES
#   0  digest sent, or there was nothing worth sending
#   1  bad usage / missing secrets / unreadable inputs
#   2  the Telegram API call itself failed (body is logged above the exit)

set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] notify-telegram: $*"; }
die() { log "$*" >&2; exit "${2:-1}"; }

PREV_REF="${1:-}"
[ -n "$PREV_REF" ] || die "usage: notify-telegram.sh <prev-git-ref|-> " 1

[ -n "${TELEGRAM_BOT_TOKEN:-}" ] ||
  die "TELEGRAM_BOT_TOKEN is unset — cannot send" 1
[ -n "${TELEGRAM_CHAT_ID:-}" ] ||
  die "TELEGRAM_CHAT_ID is unset — cannot send" 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------- 1. the previous snapshot ----------
# Mirrors the workflow's fallback: a ref that does not exist, or that did
# not carry the file, degrades to "no previous version" rather than
# failing the send. Reporting nothing as new beats reporting all 750 rows
# as new, and beats losing the summary and warnings entirely.
PREV_PATH="-"
if [ "$PREV_REF" != "-" ] &&
   git rev-parse --verify --quiet "$PREV_REF" >/dev/null &&
   git cat-file -e "${PREV_REF}:public/data/jobs.json" 2>/dev/null; then
  PREV_PATH="$WORK/prev-jobs.json"
  git show "${PREV_REF}:public/data/jobs.json" > "$PREV_PATH"
else
  log "no previous jobs.json at ${PREV_REF} — additions will be suppressed"
fi

[ -f public/data/jobs.json ] || die "public/data/jobs.json is missing" 1

RUN_ARG=()
[ -f public/data/last-run.json ] && RUN_ARG=(public/data/last-run.json)

# ---------- 2. build the message ----------
MESSAGE_FILE="$WORK/message.txt"
CHANGED_FILE="$WORK/changed"
NOTIFY_CHANGED_FILE="$CHANGED_FILE" \
  node scripts/notify-diff.mjs "$PREV_PATH" public/data/jobs.json "${RUN_ARG[@]}" \
  > "$MESSAGE_FILE" ||
  die "notify-diff.mjs failed — nothing sent" 1

if [ "$(cat "$CHANGED_FILE")" != "true" ]; then
  log "no added, removed, promoted or newly archived jobs — no message sent"
  exit 0
fi

# ---------- 3. send ----------
# --fail-with-body so a Telegram API error surfaces in the log instead of
# silently succeeding. The token never appears in the log.
#
# The response goes to a file rather than through `| head -c 400`: head
# closes the pipe as soon as it has its 400 bytes, curl dies with EPIPE
# (exit 23) on the rest of the body, and pipefail turns that into a failed
# run even though the message was delivered. Telegram echoes the whole
# message text back in the JSON, so the body is several KB and the race is
# real but intermittent — it cost the workflow three false failures
# (2026-08-17 01:19 and 07:29, 2026-08-19 01:22) before it was understood.
RESPONSE="$WORK/response.json"
STATUS=0
curl --silent --show-error --fail-with-body \
     -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
     -d chat_id="${TELEGRAM_CHAT_ID}" \
     -d parse_mode="HTML" \
     -d disable_web_page_preview="true" \
     --data-urlencode "text@${MESSAGE_FILE}" \
     --output "$RESPONSE" || STATUS=$?

# Print the body before propagating a curl failure, so an API error is
# still visible in the log — that is the point of --fail-with-body, and
# `set -e` would otherwise abort first.
log "telegram response: $(head -c 400 "$RESPONSE" 2>/dev/null || echo '<empty>')"

[ "$STATUS" -eq 0 ] ||
  die "curl exited $STATUS — the digest for this run was NOT delivered" 2

log "digest sent"
