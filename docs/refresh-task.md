# Scheduled task: `job-list-refresh`

Source of truth for the `job-list-refresh` prompt, and for how the refresh actually runs.

**Read this before editing anything below.** This file is not a description of the pipeline — it *is* the pipeline's prompt. `scripts/refresh-run.sh` step 5 tells the merge agent to "Read docs/refresh-task.md now and follow it end to end," every six hours, and points it at sections **by name**: "Phase 1 — Linux VM variant" and its path-mapping table, "Browser collection (Phase 2b)", "1. Collect", "2. Liveness", "3. Merge", and the browse step's "Output" block. Those headings are load-bearing — rename one and the prompt's pointer dangles. A factual error here is a prompt bug shipped to production on the next timer tick, not documentation debt.

**Why the canonical prompt is still here.** The "Prompt" section below is preserved verbatim from the original Cowork scheduled task. It is no longer run as written — that task and its `launchd` publisher were retired on 2026-07-30 — but the merge agent still reads it for the collect, liveness, merge, salary, fit-filter and run-note rules, which are unchanged and machine-independent. "Phase 1 — Linux VM variant" supersedes its paths, its "do not run git" rule and its publishing model; where the two disagree, that section wins.

## How this fits together

```
systemd timer on 01-apps-vm (Proxmox guest) — *-*-* 1/6:00:00, +≤600s jitter
  └─ container: scripts/refresh-run.sh
      2b. tracker sync import     gated: JOBS_TRACKER_SYNC_URL + Access token
      3.  npm run fetch           Profession HTML + NFJ SSR, sessionless
      3b. npm run liveness        started here, waited on at 4d
      4.  claude --print (sonnet) ──► Playwright MCP ──► logged-in Chromium
            browse step               writes .cache/browser-latest.json
      4b. login-state assertion   logged_out blocks the run (exit 7)
      4c. npm run filter-browser  ledger + vetoes ──► browser-filtered.json
      5.  claude --print (opus)   merge ──► last-run.json, then jobs.json
      6.  npm run check           restores both files from git on failure
      7.  scripts/publish.sh      gated: JOBS_REFRESH_PUBLISH=true
      7b. notify-telegram.sh      gated: JOBS_REFRESH_NOTIFY_ENABLED=true
                      │
                push to main ──► Workers Builds ──► jobs.example.com
```

Steps 4–4c run only when `JOBS_REFRESH_BROWSER_ENABLED=true`, which is how the VM is configured today. Both Claude invocations run with `--permission-mode bypassPermissions`; the container's mounts are the whole blast radius. README.md carries the exit-code table and the publish gate.

### Retired 2026-07-30: the macOS split (kept for the reasoning)

This used to run on a MacBook as a Cowork scheduled task plus a `launchd` publisher (`com.example.jobs-dashboard-publish`), split across a trust boundary. Two macOS-specific limits forced that split; neither exists in the Linux container:

- Connected folders were mounted in the agent sandbox with **unlink denied** — create and rename worked, delete did not. That was a deliberate guard so an agent reading untrusted web pages could not delete files. Git is unlink-heavy (`index.lock` replacement, `HEAD.lock`, temp objects), so a commit under that mount half-succeeded and stranded lock files. `scripts/publish.sh` still carries the preflight probe that detects this.
- The repo lived in `~/Projects` and not `~/Documents` because `~/Documents`, `~/Desktop` and `~/Downloads` are TCC-protected on macOS. A LaunchAgent has no UI session and cannot answer a consent prompt, so access there failed silently — observed as `last exit code = 126`. Adding `/bin/bash` to Full Disk Access was rejected: it would grant every shell script on the machine full disk access to solve one narrow problem.

**Paths are defined in exactly one place:** the path-mapping table under "Phase 1 — Linux VM variant". Nothing else may override it. If the container's mount points change, that table and `scripts/refresh-run.sh`'s `PROFILE_REPO_ROOT` must be updated together.

## Design decisions baked into the prompt

Each line is the fix for something that actually broke.

