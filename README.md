# jobs-dashboard

An agent-driven job-aggregation pipeline, published as a reference implementation. A systemd timer on a small Linux VM runs two Claude CLI invocations every six hours — one to collect, one to merge and judge — and pushes the result to a static Cloudflare Worker behind Cloudflare Access.

It is extracted from a private deployment that has been running continuously since 2026-07-30. Everything here is the real code, with deployment identifiers replaced by placeholders.

## What's interesting here

Most of the value is not the scraping. It is the failure handling around an LLM that can plausibly do nothing and report success:

- **A run that returns `0` having written nothing is treated as a failure**, not a no-op — the orchestrator hashes the run-note file before and after and retries once before paging (`scripts/refresh-run.sh` step 5b).
- **Exit codes are an interface with two writers.** `publish.sh` runs as an unguarded child under `set -e`, so its codes shadow the parent's. Codes `10`+ are reserved for the parent, after a collision caused a real false page. See the exit-code table below.
- **Absence used as a signal has to be *made* true.** Two cache files are deleted rather than assumed missing, because `.cache` persists across runs and a stale file reads as a fresh one.
- **A "logged out" portal and an "unrendered page" are different states** and are handled differently, because collapsing them once discarded 387 good rows.
- **`docs/refresh-task.md` is not documentation — it is the merge agent's prompt**, read live on every run. Sections are referenced by name from the orchestrator, so headings are load-bearing.
- **Deterministic filters run in code, judgement runs in the model.** Mechanical vetoes (location, language, title patterns) live in `scripts/vetoes.mjs`; fit and salary estimation stay with the agent. Every drop is recorded with a reason so "why is this job not on my dashboard?" is answerable.

Nearly every comment in `scripts/refresh-run.sh` documents an incident. It is worth reading as a log of things that broke.

## What's *not* in this repo

This is the pipeline, not the data.

- **No job data.** `public/data/jobs.json` and `last-run.json` are excluded — in the live deployment they name several hundred companies and record which roles the operator saved, rejected and why. The schema is documented below; the files are not here.
- **No commit history.** The upstream repo's history contains ~114 versions of the run-note file, for the same reason.
- **No credentials or account identifiers.** Hostnames, the KV namespace id, the VM name and paths are placeholders. There is no `.env` to find; the repo has never contained one.
- **Job-search targeting is genericised.** The search region, salary thresholds and role-family regexes in `scripts/vetoes.mjs` are one person's calibration on the Hungarian IT market. Treat them as an example of the *shape*, not as defaults.

## Layout

Static-assets Cloudflare Worker with exactly one API route. A companion private repository (referred to as `profile-repo`) supplies the operator's target roles and salary benchmarks to the merge step; it is not part of this project.

## Architecture

```
Linux VM (Proxmox guest 01-apps-vm)  jobs-dashboard (this repo)
  systemd timer, every 6h                public/data/jobs.json   <- data
  container: refresh agent               public/index.html|app.js|styles.css
    npm run fetch     Profession + NFJ, sessionless   wrangler.jsonc
    browse step       LinkedIn alerts, Playwright MCP
                        ──► logged-in Chromium (CDP)
    npm run liveness  probes rows seen in the last 20d
    merges all of it into jobs.json
    runs npm run check
    runs scripts/publish.sh itself
      validate → commit → push      <- the only step holding a key
    sends the Telegram digest
                       │
                 push to main
                       ▼
             Cloudflare Workers Builds
                       ▼
             Worker (static assets + /api/tracker on KV)
                       ▼
             Cloudflare Access  ──►  jobs.example.com
```

One script on the VM wrapping two Claude invocations: it fetches, collects,
merges, validates, commits and pushes in a single run — no separate watcher,
no launchd, no TCC problem. **Nothing runs on the MacBook.** The whole
pipeline moved to the VM on 2026-07-30, the session-bound LinkedIn alerts
feed included; the browser half arrives through a Playwright MCP server
attached to a logged-in Chromium, operated from the homelab repo rather than
here — see `docs/refresh-task.md`'s "Browser collection (Phase 2b)". (The
three saved-jobs lists that used to share that constraint were retired
2026-08-07.) See "History" under "Refresh pipeline" for why the old Mac-only
pipeline was split in two, and why that split is gone.

