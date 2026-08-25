#!/usr/bin/env bash
# Orchestrate one refresh run: install deps, run the sessionless machine
# feeds, optionally collect the browser-bound sources, merge everything
# into jobs.json via the Claude CLI, validate, and (optionally) publish.
#
# WHERE THIS RUNS
# ---------------
# Inside the refresh container on the Linux VM (Proxmox guest
# 01-apps-vm). A thin bootstrap script (built elsewhere, in the homelab
# repo) clones/pulls this repo to /data/jobs-dashboard and the profile-repo
# repo to /data/profile-repo, then execs this script. It lives here, not in
# the container image, so it versions alongside `npm run fetch` and
# `npm run check` instead of drifting from them.
#
# PHASE 1 + 2b SCOPE
# ------------------
# The sessionless machine feeds (`npm run fetch` — Profession.hu listing
# pages, No Fluff Jobs SSR) always run (Phase 1). One browser-bound source
# remains — the LinkedIn alerts feed — which is session-bound and needs a
# Playwright MCP server attached to a logged-in Chromium (built and
# operated outside this repo); collecting it here is gated behind
# JOBS_REFRESH_BROWSER_ENABLED (Phase 2b) — see the "Browser collection
# (Phase 2b)" and "Phase 1 — Linux VM variant" sections of
# docs/refresh-task.md.
#
# The three saved-jobs lists (LinkedIn saved, Profession.hu saved, No
# Fluff Jobs favourites) were retired 2026-08-07: measured over the nine
# days after the initial import they had produced 0, 7 and 0 new saves
# respectively, and every job they could surface already arrives through
# the sessionless feeds anyway — the portal round-trip only relayed one
# bit of intent that now lives in the dashboard's own localStorage
# tracker. Retiring them cut the browse step from three portals to one.
#
# This script never touches git itself beyond two narrow, deliberate
# exceptions: the restore in step 6, and the gated call to
# scripts/publish.sh in step 7.

set -euo pipefail

# Minimal/non-interactive environments (systemd, containers) don't inherit a
# login shell's PATH; be explicit. This script only ever runs in the Linux
# container, so unlike scripts/publish.sh there is no macOS/Homebrew entry
# to carry.
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] refresh-run: $*"; }
die() { log "$*" >&2; exit "${2:-1}"; }

# sha256 of $1, or an empty string if $1 does not exist yet — used below to
# detect whether a step actually (re)wrote its output file. A plain
# `sha256sum "$f" 2>/dev/null | awk '{print $1}'` looks like it tolerates a
# missing file (the 2>/dev/null hides the message) but does not: pipefail
# turns sha256sum's failed-open exit status into the pipeline's exit
# status even though awk itself succeeds on the empty input, and set -e
# then kills the whole script mid-assignment, before anything is logged.
# That bit us on the very first run, when .cache/browser-latest.json does
# not exist yet — the script died with exit 1 (misread as a precondition
# failure) and no log line at all.
#
# Guarding with `[ -f ]` first avoids that: the `if` with no `else` exits
# 0 with empty output when the file is absent (POSIX: no commands run, no
# failure), so `set -e` never sees a non-zero status for the routine
# "doesn't exist yet" case. A file that exists but genuinely can't be read
# (permissions, corruption) still fails loudly here — deliberately: that
# is a real problem and should abort, distinctly from "absent".
hash_or_empty() {
  if [ -f "$1" ]; then
    sha256sum "$1" | awk '{print $1}'
  fi
}

PROFILE_REPO_ROOT="/data/profile-repo"
LAST_RUN_FILE="public/data/last-run.json"
BROWSER_CACHE=".cache/browser-latest.json"

# Set by the login-state assertion (step 4b) when a portal is "undetermined"
# or "unreported" — states with no user action, so they do not block this
# run (see step 4b for why) — and checked again after publish (step 8) to
# raise a non-zero-exit alert once the run has actually finished. Declared
# up front so it is always defined under `set -u`, even when the browser
# step is skipped or disabled entirely.
BROWSER_DEGRADED=""

# ---------- 1. preconditions ----------
[ -d .git ] || die "$REPO is not a git repository — bootstrap did not clone this repo correctly" 1
command -v npm >/dev/null 2>&1 || die "npm not found on PATH ($PATH) — check Node.js is installed and reachable" 1
[ -f "$PROFILE_REPO_ROOT/profile/target-roles.md" ] ||
  die "missing $PROFILE_REPO_ROOT/profile/target-roles.md — profile-repo not checked out correctly" 1
[ -f "$PROFILE_REPO_ROOT/research/market/salary-benchmarks.md" ] ||
  die "missing $PROFILE_REPO_ROOT/research/market/salary-benchmarks.md — profile-repo not checked out correctly" 1

# ---------- 2. install dependencies ----------
# --omit=dev (added 2026-08-22): nothing this container runs needs a
# dependency at all. The refresh scripts import only node: builtins and each
# other; npm run check, fetch, filter-browser and liveness are all plain
# node. The single entry in package.json is wrangler, a devDependency used
# only by npm run dev / npm run deploy, neither of which runs here — so this
# step was pulling wrangler and workerd (a large binary) from the registry
# every six hours to install something no step uses, and putting the npm
# registry on the critical path of every run for it.
#
# Consequence worth knowing before editing package.json: anything the
# container genuinely needs at runtime must go in "dependencies". A runtime
# import parked in devDependencies will resolve on a dev machine and fail
# here.
if [ -f package-lock.json ]; then
  log "installing dependencies (npm ci --omit=dev)"
  npm ci --omit=dev --silent || die "npm ci failed" 2
