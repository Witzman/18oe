// Derives the `companies` tokens of the themes from the engine's corporation definitions (#99).
//   node themes/derive-companies.ts          prints the tokens per theme as JSON
//   node themes/derive-companies.ts --write  rewrites the "companies" key in themes/*.json
// Background: Brett takes the engine colour as is; Atlas (paper look) mixes it 12 % toward its land colour.
// Ink is never the engine's text_color (ui-spec 1.3) but the best-contrasting candidate of the theme; edge is the
// background darkened. ASSUMPTION (Rule 10): the engine colours are not yet compared with the physical game's photos.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { hexToNumber } from "./color.ts";
import { inkFor } from "../ui/kit/ink.ts";
import type { CompanyColors, Theme } from "./schema.ts";

export const ENTITIES_RB = fileURLToPath(new URL("../../lib/engine/game/g_18_oe/entities.rb", import.meta.url));

export interface EngineCorp { id: string; type: string; color: string }

/** Corporations (minors and regionals) of the engine's entities.rb: sym, type, color. */
export function engineCorporations(path = ENTITIES_RB): EngineCorp[] {
  const src = readFileSync(path, "utf8");
  const body = src.slice(src.indexOf("CORPORATIONS = ["));
  return body.split(/\n {10}\{\n/).slice(1).map((b) => {
    const id = /\bsym: '(\w+)'/.exec(b)?.[1];
    const type = /\btype: '(minor|regional|major)'/.exec(b)?.[1];
    const color = /\bcolor: '(#[0-9a-fA-F]{6})'/.exec(b)?.[1];
    if (!id || !type || !color) throw new Error(`entities.rb: corporation without sym/type/color near "${b.slice(0, 60)}"`);
    return { id, type, color: color.toLowerCase() };
  });
}

const rgb = (hex: string): [number, number, number] => { const n = hexToNumber(hex); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; };
const toHex = (c: number[]): string => `#${c.map((v) => Math.round(v).toString(16).padStart(2, "0")).join("")}`;
export const mix = (a: string, b: string, t: number): string => toHex(rgb(a).map((v, i) => v * (1 - t) + rgb(b)[i]! * t));

/** Mix factor toward the theme's land colour: 0 keeps the engine colour. */
const TINT: Record<string, number> = { brett: 0, atlas: 0.12 };

export function deriveCompanies(theme: Theme, corps: readonly EngineCorp[]): Record<string, CompanyColors> {
  const t = TINT[theme.id] ?? 0;
  return Object.fromEntries(corps.map((c) => {
    const bg = t > 0 ? mix(c.color, theme.map.land, t) : c.color;
    return [c.id, { bg, ink: inkFor(bg, theme), edge: mix(bg, "#000000", 0.45) }];
  }));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const corps = engineCorporations();
  for (const id of ["brett", "atlas"]) {
    const file = fileURLToPath(new URL(`./${id}.json`, import.meta.url));
    const raw = JSON.parse(readFileSync(file, "utf8"));
    const theme = raw as Theme; // read raw: the file may not have `companies` yet
    {
      const companies = deriveCompanies(theme, corps);
    if (process.argv.includes("--write")) {
      const out: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(raw)) { if (k === "companies") continue; out[k] = v; if (k === "company") out.companies = companies; }
      writeFileSync(file, `${JSON.stringify(out, null, 2)}\n`);
    } else console.log(theme.id, JSON.stringify(companies));
    }
  }
}