The Worker serves files plus exactly one API route: `GET/PUT /api/tracker` (`src/worker.js`), a single KV blob that syncs the application tracker across devices — added 2026-08-07; before that the Worker was static-assets-only. Access decides who gets in, for the files and the API alike. The server-side surface is deliberately one route, one key, one ~60-line file with shape validation and a size cap — keep it that way.

## Ownership boundary — read this before touching Terraform

Deployment is driven by **Cloudflare Workers Builds** watching `main` in this repo.

| Owned by Workers Builds (this repo) | Owned by Terraform (the cloudflare repo) |
| --- | --- |
| the `jobs-dashboard` Worker script and its assets | DNS record for `jobs.example.com` |
| the `TRACKER` KV namespace binding (namespace `<kv-id>…`, created by hand with wrangler 2026-08-07) | the Worker custom-domain binding |
| | the Access application and its policy (including the service-token policy for the refresh pipeline) |

Terraform must **not** declare a `cloudflare_workers_script` for `jobs-dashboard`. If it did, every `terraform apply` would overwrite whatever Workers Builds last deployed, and the two systems would fight over the same resource. A custom-domain resource that *references* the script by name is fine — that only binds a route, it does not manage the script body.

## Access control

The list reveals where the user is applying while employed. It must never be publicly reachable.

Cloudflare Access sits in front of the hostname, managed in the Terraform repo. The Worker itself performs no authentication — it assumes every request that reaches it already passed Access. If the Access policy is ever removed, the whole list becomes public immediately — and since 2026-08-07 the tracker endpoint (`PUT /api/tracker`) becomes publicly *writable* too, so the stakes of that policy went up, not down. Treat it as the single control keeping this private.

The refresh pipeline reads the same endpoint with an Access **service token** (`CF-Access-Client-Id`/`-Secret` headers): the token is created in Zero Trust and the Access application needs a Service Auth policy admitting it — both live on the Terraform side of the boundary.

`_headers` adds defence in depth: a strict CSP with no external origins, `noindex`, `frame-ancestors 'none'`, and `no-referrer`.

## Telegram notification

The digest diffs `jobs.json` against the previous commit and sends a Telegram message — **but only when something actually changed**. A refresh that only bumps `lastSeen` dates sends nothing. `scripts/notify-diff.mjs` builds the message and is shared by both senders; only the transport differs.

There are two senders, and **exactly one may be live at a time** — both means every refresh notifies twice:

| Sender | Trigger | Status |
| --- | --- | --- |
| `scripts/notify-telegram.sh`, from `refresh-run.sh` step 7b on the VM | `publish.sh` created a commit | **live** — `JOBS_REFRESH_NOTIFY_ENABLED=true` in the container |
| `.github/workflows/notify-telegram.yml` | manual dispatch only | fallback — `push:` trigger removed 2026-08-21 |

The message contains:

- new jobs, priority ones first (⭐ = DevOps, Architecture, Security or AI category, or a ceiling at 2.0M+), each with company, category, salary and a link
- jobs whose status flipped to `Mentett` since the last run
- jobs that crossed the 14-day archive threshold
- a one-line count of dead ads the run cleaned up on purpose (`cleanedDeadIds`), and a loud, itemised warning for any row that vanished *without* being on that list
- the refresh task's own written assessment, from `public/data/last-run.json`
- any warnings the task recorded

Two design points worth knowing:

**The narrative is not generated in CI.** The refresh task already forms a judgement about what it found; it writes that to `last-run.json`, which `publish.sh` commits alongside `jobs.json`. The sender just relays it. That avoids paying for a second LLM call and avoids two systems forming different opinions about the same data.

**Everything from the data is HTML-escaped** before it reaches Telegram. Job titles and company names come from scraped web pages — untrusted input by definition. The validator additionally rejects a `summary` containing `<`.

### Why a VM-side sender exists

The workflow works, but it puts a metered, externally-owned dependency in front of a message the VM already holds every input for. On 2026-08-19 and 2026-08-20 five digests were lost outright: the jobs were refused before a runner ever picked them up — *"recent account payments have failed or your spending limit needs to be increased"*. The data published normally each time, so nothing downstream noticed; the dashboard was current and the notification simply never arrived. Sending from the VM removes GitHub from the path entirely.