| Decision | Reason |
| --- | --- |
| Stop if the repo folder is not mounted | The first live run had no access to the repo; writing a partial file elsewhere would have split the state and lost `firstSeen`. |
| Merge into the existing file, never regenerate | Regenerating resets `firstSeen`, which drives the "ÚJ" badge and the archive logic. |
| Never delete rows for merely-missing ads; confirmed-dead feed rows are the exception (revised 2026-07-29) | A stale `lastSeen` is more informative than a missing row, and the UI archives it automatically after 14 days. But `check-liveness.mjs` gives proof of death (Profession 301/"lejárt", NFJ 404): dead `Értesítő`/`NFJ keresés` rows carry no curation and are deleted + ledgered; dead `Mentett` rows are kept but get `closed`, which archives them at once. One-off cleanup 2026-07-29: 22 dead + 17 German-language legacy rows removed, 3 dead saved rows left to age out. Revised 2026-08-11: dead saved rows used to stay frozen and age out over 14 days, on the reasoning that unsaving is the user's call. Keeping them in triage for two weeks to protect a decision the user was not making anyway is a bad trade — `closed` still keeps the row and its history, it just stops asking about it. Unsaving on the portal remains the user's call. |
| The task never runs git or `publish.sh` | Sandbox unlink denial makes git unsafe here. Publishing belongs to the host-side agent. |
| The task writes the Telegram narrative, CI does not | The task already forms a judgement while it works. Regenerating one in CI would cost a second LLM call and let two systems form different opinions about the same data. |
| `last-run.json` is written before `jobs.json` (added 2026-07-29) | The publish agent triggers on `jobs.json` within ~2 minutes. A run that saved the data file first and the note second got the note committed one publish late: Telegram paired the fresh diff with the previous run's summary and warnings. |
| The notifier puts summary and warnings before the item list, and the list fills the leftover budget (revised 2026-07-29) | Telegram caps messages at 4096 chars. With the list first, a 136-item run truncated the warnings — the only section the reader cannot reconstruct from the dashboard. |
| `summary` must be plain text | It is relayed to Telegram verbatim after HTML escaping; tags would render literally. The validator rejects `<`. |
| `npm run check` must pass before finishing | The agent deploys whatever lands in the file. This is the only gate. |
| Profession alerts and NFJ categories come from `npm run fetch`, not the browser (revised 2026-07-28) | The alert results pages only show a time window: on 2026-07-28 the architect alert's results page showed 0 ads while the equivalent search carried 122. The script's sources are sessionless and return the full current result set. Details: `profile-repo/research/roles/alert-audit-2026-07-28.md`. |
| Profession comes from the HTML listing pages, not the `?rss=1` feeds (revised 2026-07-29) | The RSS feeds are capped at 15 items, ignore the page segment, and pin promoted ads first — new ads can be pushed out entirely. The HTML pages paginate, can be scoped to the two IT categories (25 üzemeltetés, 10 fejlesztés — this killed the construction/"azúr"-manicure keyword noise), and each result `<li>` carries structured data attributes including the company. A keyword+category combination with zero results answers 404; the fetcher treats that as empty. |
| Rejected candidates go to `.cache/rejected-ids.json` and never come back | Full-text search over two whole IT categories yields ~1000 candidates. Without a negative cache the task would re-judge the same noise every 6 hours. The fetcher drops ledgered ids before writing its output; losing the git-ignored ledger costs one heavy re-judging run. |
| Mechanical exclusions live in the fetcher, not the fit filter (added 2026-07-29) | Non-metro locations and German-language ads are policy from `preferences.md`, not judgement — the LLM was re-dropping ~900 such rows deterministically. The city allowlist trusts only the city segment of `data-category6` (the megye segment is unreliable: "Pest megye, Debrecen" was observed); no-city values stay in. |
| Provincial priority roles pass with `locationFlag: "vidéki"` instead of widening the city allowlist (added 2026-07-29) | Adding e.g. Székesfehérvár to the allowlist would re-admit its generic sysadmin noise; the title gate (architect/devops/cloud/security/IAM/AI/SRE) keeps exactly the rows where remote or a relocation-worthy offer is plausible. First measurement: 28 flagged rows, among them a provincial AI Solution Architect role the 2026-07-28 alert-gap analysis had identified as a miss. |
| No curl/wget/requests fallback **for anything with a session** — the LinkedIn alerts feed stays in the browser | Portal sessions live in the browser; a fetch fallback there would either fail or scrape the wrong thing. The two `fetch-sources.mjs` channels need no session, which is why they are exempt. |
| The three saved-jobs lists are retired; curation lives in the dashboard's own tracker (added 2026-08-07) | In the nine days after the initial import they produced 0 (LinkedIn), 7 (Profession) and 0 (NFJ) new saves, and every job they could surface already arrives through the sessionless feeds — the portal round-trip only relayed one bit of intent. Moving that bit to the localStorage tracker cut the browse step from three portals to one, deleted the NFJ API-first workaround, and put curation in one place instead of three websites. |
| `fetch-sources.mjs` locates the NFJ SSR search entry by shape, not key | The `serverApp-state` entry key is a build hash and changes with deployments; the raw `/api/search/posting` endpoint was rejected because it returns Polish-region rows regardless of the `region=hu` parameter (probed 2026-07-28). |
| Confirm LinkedIn ad identity via `document.title` | A keyword search once returned a different, already-saved ad. A wrong link is worse than a missing one. |
| Row `id`s unseen for many consecutive runs get their own persistent streak (`.cache/unseen-streaks.json`), scoped to the machine feeds only (added 2026-07-31, scope narrowed 2026-08-07) | At 4 runs/day, a single missing run proves nothing, but the same row missing for days is a different signal — for a source that returns its full result set every run. That holds for Profession `Értesítő` and `NFJ keresés` (threshold: 12 consecutive runs, ~3 days), and stopped holding for everything else: `Mentett` portals are retired, and LinkedIn's 7-day feed window guarantees every row trips any workable threshold by age alone — 138 rows (37% of LinkedIn `Értesítő`) sat permanently in the warning before the exemption. A LinkedIn paging regression is caught by `refresh-run.sh`'s row-count check (`JOBS_REFRESH_BROWSE_MIN_ROWS`, default 60) instead — deterministic, and it fires on the first bad run rather than three days in. |

## Prompt

Reproduce verbatim when recreating the task.

---

Refresh the job dashboard data. Report in Hungarian; code and repository documentation stay English.

### Scope — read this first

**You write the data file and nothing else.** You do not commit, do not push, do not run git, and do not run `scripts/publish.sh`. "Do not run git" includes read-only commands: `git status` and `git log` also take locks, and under this mount they strand `index.lock` files that block the publish agent — a run on 2026-07-29 caused exactly this and had to clean up after itself. If you need to know what changed, diff file contents, not git state.

Publishing is done by a host-side launchd agent (`com.example.jobs-dashboard-publish`) that watches `public/data/jobs.json` and runs `scripts/publish.sh` as the logged-in user, with that user's git identity and SSH key. This split exists because connected folders are mounted in this sandbox with unlink denied, and git cannot complete a commit safely under that mount — it half-succeeds and leaves stranded lock files. Saving the file is the whole job; the agent takes it from there within about two minutes.

> **Superseded 2026-07-30 — the rule holds, the reason does not.** There is no launchd agent and no sandbox any more. Still do not run git or `scripts/publish.sh`: under `scripts/refresh-run.sh` the orchestrating script runs validation and the gated publish itself, after you return. See "Phase 1 — Linux VM variant".

### Repository

`/Users/you/Projects/jobs-dashboard` — data file: `public/data/jobs.json`.

Note it is `~/Projects`, not `~/Documents`. The repo was moved because `~/Documents` is TCC-protected on macOS and the LaunchAgent cannot answer a consent prompt there.

If that folder is not mounted in this session, stop immediately and report it. Do not write the data anywhere else and do not work around it: a partial or misplaced file would split the state and lose the `firstSeen` history.

Schema (`schemaVersion: 1`). Every job object has exactly these fields:

`id, role, company, source, category, type, description, salaryLo, salaryHi, salaryPosted, benchmark, url, status, firstSeen, lastSeen`

- `id`: `li-<linkedinJobId>` | `pr-<professionAdId>` | `nfj-<slug>` — must stay stable across runs
- `source`: `LinkedIn` | `Profession` | `NoFluff`
- `type`: `Employee` (gross HUF/month) | `Contract` (net HUF/month)
- `salaryPosted`: `true` only when the ad itself states the figure
- `status`: `Mentett` | `Értesítő` | `NFJ keresés`
- `firstSeen` / `lastSeen`: `YYYY-MM-DD`
- `closed` (optional, `YYYY-MM-DD`): the day the liveness probe confirmed the ad no longer exists on the portal. Set once, never cleared or updated. The UI archives a `closed` row immediately, saved or not.

Never invent fields or change the schema. Read the existing file first and merge into it — do not regenerate from scratch, or `firstSeen` history is lost.

### 1. Collect

Two machine feeds come from a script; everything session-bound stays in the browser.

**Machine feeds → run the fetcher first**

