#!/usr/bin/env node
// One-off migration: the legacy `Mentett` rows in public/data/jobs.json
// -> a jobs:tracker export you import from the dashboard footer.
//
// OPTIONAL — you almost certainly do not need this.
//
// The three portal saved-jobs lists (LinkedIn saved, Profession.hu saved,
// No Fluff Jobs favourites) were retired 2026-08-07. Nothing refreshes those
// rows any more, so their lastSeen freezes and the UI archives them 14 days
// later. Their curation is NOT at risk: `status: "Mentett"` stays in
// jobs.json, which is in git and permanent, and survivesArchiveHide() in
// public/app.js keeps those rows visible on the strength of that status
// alone. Importing this export changes nothing about what you can see.
//
// The one thing it does change: the "Saját státusz" dropdown will read
// "Elmentve" for these rows instead of "—", so they participate in tracker
// workflows the same way jobs you bookmark from now on will. That is a
// cosmetic/uniformity preference, not a preservation measure — and it comes
// at the cost of duplicating a git-backed fact into localStorage, which
// Safari's ITP clears after 7 days of non-use.
//
// This script only reads. It writes one file outside public/data/ and never
// touches jobs.json.
//
//   node scripts/mentett-to-tracker.mjs [--include-closed] [-o <path>]
import fs from "node:fs";
import path from "node:path";

const SRC = path.join(process.cwd(), "public/data/jobs.json");
const argv = process.argv.slice(2);
const INCLUDE_CLOSED = argv.includes("--include-closed");
const oi = argv.indexOf("-o");
const OUT = oi !== -1 && argv[oi + 1]
  ? path.resolve(argv[oi + 1])
  : path.join(process.cwd(), `jobs-tracker-mentett-${new Date().toISOString().slice(0, 10)}.json`);

// Must match TRACKER_STATUSES in public/app.js — an unknown status is
// silently dropped by the importer's sanitizeTrackerImport(), so a typo here
// produces an empty import rather than an error.
const STATUS = "saved";

const doc = JSON.parse(fs.readFileSync(SRC, "utf8"));
const rows = Array.isArray(doc) ? doc : (doc.jobs ?? Object.values(doc).find(Array.isArray));
if (!Array.isArray(rows)) {
  console.error("Could not find the job array in", SRC);
  process.exit(1);
}

const mentett = rows.filter((j) => j.status === "Mentett");
const closed = mentett.filter((j) => j.closed);
const kept = INCLUDE_CLOSED ? mentett : mentett.filter((j) => !j.closed);

const out = {};
for (const j of kept) {
  // `at` is "when you set this status", which was never recorded — firstSeen
  // is the closest honest proxy and preserves the relative ordering. It reads
  // slightly early for rows saved a while after they first appeared.
  out[j.id] = { st: STATUS, at: j.firstSeen };
}

fs.writeFileSync(OUT, JSON.stringify(out, null, 2) + "\n");

const bySource = {};
for (const j of kept) bySource[j.id.split("-")[0]] = (bySource[j.id.split("-")[0]] ?? 0) + 1;

console.log(`Mentett rows in jobs.json: ${mentett.length}`);
console.log(`  already closed (dead ad): ${closed.length}${INCLUDE_CLOSED ? " — included" : " — skipped, pass --include-closed to keep them"}`);
console.log(`  exported as "${STATUS}":   ${kept.length}`, bySource);
console.log(`\nWrote ${OUT}`);
console.log("Import it from the dashboard footer. The importer merges (imported wins on conflict), so re-importing is safe.");
