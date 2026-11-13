// Versionsangabe (#271): Roadmap-Version, Build-Id und Engine-Stand. Die Seitenversion kommt zur
// Build-Zeit aus der Datei VERSION (web/build.mjs, `__OE_VERSION__`), Server-Version, Build-Id und
// Engine-Stand aus GET /healthz (kein anderer Abruf). Texte stehen in text.ts, Farben in kit/theme.
import { h } from "./dom.ts";
import { fillText, txt } from "./text.ts";

declare const __OE_VERSION__: string | undefined;

export interface ServerVersion { version?: string; build?: string; engine?: string }

/** Version der geladenen Seite; "dev" wenn nicht über build.mjs gebaut (Tests). */
export const pageVersion = (): string => (typeof __OE_VERSION__ === "string" ? __OE_VERSION__ : "dev");

export type FetchLike = (input: string) => Promise<Response>;

/** Liest /healthz; bei jedem Fehler null (die Anzeige bleibt dann ohne Serverwerte). */
export async function fetchServerVersion(fetchFn: FetchLike = (i) => fetch(i, { cache: "no-store" })): Promise<ServerVersion | null> {
  try {
    const res = await fetchFn("/healthz");
    if (!res.ok) return null;
    const data = (await res.json()) as ServerVersion;
    return data && typeof data === "object" ? data : null;
  } catch {
    return null;
  }
}

/** Eine Zeile, die sich in Rückmeldungen kopieren lässt. */
export function versionLine(server: ServerVersion | null, page: string = pageVersion()): string {
  const none = txt("version.unknown").de;
  return fillText("version.line", { version: server?.version ?? page, build: server?.build ?? none, engine: server?.engine ?? none });
}

/** Seite und Server melden verschiedene Versionen (altes Frontend im Cache). */
export function isStale(server: ServerVersion | null, page: string = pageVersion()): boolean {
  return !!server?.version && page !== "dev" && server.version !== page;
}

function rows(server: ServerVersion | null, page: string): [string, string][] {
  const none = txt("version.unknown").de;
  return [
    [txt("version.page").de, page],
    [txt("version.server").de, server?.version ?? none],
    [txt("version.build").de, server?.build ?? none],
    [txt("version.engine").de, server?.engine ?? none],
  ];
}

function details(server: ServerVersion | null, page: string): HTMLElement {
  return h("div", { class: "version-body" },
    h("dl", {}, ...rows(server, page).flatMap(([k, val]) => [h("dt", {}, k), h("dd", {}, val)])),
    isStale(server, page) ? h("p", { class: "error", role: "alert" }, txt("version.stale").de) : null,
    h("p", { class: "muted" }, txt("version.report").de));
}

/** Fußzeile für die Anmeldeseiten: eine Zeile, füllt sich, sobald /healthz antwortet. */
export function versionFooter(fetchFn?: FetchLike): HTMLElement {
  const page = pageVersion();
  const el = h("footer", { class: "version-note muted" }, `${txt("version.label").de} ${page}`);
  void fetchServerVersion(fetchFn).then((server) => {
    el.textContent = versionLine(server, page);
    el.toggleAttribute("data-stale", isStale(server, page));
  });
  return el;
}

/** Knopf mit Info-Dialog für den Spielrahmen. */
export function versionButton(fetchFn?: FetchLike): HTMLElement {
  const page = pageVersion();
  let server: ServerVersion | null = null;
  const dialog = h("dialog", { class: "version-dialog", "aria-label": txt("version.title").de });
  const open = h("button", { type: "button", class: "version-open", title: txt("version.title").de }, page);
  const draw = () => {
    dialog.replaceChildren(
      h("h2", {}, txt("version.title").de),
      details(server, page),
      h("form", { method: "dialog" }, h("button", {}, txt("version.close").de)));
    open.textContent = server?.version ?? page;
    open.toggleAttribute("data-stale", isStale(server, page));
  };
  open.addEventListener("click", () => {
    void fetchServerVersion(fetchFn).then((s) => { server = s; draw(); });
    draw();
    if (typeof dialog.showModal === "function" && !dialog.open) dialog.showModal();
  });
  draw();
  return h("div", { class: "version-info" }, open, dialog);
}