else
  log "no package-lock.json — installing dependencies (npm install --omit=dev)"
  npm install --omit=dev --silent || die "npm install failed" 2
fi

# ---------- 2b. tracker sync import (optional, added 2026-08-07) ----------
# Pull the dashboard's tracker from the sync endpoint (GET /api/tracker on
# the Worker, KV-backed, behind Cloudflare Access — authenticated here with
# an Access service token) and fold its ignored/rejected ids into
# .cache/rejected-ids.json BEFORE the fetch below runs, so this very run's
# candidate set already excludes everything the user hid on any device.
# Replaces the manual export/import round-trip that used to feed the ledger.
#
# Deliberately non-fatal end to end: a missing config skips it, a failed
# fetch or import logs and continues — the ledger just stays as it was,
# which is exactly the pre-sync behavior. Never worth killing a refresh for.
if [ -n "${JOBS_TRACKER_SYNC_URL:-}" ]; then
  if [ -z "${JOBS_TRACKER_CLIENT_ID:-}" ] || [ -z "${JOBS_TRACKER_CLIENT_SECRET:-}" ]; then
    log "JOBS_TRACKER_SYNC_URL is set but JOBS_TRACKER_CLIENT_ID/SECRET are not — skipping tracker import"
  elif curl --fail --silent --show-error --max-time 30 \
        -H "CF-Access-Client-Id: ${JOBS_TRACKER_CLIENT_ID}" \
        -H "CF-Access-Client-Secret: ${JOBS_TRACKER_CLIENT_SECRET}" \
        -o .cache/tracker-latest.json "$JOBS_TRACKER_SYNC_URL"; then
    if node scripts/tracker-to-rejected.mjs .cache/tracker-latest.json; then
      log "tracker import ok"
    else
      log "tracker import failed on a fetched file — continuing with the existing ledger" >&2
    fi
  else
    log "tracker sync fetch failed — continuing with the existing ledger" >&2
  fi
else
  log "JOBS_TRACKER_SYNC_URL unset — skipping tracker import (manual export/import still works)"
fi

# ---------- 3. machine feeds ----------
log "running npm run fetch (sessionless Profession + No Fluff Jobs feeds)"
npm run --silent fetch ||
  die "npm run fetch failed — there is no browser fallback on the VM in Phase 1; nothing was collected" 3

# ---------- 3b. liveness sweep (start) ----------
# Hoisted out of the merge agent 2026-08-22. docs/refresh-task.md used to
# tell that agent to run this sweep itself "in the background", because the
# ~10 minutes it takes outlives the CLI's per-command shell timeout. On the
# 2026-08-22 19:00 run the agent did exactly that, then returned exit 0
# while the sweep was still going — nothing written, no jobs.json, no
# last-run.json, and a closing note that it would "pick up automatically
# when the background watcher fires". There is no watcher. Step 5b caught
# the empty run, but the guard only catches it; running the sweep here
# removes the reason to background anything at all. This script has no
# per-command timeout — systemd's TimeoutStartSec=3600 bounds the whole run
# — so it can simply wait.
#
# Started here rather than immediately before the merge so the probe
# overlaps the browser collection below (~6 min) instead of being appended
# to it. Nothing races: the sweep only reads public/data/jobs.json and
# writes .cache/dead-ids.json, while the browse step writes
# .cache/browser-latest.json and touches neither.
LIVENESS_LOG="$(mktemp)"
npm run --silent liveness >"$LIVENESS_LOG" 2>&1 &
LIVENESS_PID=$!
log "liveness sweep started (pid $LIVENESS_PID) — waited on in step 4d, before the merge"

# ---------- 4. browser collection (optional, Phase 2b) ----------
# Runs only when JOBS_REFRESH_BROWSER_ENABLED is exactly "true"; anything
# else (unset, "false", a typo) skips this step and the run behaves
# exactly as Phase 1 did — the merge only sees npm run fetch's output.
#
# This is a second, separate Claude invocation, against a Playwright MCP
# server attached to a logged-in Chromium (built and operated outside
# this repo, against the contract this script assumes is met). Its whole
# job is collecting the one remaining session-bound source — the LinkedIn
# alerts feed — into $BROWSER_CACHE. See docs/refresh-task.md's "Browser
# collection (Phase 2b)" section for the URL/selectors it follows (this
# prompt does not repeat them) and the exact shape of that file.
if [ "${JOBS_REFRESH_BROWSER_ENABLED:-}" = "true" ]; then
  [ -n "${JOBS_REFRESH_MCP_CONFIG:-}" ] ||
    die "JOBS_REFRESH_BROWSER_ENABLED=true but JOBS_REFRESH_MCP_CONFIG is unset — no MCP config to attach the browser tools from" 7
  [ -f "$JOBS_REFRESH_MCP_CONFIG" ] ||
    die "JOBS_REFRESH_MCP_CONFIG ($JOBS_REFRESH_MCP_CONFIG) does not exist" 7

  # Sonnet by default, not $ANTHROPIC_MODEL (Opus): DOM extraction here is
  # mechanical, so the cheaper model does it; the judgement work (fit
  # filtering, salary estimation, the Hungarian summary) stays on Opus in
  # the merge step below. "sonnet" is the CLI's own rolling alias for the
  # latest Sonnet, so this default never needs bumping by hand — override
  # with a dated model id instead if a run ever needs to be reproducible.
  BROWSE_MODEL="${JOBS_REFRESH_BROWSE_MODEL:-sonnet}"

  # high, not xhigh: this step is mechanical DOM extraction against
  # selectors docs/refresh-task.md already documents precisely, and it is
  # already the long pole of the whole run (12-16 minutes observed) — more
  # effort here buys accuracy on judgement calls, which this step doesn't
  # make. The merge step below runs at xhigh instead, because that's where
  # the actual judgement lives (fit filtering, salary estimation, the
  # Hungarian summary), at a fraction of the wall-clock cost (~4-9 minutes).
  BROWSE_EFFORT="${JOBS_REFRESH_BROWSE_EFFORT:-high}"

  BROWSE_PROMPT=$(cat <<'BROWSE_PROMPT_EOF'
Collect the LinkedIn alerts feed for jobs-dashboard. Read
docs/refresh-task.md now, specifically its "Browser collection (Phase
2b)" section, and follow it exactly — that section, and the "1. Collect"
selectors and DOM notes it points to, is the single source of truth for
the URL, ids and paging rules; this prompt does not repeat any of it.

