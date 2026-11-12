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
  vars.push(["--shape-tilt", String(theme.shape.tilt)]);
  vars.push(["--shape-hex-line-alpha", String(theme.shape.hexLineAlpha)]);
  vars.push(["--shape-paper", String(theme.shape.paper)]);
  vars.push(["--shape-radius", `${theme.shape.radius}px`]);
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
