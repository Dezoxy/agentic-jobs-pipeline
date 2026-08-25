#!/usr/bin/env node
// Applies .cache/dead-ids.json to public/data/jobs.json.
//
// Marking a row `closed` archives it immediately in the UI (see app.js:93) —
// saved or not, tracked or not — which is what drops it out of the
// "Feldolgozandó" triage list. Per docs/refresh-task.md the flag is written
// once and never cleared, so this script never overwrites an existing value.
//
// Usage: node scripts/apply-dead.mjs [--dry-run]

import fs from "node:fs";
import path from "node:path";

const ROOT = path.join(path.dirname(new URL(import.meta.url).pathname), "..");
const DRY = process.argv.includes("--dry-run");
const JOBS = path.join(ROOT, "public/data/jobs.json");

const doc = JSON.parse(fs.readFileSync(JOBS, "utf8"));
const { dead, checkedAt } = JSON.parse(fs.readFileSync(path.join(ROOT, ".cache/dead-ids.json"), "utf8"));
const deadSet = new Set(dead);
const today = checkedAt.slice(0, 10);

// ---------------------------------------------------------------------------
// TODO (yours): decide which confirmed-dead rows actually get the flag.
//
// Return true to mark `j` closed, false to leave it alone. Every row passed in
// is already PROVEN dead by the probe — this is a policy call, not a detection
// one. Things worth weighing:
//
//   * j.status === "Mentett" are ads you saved by hand. docs/refresh-task.md
//     says a dead saved row should stay frozen and age out over 14 days
//     ("unsaving is the user's call"), but `closed` removes it from triage now.
//     37 of the 62 dead Profession rows are Mentett.
//   * "Értesítő" / "NFJ keresés" rows carry no curation — they are feed echoes.
//   * A LinkedIn ad can be re-opened or re-posted; `closed` is permanent, and a
//     re-posted ad comes back under a NEW id anyway, so a wrong call here costs
//     you one row, not the feed.
//   * Returning true for everything is a perfectly defensible default — it just
//     means you lose the chance to look at a dead saved ad one last time.
// ---------------------------------------------------------------------------
function shouldClose(j) {
  return true; // <- replace with your policy
}

let marked = 0, already = 0, skippedByPolicy = 0;
for (const j of doc.jobs) {
  if (!deadSet.has(j.id)) continue;
  if (j.closed) { already++; continue; }
  if (!shouldClose(j)) { skippedByPolicy++; continue; }
  j.closed = today;
  marked++;
}

if (!DRY) fs.writeFileSync(JOBS, JSON.stringify(doc, null, 2) + "\n");
console.log(
  `apply-dead${DRY ? " (dry run)" : ""}: marked=${marked} already-closed=${already} ` +
  `skipped-by-policy=${skippedByPolicy} dead-in-list=${dead.length}`);