This is the only session-bound source left. The three saved-jobs lists
(LinkedIn saved, Profession.hu saved, No Fluff Jobs favourites) were
retired 2026-08-07 — do not visit them, and do not add them back to the
output file even if you see a way to reach them.

Your only job is to collect and write .cache/browser-latest.json. Do not
merge into public/data/jobs.json, do not write public/data/last-run.json,
do not run npm run check, and do not run git or scripts/publish.sh — a
separate Claude invocation handles the merge afterward.

Before scraping, verify you are genuinely logged in to LinkedIn — a
stale session returns an empty result list instead of an error, which is
indistinguishable from "the feed is quiet today" unless checked
explicitly.

Restated because getting this wrong sends a human to fix the wrong
thing: only record "logged_out" on POSITIVE evidence of being signed
out — a redirect to a login URL, or a visible sign-in prompt on a page
that otherwise rendered normally. If the page did not render
meaningfully instead (empty body text, a near-empty accessibility
snapshot, a burst of console errors), record "undetermined", not
"logged_out" — a broken render is not evidence of a bad session, and a
real prior run reported a working No Fluff Jobs session as logged_out
this exact way. See docs/refresh-task.md's "Browser collection (Phase
2b)" section for the full definition of each state.

Record LinkedIn's outcome in the file's auth object as an object with
"state" ("ok" | "logged_out" | "undetermined") and a short human-readable
"reason" (required whenever state isn't "ok", describing what you saw) —
and still write the file with whatever you managed to collect even when
the check did not come back "ok".
BROWSE_PROMPT_EOF
)

  BROWSER_BEFORE_HASH="$(hash_or_empty "$BROWSER_CACHE")"

  log "invoking claude CLI to collect browser-bound sources"
  # --permission-mode bypassPermissions: same reasoning as the merge
  # invocation below — this container's mounts are the whole blast
  # radius. --mcp-config attaches the Playwright browser tools;
  # --strict-mcp-config keeps this session limited to exactly that
  # server, ignoring any other MCP config the environment might expose.
  claude --print "$BROWSE_PROMPT" \
    --model "$BROWSE_MODEL" \
    --effort "$BROWSE_EFFORT" \
    --mcp-config "$JOBS_REFRESH_MCP_CONFIG" \
    --strict-mcp-config \
    --permission-mode bypassPermissions ||
    die "browser collection claude CLI run failed or exited non-zero" 7

  BROWSER_AFTER_HASH="$(hash_or_empty "$BROWSER_CACHE")"
  if [ -z "$BROWSER_AFTER_HASH" ] || [ "$BROWSER_AFTER_HASH" = "$BROWSER_BEFORE_HASH" ]; then
    die "claude exited 0 but did not (re)write $BROWSER_CACHE — treating this as a
         failed browser collection, not a successful one; check the journal
         for this run's claude output" 7
  fi

  # ---------- 4b. login-state assertion ----------
  # The one failure mode this step exists to catch: a logged-out portal
  # does not error, it just returns nothing, which would otherwise look
  # identical to "nothing new was saved" and let those rows' lastSeen go
  # stale until the dashboard archives them.
  #
  # Three auth states, and they are NOT treated the same:
  #
  #   logged_out    — a human has an action (sign back in) and nothing
  #                   useful will come from that portal until they do, so
  #                   this blocks the run outright, right here, before
  #                   the merge ever runs.
  #   undetermined  — the check itself was inconclusive (the page didn't
  #                   render), not evidence of a bad session. Collapsing
  #                   this into logged_out caused a real false positive
  #                   on the first live run: No Fluff Jobs failed to
  #                   render in a small viewport and got reported as
  #                   logged_out, which discarded 387 good rows already
  #                   collected from the other two portals and told a
  #                   human to re-authenticate a session that was fine.
  #                   There is no user action here, so it does NOT block
  #                   — the run continues, merges, validates and
  #                   publishes normally, and a distinct exit code fires
  #                   only AFTER publish, purely to raise an alert (see
  #                   step 8) — otherwise a quiet cycle plus a broken
  #                   portal would be completely silent, which is exactly
  #                   the failure this whole feature exists to prevent.
  #                   Now that LinkedIn is the only portal here, this
  #                   state means no browser rows at all this cycle — but
  #                   it still must not block, because the sessionless
  #                   machine feeds (npm run fetch, ~52% of the corpus)
  #                   are unaffected and still worth merging and
  #                   publishing. Same reasoning as before, smaller
  #                   surviving set.
  #   unreported    — the auth object is missing this portal, or carries
  #                   a value that isn't one of the three above. Also no
  #                   user action, so it does NOT block either, same as
  #                   undetermined — but it means the browse step itself
  #                   has a bug (not a flaky site), so it is reported
  #                   with that distinction, never silently merged into
  #                   either of the other two categories.
  #
  # Node signals which case applies via its own exit status: 0 = nothing
  # blocks (stdout may still list undetermined/unreported portals), 2 =
  # $BROWSER_CACHE itself could not be read, 3 = at least one logged_out
  # portal was found (stdout lists every non-"ok" portal for full
  # context, since the die message below must not hide the others just
  # because logged_out is the one blocking).
  if AUTH_CHECK=$(node -e '
    const fs = require("node:fs");
    const path = process.argv[1];
    let doc;
    try {
      doc = JSON.parse(fs.readFileSync(path, "utf8"));
    } catch (e) {
      console.error("invalid JSON: " + e.message);
      process.exit(2);
    }

    // LinkedIn alerts is the only session-bound source left (the three
    // saved-jobs lists were retired 2026-08-07). Kept as an array, not
    // collapsed to a scalar, so restoring a portal is a one-word change.
    const expected = ["linkedin"];
    const auth = doc.auth || {};

    // Accepts the documented { state, reason } shape, and also a bare
    // state string for robustness — either way, anything that is not
    // recognised comes back as state: undefined, bucketed as unreported.
    function normalize(raw) {
      if (typeof raw === "string") return { state: raw, reason: "" };
      if (raw && typeof raw === "object" && typeof raw.state === "string") {
        return { state: raw.state, reason: typeof raw.reason === "string" ? raw.reason : "" };
      }
      return { state: undefined, reason: "" };
    }

    const ADVICE = {
      logged_out: "re-authenticate at chrome.example.com",
      undetermined: "a rendering problem, not a login problem — no action needed unless it recurs, then inspect the browse-step viewport/console log",
      unreported: "looks like a browse-step bug (missing or unrecognised auth entry), not a portal problem — investigate the browse-step log",
    };

    let sawLoggedOut = false;
    const lines = [];
    for (const portal of expected) {
      const { state, reason } = normalize(auth[portal]);
      if (state === "ok") continue;
      const category = state === "logged_out" || state === "undetermined" ? state : "unreported";
      if (category === "logged_out") sawLoggedOut = true;
      const why = reason ? ` — ${reason}` : "";
      lines.push(`${portal}: ${category}${why} (${ADVICE[category]})`);
    }

    // Row-count sanity check (added 2026-08-07): a paging or DOM regression
    // is invisible to the auth tri-state — the session is fine, the page
    // renders, but only the first results page (or none) gets collected.
    // The 2026-07-29 LinkedIn DOM change would have looked exactly like
    // this. It is also the failure the unseen-streak tracker used to stand
    // guard for on this source before LinkedIn rows were exempted from it
    // (the 7-day feed window made every row trip the streak threshold by
    // age alone — see docs/refresh-task.md "3. Merge").
    //
    // Threshold derivation (measured 2026-08-07 over the prior six daily
    // full-feed sweeps in git history): the feed contributed 112-159
    // accepted rows per run — and the raw linkedinAlerts count is higher
    // still, since it includes rows the merge later rejects — while a
    // page-1-only regression yields ~10-25. 60 is half the observed
    // minimum: comfortably below any normal run, several times above the
    // failure mode. Only checked when the session is confirmed "ok" (a
    // non-ok state already raises its own line above, and its row count
    // is expected to be low). Non-blocking, same as undetermined: the
    // machine feeds are unaffected, so the run publishes and the exit-8
    // alert fires after.
    const rawMin = Number.parseInt(process.env.JOBS_REFRESH_BROWSE_MIN_ROWS ?? "", 10);
    const minRows = Number.isFinite(rawMin) ? rawMin : 60;
    if (normalize(auth["linkedin"]).state === "ok") {
      const n = Array.isArray(doc.linkedinAlerts) ? doc.linkedinAlerts.length : 0;
      if (n < minRows) {
        // NOTE: this whole script lives inside a single-quoted shell
        // argument — no apostrophes anywhere in it, or the quoting breaks.
        lines.push(`linkedin: authenticated ok, but only ${n} alert row(s) collected (expected >= ${minRows}; normal runs bring 110+) — the session is fine, so suspect start= paging, rendering, or another DOM change; check the browse-step log against the selector notes in docs/refresh-task.md`);
      }
    }

    process.stdout.write(lines.join("\n"));
    process.exit(sawLoggedOut ? 3 : 0);
  ' "$BROWSER_CACHE"); then
    AUTH_RC=0
  else
    AUTH_RC=$?
  fi

  if [ "$AUTH_RC" -eq 2 ]; then
    die "browser collection wrote an unreadable $BROWSER_CACHE — check the journal for this run's claude output" 7
  elif [ "$AUTH_RC" -eq 3 ]; then
    die "browser collection found a logged-out portal — this blocks the whole run; per-portal detail below:
$AUTH_CHECK" 7
  elif [ "$AUTH_RC" -ne 0 ]; then
    die "browser collection's login-state check itself failed unexpectedly (node exit $AUTH_RC) — check the journal for this run's claude output" 7
  fi

  BROWSER_DEGRADED="$AUTH_CHECK"
  if [ -n "$BROWSER_DEGRADED" ]; then
    log "browser collection: degraded but not blocked — either the session
         could not be confirmed, or it authenticated and returned
         suspiciously few rows. Continuing to merge/validate/publish
         normally; this run will still exit non-zero afterward solely to
         raise an alert (see step 8). Detail:
$BROWSER_DEGRADED"
  else
    log "browser collection ok — LinkedIn authenticated, row count normal"
  fi

  # ---------- 4c. filter the browser rows (added 2026-08-12) ----------
  # The alerts feed never passes through npm run fetch, so until now its
  # mechanical vetoes and the rejected ledger were applied by the merge agent
  # from prose in docs/refresh-task.md. Same rules, now as code and against
  # the same scripts/vetoes.mjs the fetcher uses — and every drop is recorded
  # in .cache/browser-filtered.json's droppedRows, which is what makes "why is
  # this LinkedIn job not on my dashboard?" answerable at all.
  #
  # Fatal on failure, unlike the tracker import above: if this silently does
  # not run, the merge reads unfiltered rows, re-admits ledgered ads and bumps
  # their lastSeen so they never archive. A failed refresh is recoverable; a
  # quietly un-ledgered feed is the regression step 3 exists to prevent.
  #
  # Exit 11, not 8, since 2026-08-25. This is a BLOCKING failure — it stops
  # the run here, before the merge, and nothing is published. Exit 8 means the
  # opposite: the run succeeded, the data is live, and a browser degradation
  # needs a human's attention afterwards (step 8). Sharing one code made those
  # two indistinguishable to the homelab notifier, which keys its advisories on
  # unit:exit-status and so would report "run succeeded, data published" for a
  # cycle that published nothing. Same class of collision as the no-op merge
  # guard's 6 -> 10 move three days earlier, and fixed the same way: give the
  # blocking case a code of its own in the 10+ range this script owns.
  log "filtering browser-collected rows"
  npm run --silent filter-browser ||
    die "filter-browser failed — refusing to merge unfiltered browser rows;
         this run is BLOCKED and published nothing (contrast exit 8, which
         means the run succeeded and only needs a human to look at a browser
         degradation afterwards)" 11

  # Inert-veto check (added 2026-08-21). Same class of problem as the row-count
  # check in step 4b, and handled the same way: the session is fine, the page
  # rendered, the filter ran and exited 0 — but judgeLinkedIn was handed an
  # empty string for every row, so both vetoes kept everything and only the
  # ledger actually applied. Nothing in the counts distinguishes that from a
  # feed with nothing to drop, which is why it went unnoticed for nine days.
  #
  # Non-blocking, deliberately: the machine feeds are unaffected and the merge
  # still judges these rows, so the run publishes and the exit-8 alert fires
  # afterward. Failing here would trade a degraded filter for no refresh.
  TITLE_CHECK="$(node -e '
    const fs = require("node:fs");
    try {
      const d = JSON.parse(fs.readFileSync(".cache/browser-filtered.json", "utf8"));
      const kept = Array.isArray(d.linkedinAlerts) ? d.linkedinAlerts.length : 0;
      const rows = kept + (Array.isArray(d.droppedRows) ? d.droppedRows.length : 0);
      if (rows > 0 && (d.titled ?? 0) === 0) {
        process.stdout.write("linkedin: " + rows + " row(s) collected but none carry a role or title, so the language and title vetoes judged an empty string and kept every row — only the ledger applied. The browse step must write a title per row; see the Output section of docs/refresh-task.md. Until it does, the merge agent re-judges by hand what the regexes exist to drop.");
      }
    } catch (e) {
      process.stdout.write("linkedin: could not read .cache/browser-filtered.json to check the vetoes actually judged anything (" + e.message + ")");
    }
  ')"
  if [ -n "$TITLE_CHECK" ]; then
    log "browser collection: degraded but not blocked — $TITLE_CHECK"
    BROWSER_DEGRADED="${BROWSER_DEGRADED:+$BROWSER_DEGRADED
}$TITLE_CHECK"
  fi
