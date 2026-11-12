// Text colour on a coloured surface is computed, never taken from the engine (ui-spec 1.3).
import { contrast } from "../../themes/color.ts";
import type { Theme } from "../../themes/schema.ts";

/** Neutral gray of level 0..255 as "#rrggbb" (0 black, 255 white), computed so no colour literal sits in the code. */
function grayHex(level: number): string {
  const part = level.toString(16).padStart(2, "0");
  return `#${part}${part}${part}`;
}

/** Candidate text colours: the theme's own inks first (they win ties), black and white as a last resort for mid-tone seals. */
export function inkCandidates(theme: Theme): string[] {
  return [theme.ui.ink, theme.ui.panel, theme.ui.bar, theme.ui.barInk, grayHex(0), grayHex(255)];
}

export function inkFor(bg: string, theme: Theme): string {
  let best = "";
  let bestRatio = -1;
  for (const c of inkCandidates(theme)) {
    const ratio = contrast(c, bg);
    if (ratio > bestRatio + 1e-9) { best = c; bestRatio = ratio; }
  }
  return best;
}

/** Whether the best candidate reaches the 4.5:1 the spec asks for. */
export function inkReadable(bg: string, theme: Theme): boolean {
  return contrast(inkFor(bg, theme), bg) >= 4.5;
}
