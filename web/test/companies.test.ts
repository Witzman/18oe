// Company colours as theme tokens (#99). Every corporation of the engine has a token in every theme, the
// abbreviation on it is readable, and two companies of one tier can be told apart. Not covered: the match with
// the physical game's photos (ASSUMPTION, see the issue); the sym itself always sits on the seal, so colour is
// never the only cue.
import assert from "node:assert/strict";
import { test } from "node:test";
import { companyBg, companyColors } from "../themes/companies.ts";
import { contrast, deltaE } from "../themes/color.ts";
import { deriveCompanies, engineCorporations } from "../themes/derive-companies.ts";
import { themes } from "../themes/index.ts";
import { COMPANY_COLOR_KEYS, themeProblems } from "../themes/schema.ts";
import { inkFor } from "../ui/kit/ink.ts";

const corps = engineCorporations();
/** Assumption: ΔE76 of 6 between two companies of one tier is the least that still reads as two colours side by side. */
const MIN_DELTA_E = 6;
/** Pairs below this are reported in the issue (engine colours that are close); not a failure. */
const WATCH_DELTA_E = 10;

test("the engine has 36 corporations, all with a colour", () => {
  assert.equal(corps.length, 36);
  assert.equal(new Set(corps.map((c) => c.id)).size, 36);
});

for (const theme of themes) {
  test(`${theme.id}: every engine corporation has a company token, and nothing else does`, () => {
    assert.deepEqual(Object.keys(theme.companies).sort(), corps.map((c) => c.id).sort());
    for (const c of corps) assert.deepEqual(Object.keys(theme.companies[c.id]!).sort(), [...COMPANY_COLOR_KEYS].sort(), c.id);
  });

  test(`${theme.id}: the tokens are what the derive tool makes of the engine`, () => {
    assert.deepEqual(theme.companies, deriveCompanies(theme, corps));
    if (theme.id === "brett") for (const c of corps) assert.equal(theme.companies[c.id]!.bg, c.color, c.id);
  });

  test(`${theme.id}: abbreviation on the company colour reaches 4.5:1`, () => {
    for (const c of corps) {
      const t = theme.companies[c.id]!;
      assert.ok(contrast(t.ink, t.bg) >= 4.5, `${c.id} ${t.ink} on ${t.bg}`);
      assert.equal(t.ink, inkFor(t.bg, theme), c.id);
    }
  });

  test(`${theme.id}: two companies of one tier differ by at least ΔE ${MIN_DELTA_E}`, () => {
    for (const tier of new Set(corps.map((c) => c.type))) {
      const ids = corps.filter((c) => c.type === tier).map((c) => c.id);
      for (let i = 0; i < ids.length; i++) for (let j = i + 1; j < ids.length; j++) {
        const d = deltaE(theme.companies[ids[i]!]!.bg, theme.companies[ids[j]!]!.bg);
        assert.ok(d >= MIN_DELTA_E, `${theme.id} ${ids[i]} / ${ids[j]}: ΔE ${d.toFixed(1)}`);
      }
    }
  });
}

test("close engine colours of one tier (report for the issue, below ΔE 10)", () => {
  const close: string[] = [];
  const theme = themes[0]!;
  for (const tier of new Set(corps.map((c) => c.type))) {
    const ids = corps.filter((c) => c.type === tier).map((c) => c.id);
    for (let i = 0; i < ids.length; i++) for (let j = i + 1; j < ids.length; j++) {
      const d = deltaE(theme.companies[ids[i]!]!.bg, theme.companies[ids[j]!]!.bg);
      if (d < WATCH_DELTA_E) close.push(`${ids[i]}/${ids[j]} ${d.toFixed(1)}`);
    }
  }
  if (close.length) console.log(`# close pairs: ${close.join(", ")}`);
});

test("unknown ids fall back to the placeholder palette, known ids never do", () => {
  const theme = themes[0]!;
  assert.equal(companyColors(theme, "NOPE"), null);
  assert.equal(companyColors(theme, "__proto__"), null);
  assert.equal(companyBg(theme, "NOPE"), theme.company.c1);
  assert.equal(companyBg(theme, "NOPE", ["x", "NOPE"]), theme.company.c2);
  assert.equal(companyBg(theme, "PLM", ["x", "PLM"]), theme.companies.PLM!.bg);
});

test("a theme with a malformed company token is rejected", () => {
  const raw = structuredClone(themes[0]!) as unknown as Record<string, Record<string, Record<string, string>>>;
  delete raw.companies!.PLM!.ink;
  raw.companies!.KBS!.bg = "blue";
  const problems = themeProblems(raw);
  assert.ok(problems.some((p) => p.startsWith("companies.PLM.ink")), problems.join("; "));
  assert.ok(problems.some((p) => p.startsWith("companies.KBS.bg")), problems.join("; "));
});
