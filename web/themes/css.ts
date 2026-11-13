// Theme -> CSS custom properties. Used by the build (dist/themes.css) and by the tests.
import { COLOR_KEYS, type ColorGroup, type Theme } from "./schema.ts";

const kebab = (s: string) => s.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);

/** Name of the CSS variable for a colour token, e.g. ("map", "seaDeep") -> "--map-sea-deep". */
export function cssVar(group: ColorGroup, key: string): string {
  return `--${group}-${kebab(key)}`;
}

export function themeVars(theme: Theme): [name: string, value: string][] {
  const vars: [string, string][] = [];
  for (const group of Object.keys(COLOR_KEYS) as ColorGroup[]) {
    const colors: Record<string, string> = theme[group];
    for (const key of COLOR_KEYS[group]) vars.push([cssVar(group, key), colors[key]!]);
  }
  vars.push(["--font-head", theme.font.head], ["--font-body", theme.font.body]);
  // Numbers keep their unit-free value (angles in degrees, lengths in hex side lengths,
  // times in ms) except the panel metrics, which are pixels.
  const px = new Set(["radius", "barHeight", "sideWidth", "gap", "hit"]);
  for (const [group, values] of [["camera", theme.camera], ["track", theme.track], ["motion", theme.motion], ["shape", theme.shape]] as const) {
    for (const [key, value] of Object.entries(values)) {
      if (key === "tileStyle") continue; // a data attribute (themes/choice.ts)
      const text = typeof value === "boolean" ? (value ? "1" : "0") : px.has(key) ? `${value}px` : String(value);
      vars.push([`--${group}-${kebab(key)}`, text]);
    }
  }
  return vars;
}

/** One rule per theme; the default theme also applies when no data-theme is set. */
export function themesCss(themes: readonly Theme[], defaultId: string): string {
  const head = "/* Generated from web/themes/*.json by build.mjs. Do not edit. */\n";
  return head + themes.map((t) => {
    const selector = t.id === defaultId ? `:root, :root[data-theme="${t.id}"]` : `:root[data-theme="${t.id}"]`;
    const body = themeVars(t).map(([k, v]) => `  ${k}: ${v};`).join("\n");
    return `${selector} {\n  color-scheme: ${t.colorScheme};\n${body}\n}\n`;
  }).join("");
}
