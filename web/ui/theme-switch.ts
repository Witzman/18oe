// Dev menu (#95): pick the theme and the tile style; the pick is stored and applied at once.
import { applyChoice, loadChoice, saveTheme, saveTileStyle, type KeyValue } from "../themes/choice.ts";
import { themes } from "../themes/index.ts";
import { TILE_STYLES, type TileStyle } from "../themes/schema.ts";
import { h } from "./dom.ts";

export const THEME_CHANGED = "oe:themechange";
const TILE_LABEL: Record<TileStyle, string> = { full: "Vollfläche", inner: "Innenrahmen" };

function storage(): KeyValue | null {
  try { return window.localStorage; } catch { return null; }
}

/** Applies the stored choice to the page. Call once before the first render. */
export function initTheme(): void {
  applyChoice(document.documentElement, loadChoice(storage()));
}

export function themeSwitch(): HTMLElement {
  const box = h("details", { class: "dev-menu" });
  const draw = () => {
    const choice = loadChoice(storage());
    applyChoice(document.documentElement, choice);
    const pick = (label: string, on: boolean, act: () => void) =>
      h("button", { type: "button", "aria-pressed": String(on), onclick: () => {
        act();
        draw();
        document.dispatchEvent(new CustomEvent(THEME_CHANGED));
      } }, label);
    box.replaceChildren(
      h("summary", {}, "Look"),
      h("div", { class: "row", role: "group", "aria-label": "Theme" }, h("span", {}, "Theme"),
        ...themes.map((t) => pick(t.name, t.id === choice.theme.id, () => saveTheme(storage(), t.id)))),
      h("div", { class: "row", role: "group", "aria-label": "Kachelstil" }, h("span", {}, "Kachel"),
        ...TILE_STYLES.map((s) => pick(TILE_LABEL[s], s === choice.tileStyle,
          () => saveTileStyle(storage(), s === choice.theme.shape.tileStyle ? null : s)))),
      h("div", { class: "swatch", "aria-hidden": "true" },
        h("span", { class: "sw-sea" }), h("span", { class: "sw-land" }), h("span", { class: "sw-high" }),
        h("span", { class: "sw-tile" }, h("i", {}))),
    );
  };
  draw();
  return box;
}
