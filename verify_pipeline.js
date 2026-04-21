#!/usr/bin/env node
/**
 * verify_pipeline.js
 *
 * Vérification de cohérence du pipeline de benchmark :
 *   Cloud Scheduler (github-relay) → trigger_pingers.yml → pinger → GCS → publish.yml → site
 *
 * Pour une fenêtre d'observation [--since T, now], le script :
 *   1. Calcule les slots qui AURAIENT DU être déclenchés (1 slot / 30 min, 12 slots rotatifs)
 *   2. Liste les fichiers réellement présents dans le bucket GCS public
 *   3. Fait le diff : pour chaque slot → ok / manquant / doublon
 *   4. Fetch `llms-full.json` publié et compare le compte de runs agrégés
 *
 * Usage :
 *   node verify_pipeline.js                              # fenêtre = 6 dernières heures
 *   node verify_pipeline.js --since 2026-04-19T16:00:00Z
 *   node verify_pipeline.js --since 2026-04-19T16:00:00Z --tolerance 600
 *
 * Aucune dépendance : Node >= 18 (fetch natif).
 */

const args = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i !== -1 ? args[i + 1] : null; };

const BUCKET = "mcp-benchmark-results";
const PUBLISHER_JSON_URL =
  "https://mcp-server-hosting-providers-benchmark.github.io/tools_list_latency_publisher/llms-full.json";
const SCHEDULER_PROJECT = "tools-list-latency-pingers";
const SCHEDULER_LOCATION = "us-central1";
const SCHEDULER_JOB_ID = "github-relay";

// Ordre des labels = ordre des slots dans trigger_pingers.yml
const SLOT_LABELS = [
  "sydney_au", "virginia_us", "oregon_us", "paris_fr",
  "warsaw_pl", "hong_kong_hk", "tokyo_jp", "singapore_sg",
  "mumbai_in", "sao_paulo_br", "tel_aviv_il", "johannesburg_za",
];

const now = new Date();
const since = flag("--since")
  ? new Date(flag("--since"))
  : new Date(now.getTime() - 6 * 3600 * 1000);
const tolerance_ms = parseInt(flag("--tolerance") ?? "600", 10) * 1000;

// --- Formatage Paris ---
const paris_day = d => d.toLocaleString("fr-FR", {
  timeZone: "Europe/Paris", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit",
});
const paris_hms = d => d.toLocaleString("fr-FR", {
  timeZone: "Europe/Paris", hour: "2-digit", minute: "2-digit", second: "2-digit",
});
const paris_full = d => d.toLocaleString("fr-FR", {
  timeZone: "Europe/Paris", year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", second: "2-digit",
});

// --- Slots attendus entre since et now ---
// Slots déclenchés à chaque :00 et :30 UTC. Slot = (hour*2 + floor(min/30)) % 12.
function expected_slots(from, to) {
  const start = new Date(from);
  const m = start.getUTCMinutes();
  if (m === 0 || m === 30) start.setUTCSeconds(0, 0);
  else if (m < 30) start.setUTCMinutes(30, 0, 0);
  else { start.setUTCHours(start.getUTCHours() + 1); start.setUTCMinutes(0, 0, 0); }

  const slots = [];
  for (let t = new Date(start); t <= to; t = new Date(t.getTime() + 30 * 60 * 1000)) {
    const slot_idx = (t.getUTCHours() * 2 + Math.floor(t.getUTCMinutes() / 30)) % 12;
    slots.push({ time: new Date(t), slot: slot_idx, label: SLOT_LABELS[slot_idx] });
  }
  return slots;
}

// --- Listing public du bucket GCS ---
async function list_gcs_files() {
  const url = `https://storage.googleapis.com/storage/v1/b/${BUCKET}/o`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`GCS list failed (${res.status})`);
  const data = await res.json();
  return (data.items ?? [])
    .map(item => ({
      name: item.name,
      label: item.name.split("/")[0],
      ts: new Date(item.timeCreated),
    }))
    .filter(f => SLOT_LABELS.includes(f.label));
}

// --- Runs agrégés côté publisher ---
// Retourne des runs uniques {label, ts} en mappant display-name → label technique.
async function fetch_publisher_runs() {
  try {
    const res = await fetch(PUBLISHER_JSON_URL, { cache: "no-store" });
    if (!res.ok) return { error: `HTTP ${res.status}` };
    const data = await res.json();

    // Mapping "Singapore, Singapore" → "singapore_sg" via source_url
    const display_to_label = {};
    for (const loc of data.pinger_locations ?? []) {
      const m = (loc.source_url ?? "").match(/mcp-pinger-([a-z0-9-]+)/);
      if (m) display_to_label[loc.location] = m[1].replace(/-/g, "_");
    }

    const seen = new Set();
    const runs = [];
    for (const p of data.providers ?? []) {
      for (const r of p.runs ?? []) {
        const label = display_to_label[r.pinger] ?? null;
        const key = `${label}|${r.ts}`;
        if (seen.has(key)) continue;
        seen.add(key);
        runs.push({ label, ts: new Date(r.ts) });
      }
    }
    return {
      runs,
      last_updated: data.last_updated,
      period: data.evaluation_period,
    };
  } catch (e) { return { error: e.message }; }
}

