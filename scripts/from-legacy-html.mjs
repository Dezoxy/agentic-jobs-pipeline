#!/usr/bin/env node
// One-off migration: profile-repo/saved-jobs-overview.html  ->  public/data/jobs.json
// After this runs once, jobs.json is the source of truth and this script is no longer needed.
import fs from "node:fs";
import path from "node:path";

const SRC = process.argv[2] ?? "/Users/you/Documents/profile-repo/saved-jobs-overview.html";
const OUT = path.join(process.cwd(), "public/data/jobs.json");
const TODAY = new Date().toISOString().slice(0, 10);

const html = fs.readFileSync(SRC, "utf8");
const m = html.match(/const D = \[([\s\S]*?)\n\];/);
if (!m) {
  console.error("Could not find the D array in", SRC);
  process.exit(1);
}
const rows = eval("[" + m[1] + "]");

const slug = (s) =>
  s.toLowerCase()
    .normalize("NFD").replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60);

const SRC_KEY = { LinkedIn: "li", Profession: "pr", NoFluff: "nfj" };

const jobs = rows.map((r) => {
  const [role, company, source, category, type, description,
         salaryLo, salaryHi, posted, benchmark, url, status] = r;
  // stable id from the portal's own identifier where possible
  let ident = null;
  const li = url.match(/\/jobs\/view\/(\d+)/);
  const pr = url.match(/-(\d{6,})(?:\/|$)/);
  const nfj = url.match(/\/hu\/job\/([^/?#]+)/);
  if (li) ident = li[1];
  else if (pr) ident = pr[1];
  else if (nfj) ident = slug(nfj[1]);
  else ident = slug(role + "-" + company);

  return {
    id: `${SRC_KEY[source]}-${ident}`,
    role, company, source, category, type,
    description,
    salaryLo, salaryHi,
    salaryPosted: posted === 1,
    benchmark,
    url,
    status,
    firstSeen: TODAY,
    lastSeen: TODAY,
  };
});

// id collisions would silently drop rows later — fail loudly instead
const seen = new Map();
for (const j of jobs) {
  if (seen.has(j.id)) {
    console.error("Duplicate id:", j.id, "\n  ", seen.get(j.id).role, "@", seen.get(j.id).company,
                  "\n  ", j.role, "@", j.company);
    process.exit(1);
  }
  seen.set(j.id, j);
}

const doc = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  source: "profile-repo/saved-jobs-overview.html (legacy migration)",
  jobs,
};

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(doc, null, 2) + "\n");

const by = (k) => jobs.reduce((a, j) => ((a[j[k]] = (a[j[k]] || 0) + 1), a), {});
console.log("wrote", OUT);
console.log("jobs:", jobs.length);
console.log("status:", by("status"));
console.log("source:", by("source"));
console.log("posted salary:", jobs.filter((j) => j.salaryPosted).length);