else
  # Remove any stale filtered file before saying this run has no browser
  # source (added 2026-08-25). .cache persists across runs by design —
  # rejected-ids.json and unseen-streaks.json must — so a
  # browser-filtered.json written while the gate was ON is still sitting here
  # after it is switched off. The merge prompt tells the agent that an ABSENT
  # filtered file means "no browser-collected source this run", so a stale one
  # reads as a fresh collection instead: the agent merges last cycle's
  # LinkedIn rows and bumps their lastSeen, and they never archive. Silent,
  # and exactly the regression step 4c exists to prevent.
  #
  # Same trap .cache/dead-ids.json is deleted for when the liveness sweep
  # fails (step 4d), and fixed the same way: when absence is the signal,
  # absence has to be made true rather than assumed.
  #
  # browser-latest.json is deliberately NOT removed. Nothing downstream reads
  # it — filter-browser.mjs is its only consumer and does not run on this
  # path — and the gate is usually switched off precisely while the browser
  # stack is being investigated, so the last good raw collection is evidence
  # worth keeping.
  rm -f .cache/browser-filtered.json
  log "JOBS_REFRESH_BROWSER_ENABLED is not \"true\" (got: \"${JOBS_REFRESH_BROWSER_ENABLED:-<unset>}\") — skipping browser collection; removed any stale .cache/browser-filtered.json so the merge cannot mistake it for this run's; merge will only see npm run fetch's output"