```bash
cd /Users/you/Projects/jobs-dashboard
npm run fetch
```

This runs `scripts/fetch-sources.mjs` (sessionless HTTP: Profession HTML listing pages scoped to the two IT categories + NFJ HU SSR pages) and writes `.cache/sources-latest.json`. Read that file:

- `profession[]` rows → status `Értesítő`. Each row has `id` (`pr-<adId>`), `role`, `company`, `url`, `location`, `profCategory`, the alert family and the matched keywords. No posting date — `firstSeen` from the merge carries recency.
- The fetcher already applied the deterministic exclusions from `preferences.md`: non-Budapest-metro locations (city-segment allowlist; no-city rows like "Pest megye"/"Országos" are kept), German-language markers (title regex including all gendered-tag variants like `(m/f/d)`/`(gn)`, + NFJ `jobLanguage`), and — added 2026-08-07, calibrated to 98% precision on 764 user-judged rows — title vetoes: junior/intern outright; SAP/consultant/developer/vendor-platform titles only when no core-domain anchor (security/devops/cloud/infra/AI/…) rescues them into your judgement; NFJ rows whose *posted* band tops out under 900k gross. Do not re-filter for these; the counts are in the output's `dropped` field (`location`, `language`, `title`, `ledger`) — mention them in `warnings` only if they look anomalous (e.g. zero, or a sudden multiple of the usual).
- `droppedRows[]` (added 2026-08-11) lists **every** candidate this run dropped — mechanical veto and ledger alike — as `{id, source, role, company, url, location, reason}`. It is what makes "why is this job not on my dashboard?" answerable: `jq -r '.droppedRows[] | select(.id=="pr-123")' .cache/sources-latest.json`. Rewritten each run, deliberately not accumulated: a still-listed ad is re-fetched and re-judged every six hours, so the current file always covers the ads that can still be found on the portal. Mechanical drops are **not** ledgered — a deterministic rule re-evaluates itself for free, and freezing its verdict would mean that loosening a veto later silently failed to release anything it had already dropped.
- Rows with `locationFlag: "vidéki"` are provincial ads that survived because the title matches a priority family (architect/devops/cloud/security/IAM/AI/SRE). For these, check the ad for remote/hybrid before accepting; note the provincial location in `description` either way.
- `nfj[]` rows → status `NFJ keresés`. Each row has `id` (`nfj-<slug>`), `role`, `company`, `url`, structured salary (`salaryLo/Hi`, `salaryType`: `permanent` = Employee, `b2b` = Contract, `salaryVisible`), `seniority`, `posted`, categories.
- The fetcher already dropped every id listed in `.cache/rejected-ids.json`, so each candidate you see is either genuinely new or previously accepted. **After the fit filter, append the ids you rejected to `.cache/rejected-ids.json` with a reason** — `{ "ids": { "<id>": "<reason>", … } }`, create it if missing, keep existing entries. This is what keeps the next run's candidate set small. Prefix your reasons with `fit:` (`fit:missing-core-skill`, `fit:salary-floor`, `fit:language-requirement`) so they are distinguishable from the other writers' — see `scripts/ledger.mjs` for the vocabulary. Reasons became mandatory on 2026-08-11: the ledger was a flat array of ids until then, which made "why is this job not on my dashboard?" unanswerable — the id was there, the reason was nowhere. Entries predating the change read `legacy`; overwrite one when you rejudge that id, never overwrite a real reason. Never put an id there that made it into `jobs.json` yourself. One standing exception exists (added 2026-08-07): `scripts/tracker-to-rejected.mjs` bulk-imports the ids the user marked `Nem érdekel`/`Elutasítva` on the dashboard — `scripts/refresh-run.sh` runs it automatically before the fetch when the tracker sync endpoint is configured (see README), so this happens every cycle, not just on manual imports — and those ids often *are* still rows in `jobs.json`; the user's explicit verdict outranks the feed. Treat such rows like any other ledgered id: never re-offer, never bump, let them age into the archive (see "3. Merge").
- If the script reports errors for some feeds, carry them into `warnings`. If it exits non-zero (both sources empty), fall back to the old browser flow for this run and report it.
- One-off note: the first run after 2026-07-29 sees the full ~1000-row candidate corpus (no ledger yet). Judge on `role` + `company` + `profCategory`, be ruthless, ledger every reject — subsequent runs then only see the daily delta.

Do not fetch these two sources through the browser any more, and never fall back to curl/wget/requests for anything else: the LinkedIn alerts feed is session-bound and stays in the browser. If the browser half is unavailable, collect the machine feeds, then stop and report it.

**Saved-jobs lists → retired 2026-08-07**

The three saved-jobs lists (LinkedIn saved, Profession.hu `/munkavallalo/allasaim`, No Fluff Jobs favourites) are no longer collected. Do not visit them, and do not assign the `Mentett` status to anything.

Measured over the nine days after the 2026-07-28 initial import, they produced **0, 7 and 0** new saves respectively out of 187 `Mentett` rows — 176 of those rows landed on the import day alone. Meanwhile every job those lists could surface already arrives through the sessionless machine feeds: the merge rule they depended on ("if it is now saved but was `Értesítő`, change status") proves the row was already present, so the portal round-trip existed only to relay a single bit of intent. That bit now lives in the dashboard's own localStorage tracker, which is one place instead of three websites, and costs no browser session at all.

Retiring them cut the browse step from three portals to one and deleted the entire No Fluff Jobs API-first workaround — a source that had required the most fragile code in this document to retrieve exactly one row.

**Existing `Mentett` rows are legacy.** Never bump their `lastSeen`, never change their `status`, never delete them. They age into the archive on their own after 14 days via the UI's staleness rule, which is the intended outcome. The `Mentett` status itself is what preserves the curation — it stays in `jobs.json` permanently, and the UI keeps those rows visible on the strength of it (`survivesArchiveHide` in `public/app.js`). That is exactly why the status must never be rewritten.

**LinkedIn alerts → status `Értesítő` (browser)** — the only session-bound source left
Preference feed, last 7 days: `https://www.linkedin.com/jobs/search-results/?keywords=Solutions%20Architect%20or%20System%20Engineer%20or%20Cloud%20Engineer%20or%20Information%20Technology%20Consultant%20or%20Technical%20Business%20Analyst%20or%20Security%20Engineer%20or%20IAM%20or%20SAP%20Consultant&origin=PREFERENCES_LANDING&geoId=<your-region-id>&f_TPR=r604800`
(Keywords extended 2026-07-28 to match the security/IAM and SAP/ERP alerts added that day.)