// Extrait le timestamp d'un nom de fichier GCS : "singapore_sg/tools_list_2026-04-19T15-31-42-675Z.json"
function ts_from_filename(name) {
  const m = name.match(/tools_list_(.+)\.json$/);
  if (!m) return null;
  const s = m[1];
  if (s.length < 24) return null;
  const iso = s.slice(0, 13) + ":" + s.slice(14, 16) + ":" + s.slice(17, 19) + "." + s.slice(20);
  const d = new Date(iso);
  return isNaN(d) ? null : d;
}

async function read_scheduler_logs_for_slot(slot_time) {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execFileAsync = promisify(execFile);

  const from = new Date(slot_time.getTime() - 10 * 60 * 1000);
  const to = new Date(slot_time.getTime() + 10 * 60 * 1000);
  const filter = [
    `resource.type="cloud_scheduler_job"`,
    `resource.labels.location="${SCHEDULER_LOCATION}"`,
    `resource.labels.job_id="${SCHEDULER_JOB_ID}"`,
    `timestamp>="${from.toISOString()}"`,
    `timestamp<="${to.toISOString()}"`,
  ].join(" AND ");

  try {
    const { stdout } = await execFileAsync(
      "gcloud",
      [
        "logging", "read", filter,
        `--project=${SCHEDULER_PROJECT}`,
        "--format=json",
        "--limit=50",
        "--order=asc",
      ],
      { timeout: 30000, maxBuffer: 1024 * 1024 }
    );
    return { entries: JSON.parse(stdout || "[]") };
  } catch (e) {
    const message = e.stderr?.trim() || e.message || String(e);
    return { error: message.split("\n")[0] };
  }
}

function scheduler_entry_type(entry) {
  return entry.jsonPayload?.["@type"]?.split(".").pop() ?? "(type inconnu)";
}

function scheduler_result(entry) {
  const status = entry.httpRequest?.status ? `HTTP ${entry.httpRequest.status}` : (entry.jsonPayload?.status ?? entry.severity ?? "statut inconnu");
  const debug = entry.jsonPayload?.debugInfo;
  return debug ? `${status} · ${debug}` : status;
}

// --- Exécution ---
const [gcs_files, publisher] = await Promise.all([
  list_gcs_files(),
  fetch_publisher_runs(),
]);

const gcs_in_window = gcs_files
  .filter(f => f.ts >= since && f.ts <= now)
  .sort((a, b) => a.ts - b.ts);

const slots = expected_slots(since, now);

console.log(`\nFenêtre Paris : ${paris_full(since)} → ${paris_full(now)}`);
console.log(`(UTC : ${since.toISOString()} → ${now.toISOString()})`);
console.log(`Tolérance d'appariement slot/fichier : ±${tolerance_ms / 1000}s\n`);

console.log("═══ Test 1 : Les pingers prévus par le schedule ont-ils tous déposé leur fichier dans GCS ? ═══\n");
console.log("Slot | Pinger attendu   | Heure slot (Paris)  | Fichier(s) GCS (Paris)  | Statut");
console.log("-----|------------------|---------------------|-------------------------|--------");

let ok = 0, missing = 0, dup = 0;
const used = new Set();
const missing_slots = [];

for (const s of slots) {
  const matches = gcs_in_window.filter(f =>
    f.label === s.label &&
    Math.abs(f.ts.getTime() - s.time.getTime()) <= tolerance_ms
  );
  matches.forEach(m => used.add(m.name));
  const status = matches.length === 0 ? "✗ manquant"
               : matches.length === 1 ? "✓ ok"
               : `⚠ ${matches.length} fichiers`;
  if (matches.length === 0) missing++;
  else if (matches.length === 1) ok++;
  else dup++;
  if (matches.length === 0) missing_slots.push(s);

  const time_str = paris_day(s.time);
  const files_str = matches.length
    ? matches.map(m => paris_hms(m.ts)).join(", ")
    : "—";
  console.log(
    `${String(s.slot).padStart(4)} | ${s.label.padEnd(16)} | ${time_str.padEnd(19)} | ${files_str.padEnd(23)} | ${status}`
  );
}

// Fichiers GCS non rattachés à un slot attendu
const unexpected = gcs_in_window.filter(f => !used.has(f.name));
if (unexpected.length) {
  console.log("\nFichiers GCS non appariés à un slot attendu :");
  for (const f of unexpected) {
    console.log(`  ${f.label.padEnd(16)} ${paris_full(f.ts)} Paris  (${f.name})`);
  }
}

console.log(
  `\nBilan slots : ${ok} ok · ${missing} manquants · ${dup} doublons · ${unexpected.length} fichiers inattendus`
);
console.log(`Fichiers GCS dans la fenêtre : ${gcs_in_window.length}`);