fi

# ---------- 4d. liveness sweep (wait) ----------
# Non-fatal end to end, matching docs/refresh-task.md's rule that a liveness
# failure "simply means no liveness handling this run". The sweep's output is
# replayed into the journal here rather than streamed, so it stays in one
# block instead of interleaving with the browse step's.
#
# On failure .cache/dead-ids.json is REMOVED, not left alone: it survives
# across runs, so a stale one from an earlier sweep would otherwise be
# indistinguishable from a fresh verdict, and the merge agent would close
# rows on evidence hours or days old. Absent means "no liveness this run",
# which is exactly what the doc tells the agent to handle.
LIVENESS_RC=0
wait "$LIVENESS_PID" || LIVENESS_RC=$?
cat "$LIVENESS_LOG"
rm -f "$LIVENESS_LOG"
if [ "$LIVENESS_RC" -ne 0 ]; then
  log "liveness sweep failed (exit $LIVENESS_RC) — removing .cache/dead-ids.json so the merge cannot apply a previous run's verdicts; this run does no liveness handling" >&2
  rm -f .cache/dead-ids.json
else
  # Worth doing every run per the doc: the undecided rows are almost always
  # LinkedIn http-429, and a second pass a minute later usually settles them.
  # A failure here is milder than above — the first sweep's dead-ids.json is
  # still current, just with its unknowns left unresolved — so it is kept.
  log "liveness sweep finished — re-probing undecided rows (--retry-unknown)"
  if npm run --silent liveness -- --retry-unknown; then
    log "liveness retry pass finished"
  else
    log "liveness retry pass failed — keeping the first sweep's .cache/dead-ids.json, unknowns left undecided" >&2
  fi