DOM note (observed 2026-07-29): the result list no longer contains `/jobs/view/` links. The job id lives in the `componentkey="job-card-component-ref-<id>"` attribute of each card — extract ids from there and pair them with the card's visible text. Scroll-based lazy-load, `sessionStorage` and `localStorage` accumulation across navigations all fail; paging with the `start` URL parameter is the only reliable mechanism.

**Stop paging at `start=200`.** Beyond that the feed degrades into developer roles and foreign-language ads (observed 2026-07-29: the 200–250 range yielded almost nothing relevant). The extra pages cost browser time without coverage.

**Getting a LinkedIn URL for an alert hit:** navigate to `https://www.linkedin.com/jobs/search-results/?keywords=<title>%20<company>&geoId=<your-region-id>`, read the id from the card's `componentkey` (or `(location.search.match(/currentJobId=(\d+)/)||['','none'])[1]` after opening it), and confirm via `document.title` that it is the right ad. If it cannot be confirmed, skip the row rather than storing a wrong link.

### 2. Liveness

```bash
cd /Users/you/Projects/jobs-dashboard
npm run liveness
```

**Under `scripts/refresh-run.sh` you do not run this step at all (revised 2026-08-22).** The script starts the sweep after `npm run fetch`, waits for it before invoking the merge, and runs the `--retry-unknown` pass itself — `.cache/dead-ids.json` is already on disk and current when you are called. Skip straight to applying it below. If the file is absent, that run's sweep failed: do no liveness handling and say so in `warnings`. The commands below are for standalone runs only.

Why the split: the sweep takes ~10 minutes, which outlives an agent's per-command shell timeout, so this section used to tell the merge agent to background it and poll. On 2026-08-22 19:00 the agent did exactly that and then returned exit 0 while the sweep was still running — nothing written, nothing published, and a closing note that it would "pick up automatically when the background watcher fires". There is no watcher. A shell has no per-command timeout, so the orchestrated path just waits for it. **In a standalone run**, where you do still start it in the background, do not return until you have polled `.cache/dead-ids.json` to completion — a backgrounded command you have not waited for is unfinished work, not delegated work.

Runs `scripts/check-liveness.mjs` (sessionless, ~10 min for ~790 rows since LinkedIn joined the sweep, because the probe paces itself to stay under the rate limiter). It probes every row seen in the last 20 days, one signature per source (revised 2026-08-11 — before that it covered only Profession and NFJ, and got NFJ wrong):

| Source | Live | Dead |
| --- | --- | --- |
| Profession | 200, no "lejárt" in the body | 301 to a category listing, or a "lejárt" body |
| NoFluff | `GET /api/posting/<slug>` → `PUBLISHED`/`ACTIVE` | that status is `EXPIRED`/`DISABLED`, or 404 |
| LinkedIn | `GET /jobs-guest/jobs/api/jobPosting/<id>` → 200 without a banner | 404, or "No longer accepting applications" |

NFJ needs the API because the HTML page answers 200 even for an expired ad — the old status-code check reported all 56 NFJ rows alive while 9 were gone. LinkedIn was long assumed to need a session; the *guest* fragment does not, which is what brought the ~500 li- rows into scope.

A throttle (LinkedIn answers 429/999 under load) or a network error is **not** proof of death — those rows land in `unknown` as `{id, why}` and are left alone, so `checked` is normally lower than the row count. Follow a sweep with

```bash
npm run liveness -- --retry-unknown
```

which re-probes only that set and merges into the existing dead list. Worth doing every run: the undecided rows are almost always LinkedIn `http-429`, and a second pass a minute later usually decides all of them. Rows in `dead` are ads that verifiably no longer exist:

- **Never bump `lastSeen` for a dead id** — not even if a saved list still contains it. `closed` is what archives the row; the frozen `lastSeen` is the backstop for any dead row that never gets the flag.
- **Delete dead `Értesítő` / `NFJ keresés` rows** and append their ids to `.cache/rejected-ids.json`. No curation is lost: they were feed echoes of ads that are gone. **Also list every id you delete in `last-run.json`'s `cleanedDeadIds`** (see step 6) — `.cache/` is git-ignored, so that array is the only way the Telegram notifier can tell your deliberate cleanup apart from a row going missing by accident.
- **Dead `Mentett` rows stay, but get `closed: <today>`** (only if not already set) — the UI moves them to the archive view immediately, saved or not. Unsaving them on the portal remains the user's call, not the task's.
- Mention the dead count in `summary` when it is notable; a liveness script failure goes to `warnings` and simply means no liveness handling this run. Under `refresh-run.sh` that failure reaches you as a **missing** `.cache/dead-ids.json` — the script deletes it rather than leaving a previous sweep's verdicts to be mistaken for this run's, so absent means "no liveness this run", never "nothing died".

### 3. Merge

- **Read the browser rows from `.cache/browser-filtered.json`, not `browser-latest.json` (revised 2026-08-12).** `scripts/filter-browser.mjs` now applies the rejected ledger *and* the deterministic vetoes to the alerts feed, the same `scripts/vetoes.mjs` rules the fetcher runs, and `refresh-run.sh` calls it right after the browse step. Its `linkedinAlerts` is the filtered array — merge that one. You no longer apply the ledger or the mechanical vetoes to these rows by hand; doing it from prose is what let the rules drift and left every LinkedIn drop untraceable. What it dropped and why is in that file's `droppedRows` (same shape as the fetcher's), and its counts are in `dropped`. Never fall back to `browser-latest.json`: merging unfiltered rows re-admits ledgered ads, bumps their `lastSeen` and stops them ever archiving. Under `refresh-run.sh` you cannot actually meet that temptation — a `filter-browser` failure kills the run at step 4c (exit `11`), before you are invoked — so if the filtered file is absent when you run, the browse step was **disabled** for this cycle, not broken. Merge the machine feeds alone and say so in `warnings`. (The script removes any stale filtered file on that path, so absent genuinely means absent.)
- Job already present: set `lastSeen` to today (unless its id is in `dead-ids.json` — see above, or in `.cache/rejected-ids.json` — a ledgered row must never be bumped; its frozen `lastSeen` is what ages it into the archive). Keep `firstSeen`. Never change a row's `status`: since the saved-jobs lists were retired (2026-08-07) nothing promotes a row to `Mentett` any more, and the legacy `Mentett` rows must keep the status they have.
- New job: append with `firstSeen` = `lastSeen` = today — **unless it is a cross-source duplicate (added 2026-08-07)**: when a live, non-archived row from a *different* source already carries the same role at the same company (compare case-insensitively, ignoring company suffixes like Kft./Zrt.), do not append a second row — ledger the new id instead and mention the skip in `summary` if notable. The 2026-08-07 cleanup (`scripts/dedupe-jobs.mjs`) removed 33 such pairs that had accumulated. Same-source same-title rows are NOT duplicates (an employer genuinely posts several identical openings) — append those normally. If the existing twin is archived, append normally too: a reappearance under a new id after the old ad died is a repost worth seeing.
- Job missing from today's sources but not proven dead: leave the row untouched. Do **not** delete it — the stale `lastSeen` makes the UI mark it archived after 14 days automatically.
- Otherwise never remove rows; the only further exception is an exact duplicate id, which is a bug worth reporting.

