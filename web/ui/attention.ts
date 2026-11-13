// "Du bist dran" ausserhalb der Rundenleiste (#163, ui-spec 3.7): Seitentitel und Favicon mit Punkt.
// Kein Ton, keine Browser-Benachrichtigung. Die Funktionen sind rein; applyAttention schreibt ins Dokument.
import { fillText, txt } from "./text.ts";
import { THEME_CHANGED } from "./theme-switch.ts";

// Seitentitel: "(●) 18OE · Partie 12" wenn ich dran bin, sonst "18OE · Partie 12"; ohne Partie nur "18OE".
export function pageTitle(mine: boolean, gameId: number | null): string {
  const base = gameId === null ? txt("attention.title_lobby").de : fillText("attention.title_game", { id: gameId });
  return mine ? `${txt("attention.dot").de} ${base}` : base;
}

// Favicon als SVG-Data-URI. Farben kommen aus den Theme-Tokens (--ui-accent, --ui-panel, --ui-ink),
// hier nur als Parameter; ohne Punkt ist es das Siegel allein.
export interface FaviconColors { accent: string; panel: string; ink: string }
export function faviconHref(mine: boolean, c: FaviconColors): string {
  const dot = mine ? `<circle cx="23" cy="9" r="7.5" fill="${c.accent}" stroke="${c.panel}" stroke-width="2"/>` : "";
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect x="1" y="1" width="30" height="30" rx="6" fill="${c.panel}" stroke="${c.ink}" stroke-width="2"/><text x="16" y="23" font-size="15" font-weight="700" text-anchor="middle" font-family="serif" fill="${c.ink}">18</text>${dot}</svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

const token = (style: CSSStyleDeclaration, name: string, fallback: string) => style.getPropertyValue(name).trim() || fallback;

let last: { mine: boolean; gameId: number | null } = { mine: false, gameId: null };

export function applyAttention(mine: boolean, gameId: number | null, doc: Document = document): void {
  last = { mine, gameId };
  doc.title = pageTitle(mine, gameId);
  let link = doc.querySelector<HTMLLinkElement>('link[rel="icon"]');
  if (!link) {
    link = doc.createElement("link");
    link.rel = "icon";
    link.type = "image/svg+xml";
    doc.head.append(link);
  }
  const style = doc.defaultView?.getComputedStyle(doc.documentElement);
  const c: FaviconColors = style
    ? { accent: token(style, "--ui-accent", "#b8860b"), panel: token(style, "--ui-panel", "#ffffff"), ink: token(style, "--ui-ink", "#222222") }
    : { accent: "#b8860b", panel: "#ffffff", ink: "#222222" };
  link.href = faviconHref(mine, c);
}

// Nach Themenwechsel das Favicon neu einfaerben.
export function watchTheme(doc: Document = document): void {
  doc.addEventListener(THEME_CHANGED, () => applyAttention(last.mine, last.gameId, doc));
}