fi

# ---------- 5. merge via the Claude CLI ----------
# docs/refresh-task.md — including its Phase 1 path-mapping table — is the
# single source of truth for paths and merge rules; this prompt does not
# duplicate any of that and just points Claude at it. It only restates the
# two rules that corrupt data if missed, plus the one thing the doc cannot
# know on its own: that this particular run is orchestrated by this script,
# not standalone, so Claude must leave validation, git and publishing to it.
PROMPT=$(cat <<'PROMPT_EOF'
Run the Phase 1 Linux refresh for jobs-dashboard. Read docs/refresh-task.md
now and follow it end to end, in particular the "Phase 1 — Linux VM
variant" section and its path-mapping table — that file, including that
table, is the single source of truth for paths and rules; this prompt is
not a substitute for it and does not repeat its path handling. `npm run
fetch` has already run this session.

When JOBS_REFRESH_BROWSER_ENABLED=true, a separate browser-collection
Claude run has already executed and written .cache/browser-latest.json,
and scripts/filter-browser.mjs has since applied the rejected ledger and
the deterministic vetoes to it, writing .cache/browser-filtered.json.
Read the FILTERED file, not the raw one: its linkedinAlerts array is the
merge input, and its droppedRows records what was removed and why. Do not
re-apply the ledger or the mechanical vetoes to those rows yourself.
Read docs/refresh-task.md's "Browser collection (Phase 2b)" section for
what it contains and which status its one source (the LinkedIn alerts
feed) maps to, and merge it in alongside .cache/sources-latest.json. When
the filtered file does not exist, this run has no browser-collected source
this time — merge exactly as Phase 1 and say so in warnings, same as today.

That file's auth object may mark linkedin "undetermined", or (rarely)
carry no confirmed state for it at all — "logged_out" never reaches you
here, because that already stopped this whole run before this invocation
started. If it is not "ok", add one line to this run's warnings naming
the recorded reason: say the page did not render for "undetermined" (a
rendering problem, not a login problem — do not suggest
re-authenticating), and say it looks like a browse-step bug for anything
else (a missing or unrecognised auth entry, not a portal problem).

The three saved-jobs lists were retired 2026-08-07, so no source assigns
the "Mentett" status any more. Existing "Mentett" rows in jobs.json are
legacy: never bump their lastSeen, never change their status, and never
delete them — they age into the archive on their own via the UI's 14-day
rule, which is the intended outcome. New rows are only ever "Értesítő"
or "NFJ keresés".

Restated because getting either wrong corrupts data: merge into the
existing public/data/jobs.json, never regenerate it from scratch —
firstSeen history must survive. Write public/data/last-run.json to disk
BEFORE public/data/jobs.json, every time, in that order.

The liveness sweep has ALREADY RUN this session: this script ran
`npm run liveness` and its `--retry-unknown` pass before invoking you, and
.cache/dead-ids.json is on disk and current. Do not run npm run liveness
yourself — just apply that file per docs/refresh-task.md's Liveness
section. If it is absent, this run's sweep failed: do no liveness handling
and say so in warnings, exactly as the doc prescribes.

Everything you do here runs in the foreground and must be FINISHED before
you return. Never start a command in the background and return expecting
something else to collect the result — nothing will, and this script reads
your exit as the run's outcome. If a step is still in progress, you are not
done. A run that returns 0 having written nothing is a failed run: it is
detected as one, publishes nothing, and pages a human.

This run is orchestrated by scripts/refresh-run.sh, not standalone: it
runs npm run check and the gated publish itself after you finish. Despite
what the Phase 1 section says a standalone run may do, do not run git and
do not run scripts/publish.sh yourself here. Do not delete or reset
.cache/ — .cache/rejected-ids.json and .cache/unseen-streaks.json must
both persist across runs.
PROMPT_EOF
)

# Marker for step 5b below: last-run.json is written unconditionally, every
# run, even when nothing changed — so it not being rewritten is the signal
# that the merge produced no output (see step 5b).
BEFORE_HASH="$(hash_or_empty "$LAST_RUN_FILE")"

# xhigh, not high: this is where the judgement lives (fit filtering
# against target-roles.md, salary estimation, the Hungarian summary),
# unlike the browse step's mechanical DOM extraction above, and it's the
# shorter of the two runs (~4-9 minutes vs. 12-16) — the extra effort
# costs comparatively little wall-clock time.
MERGE_EFFORT="${JOBS_REFRESH_MERGE_EFFORT:-xhigh}"