**Track how long a row has gone unseen, separately from whether a single run proves anything (added 2026-07-31).** A row missing from just this run is not a problem by itself — LinkedIn's snapshot genuinely varies run to run, and the run note already says so. But the same row missing from every run for days is a completely different signal, and before this existed the two looked identical in `warnings`. So:

- Maintain `.cache/unseen-streaks.json`: a flat JSON object of `{ "<id>": <consecutive-unseen-run count> }`. Create it if missing. Never delete or reset it wholesale — same rule as `.cache/rejected-ids.json`, only individual entries change.
- For every id seen in today's sources (machine feeds, and the browser sources when collected): if it has an entry here, remove it — the streak resets to zero by no longer being tracked.
- For every existing row that is missing from today's sources but not proven dead (the bullet above): increment its streak by 1 (create the entry at 1 if it has none yet) — **but only if you are confident its source was actually, successfully queried this run.** If a portal's check failed, was inconclusive, or was not attempted at all this cycle, its absence tells you nothing about the row; leave that row's streak exactly as it was rather than treating silence as evidence of anything. (The Phase 2b variant defines "confident" precisely — see that section.)
- When a row is deleted (a confirmed-dead `Értesítő`/`NFJ keresés` row) or newly gets `closed` (a confirmed-dead `Mentett` row), remove its streak entry too — it is now resolved, not silently ageing, and warning about it further would be noise. Prune any entry whose id no longer exists in `jobs.json` at all, for the same reason.
- **Legacy `Mentett` rows are never streak-tracked at all (added 2026-08-07).** Their portals are retired, so no run queries them and the "confident its source was queried" test above can never be satisfied — leave those rows out of `.cache/unseen-streaks.json` entirely rather than letting a streak climb forever on a source nobody is asking about any more. They are *expected* to go unseen and archive; that is the retirement working, not a fault to warn about. Prune any `Mentett` entry still left in the file from before the retirement.
- **LinkedIn `Értesítő` rows are not streak-tracked either (added later on 2026-08-07).** The alerts feed only shows the last 7 days (`f_TPR=r604800`), so for a LinkedIn row absence measures the row's *age*, not its ad's existence: at 4 runs/day every single row leaves the feed window around 28 runs and trips the 12-run threshold around day 10, staying tripped until the 14-day archive. There is no threshold that separates signal from noise here — anything below 56 runs fires for every row, anything above fires for none. On the day this was added, 138 rows (37% of all LinkedIn `Értesítő`) sat in the warning with nothing actionable about any of them. The failure the streak was actually standing guard for on this source — `start=` paging silently regressing so later pages stop arriving — is caught deterministically instead by `scripts/refresh-run.sh`'s collected-row-count check (`JOBS_REFRESH_BROWSE_MIN_ROWS`, default 60; see README's exit-code table), which fires on the *first* bad run rather than three days later. Prune any `li-` entry still left in `.cache/unseen-streaks.json`.
- **Ledgered rows are not streak-tracked either (added 2026-08-07).** A row whose id is in `.cache/rejected-ids.json` (typically via `scripts/tracker-to-rejected.mjs` — the user marked it `Nem érdekel`) is *deliberately* no longer refreshed: the fetcher withholds it from the sources, so its absence is the mechanism working, not a signal. Letting it climb to the 12-run threshold would put every user-rejected row into `warnings` three days after each tracker import. Leave these rows out of `.cache/unseen-streaks.json` entirely, and prune any entry whose id is in the ledger.
- Once an entry crosses a threshold, surface it in `warnings` — do not let it keep silently climbing unmentioned run after run. Threshold (4 runs/day, so 56 runs ≈ the 14-day archive window): **12 consecutive runs (~3 days)**, applying to the only rows still tracked — Profession `Értesítő` and `NFJ keresés`, the machine feeds. For those two, the fetcher returns the full current result set every run, so a persistent absence genuinely means the ad left the feed; that is what makes the streak informative there and meaningless for a time-windowed feed. ~9 days of margin remain before the row would actually archive. (A separate, earlier 6-run threshold used to apply to `Mentett` because a silently-ageing saved job was the worse outcome; with those lists retired and their rows deliberately ageing out, it no longer applies.)
- **Bound the warning — never enumerate.** A run can have 100+ rows unseen today without any of them being a real problem; do not let a real problem turn into 100+ lines either. State how many crossed the threshold, name only the two or three longest streaks (role + company + run count), and summarise the rest as "+N more". One or two `warnings` lines total, never one line per row.

### 4. Salary

No Fluff Jobs salaries arrive structured in the fetcher output: when `salaryVisible` is true, copy `salaryLo`/`salaryHi` verbatim, `salaryPosted: true`, `benchmark: "hirdetett sáv"`, and map `salaryType` `permanent` → `Employee`, `b2b` → `Contract`. When `salaryVisible` is false (Salary Match), estimate like any other source.

Everything else: estimate from the NFJ Fizetési Iránytű 2026 H1 bands in `/Users/you/Documents/profile-repo/research/market/salary-benchmarks.md`, then apply the employer adjustment — state/non-profit −20…−28%, small Hungarian company −8…−10%, Hungarian large corporate and banks = base band, foreign product or remote-first +15…+30%, German-language role +15%. Set `salaryPosted: false` and name the band in `benchmark`.

### 5. Fit filter

Read `/Users/you/Documents/profile-repo/profile/target-roles.md` before judging new ads. Skip pure keyword noise — and write every skipped candidate's id into `.cache/rejected-ids.json` so it never comes back. When a role is blocked by a known gap, say so in `description`: no certifications, no SAP, no Kubernetes, no people-management experience, no German. (English is governed by the calibrated rule below — it is not in this list on purpose.)

