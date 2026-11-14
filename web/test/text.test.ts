import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { TEXT, txt } from "../ui/text.ts";

const WEB = fileURLToPath(new URL("..", import.meta.url));
const ENGINE = join(WEB, "..", "lib", "engine");
const G18OE_STEPS = join(ENGINE, "game", "g_18_oe", "step");
const ACTIONS = join(ENGINE, "action");

// Konstanten, geprüft gegen den Code (Quelle je Zeile).
const ROUND_TYPES = ["auction", "concession", "stock", "operating", "consolidation"]; // lib/oe/view.rb
const TIERS = ["minor", "regional", "major", "national"]; // Regelwerk §6.2, §9.2 bis §9.4
const DIVIDEND_KINDS = ["withhold", "half", "payout"]; // Regelwerk §11.4
const ERROR_CODES = [
  "bad_request", "login_required", "forbidden", "not_your_turn", "not_found", "conflict",
  "rejected", "invalid_seats", "game_limit", "internal_error", "network", "timeout", "bad_response",
  "unknown_player", "invalid_login", "rate_limited", "invalid_invite", "invalid_name", "invalid_email", "invalid_password", "name_taken", "registration_failed",
]; // lib/oe/games_api.rb, app.rb, web/api.ts
const RULE_REFS = [
  "§4", "§4.4", "§5.1.2", "§6.2", "§6.3", "§7", "§8.1", "§8.2", "§9", "§10", "§10.6",
  "§11", "§11.4", "§12", "§13", "§14", "§15",
];

// Dateien unter web/ui, die noch deutschen Text außerhalb von text.ts enthalten.
// Die Liste schrumpft: sobald eine Datei keinen deutschen Text mehr hat, schlägt der
// Test fehl, bis die Ausnahme gestrichen ist.
const EXEMPT_FILES = [
  "ui/theme-switch.ts", // Bestand: Beschriftung des Umschalters
];
const EXEMPT_DIRS = [
  "ui/kit/", // Bausteine von einem anderen Agenten, hier nicht anfassen
];

function stepClassNames(): string[] {
  const names: string[] = [];
  for (const f of readdirSync(G18OE_STEPS)) {
    if (!f.endsWith(".rb")) continue;
    const src = readFileSync(join(G18OE_STEPS, f), "utf8");
    for (const m of src.matchAll(/^\s*class (\w+) < /gm)) names.push(m[1]!);
  }
  return names.sort();
}

function actionTypes(): string[] {
  return readdirSync(ACTIONS)
    .filter((f) => f.endsWith(".rb") && f !== "base.rb")
    .map((f) => f.slice(0, -3))
    .sort();
}

// Liefert die Textinhalte aller Zeichenketten-Literale einer Quelldatei (ohne Kommentarzeilen).
function stringLiterals(src: string): string[] {
  const out: string[] = [];
  const re = /"((?:[^"\\\n]|\\.)*)"|'((?:[^'\\\n]|\\.)*)'|`((?:[^`\\]|\\.)*)`/g;
  for (const line of src.split("\n")) {
    if (/^\s*(\/\/|\*|\/\*)/.test(line)) continue;
    for (const m of line.matchAll(re)) out.push(m[1] ?? m[2] ?? m[3] ?? "");
  }
  return out;
}

const GERMAN = /[äöüÄÖÜß]|\b(und|oder|nicht|der|die|das|mit|für|ist|sind|keine|kein|bitte|Zug|Züge|Runde|Runden|Firma|Firmen|Spieler|Gleis|Gleise|Plätze|Verbindung)\b/;

function hasGermanText(src: string): boolean {
  return stringLiterals(src).some((s) => GERMAN.test(s));
}

function uiFiles(): string[] {
  const dir = join(WEB, "ui");
  return readdirSync(dir, { recursive: true })
    .map((f) => String(f))
    .filter((f) => f.endsWith(".ts") && statSync(join(dir, f)).isFile())
    .map((f) => `ui/${f}`)
    .sort();
}

test("every action type in lib/engine/action has an entry", () => {
  const types = actionTypes();
  assert.ok(types.length >= 70, `expected the full action list, got ${types.length}`);
  const missing = types.filter((t) => !TEXT[`action.${t}`]);
  assert.deepEqual(missing, []);
});

test("every step class of lib/engine/game/g_18_oe/step has an entry", () => {
  const classes = stepClassNames();
  assert.ok(classes.length >= 18, `expected the G18OE step classes, got ${classes.length}`);
  const missing = classes.filter((c) => !TEXT[`step.${c}`]);
  assert.deepEqual(missing, []);
});

test("round types, tiers, dividend kinds, error codes and rule references have entries", () => {
  const keys = [
    ...ROUND_TYPES.map((r) => `round.${r}`),
    ...TIERS.map((t) => `tier.${t}`),
    ...DIVIDEND_KINDS.map((d) => `dividend.${d}`),
    ...ERROR_CODES.map((c) => `error.${c}`),
    ...RULE_REFS.map((r) => `ref.${r}`),
  ];
  assert.deepEqual(keys.filter((k) => !TEXT[k]), []);
});

test("every reason for an invalid action (ui-spec §3.5) has an entry", () => {
  const reasons = [
    "cash", "certificate_limit", "no_build_points", "no_token", "no_train",
    "tile_unavailable", "phase", "default",
  ];
  assert.deepEqual(reasons.filter((r) => !TEXT[`invalid.${r}`]), []);
});

test("no entry has an empty German, English or rule text", () => {
  for (const [key, entry] of Object.entries(TEXT)) {
    for (const field of ["de", "en", "regel"] as const) {
      assert.ok(entry[field].trim().length > 0, `${key}.${field} is empty`);
    }
  }
});

test("txt() returns the entry, and falls back to the key for an unknown key", () => {
  assert.equal(txt("round.stock").en, "Stock Round");
  assert.deepEqual(txt("nicht.da"), { de: "nicht.da", en: "nicht.da", regel: "—" });
});

test("no German running text in web/ui outside text.ts (except the named exemptions)", () => {
  const files = uiFiles().filter((f) => f !== "ui/text.ts");
  const exempt = (f: string) =>
    EXEMPT_FILES.includes(f) || EXEMPT_DIRS.some((d) => f.startsWith(d));

  const offending = files.filter((f) => !exempt(f) && hasGermanText(readFileSync(join(WEB, f), "utf8")));
  assert.deepEqual(offending, [], "German text outside text.ts: move it to web/ui/text.ts or name the file in EXEMPT_FILES");

  // Die Ausnahmeliste schrumpft: eine Datei ohne deutschen Text fliegt aus der Liste.
  const stale = EXEMPT_FILES.filter((f) => {
    const path = join(WEB, f);
    try {
      return !hasGermanText(readFileSync(path, "utf8"));
    } catch {
      return true; // Datei gibt es nicht mehr
    }
  });
  assert.deepEqual(stale, [], "these exemptions have no German text left (or no file): remove them from EXEMPT_FILES");
});

test("the search detects German text in a UI file", () => {
  assert.equal(hasGermanText('h("span", {}, "Plätze frei")'), true);
  assert.equal(hasGermanText("h(\"b\", {}, \"Du bist nicht am Zug\")"), true);
  assert.equal(hasGermanText('h("b", {}, "Pass")'), false);
  assert.equal(hasGermanText("// Kommentar mit Ärger"), false);
});