# Attempts at the merge before giving up (added 2026-08-22). Step 5b below
# detects a merge that returned 0 having written nothing; twice in the
# eleven days to 2026-08-22 (08-16 01:15, 08-22 19:13) that was the agent
# narrating work it still intended to do and then returning anyway — once
# after backgrounding the liveness sweep (now hoisted into step 3b), once
# mid-fit-judgement with its merge script already drafted. Both were
# transient: the 08-22 run was re-triggered by hand on identical inputs
# minutes later and succeeded.
#
# So the first no-op is retried rather than paged. It costs one extra agent
# invocation and ~4-9 minutes, only on the failure path, and it turns the
# common case into a self-healing delay instead of a cycle that publishes
# nothing. Reaching the die below now means TWO consecutive no-ops, which is
# evidence of something structural rather than a flaky return — which is
# also what makes exit 10's advisory able to stop hedging.
#
# Set to 1 to restore the old page-on-first-no-op behaviour.
MERGE_ATTEMPTS="${JOBS_REFRESH_MERGE_ATTEMPTS:-2}"

# Appended to the prompt on a retry only: the previous attempt may have left
# a half-built merge script or scratch files in .cache/, and saying so beats
# letting the next attempt rediscover them and guess at their provenance.
RETRY_NOTE='

IMPORTANT — this is a RETRY. An earlier attempt in this same run returned
without writing public/data/last-run.json or public/data/jobs.json, so the
run produced nothing. Those two files have been restored to their last
committed state, and any scratch files that attempt left in .cache/ (a
drafted merge script, for instance) are still there — reuse them if they
are sound, ignore them if not, but verify rather than trust them. Complete
the merge and write both files this time before you return.'

# ---------- 5b. run the merge, retrying once if it writes nothing ----------
# A claude run can exit 0 while having done nothing (e.g. every write was
# denied, or it returns mid-task narrating work it still intends to do).
# That would otherwise reach npm run check on the unchanged data, pass, and
# report success — a run that looks healthy and produced nothing, exactly
# the silent-failure mode this migration exists to kill. jobs.json is not a
# reliable signal (a legitimate run can leave it byte-identical), but
# last-run.json is written unconditionally, so an unchanged hash means no
# merge output at all.
#
# Exit 10, not 6, since 2026-08-22. scripts/publish.sh runs as an unguarded
# child of this script, so under set -e its exit codes surface as this
# service's exit code — its 1-6 shadow ours one for one, and the homelab notifier
# keys its advisories on unit:exit-status. This guard held 6 first, but the
# notifier's 6 was later written against publish.sh's "origin/main diverged",
# so the 2026-08-22 19:00 no-op run paged as an ACTION REQUIRED divergence
# that did not exist. Codes 10+ are ours alone and cannot collide with
# publish.sh.
log "invoking claude CLI to merge feeds into jobs.json"
MERGE_ATTEMPT=1
while :; do
  if [ "$MERGE_ATTEMPT" -gt 1 ]; then
    log "merge attempt $MERGE_ATTEMPT/$MERGE_ATTEMPTS"
    MERGE_PROMPT="$PROMPT$RETRY_NOTE"
  else
    MERGE_PROMPT="$PROMPT"
  fi

  # --permission-mode bypassPermissions: this container only mounts the repo,
  # the profile-repo checkout, the Claude config/home dir, and read-only SSH
  # keys — the blast radius of bypassing prompts is the container itself.
  # Do NOT copy this flag onto a host that isn't this narrowly sandboxed.
  # --add-dir: grants read access to profile-repo, which sits outside the repo
  # working tree (target-roles.md, salary-benchmarks.md) and would otherwise
  # be unreachable to the session.
  claude --print "$MERGE_PROMPT" \
    --model "$ANTHROPIC_MODEL" \
    --effort "$MERGE_EFFORT" \
    --permission-mode bypassPermissions \
    --add-dir "$PROFILE_REPO_ROOT" ||
    die "claude CLI merge run failed or exited non-zero" 4

  AFTER_HASH="$(hash_or_empty "$LAST_RUN_FILE")"
  if [ -n "$AFTER_HASH" ] && [ "$AFTER_HASH" != "$BEFORE_HASH" ]; then
    break
  fi

  if [ "$MERGE_ATTEMPT" -ge "$MERGE_ATTEMPTS" ]; then
    die "claude exited 0 but did not rewrite $LAST_RUN_FILE, on all $MERGE_ATTEMPTS
       attempt(s) — treating this as a failed run, not a successful no-op.
       $LAST_RUN_FILE is written on every run, so this usually means a
       permission denial or an early abort; check the journal for this run's
       claude output. Repeating across attempts points at something
       structural rather than a flaky return." 10
  fi

  # Restore before retrying so the next attempt starts from the last
  # committed state rather than whatever a half-finished one left behind.
  # Non-fatal if it fails: the merge is a merge into the existing jobs.json
  # either way, and step 6's validate-and-restore is the backstop for a file
  # this leaves broken.
  log "merge attempt $MERGE_ATTEMPT returned 0 but wrote nothing — restoring the data files and retrying" >&2
  git checkout -- public/data/jobs.json "$LAST_RUN_FILE" ||
    log "could not restore the data files before the retry — continuing anyway; npm run check (step 6) is the backstop" >&2

  # Re-baseline: the restore may itself have changed last-run.json, and the
  # next attempt's no-op test has to compare against what is on disk now.
  BEFORE_HASH="$(hash_or_empty "$LAST_RUN_FILE")"
  MERGE_ATTEMPT=$((MERGE_ATTEMPT + 1))
done