**Mechanical rejects (added 2026-08-07, mostly automated 2026-08-12).** The gendered-tag and junior/intern vetoes no longer need applying by hand to LinkedIn rows — `scripts/filter-browser.mjs` runs them before you see the file (see "3. Merge"). What is still yours, because it depends on a judgement no script can make: when your own step-4 salary estimate tops out under ~0.9M gross, reject — every such row on the 2026-08-07 export was hidden. Ledger it as `fit:salary-floor`.

**English is only a rejection reason at explicitly advanced levels (calibrated 2026-08-07).** Reject for English only when the ad itself demands C1/C2, "felsőfokú", "fluent", "native", "business fluent/tárgyalóképes" or equivalent. An ad that asks for B2/"középfokú", says just "English" with no level, or doesn't mention language at all is NOT rejectable on English grounds — when the level cannot be established from the ad, assume it is fine and judge the role on its merits. (Rationale: the level actually demanded is usually softer in practice than the JD template suggests, and the earlier stricter reading was discarding otherwise-fitting roles.) Mention English in `description` only when an explicit advanced demand is present.

### 6. Write the run note

**Write order matters: `last-run.json` must be on disk before you write the final `public/data/jobs.json`.** The launchd watcher triggers on `jobs.json`; if the note is written after it, the publish commit pairs the new data with the previous run's note — on 2026-07-29 Telegram shipped a stale summary and stale warnings exactly this way. Do the merge in memory, write the note first, save `jobs.json` last.

Write `public/data/last-run.json`, overwriting whatever is there:

```json
{
  "ranAt": "<ISO 8601 timestamp with offset>",
  "summary": "<plain Hungarian text, max ~1200 characters>",
  "warnings": ["<optional, one string per problem>"],
  "cleanedDeadIds": ["<every row id you deleted this run, or omit>"]
}
```

**`cleanedDeadIds` is how a deliberate deletion stops looking like data loss (added 2026-08-01).** List the id of every row you removed in step 2 — the confirmed-dead `Értesítő`/`NFJ keresés` rows — and nothing else. The notifier subtracts these from the rows that vanished between the two snapshots and reports them as routine cleanup; whatever is left over it reports loudly as unexpected, which is exactly what that warning is for. Omitting the field is safe but blunt: every deletion then fires the alarm (on 2026-08-01 a correct 35-row cleanup did precisely that). Never list an id you did not actually delete — that would mask a real loss.

This text is sent to Telegram verbatim, so:

- **Plain text only.** No HTML tags, no Markdown, no links — the notifier escapes HTML and tags would show literally. Validation rejects anything containing `<`.
- Keep it under 1500 characters or validation fails. Aim for 600–1200.
- Say what a person needs to know in ten seconds: how many new items and from where, which single new item is the best fit and *why* in one sentence, and what you deliberately skipped as noise.
- Do not repeat the raw counts — the notification already computes and shows those. Add the judgement the numbers cannot carry.
- Put anything that went wrong in `warnings`, not in `summary`: an unmounted folder, an expired portal session, a skipped LinkedIn URL that could not be confirmed, a fetch-sources feed error, a category that returned nothing when it usually returns something.
- If nothing changed, still write the file with a one-line summary saying so.

### 7. Validate, then stop

```bash
cd /Users/you/Projects/jobs-dashboard
npm run check
```

`npm run check` must pass before you consider the run finished. It validates both files: invalid JSON, missing fields, duplicate or malformed ids (`li-\d+ | pr-\d+ | nfj-<lowercase slug>`), duplicate URLs, non-https URLs, inverted or absurd salary ranges, malformed dates, and in the run note a missing `ranAt`, an over-long summary, HTML in the summary, or a non-array `warnings`. If it fails, fix the data and re-run it. If you cannot fix it, restore the previous content and report — a broken file would otherwise be committed and deployed. (Under `scripts/refresh-run.sh` there is a backstop: step 6 re-runs this check and restores both files from git if it fails. Do not rely on it — it aborts the run, so a file you could have fixed costs the whole cycle.)

Once it passes, you are done. Do not run git. Do not run `scripts/publish.sh`. Under `scripts/refresh-run.sh` that script publishes and sends the Telegram digest itself once you return, both behind their own env gates. (Before 2026-07-30 this was a launchd agent plus a GitHub Actions workflow; the workflow is manual-dispatch only since 2026-08-21.)

### Report

In Hungarian, short. State: total job count, how many new / updated / newly archived, whether `npm run check` passed, and the single most interesting new item with its salary and why. If nothing changed, say it in one sentence. If a source was unavailable, the LinkedIn session had expired or could not be confirmed, the liveness sweep failed, or the browser half did not run this cycle, say that explicitly rather than reporting a silent no-op.

---

## Phase 1 — Linux VM variant

The prompt above is the canonical, full-featured task and is left untouched. This section describes how the task actually runs today, on the Linux VM (Proxmox guest `01-apps-vm`), inside a container — it supersedes the parts of the prompt above that were written for the macOS Cowork sandbox.

**"Phase 1" is now a section name, not a description of scope.** The name is kept because `scripts/refresh-run.sh`'s merge prompt points at this heading by name. The migration it referred to is finished: the VM took over the machine feeds on 2026-07-30, and "Browser collection (Phase 2b)" below brought the LinkedIn alerts feed over the same day. Nothing runs on the MacBook any more. What remains genuinely Phase-1-shaped is only the path mapping in the next table and the git/publish change below it.

**Path mapping — supersedes every absolute path in the prompt above.** The canonical prompt hard-codes macOS paths. Read every absolute path in it through this table when running on the VM:

| Canonical prompt (macOS) | Container (Phase 1) |
| --- | --- |
| `/Users/you/Projects/jobs-dashboard` | `/data/jobs-dashboard` |
| `/Users/you/Documents/profile-repo` | `/data/profile-repo` (sparse checkout: only `profile/target-roles.md` and `research/market/salary-benchmarks.md` are present) |

So every `cd /Users/you/Projects/jobs-dashboard` above means `cd /data/jobs-dashboard`, and every path under `/Users/you/Documents/profile-repo/...` means the same path under `/data/profile-repo/...`. This is the one place path handling is defined for the VM — nowhere else should override it.

**Unchanged: machine feeds.** `npm run fetch` (Profession HTML listing pages + NFJ SSR, both sessionless HTTP) works exactly as documented in "1. Collect" above. Nothing about this feed depends on the Mac or the browser, so it runs as-is in the container.

**Live: the browser-bound source.** The LinkedIn alerts feed requires a session-bound browser the Linux container does not have on its own. "Browser collection (Phase 2b)" below supplies one via a Playwright MCP server attached to a logged-in Chromium, and **it is enabled on the VM** — `JOBS_REFRESH_BROWSER_ENABLED=true` in the container environment, since 2026-07-30. Assume the filtered browser rows are present unless this run tells you otherwise.

