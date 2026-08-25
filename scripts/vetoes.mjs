// The deterministic candidate vetoes, shared by every collection path.
//
// Extracted from fetch-sources.mjs on 2026-08-12 so the browser-collected
// LinkedIn rows can run the same rules instead of an agent re-applying them
// from prose — docs/refresh-task.md used to instruct exactly that, by hand.
// Two copies of a regex calibrated against 764 hand-judged rows would drift
// on the first edit, and silently: nothing compares them.
//
// judge*() returns "keep" | "keep-flag" | "<reason>", where a reason reads
// "<counter>:<detail>" and <counter> is one of location/language/title. The
// callers bucket their counters by the prefix and keep the whole string as
// the audit trail in droppedRows.

// Deterministic pre-filters (added 2026-07-29). Policy source:
// profile-repo/profile/preferences.md — Budapest metro only, German-language
// roles explicitly excluded. These rows were being re-dropped by the LLM
// fit filter on every run; dropping them here costs nothing and cannot
// misjudge, because the rule is mechanical.
//
// Location: the listing's data-category6 is "<megye>, <város>" but the
// megye segment is unreliable (observed "Pest megye, Debrecen"), so only
// the city segment is trusted. No city segment ("Pest megye", "Országos",
// empty) → keep, the ad may be countrywide or remote-capable.
// Trade-off, accepted: a provincial ad that would allow remote work is
// dropped too — the browser-era fit filter applied the same rule.
export const METRO_CITIES = new Set([
  "budapest", "budaörs", "érd", "vecsés", "dunaharaszti", "biatorbágy",
  "törökbálint", "dunakeszi", "szentendre", "gödöllő", "vác",
  "szigetszentmiklós", "gyál", "fót", "monor",
]);
export const FOREIGN_LOC = /németország|ausztria|svájc|szlovákia|románia|deutschland/i;
// Gendered recruitment tags — (m/w/d), (m/f/d), (gn), (m/w/x) and friends —
// are German-market ads whatever language the title is in. The original two
// hard-coded variants missed (m/f/d) and (gn): 15 such rows reached the list
// and the user hid all 15 (tracker export, 2026-08-07). Any 2-3 letter
// combination of m/w/f/d/x/gn in parens counts, plus bare (gn).
export const GERMAN_ROLE = /german|német nyelv|\((?:m|w|f|d|x|gn)\s*[/|]\s*(?:m|w|f|d|x|gn)(?:\s*[/|]\s*(?:m|w|f|d|x|gn))?\)|\(gn\)/i;

// Gem gate (added 2026-07-29, "bővítsd hátha"): a provincial city normally
// means drop, but a title in the priority families (target-roles.md:
// architect, devops/cloud, security/IAM, AI, SRE/platform) is kept and
// flagged "vidéki" instead — these are the ads where remote/hybrid or a
// relocation-worthy offer is plausible (probe: DT Debrecen Cloud/Security
// Engineer, Szeged SOC engineer pass; generic provincial sysadmins don't).
// Deliberately NOT solved by widening the city allowlist: adding e.g.
// Székesfehérvár wholesale would re-admit its generic sysadmin noise while
// the gate already keeps its architect/AI roles.
export const PRIORITY_ROLE = /architect|architekt|devops|cloud|security|iam|site reliability|\bsre\b|\bai\b|\bml\b|mlops|platform engineer/i;

// Title vetoes (added 2026-08-07). Calibrated against the 764 rows the user
// had judged on the dashboard by then: this exact ruleset mechanically drops
// 109 of them, 107 correctly hidden, 2 borderline false drops (98%). Two
// tiers, because "consultant" is 89% noise yet "IAM Consultant" was kept:
//   - HARD fires regardless of anything else (junior; gender tags are
//     handled by GERMAN_ROLE above): 100% hide rate, no rescue needed.
//   - SOFT fires only when the title carries no core-domain anchor — the
//     anchor doesn't accept the ad, it only forwards it to the LLM fit
//     filter instead of killing it here. SAP is soft too: "Platform
//     Engineer (SAP BTP)" and "Rendszermérnök (SAP bázis)" were kept while
//     plain "SAP Consultant" never was.
// Business Analyst titles are deliberately NOT here: that family is demoted
// (sorted last, kept out of the digest), not dropped — see public/app.js.
export const VETO_JUNIOR = /\bjunior\b|\bintern(ship)?\b|gyakornok|\btrainee\b|\bgraduate\b|pályakezdő/i;
export const VETO_SOFT = {
  sap: /\bsap\b|s\/4hana|successfactors|\bariba\b|\babap\b/i,
  consultant: /\bconsultant\b|\btanácsadó\b|\badvisor\b/i,
  developer: /\bdeveloper\b|fejlesztő|software engineer|\bprogramozó\b/i,
  vendor: /servicenow|salesforce|veeva|genesys|dynamics 365|\bd365\b|sharepoint/i,
};
export const CORE_ANCHOR = /security|biztonság|cyber|\biam\b|identity|devops|\bsre\b|site reliability|platform engineer|cloud engineer|cloud architect|infrastruct|infrastruktúr|rendszermérnök|rendszergazda|üzemeltet|network|hálózat|kubernetes|openshift|\bai\b|\bml\b|mlops|observability|linux|automation|automatizál/i;

// returns the veto reason, or null to let the row through to the fit filter
export function titleVeto(role) {
  const t = role || "";
  if (VETO_JUNIOR.test(t)) return "junior";
  if (CORE_ANCHOR.test(t)) return null;
  for (const [reason, re] of Object.entries(VETO_SOFT)) if (re.test(t)) return reason;
  return null;
}

// returns: "keep" | "keep-flag" (provincial priority role) | "<drop reason>"
export function judgeProfession(role, loc) {
  if (GERMAN_ROLE.test(role || "")) return "language:german-or-gender-tag";
  const veto = titleVeto(role);
  if (veto) return `title:${veto}`;
  if (FOREIGN_LOC.test(loc || "")) return "location:foreign";
  const city = ((loc || "").split(",")[1] || "").trim().toLowerCase();
  if (!city || METRO_CITIES.has(city)) return "keep";
  if (PRIORITY_ROLE.test(role || "")) return "keep-flag";
  return "location:provincial";
}

// LinkedIn rows carry no location — the alerts selector yields id/url/title
// only (see docs/refresh-task.md, "Browser collection") — so the metro and
// foreign-location rules have nothing to read and are deliberately absent
// here rather than guessed at from the title. What remains is exactly what
// the merge step was told to apply by hand: the German/gendered-tag veto and
// the title vetoes.
export function judgeLinkedIn(role) {
  if (GERMAN_ROLE.test(role || "")) return "language:german-or-gender-tag";
  const veto = titleVeto(role);
  if (veto) return `title:${veto}`;
  return "keep";
}
