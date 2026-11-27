// Putting our map (#614) and our price board (#619) where the page has its own: a box right before the page's
// element, which is hidden while ours shows. The switch brings the page's back, for the actions that need it. The
// page redraws and replaces its elements at will, so `sync` runs after every change and does nothing when in place.

import { txt } from "../ui/text.ts";

export interface Placed {
  /** Bar (switch and note) and stage. */
  box: HTMLElement;
  /** Where ours is mounted. */
  stage: HTMLElement;
  /** Puts the box in place; false when the page shows no such element. */
  sync(): boolean;
  /** Ours is on screen (false: the player switched to the page's, or ours cannot be shown). */
  showing(): boolean;
  /** Ours cannot be drawn: say why and leave the page's, for good. */
  fail(message: string): void;
  /** The game cannot be read: say why and leave the page's, until called with null. */
  lose(reason: string | null): void;
  /** Takes ours away and leaves the page's. */
  remove(): void;
}

// Assign only on a change: each write is a DOM mutation, and mutations trigger the next sync.
function set<T, K extends keyof T>(target: T, key: K, value: T[K]): void {
  if (target[key] !== value) target[key] = value;
}

export type Store = Pick<Storage, "getItem" | "setItem">;

/** What is replaced and how it is called. */
interface View {
  /** localStorage key of "show the page's own". */
  key: string;
  /** The page's element that ours stands in for, or null when the page shows none. */
  find: (document: Document) => HTMLElement | null;
  texts: { original: string; ours: string; failed: string };
  stage: Record<string, string>;
}

const MAP: View = {
  key: "oe.addon.original",
  // the scrolling element around the page's svg#map
  find: (document) => (document.getElementById("map")?.parentNode ?? null) as HTMLElement | null,
  texts: { original: "addon.map_original", ours: "addon.map_ours", failed: "addon.failed" },
  stage: { position: "relative", width: "100%", height: "80vh", minHeight: "400px" },
};

const MARKET: View = {
  key: "oe.addon.market_original",
  find: (document) => document.querySelector<HTMLElement>("[data-oe-market]"),
  texts: { original: "addon.market_original", ours: "addon.market_ours", failed: "addon.market_failed" },
  stage: { position: "relative", width: "100%", overflow: "auto" },
};

export const attachMap = (document: Document, storage: Store, onShow?: () => void): Placed => attach(MAP, document, storage, onShow);
export const attachMarket = (document: Document, storage: Store, onShow?: () => void): Placed => attach(MARKET, document, storage, onShow);

function attach(view: View, document: Document, storage: Store, onShow?: () => void): Placed {
  const make = (tag: string, style: Record<string, string>) => {
    const el = document.createElement(tag);
    Object.assign(el.style, style);
    return el;
  };
  // A width of its own: where the page lets the map's column shrink to its content (Game tab), it takes the room.
  const box = make("div", { width: "100vw", maxWidth: "100%" });
  const bar = make("div", { display: "flex", gap: "0.5rem", alignItems: "center", margin: "0.5rem 0 0 0" });
  const button = make("button", { padding: "0.35rem 0.8rem", cursor: "pointer" }) as HTMLButtonElement;
  const note = make("span", {});
  const stage = make("div", view.stage);
  button.setAttribute("type", "button");
  bar.append(button, note);
  box.append(bar, stage);

  let failed: string | null = null;
  let lost: string | null = null;
  let page: HTMLElement | null = null;
  const read = () => { try { return storage.getItem(view.key) === "1"; } catch { return false; } };
  let original = read();
  const broken = () => failed ?? lost;
  const showing = () => broken() === null && !original;

  function apply() {
    const reason = broken();
    set(note, "textContent", reason === null ? "" : txt(view.texts.failed).text.replace("{reason}", reason));
    set(button.style, "display", reason === null ? "" : "none");
    if (page) set(page.style, "display", showing() ? "none" : "");
    set(stage.style, "display", showing() ? "" : "none");
    set(button, "textContent", txt(showing() ? view.texts.original : view.texts.ours).text);
  }

  button.onclick = () => {
    original = !original;
    try { storage.setItem(view.key, original ? "1" : "0"); } catch { /* not remembered */ }
    apply();
    onShow?.();
  };

  return {
    box, stage, showing,
    sync() {
      const scroller = view.find(document);
      if (page && page !== scroller) set(page.style, "display", "");
      page = scroller;
      if (!scroller?.parentNode) {
        if (box.parentNode) box.remove();
        return false;
      }
      if (box.parentNode !== scroller.parentNode || box.nextSibling !== scroller) scroller.parentNode.insertBefore(box, scroller);
      apply();
      return true;
    },
    fail(message) {
      failed = message;
      apply();
    },
    lose(reason) {
      lost = reason;
      apply();
    },
    remove() {
      if (page) set(page.style, "display", "");
      page = null;
      if (box.parentNode) box.remove();
    },
  };
}