The step is still *gated*, so both paths must stay coherent: when the flag is not exactly `true`, steps 4–4c are skipped and only `npm run fetch` feeds the merge. On that path `refresh-run.sh` deletes `.cache/browser-filtered.json` rather than assuming it is absent — `.cache` persists across runs, so one left behind from a cycle when the gate was on would otherwise be merged as if it were current. `scripts/refresh-run.sh`'s prompt tells you which case you are in — if the filtered file is absent, merge the machine feeds alone and say so in `warnings`. (The three saved-jobs lists that used to sit here too were retired 2026-08-07 — see "1. Collect".)

**Changed: the agent may run git and `scripts/publish.sh` directly.** The "do not run git" rule in the Scope section above was a macOS Cowork-sandbox artefact: connected folders were mounted there with unlink denied, so a commit under that mount half-succeeded and stranded lock files. That constraint does not exist in the Linux container — there is no sandbox unlink guard — so in this variant the agent runs `npm run check` and then `scripts/publish.sh` itself (validate → commit → push) after writing the data files, instead of stopping and waiting for a separate host-side publisher.

**Still applies and still matters: write order.** `public/data/last-run.json` must still be written to disk *before* `public/data/jobs.json`. This rule has nothing to do with the sandbox — it exists so the Telegram notification pairs the right narrative with the right diff (see the 2026-07-29 write-order note in the table above). Writing them in the wrong order produces a stale summary against fresh data on Linux exactly as it did on the Mac.

---

## Browser collection (Phase 2b)

Phase 2b adds the browser-bound half of the refresh to the VM. A Playwright MCP server attached to a logged-in Chromium (built and operated in a separate repo, against the contract this section assumes is met) gives `scripts/refresh-run.sh` a second, narrower Claude invocation that can reach the one session-bound source documented in "1. Collect" above: the LinkedIn alerts feed.

**Scope shrank to one source on 2026-08-07** — see "1. Collect" → "Saved-jobs lists → retired" for the measurements behind that. What matters here: this step now visits one portal, not three, so the fixed cost of the browse step (the separate repo, the MCP server, the logged-in Chromium, the re-auth flow) is entirely carried by the LinkedIn alerts feed. That feed supplies 488 of 768 rows (64% of the corpus, measured 2026-08-24; it was 361 of 750 when the saved-jobs lists were retired) and is by a wide margin the biggest discovery channel in the pipeline, so it comfortably justifies the whole apparatus on its own — but it also means there is no longer any partial-success case here. Either the LinkedIn session works and the browser half arrives, or it doesn't and the run proceeds on the machine feeds alone.

This section defines the browse step's job and its output file only. It does not restate the URL, selectors, or DOM notes — read "1. Collect" → "LinkedIn alerts → status `Értesítő` (browser)" above for those, including the 2026-07-29 LinkedIn DOM change (ids come from the `componentkey="job-card-component-ref-<id>"` attribute, not `/jobs/view/` links, and only `start=` paging works) and the `start=200` paging cutoff.

**Gating.** Controlled by `JOBS_REFRESH_BROWSER_ENABLED` in the container environment. Anything other than exactly `true` (including unset) skips this step entirely; the run behaves exactly as the "Phase 1 — Linux VM variant" section above describes.

**Scope — collection only.** This Claude invocation collects and writes `.cache/browser-latest.json`. It must not merge into `public/data/jobs.json`, must not write `public/data/last-run.json`, must not run `npm run check`, and must not run git or `scripts/publish.sh` — the existing merge step (a separate Claude invocation) owns all of that, the same split `npm run fetch` already has today.

**Login-state assertion — read this before anything else.** A LinkedIn session that has expired does not error when scraped — it returns an empty result list, indistinguishable from "the alert feed is quiet today." Left unchecked, a whole cycle's worth of discovery silently reports as zero new jobs, and nothing in `warnings` says why. So before scraping, confirm the page you land on is the authenticated view, not a login/sign-in redirect or prompt.

(The original reason for this check was worse: a stale saved-jobs session would let already-curated `Mentett` rows go unbumped until the dashboard archived them 14 days later. Those lists are retired now, so the stakes here are a missed discovery cycle rather than silent data loss — but the check is just as necessary, because the failure is just as invisible.)

**`"logged_out"` requires positive evidence, not just an absence of proof.** A first live run reported No Fluff Jobs as `logged_out` when the account was genuinely signed in — the SPA had simply failed to render in a small viewport (empty body text, a near-empty accessibility snapshot, a burst of console errors), leaving nothing that looked like a logged-in page. That got treated as a bad session, which discarded a good run and sent a human to re-authenticate a session that was fine. So:

- Record `"logged_out"` only when you see *positive* evidence of being signed out: a redirect to a login/sign-in URL, or a visible sign-in prompt on a page that otherwise rendered normally.
- Record `"undetermined"` when the check was inconclusive because the page itself didn't render meaningfully — empty or near-empty body text, a near-empty accessibility tree, a burst of console errors. A broken render is not evidence of a bad session; it is evidence the check couldn't complete. Do not guess "logged_out" from silence.
- A zero-result authenticated page (genuinely logged in, genuinely nothing saved) is `"ok"` — it must never be confused with either failure state.