if (missing_slots.length) {
  console.log(`\nDiagnostic Cloud Scheduler pour les slots manquants :`);
  console.log(`Job automatique : ${SCHEDULER_JOB_ID} (${SCHEDULER_PROJECT}, ${SCHEDULER_LOCATION})\n`);
  console.log("Slot | Pinger attendu   | Heure slot (Paris)  | Trace tâche automatique | Résultat inscrit dans les logs");
  console.log("-----|------------------|---------------------|-------------------------|-------------------------------");

  for (const s of missing_slots) {
    const scheduler = await read_scheduler_logs_for_slot(s.time);
    let trace = "non vérifié";
    let result = "non vérifié";

    if (scheduler.error) {
      trace = "⚠ lecture impossible";
      result = scheduler.error;
    } else if (scheduler.entries.length === 0) {
      trace = "✗ aucune trace";
      result = "aucune entrée Cloud Scheduler dans ±10 min";
    } else {
      const started = scheduler.entries.filter(e => scheduler_entry_type(e) === "AttemptStarted");
      const finished = scheduler.entries.filter(e => scheduler_entry_type(e) === "AttemptFinished");
      trace = started.length ? `✓ ${started.length} tentative(s)` : "⚠ résultat sans démarrage";
      result = finished.length
        ? scheduler_result(finished[finished.length - 1])
        : "aucune entrée de fin de tentative";
    }

    console.log(
      `${String(s.slot).padStart(4)} | ${s.label.padEnd(16)} | ${paris_day(s.time).padEnd(19)} | ${trace.padEnd(23)} | ${result}`
    );
  }
}

// --- Test 2 : Publisher vs GCS (identité, pas juste count) ---
console.log(`\n═══ Test 2 : Le site publié reflète-t-il fidèlement le contenu actuel de GCS ? ═══\n`);
console.log(`Publisher (${PUBLISHER_JSON_URL}) :`);

let test2_ok = true;
if (publisher.error) {
  console.log(`  ERREUR : ${publisher.error}`);
  test2_ok = false;
} else {
  console.log(`  Dernière mise à jour : ${paris_full(new Date(publisher.last_updated))} Paris`);
  console.log(`  Période couverte : ${paris_full(new Date(publisher.period?.from))} → ${paris_full(new Date(publisher.period?.to))} Paris\n`);

  // Sets de runs uniques sur 24h glissantes
  const cutoff = new Date(now.getTime() - 86400 * 1000);

  const gcs_runs = gcs_files
    .map(f => ({ label: f.label, ts: ts_from_filename(f.name) ?? f.ts }))
    .filter(r => r.ts >= cutoff);

  const pub_runs = publisher.runs.filter(r => r.ts >= cutoff);

  // Appariement par label + |dt| ≤ 5 sec (drift entre timestamp interne JSON et filename)
  const match_tolerance_ms = 5000;
  const pub_matched = new Set();
  const rows = [];

  for (const g of gcs_runs) {
    const match = pub_runs.find((p, i) =>
      !pub_matched.has(i) &&
      p.label === g.label &&
      Math.abs(p.ts.getTime() - g.ts.getTime()) <= match_tolerance_ms
    );
    if (match) {
      const idx = pub_runs.indexOf(match);
      pub_matched.add(idx);
      rows.push({ label: g.label, ts: g.ts, gcs: true, pub: true });
    } else {
      rows.push({ label: g.label, ts: g.ts, gcs: true, pub: false });
    }
  }
  pub_runs.forEach((p, i) => {
    if (!pub_matched.has(i)) rows.push({ label: p.label ?? "(inconnu)", ts: p.ts, gcs: false, pub: true });
  });

  rows.sort((a, b) => a.ts - b.ts);

  console.log("Pinger            | Heure run (Paris)    | GCS | Publisher | Statut");
  console.log("------------------|----------------------|-----|-----------|--------");
  let sync = 0, only_gcs = 0, only_pub = 0;
  for (const r of rows) {
    const status = r.gcs && r.pub ? "✓ synchro"
                 : r.gcs          ? "⚠ absent publisher"
                                  : "⚠ absent GCS";
    if (r.gcs && r.pub) sync++;
    else if (r.gcs) only_gcs++;
    else only_pub++;
    console.log(
      `${(r.label ?? "").padEnd(17)} | ${paris_full(r.ts).padEnd(20)} | ${(r.gcs ? "✓" : "✗").padEnd(3)} | ${(r.pub ? "✓" : "✗").padEnd(9)} | ${status}`
    );
  }
  if (rows.length === 0) console.log("  (aucun run dans les 24 dernières heures)");

  console.log(`\nBilan : ${sync} synchro · ${only_gcs} sur GCS seulement · ${only_pub} sur publisher seulement`);
  test2_ok = only_gcs === 0 && only_pub === 0;
}

// Exit code utile pour CI : 0 si tout vert, 1 sinon
const test1_ok = missing === 0 && dup === 0 && unexpected.length === 0;
process.exit(test1_ok && test2_ok ? 0 : 1);