# ---------- 6. validate ----------
log "running npm run check"
if ! npm run --silent check; then
  log "npm run check failed — restoring the last committed data files" >&2
  if ! git checkout -- public/data/jobs.json public/data/last-run.json; then
    die "npm run check failed AND restoring the previous data files also failed — public/data/jobs.json may be broken; fix by hand before the next run" 5
  fi
  die "npm run check failed after the merge; jobs.json and last-run.json were restored to the last committed state" 5
fi

# ---------- 7. publish (gated) ----------
# Fail safe: unset, empty, or anything other than the literal string
# "true" means do not publish.
#
# HEAD is sampled either side of publish.sh so step 7b can tell a run that
# actually committed something from one that published nothing (unchanged
# data) or that only pushed a commit stranded by an earlier failed push.
# Reading it back from git beats trusting a flag: publish.sh owns that
# decision and may legitimately do nothing.
HEAD_BEFORE_PUBLISH=""
HEAD_AFTER_PUBLISH=""
if [ "${JOBS_REFRESH_PUBLISH:-}" = "true" ]; then
  log "JOBS_REFRESH_PUBLISH=true — running scripts/publish.sh"
  HEAD_BEFORE_PUBLISH="$(git rev-parse HEAD)"
  "$REPO/scripts/publish.sh"
  HEAD_AFTER_PUBLISH="$(git rev-parse HEAD)"
else
  log "JOBS_REFRESH_PUBLISH is not \"true\" (got: \"${JOBS_REFRESH_PUBLISH:-<unset>}\") — publishing disabled; changes are left uncommitted in the working tree"
fi

# ---------- 7b. Telegram digest (gated) ----------
# Fail safe, same convention as JOBS_REFRESH_PUBLISH: only the literal
# string "true" enables the send. Left off, the GitHub Actions workflow
# stays the only sender and nothing here runs — see the cutover checklist
# in scripts/notify-telegram.sh. Both senders live at once means every
# refresh notifies twice.
#
# Only a run that actually produced a commit has anything to report. The
# previous snapshot is HEAD_BEFORE_PUBLISH rather than HEAD~1 so the diff
# is anchored to what this run inherited, whatever publish.sh did on top.
NOTIFY_FAILED=""
if [ "${JOBS_REFRESH_NOTIFY_ENABLED:-}" = "true" ]; then
  if [ -z "$HEAD_AFTER_PUBLISH" ]; then
    log "publishing was disabled — no commit to notify about"
  elif [ "$HEAD_BEFORE_PUBLISH" = "$HEAD_AFTER_PUBLISH" ]; then
    log "publish created no new commit — nothing to notify about"
  elif "$REPO/scripts/notify-telegram.sh" "$HEAD_BEFORE_PUBLISH"; then
    log "Telegram digest handled"
  else
    # Captured rather than fatal: the data is already committed and pushed,
    # and killing the run here would leave that success looking like a
    # failure. It still has to reach a human though — a digest that goes
    # missing quietly is precisely what this whole path exists to stop, so
    # it is raised as an alert at the end of the script.
    NOTIFY_FAILED="scripts/notify-telegram.sh failed for commit $HEAD_AFTER_PUBLISH (exit above); the data published fine but the digest did not go out"
    log "$NOTIFY_FAILED" >&2
  fi
else
  log "JOBS_REFRESH_NOTIFY_ENABLED is not \"true\" (got: \"${JOBS_REFRESH_NOTIFY_ENABLED:-<unset>}\") — VM-side Telegram send disabled; the GitHub Actions workflow remains the sender"
fi

# ---------- 8. browser-collection degradation alert (post-publish) ----------
# Deliberately the very last thing this script does. An undetermined or
# unreported portal (step 4b) does not block the run — merge, npm run
# check and publish above already ran and completed normally, and the
# affected portal is already recorded in this run's warnings on the
# dashboard. But systemd's OnFailure= only fires on a non-zero exit, and
# last-run.json's warnings only reach a human via the Telegram digest
# (whichever sender is live), which is gated on jobs.json changing — so a
# quiet cycle (nothing new from the other feeds) plus a broken portal
# would otherwise be completely silent. This exit exists only to force
# that alert. It must run strictly AFTER publish, never instead of it —
# "$REPO/scripts/publish.sh" above is an unguarded command, so under
# set -e a publish failure already stops the script right there with its
# own distinct exit code; this block is only ever reached once publish
# has actually finished (or was intentionally skipped), so it can never
# mask a publish failure.
if [ -n "$BROWSER_DEGRADED" ]; then
  die "RUN SUCCEEDED — merge, npm run check and publish (or the intentional
       JOBS_REFRESH_PUBLISH skip) all completed normally above; the data is
       good and already published if enabled. This non-zero exit exists
       ONLY to raise an alert about a browser-collection degradation (an
       unconfirmed session, or a suspiciously low collected-row count) that
       needs a human to look at — it is NOT reporting a failure of this run.
       Detail (also recorded in this run's warnings on the dashboard):
$BROWSER_DEGRADED" 8
fi

# ---------- 9. undelivered-digest alert ----------
# Same shape and same reasoning as step 8: the run itself succeeded and the
# data is published, but a human needs to know the notification never
# arrived. systemd's OnFailure= is the only alerting channel this container
# has, so a distinct non-zero exit is how that gets said.
#
# Step 8 can pre-empt this one when a run manages both problems at once;
# both are logged above regardless, so nothing is lost — only the exit code
# is single-valued.
if [ -n "$NOTIFY_FAILED" ]; then
  die "RUN SUCCEEDED — merge, npm run check and publish all completed
       normally above and the data is live. This non-zero exit exists ONLY
       to report that the Telegram digest for this run was not delivered:
$NOTIFY_FAILED" 9
fi

exit 0
