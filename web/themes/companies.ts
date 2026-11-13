// Company colours by id (#99). Real ones come from `theme.companies`; an id without an entry
// falls back to the placeholder palette company.c1..c6 by its position in the list (as before #99).
import type { CompanyColors, Theme } from "./schema.ts";

const FALLBACK_KEYS = ["c1", "c2", "c3", "c4", "c5", "c6"] as const;

/** The theme's entry for company `id`, or null for an unknown id. */
export function companyColors(theme: Theme, id: string): CompanyColors | null {
  return Object.hasOwn(theme.companies, id) ? theme.companies[id]! : null;
}

/** Background colour of company `id`; `ids` is the game's company list, used only for the fallback slot of unknown ids. */
export function companyBg(theme: Theme, id: string, ids: readonly string[] = []): string {
  return companyColors(theme, id)?.bg ?? theme.company[FALLBACK_KEYS[Math.max(0, ids.indexOf(id)) % FALLBACK_KEYS.length]!];
}
