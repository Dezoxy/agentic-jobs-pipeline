#!/usr/bin/env node
// Cross-source dedupe for public/data/jobs.json.
//
//   node scripts/dedupe-jobs.mjs [--dry-run] [tracker-export.json]
//
// The same ad routinely arrives through two portals (LinkedIn + Profession,
// LinkedIn + NFJ, ...) under two ids, and the merge step keys rows by id, so
// both copies live on as separate rows. Measured 2026-08-07: 33 such pairs.
//
// Scope — cross-source groups ONLY. Two same-source rows with an identical
// title+company (e.g. DT posting "DevOps Engineer" for several teams, or a
// repost under a fresh LinkedIn id) may genuinely be different openings; this
// script never touches those. The dedupe key is the normalized (role,
// company) pair, the same normalization the 2026-08-07 analysis used.
//
// Which copy survives — additive score, highest wins:
//   +1000 tracker status saved/applied/interview/offer (user is holding it)
//   +500  status "Mentett" (git-permanent curation marker)
//   +250  tracker status ignored/rejected (keeps the user's verdict attached
//         to a row that exists — the negative marker hides it anyway)
//   +50   salaryPosted (real band beats an estimate)
//   +25   probeable id (pr-/nfj- — check-liveness.mjs cannot probe li- rows)
//   tiebreak: earlier firstSeen, then id (determinism)
// The keeper absorbs the group's history: firstSeen = min, lastSeen = max.
//
// A "Mentett" row may only be deleted when the keeper is also "Mentett" —
// otherwise the group is skipped and reported for manual review, because
// docs/refresh-task.md's standing rule is that Mentett rows never get
// deleted and this script does not get to override the curation it protects.
//
// Deleted ids go into .cache/rejected-ids.json so the feeds cannot re-add
// them. Deletions WILL fire notify-diff.mjs's "Eltűnt a fájlból — ez nem
// várt" warning on the next published diff — that alarm exists precisely to
// make silent row loss impossible, so run this deliberately, not routinely,
// and expect that message once.
import fs from "node:fs";
import path from "node:path";
import { mergeLedger, previewLedger } from "./ledger.mjs";

const argv = process.argv.slice(2);
const DRY = argv.includes("--dry-run");
const TRACKER_PATH = argv.find((a) => !a.startsWith("--"));

const ROOT = path.join(path.dirname(new URL(import.meta.url).pathname), "..");
const JOBS = path.join(ROOT, "public", "data", "jobs.json");
const LEDGER = path.join(ROOT, ".cache", "rejected-ids.json");

const readJson = (p, fb) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return fb; } };

const doc = readJson(JOBS, null);
if (!doc?.jobs) { console.error("cannot read " + JOBS); process.exit(2); }
const tracker = TRACKER_PATH ? readJson(TRACKER_PATH, {}) : {};

const POSITIVE = new Set(["saved", "applied", "interview", "offer"]);
const NEGATIVE = new Set(["ignored", "rejected"]);

// Same normalization as the 2026-08-07 duplicate analysis.
const norm = (s) => (s || "").toLowerCase().normalize("NFD")
  .replace(/[̀-ͯ]/g, "")
  .replace(/\b(kft|zrt|nyrt|bt|ltd|hungary|magyarorszag|group|hungaria|kkt|inc|gmbh|services?|technologies)\b/g, "")
  .replace(/[^a-z0-9]+/g, "");

const score = (j) => {
  const st = tracker[j.id]?.st;
  return (POSITIVE.has(st) ? 1000 : 0) +
         (j.status === "Mentett" ? 500 : 0) +
         (NEGATIVE.has(st) ? 250 : 0) +
         (j.salaryPosted ? 50 : 0) +
         (/^(pr|nfj)-/.test(j.id) ? 25 : 0);
};

const groups = new Map();
for (const j of doc.jobs) {
  const k = norm(j.role) + "|" + norm(j.company);
  if (!groups.has(k)) groups.set(k, []);
  groups.get(k).push(j);
}

const removeIds = new Set();
const keeperOf = new Map(); // loser id -> the id it was merged into, for the ledger reason
const skipped = [];
let mergedGroups = 0;

for (const list of groups.values()) {
  if (list.length < 2) continue;
  if (new Set(list.map((j) => j.source)).size < 2) continue; // same-source: never touch
  const ranked = [...list].sort((a, b) =>
    score(b) - score(a) ||
    (a.firstSeen || "").localeCompare(b.firstSeen || "") ||
    a.id.localeCompare(b.id));
  const keeper = ranked[0];
  const losers = ranked.slice(1);
  if (losers.some((j) => j.status === "Mentett") && keeper.status !== "Mentett") {
    skipped.push(list);
    continue;
  }
  keeper.firstSeen = list.map((j) => j.firstSeen).sort()[0];
  keeper.lastSeen = list.map((j) => j.lastSeen).sort().at(-1);
  losers.forEach((j) => { removeIds.add(j.id); keeperOf.set(j.id, keeper.id); });
  mergedGroups++;
  console.log(`merge: keep ${keeper.id} (${keeper.status}${tracker[keeper.id] ? "," + tracker[keeper.id].st : ""})` +
    ` drop ${losers.map((j) => j.id).join(", ")} :: ${keeper.role} @ ${keeper.company}`);
}

for (const list of skipped) {
  console.log(`SKIP (Mentett would be deleted — review by hand): ` +
    list.map((j) => `${j.id}(${j.status})`).join(" + ") + ` :: ${list[0].role}`);
}

if (removeIds.size === 0) {
  console.log("\nNo cross-source duplicates to merge.");
  process.exit(0);
}

doc.jobs = doc.jobs.filter((j) => !removeIds.has(j.id));

// Reason carries the survivor's id: "why is this gone?" answers itself with
// where to look instead. See scripts/ledger.mjs for the ledger format.
const additions = Object.fromEntries([...removeIds].map((id) => [id, `dedupe:${keeperOf.get(id) ?? "?"}`]));
const counts = DRY ? previewLedger(LEDGER, additions) : mergeLedger(LEDGER, additions);

if (!DRY) fs.writeFileSync(JOBS, JSON.stringify(doc, null, 2) + "\n");

console.log(`\nmerged ${mergedGroups} group(s): removed ${removeIds.size} row(s), ` +
  `jobs ${doc.jobs.length + removeIds.size} -> ${doc.jobs.length}`);
console.log(`ledger: ${counts.before} -> ${counts.after} (+${counts.added} new)`);
if (skipped.length) console.log(`skipped ${skipped.length} group(s) for manual review (see SKIP lines)`);
console.log(DRY
  ? "--dry-run: nothing written."
  : "Run `npm run check`, then expect a one-time \"Eltűnt a fájlból\" warning in the next Telegram diff — deliberate, this is it.");