The trade-off is the Actions run log, which was a free audit trail. `scripts/notify-telegram.sh` logs the full Telegram API response instead, so the VM's run journal becomes the record.

A digest that fails to send from the VM exits `9` — the run itself succeeded and the data is live, but `systemd`'s `OnFailure=` is the container's only alerting channel, and a silently-lost digest is the exact failure this path exists to prevent. Same shape as the exit `8` browser-degradation alert.

### Rolling back to the workflow

Restore the `push:` block in `.github/workflows/notify-telegram.yml`, then unset `JOBS_REFRESH_NOTIFY_ENABLED` on the VM — in that order, so there is never a window with no sender. Both set at once means every refresh notifies twice.

The container's credentials are `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` in `/opt/<stack>/jobs-refresh.env`, rendered by an Ansible role from a secrets store — deliberately the same "Job Agent" bot and private chat the workflow used, and *not* the homelab alert bot that handles `OnFailure=` notifications.

### Setup

1. Create a bot with [@BotFather](https://t.me/BotFather), keep the token.
2. Send the bot a message, then read your chat id from `https://api.telegram.org/bot<TOKEN>/getUpdates`.
3. Add two repository secrets under Settings → Secrets and variables → Actions:
   - `TELEGRAM_BOT_TOKEN`
   - `TELEGRAM_CHAT_ID`
   The VM sender reads the same two names from its environment.
4. Test without waiting for a refresh: Actions → Notify Telegram → Run workflow → tick **force**. For the VM sender, run `scripts/notify-telegram.sh HEAD~1` by hand in the container.

### Privacy note

The message names the companies you are looking at. Telegram cloud chats are not end-to-end encrypted, so this content sits on Telegram's servers — a weaker boundary than the Cloudflare Access protected dashboard. That is an accepted trade-off for push convenience; if it stops being acceptable, the same workflow can post to a self-hosted endpoint instead.

## Data model

`public/data/jobs.json`:

```jsonc
{
  "schemaVersion": 1,
  "generatedAt": "2026-07-28T12:08:15.037Z",
  "jobs": [
    {
      "id": "li-4441024544",        // <source>-<portal id>, stable across refreshes
      "role": "Senior Cloud Engineer",
      "company": "Example Kft.",
      "source": "LinkedIn",          // LinkedIn | Profession | NoFluff
      "category": "Artificial Intelligence",
      "type": "Employee",            // Employee (gross) | Contract (net, B2B)
      "description": "…",
      "salaryLo": 1900000,
      "salaryHi": 2600000,
      "salaryPosted": false,         // true only when the ad states the figure
      "benchmark": "AI Senior + lead prémium",
      "url": "https://…",
      "status": "Mentett",           // Mentett | Értesítő | NFJ keresés
      "firstSeen": "2026-07-27",
      "lastSeen": "2026-07-28"
    }
  ]
}
```

`lastSeen` drives archiving: a job not seen in any source for more than 14 days is shown as archived and hidden by default. `firstSeen` drives the "ÚJ" badge (7 days).

`public/data/last-run.json` carries the refresh task's own note:

```jsonc
{
  "ranAt": "2026-07-28T16:30:00+02:00",
  "summary": "plain Hungarian text, max ~1200 chars — no HTML, no Markdown",
  "warnings": ["optional, one string per problem"],
  "cleanedDeadIds": ["pr-2936905", "…ids the run deleted on purpose, or omit"]
}
```

`cleanedDeadIds` exists so the notifier can tell a deliberate deletion from data loss. The task deletes confirmed-dead `Értesítő`/`NFJ keresés` rows (see `scripts/check-liveness.mjs`); everything else is supposed to stay put and age into the archive. The diff subtracts these ids from the rows that vanished and reports the rest as unexpected — so the "eltűnt a fájlból" warning only fires when something genuinely went missing.

It is committed together with `jobs.json` so the narrative always matches the numbers it describes. Both files are validated by `npm run check`.

Salary figures with `salaryPosted: false` are estimates from the NFJ Fizetési Iránytű 2026 H1 bands with an employer-type adjustment. They are a screening aid, not a negotiating position.

### Client-side state (localStorage)

The UI keeps two pieces of state in the browser only — they never touch the repo or the pipeline:

- `jobs:lastVisit` — ISO timestamp of the previous visit; drives the "friss" (new since your last visit) highlight. Day-granular comparison, inclusive of the visit day, because `firstSeen` has no time component and the refresh runs every 6 hours.
- `jobs:tracker` — `{ [jobId]: { st, at } }` with `st` ∈ `saved | applied | interview | offer | rejected | ignored`; drives the "Saját státusz" column, the applied/ignored filters and the row tints. `saved` was added 2026-08-07 when the three portal saved-jobs lists were retired: it is the only neutral-positive status (everything else is application progress or a rejection), and it is where bookmarking a job for later now happens instead of on the portals. `scripts/mentett-to-tracker.mjs` can export the legacy `Mentett` rows into this format, but importing it is **optional** — those rows keep `status: "Mentett"` in `jobs.json` (git-backed and permanent), and `survivesArchiveHide` in `public/app.js` treats that status as a marker in its own right, so they stay visible with no action. The import only changes what the "Saját státusz" dropdown shows for them.

**Since 2026-08-07 the tracker syncs across devices** via `GET/PUT /api/tracker` (`src/worker.js`, one KV blob, behind the same Access policy as the site): the page pulls and merges on load (per id, newer `at` wins; new writes stamp full ISO timestamps, legacy entries carry day-only dates and compare correctly), pushes debounced on every change, and shows a small ☁ indicator in the header (moved there 2026-08-08 so it's visible on mobile without scrolling; was in the footer before). localStorage is thereby demoted to an offline cache, so Safari's 7-day ITP eviction stops being data loss. The `jobs:lastSync` key records when this browser last merged with the server — it is what distinguishes "edited locally while offline" from "deleted on another device". Filter state is not stored; it lives in the URL hash (never sent to the server, so search terms stay out of Cloudflare logs) — including the `inbox` key added 2026-08-08 for the "Feldolgozandó" triage-mode toggle (rows with no tracker status yet, not archived). Triage mode is the **default** since later that day — only the off state serializes (`inbox=0`), so a bare URL opens the to-do view and "Összes" is the explicit choice.

**Desktop keyboard shortcuts** (added 2026-08-08, see the footer hint line): `j`/`k` move a row cursor, `x` sets "Nem érdekel" (with the same undo snackbar as the row's ✕ button), `s` sets "Elmentve", `Enter` opens the cursor row's ad in a new tab. Ignored while a form field has focus.

The footer export/import buttons remain as backup and as the escape hatch if the API is ever down. `scripts/tracker-to-rejected.mjs <export.json>` merges a tracker JSON's `ignored`/`rejected` ids into `.cache/rejected-ids.json`, so a "Nem érdekel" click reaches the fetcher and the fit filter instead of dying in the browser (measured before the fix: 519 negative verdicts, 5 in the ledger). The refresh pipeline now runs this automatically each cycle against the sync endpoint (see `scripts/refresh-run.sh` step 2b — gated on `JOBS_TRACKER_SYNC_URL` + `JOBS_TRACKER_CLIENT_ID`/`_SECRET`, an Access service token); the manual path still works and is idempotent. Ledgered rows stop being refreshed and age into the archive on their own — see `docs/refresh-task.md` ("3. Merge") for the pipeline-side rules this relies on.

Lookups go through `ledgerLookup()` (added 2026-08-24), not a bare `id in ledger`: NFJ re-slugs a re-published ad as `<slug>-1`, `<slug>-2`, … so an exact-id ledger leaks a rejected ad back into the feed every time the employer reposts it. Observed on a senior analyst ad that had been ledgered since July and arrived as a fresh `…-budapest-1` candidate. The fallback strips one trailing `-<n>` and is scoped to `nfj-` ids only — `pr-` and `li-` ids *end* in their numeric key, so the same normalisation would collapse them to `pr-`/`li-` and suppress both corpora wholesale. A fallback hit records `"<reason> (slug variant of <id>)"` in `droppedRows`, so a reused verdict never reads as an exact one.

Two category rules are intentionally duplicated in `public/app.js` and `scripts/notify-diff.mjs` — change both or neither:

- ⭐ priority: category ∈ DevOps/Architecture/Security/AI, or `salaryHi` ≥ 2.0M.
- demoted: category = Business Analyst (83% "Nem érdekel" rate measured 2026-08-07, but the kept 17% was real — so the family sorts last in the UI and is counted but never enumerated in the Telegram digest, instead of being dropped).

## Local development

```bash
npm install
npm run check     # validate jobs.json — run this before every commit
npm run dev       # wrangler dev, serves ./public
```

`npm run check` fails on: invalid JSON, missing fields, duplicate ids or URLs, non-https URLs, inverted or absurd salary ranges, malformed dates. Workers Builds deploys whatever is on `main`, so this is the only gate between a bad refresh and a broken live site.

## Deployment

Push to `main`. Workers Builds does the rest. There is no build step — the assets are served as-is.

Manual fallback if Workers Builds is unavailable: `npx wrangler deploy` with a Cloudflare API token that has Workers Scripts:Edit.

## Git identity

GitHub blocks pushes that would publish a private email address. Commits here must use the account's noreply address:

```bash
git config user.email "<id>+<user>@users.noreply.github.com"
git config user.name "toom"
```

This matches the `profile-repo` convention, so no real address ever reaches a remote.

## Refresh pipeline

Every 6 hours (`*-*-* 1/6:00:00` plus up to 600s jitter — 01/07/13/19 UTC), a systemd timer on the Linux VM (Proxmox guest `01-apps-vm`) runs the refresh agent inside a container. The timer, the unit and the container's environment file (`/opt/<stack>/jobs-refresh.env`) are versioned in the homelab Ansible repo, not here; `job-list-refresh` was the id of the retired Cowork task and survives only as the name of the prompt in `docs/refresh-task.md`.

**The VM covers every source.** The sessionless machine feeds come from `npm run fetch` (Profession.hu listing pages, No Fluff Jobs SSR); the session-bound LinkedIn alerts feed comes from the browse step described below, live on the VM since 2026-07-30 — the same day the machine feeds moved. LinkedIn is the larger half: 488 of 768 rows (64%) on 2026-08-24, against 280 (36%) from the machine feeds. The three saved-jobs lists that used to sit on this side of the boundary (LinkedIn saved, Profession.hu saved, No Fluff Jobs favourites) were retired 2026-08-07; curation now lives in the dashboard's own localStorage tracker.

The agent merges its results into `public/data/jobs.json` preserving `firstSeen`, runs `npm run check`, then runs `scripts/publish.sh` itself: validate, commit if changed, push. There is no separate watcher process and no launchd agent — the container has no TCC restriction and no sandbox unlink guard, so the agent that parses untrusted web pages can also run git directly and hold the push credential.

`publish.sh` pushes whenever `main` is ahead of `origin/main`, independently of whether it just committed. That matters when a push fails (VM offline, expired key): the commit stays local and goes out on the next scheduled run instead of sitting there forever, since `jobs.json` no longer looks "changed" by then.

Exit codes: `0` success or nothing to do, `1` not a repository, `2` live git lock, `3` push failed (commit stays local, retried next run), `4` preflight write-probe failed — check filesystem permissions/mount, `5` could not take the run lock, `6` `origin/main` has commits we do not have.

### `scripts/refresh-run.sh` and the publish gate

`scripts/refresh-run.sh` is the entry point the container execs. A thin bootstrap (versioned in the homelab repo, not here) clones/pulls this repo to `/data/jobs-dashboard` and `profile-repo` to `/data/profile-repo`, then hands off to this script, which: checks those checkouts and `npm` are actually present, installs dependencies (`npm ci --omit=dev` if a lockfile exists, else `npm install --omit=dev` — nothing the container runs imports a runtime dependency, so since 2026-08-22 this no longer pulls wrangler and workerd from the registry every six hours), imports the dashboard tracker's rejects, runs `npm run fetch` for the sessionless machine feeds, starts the liveness sweep in the background, runs the browse step and filters its output, waits for the sweep, invokes the Claude CLI (`claude --print … --model "$ANTHROPIC_MODEL" --effort "$JOBS_REFRESH_MERGE_EFFORT" --permission-mode bypassPermissions --add-dir /data/profile-repo`) to merge the results into `public/data/jobs.json` following `docs/refresh-task.md`, then runs `npm run check`. If validation fails, it restores `public/data/jobs.json` and `public/data/last-run.json` from git and exits non-zero — a broken merge never gets a chance to publish.

`bypassPermissions` is scoped to what this container actually mounts — the repo, the profile-repo checkout, the Claude config dir, and read-only SSH keys — so the blast radius of skipping prompts is the container itself; `--add-dir` is what makes `/data/profile-repo` (outside the repo working tree) reachable at all. Neither flag belongs on a host that isn't this narrowly sandboxed.

**A `claude` run can exit `0` while doing nothing** — e.g. every write denied — which would otherwise validate the unchanged data, pass, and report success: a run that looks healthy and produced nothing. `public/data/last-run.json` is written unconditionally on every real run (even a no-op one), so the script hashes it before and after the Claude call; an unchanged hash means the merge produced nothing.

**A first no-op is retried, not paged (added 2026-08-22).** Twice in the eleven days to 2026-08-22 the cause was transient — the agent narrating work it still intended to do and then returning anyway — and a hand re-trigger on identical inputs succeeded. So the script restores the data files from git, appends a note to the prompt saying this is a retry and that scratch files from the previous attempt may still be in `.cache/`, and tries again; `JOBS_REFRESH_MERGE_ATTEMPTS` (default 2) bounds it, and `1` restores the old page-on-first-no-op behaviour. Reaching the failure means two consecutive no-ops, which is evidence of something structural rather than a flaky return — that is exit `10`, **not** `6`; see the exit-code table for why the distinction matters.

**Between the fetch and merge steps, an optional browser-collection step (Phase 2b) can run.** When `JOBS_REFRESH_BROWSER_ENABLED` is exactly `true`, the script invokes the Claude CLI a second time (`claude --print … --model "$JOBS_REFRESH_BROWSE_MODEL" --effort "$JOBS_REFRESH_BROWSE_EFFORT" --mcp-config "$JOBS_REFRESH_MCP_CONFIG" --strict-mcp-config --permission-mode bypassPermissions`) against a Playwright MCP server attached to a logged-in Chromium, to collect the one remaining session-bound source (the LinkedIn alerts feed) into `.cache/browser-latest.json` — see `docs/refresh-task.md`'s "Browser collection (Phase 2b)" section for the file's shape. This step never merges, never writes `public/data/`, and never runs git; the existing merge step consumes its output alongside `.cache/sources-latest.json`, the same way it already consumes the machine feeds. It runs on a separate, cheaper model (`JOBS_REFRESH_BROWSE_MODEL`, default `sonnet`) than the merge step's `ANTHROPIC_MODEL` (Opus) — DOM extraction is mechanical, while the fit-filtering/salary/summary judgement stays on Opus in the merge step. Unset or not exactly `true` skips the step entirely and the merge sees only `npm run fetch`'s output. It is set to `true` on the VM; the gate exists so a broken browser stack can be switched off without stopping the machine feeds.

**The two Claude invocations run at different effort levels, deliberately.** `JOBS_REFRESH_BROWSE_EFFORT` (default `high`) governs the browse step, `JOBS_REFRESH_MERGE_EFFORT` (default `xhigh`) governs the merge step. The browse step is mechanical DOM extraction against documented selectors and is already the long pole of the run (12-16 minutes observed); the merge step is where the actual judgement happens (fit filtering, salary estimation, the Hungarian summary) and is the shorter of the two (~4-9 minutes), so it gets the higher effort level. Both fall back to those defaults when the env var is absent, same pattern as `JOBS_REFRESH_BROWSE_MODEL`.

**The browser step checks the LinkedIn session is genuinely authenticated before scraping, and the three possible outcomes are handled differently on purpose.** A stale session doesn't error when scraped — it returns an empty result list, indistinguishable from "the alert feed is quiet today" — so a whole discovery cycle would silently report zero new jobs with nothing in `warnings` saying why. The check exists to catch that loudly. (Before the saved-jobs lists were retired the stakes were worse still: unbumped `lastSeen` on already-curated rows, archived 14 days later.) The result lands in `.cache/browser-latest.json`'s `auth` object as one of three states:

- **`logged_out`** — positive evidence of a signed-out session (a login redirect, or a visible sign-in prompt). There is a human action here (sign back in), and nothing useful will come from that portal until they do, so this **blocks the run outright**: `refresh-run.sh` aborts immediately, before the merge ever runs (exit `7`), the same all-or-nothing failure semantics the script already applies to every earlier collection step (`npm run fetch` failing already blocks the merge too, for the same reason). The abort message names the portal, its reason, and says to re-authenticate at `chrome.example.com`.
- **`undetermined`** — the check was inconclusive because the page itself didn't render (empty body, near-empty accessibility snapshot, a burst of console errors). This is evidence the check couldn't complete, not evidence of a bad session, and there is no human action to take — so it does **not** block. A first live run collapsed this into `logged_out` by mistake (a broken No Fluff Jobs render, not a bad session) and discarded 387 good rows already collected from the other two portals; that is exactly what this state prevents. Now that LinkedIn is the only portal, this state means no browser rows at all — but it still must not block, because the sessionless machine feeds (280 of 768 rows, 36% of the corpus on 2026-08-24) are unaffected and worth publishing.
- **`unreported`** — the portal is missing from the auth object, or carries a value that isn't one of the two above. Also no human action, so it does not block either — but it signals a bug in the browse step itself, not a flaky portal, and is reported with that distinction rather than being folded into `undetermined`.

**Separately from the auth tri-state, the script counts what was actually collected (added 2026-08-07).** A paging or DOM regression is invisible to the auth check — the session is fine, the page renders, but only the first results page (or none) gets scraped; the 2026-07-29 LinkedIn DOM change would have looked exactly like this. So when the session is confirmed `ok`, fewer than `JOBS_REFRESH_BROWSE_MIN_ROWS` collected alert rows (default 60 — half the minimum of the 112–159 accepted rows observed across six daily feed sweeps, several times above the ~10–25 a page-1-only failure yields) is treated like `undetermined`: no block, publish proceeds, exit `8` raises the alert after. This check replaced the unseen-streak warning for LinkedIn rows, which the 7-day feed window had reduced to a permanent 138-row false alarm — see `docs/refresh-task.md`'s "3. Merge".

**A non-blocking portal (`undetermined`/`unreported`) still needs to reach a human, without discarding a good run to do it.** `systemd`'s `OnFailure=` only fires on a non-zero exit, and `last-run.json`'s `warnings` only reach the owner through the Telegram digest, which is gated on `jobs.json` actually changing (that gate is the same whichever sender is live — see "Telegram notification") — so silently continuing with exit `0` could mean a quiet cycle plus a broken portal goes completely unnoticed. So the run continues through merge (which records the affected portal and its reason in this run's `warnings`), `npm run check`, and the gated publish exactly as normal — and only *after* publish has completed (or been intentionally skipped) does the script exit non-zero (exit `8`) purely to trigger the alert. The exit message is explicit that the run succeeded and the data is good; the non-zero status exists only to get a human's attention, not to report a failure. A publish failure is unaffected by this and still surfaces as its own earlier, distinct error, since `scripts/publish.sh` runs as a plain unguarded command under `set -e` — this step is only ever reached once publish has actually finished.

**Exit codes — and the collision that shaped them.** `scripts/publish.sh` runs as an unguarded child of `refresh-run.sh` under `set -e`, so *its* exit codes surface as this service's exit code and shadow this script's one for one. `the homelab notifier` keys its advisories on the unit's exit status, so an overlap is not cosmetic: the no-op-merge guard originally held `6`, the notifier's `6` was later written against `publish.sh`'s "`origin/main` diverged", and the 2026-08-22 19:00 no-op run paged as an ACTION REQUIRED divergence that did not exist. The guard moved to `10` on 2026-08-22 — codes `10` and above are this script's alone and cannot collide.

The same reasoning applied a second time on 2026-08-25. Exit `8` had come to mean two opposite things: a `filter-browser` failure that **blocks** the run before the merge, and a post-publish alert on a run that **succeeded**. The notifier could not tell them apart, so a cycle that published nothing would be reported as one that published fine. The blocking case is now exit `11`.

| Code | Meaning |
| --- | --- |
| `0` | success |
| `1` | a precondition failed — not a repo, `npm` missing, `profile-repo` not checked out |
| `2` | dependency install failed |
| `3` | `npm run fetch` failed — nothing was collected, and there is no HTTP fallback for the machine feeds |
| `4` | the Claude CLI merge run failed (non-zero exit) |
| `5` | `npm run check` failed after the merge — `jobs.json` and `last-run.json` were restored from git |
| `6` | **not used by this script** — left clear because `publish.sh`'s `6` (`origin/main` has commits we do not have) propagates through it |
| `7` | the browser collection failed and **blocked the run before the merge** — the Claude CLI run failed, it exited `0` without (re)writing `.cache/browser-latest.json`, that file was unreadable, or LinkedIn came back `logged_out` |
| `8` | the run **succeeded** and the data is live, but the browser collection was degraded and needs a human to look — the session came back `undetermined`/`unreported`, or it authenticated and collected fewer than `JOBS_REFRESH_BROWSE_MIN_ROWS` rows (default 60; normal runs bring 110+, a page-1-only paging regression ~10–25), or rows arrived with no `title` so the vetoes judged an empty string and only the ledger applied. Raised after publish, never before |
| `9` | the run **succeeded** and the data is live, but the Telegram digest was not delivered |
| `10` | Claude exited `0` but never rewrote `last-run.json`, on every attempt (`JOBS_REFRESH_MERGE_ATTEMPTS`, default 2) — treated as a failed, silent no-op rather than a successful one |
| `11` | `npm run filter-browser` failed and **blocked the run before the merge** — merging unfiltered rows would re-admit ledgered ads and bump their `lastSeen` so they never archive. Nothing was published (added 2026-08-25; was `8`) |

**The split that matters for alerting:** `8` and `9` are alerts on a run that *succeeded* — the merge, validation and publish all completed, the data is live, and the exit message says so explicitly. Every other non-zero code is a genuine failure that published nothing. Since 2026-08-25 no code straddles that line, so a notifier can key on the exit status alone to decide whether the dashboard is current.

**Running and publishing are separate steps, gated independently.** `refresh-run.sh` only calls `scripts/publish.sh` when the environment variable `JOBS_REFRESH_PUBLISH` is exactly `true`; anything else — unset, empty, `false`, a typo — is treated as "do not publish" (fail safe), logs that plainly, and exits 0 leaving the refreshed files uncommitted in the working tree. That makes it possible to run a refresh and inspect the diff by hand before anything reaches git, without touching the publish path at all.

### History

This used to run on a MacBook, split into two components across a trust boundary, because of two macOS-specific limits that don't exist on Linux:

- Connected folders were mounted into the Cowork sandbox with **unlink denied** (create and rename worked, delete did not), so the refresh agent — which parses attacker-controllable LinkedIn/No Fluff Jobs pages — could only write `jobs.json` and was never allowed to run git itself.
- A separate `launchd` agent (`com.example.jobs-dashboard-publish`) held the only git credential and watched `jobs.json` for changes to publish it, because `~/Documents` is TCC-protected and a LaunchAgent has no UI session to clear that prompt — hence the repo lived in `~/Projects` instead.

Neither limit applies inside a Linux container, so the split no longer earns its complexity: on the VM, one script fetches, collects, merges, validates, commits and pushes in one run. The browser-bound source was the last thing still tied to the Mac, and it moved on 2026-07-30 as well — the logged-in Chromium runs on the VM now, and the browse step reaches it over CDP through a Playwright MCP server. Nothing here is split across two machines any more.

### Troubleshooting

Run `scripts/publish.sh` by hand to reproduce a failure; each step logs to stdout with a timestamp.

Push fails with `Host key verification failed` or an auth error: there is no terminal to answer a prompt, so `publish.sh` sets `GIT_TERMINAL_PROMPT=0` to fail fast instead of hanging. Make sure `github.com` is in the container's `~/.ssh/known_hosts` and the deploy key loads without a passphrase prompt.