**These three are not treated the same, and the difference matters more than which fix applies (revised 2026-07-31).** `"logged_out"` blocks the whole run outright, immediately, before the merge ever runs — there is a human action (sign back in) and nothing useful comes from that portal until they take it. `"undetermined"` does **not** block: there is no user action to take, and discarding an otherwise-good run over an inconclusive check helps nobody — a real run once threw away 387 good rows this way — so the run continues through merge, `npm run check`, and the gated publish exactly as normal, and only raises an alert *after* publish, via a distinct non-zero exit (see README.md's exit-code table). A portal missing from `auth` entirely, or carrying a value that is neither of the two above, is a third state, `"unreported"` — it means the browse step itself has a bug, not that the portal is flaky, and is handled the same as `"undetermined"` (no block, alert after publish) but reported with that distinction. Never collapse any of the three into another.

**If LinkedIn ever stops rendering, go to the network layer rather than fighting the DOM (generalised 2026-08-07).** The retired No Fluff Jobs source taught this the expensive way: its favourites page rendered an ~89-character empty shell across three runs because third-party tracker blocking (AdGuard, including the Usercentrics consent manager) stopped the SPA hydrating, while an authenticated API call answered correctly every time. LinkedIn has rendered reliably here so far, so do **not** pre-emptively change it. But if it starts coming back empty, inspect what the page actually requests over the network, try the authenticated API call behind it, and read the data out of whatever JSON it returns — do not assume a fixed response shape.

That fallback does not change the tri-state contract above: an API call answering 401/403 is exactly as positive evidence of `"logged_out"` as a login redirect on the page; an API call failing for any other reason (network error, 5xx, timeout, an unrecognisable response) is `"undetermined"`, exactly like an unrendered page — inconclusive, not evidence of a bad session.

Record the outcome in `.cache/browser-latest.json`'s `auth` object as an object with `"state"` (`"ok"` | `"logged_out"` | `"undetermined"`) and a short, human-readable `"reason"` describing what you saw — required whenever `state` isn't `"ok"`, since that reason is what tells a human on a phone which fix to reach for. Write the file regardless of outcome, with whatever you managed to collect. `scripts/refresh-run.sh` reads it after you finish and decides whether the run continues; treat anything you don't explicitly confirm `"ok"` as unconfirmed.

**Output — `.cache/browser-latest.json`:**

```jsonc
{
  "collectedAt": "2026-08-07T18:00:00.000Z",  // ISO 8601, when this run finished
  "auth": {
    "linkedin": { "state": "ok" }
    // "state" is "ok" | "logged_out" | "undetermined"; "reason" is required
    // whenever state isn't "ok" — e.g. { "state": "logged_out", "reason":
    // "redirected to https://www.linkedin.com/login" }
  },
  "linkedinAlerts": [
    {
      "id": "li-4298...",                    // required
      "url": "https://www.linkedin.com/...", // required
      "title": "Senior Cloud Engineer",      // required — the role line ONLY
      "text": "Senior Cloud Engineer Acme Budapest, Hungary (On-site) ..."
    }
  ]
}
```

`linkedin` is the only key `refresh-run.sh` looks for in `auth`, and `linkedinAlerts` the only array that matters downstream — though since 2026-08-12 the merge reads it from `.cache/browser-filtered.json` rather than here, after `scripts/filter-browser.mjs` has applied the ledger and the deterministic vetoes. This step still writes the raw file and still does not filter. The retired keys (`linkedinSaved`, `professionSaved`, `nofluffFavourites`, and their `auth` entries) must not be written — the merge would have no status to give their rows.

**Every row needs `id` (`li-<id>`), `url` and `title` — all three, `title` included (tightened 2026-08-21).** `title` must be the role line on its own, not the whole card: no company, no location, no "Promoted"/"Posted 4 days ago" boilerplate. Carry the full card text as `text` as well if you have it, but `text` is not a substitute.

This is not cosmetic. `scripts/filter-browser.mjs` runs the deterministic vetoes against `title`, and `judgeLinkedIn("")` returns `keep` — so a row with no `title` silently bypasses both the gendered-tag/German rule and the title vetoes while the ledger keeps working, which looks exactly like a feed with nothing to drop. That is what happened between 2026-08-12 and 2026-08-21: rows arrived carrying only `id`, `url` and `text`, and 21 of 41 rows that the regexes should have dropped reached the merge agent instead. The vetoes are calibrated on 764 hand-judged *titles*; handing them a whole card would make `CORE_ANCHOR` rescue rows on an incidental match in a company name, so the fix is a real title here, not a looser matcher there. `refresh-run.sh` now raises the browser-degradation alert (exit 8, after publish) when rows arrive and none are titled.

Do not judge, filter, or estimate anything here — the merge step still applies the fit filter and salary work; this step only collects. If the state is not `"ok"`, the array may be empty or partial — collect what the check allows before giving up, but never invent or carry over stale rows to make the file look complete.

See README.md's exit-code table for exactly what `scripts/refresh-run.sh` does with this file: a `"logged_out"` portal aborts the whole run immediately (exit `7`); an `"undetermined"` or `"unreported"` portal does not block, but the run still exits non-zero (exit `8`) once publish has completed, purely to raise an alert. Either way, the message names the portal, its state, and its reason, so the fix (re-authenticate vs. investigate rendering vs. investigate the browse step itself) is unambiguous.

**No longer feeds "3. Merge"'s unseen-streak tracking (revised 2026-08-07).** No browser-collected row is streak-tracked any more: `Mentett` rows are retired, and LinkedIn `Értesítő` rows are exempt because the 7-day feed window makes absence a measure of age, not of the ad's existence — see "3. Merge" for both rules. The `auth` object's job is now solely to gate the run (`logged_out` blocks, the rest alert), and the row-count guard for this file lives in `scripts/refresh-run.sh`, not in the merge: after a confirmed-`ok` session, it warns when `linkedinAlerts` carries fewer than `JOBS_REFRESH_BROWSE_MIN_ROWS` rows (default 60 — derived from six observed daily sweeps contributing 112–159 accepted rows, against ~10–25 for a page-1-only paging regression). The merge itself applies no minimum; it merges whatever was genuinely collected.

## Where the schedule actually lives

There is no Cowork scheduled task any more, and nothing to recreate in a chat. Since 2026-07-30 the schedule is a **systemd timer** on `01-apps-vm` (`*-*-* 1/6:00:00` with up to 600s jitter, so 01/07/13/19 UTC), versioned in the homelab Ansible repo, not here — the same `jobs-refresh` unit family as `/opt/<stack>/jobs-refresh.env`. It execs `scripts/refresh-run.sh` inside the refresh container; that script owns the run order, the gating and the exit codes.

Changing the cadence, the environment gating (`JOBS_REFRESH_*`), or the container's mounts is a homelab-repo change. Changing what the agent *does* with the data is a change to this file.

## Keeping this file in sync

This file is read live by the merge agent on every run (see the note at the top), so it cannot drift quietly — a wrong statement here becomes wrong agent behaviour within six hours. Two rules:

- **Change the rules and the code in the same commit.** Anything this file asserts about `scripts/refresh-run.sh` — step order, gating, exit codes, which cache file to read — has a counterpart in that script. The example to remember is the one this file carried from 2026-07-30 to 2026-08-25: "Not available in Phase 1 by default: the browser-bound source", asserted for four weeks while the browse step was live and supplying the majority of the corpus. The merge agent read that sentence every six hours; only `refresh-run.sh`'s inline prompt, which is more specific, kept it from acting on it.
- **Do not rename the headings the prompt points at.** `refresh-run.sh` references "Phase 1 — Linux VM variant", "Browser collection (Phase 2b)", "1. Collect", "2. Liveness", "3. Merge" and the browse step's "Output" block by name.
