// Putting our map where the page's map is (#614): a box right before the scrolling element around svg#map, which
// is hidden while ours shows. The switch brings the page's map back, for the actions that need it. The page
// redraws and replaces its elements at will, so `sync` runs after every change and does nothing when in place.

import { txt } from "../ui/text.ts";

const KEY = "oe.addon.original";

export interface Placed {
  /** Bar (switch and note) and stage. */
  box: HTMLElement;
  /** Where the map is mounted. */
  stage: HTMLElement;
  /** Puts the box in place; false when the page shows no map. */
  sync(): boolean;
  /** Our map is on screen (false: the player switched to the page's map, or ours failed). */
  showing(): boolean;
  /** Ours cannot be drawn: say why and leave the page's map. */
  fail(message: string): void;
}

// Assign only on a change: each write is a DOM mutation, and mutations trigger the next sync.
function set<T, K extends keyof T>(target: T, key: K, value: T[K]): void {
  if (target[key] !== value) target[key] = value;
}

export function attachMap(document: Document, storage: Pick<Storage, "getItem" | "setItem">, onShow?: () => void): Placed {
  const make = (tag: string, style: Record<string, string>) => {
    const el = document.createElement(tag);
    Object.assign(el.style, style);
    return el;
  };
  const box = make("div", {});
  const bar = make("div", { display: "flex", gap: "0.5rem", alignItems: "center", margin: "0.5rem 0 0 0" });
  const button = make("button", { padding: "0.35rem 0.8rem", cursor: "pointer" }) as HTMLButtonElement;
  const note = make("span", {});
  const stage = make("div", { position: "relative", width: "100%", height: "80vh", minHeight: "400px" });
  button.setAttribute("type", "button");
  bar.append(button, note);
  box.append(bar, stage);

  let failed = false;
  let page: HTMLElement | null = null;
  const read = () => { try { return storage.getItem(KEY) === "1"; } catch { return false; } };
  let original = read();
  const showing = () => !failed && !original;

  function apply() {
    if (page) set(page.style, "display", showing() ? "none" : "");
    set(stage.style, "display", showing() ? "" : "none");
    set(button, "textContent", txt(showing() ? "addon.map_original" : "addon.map_ours").text);
  }

  button.onclick = () => {
    original = !original;
    try { storage.setItem(KEY, original ? "1" : "0"); } catch { /* not remembered */ }
    apply();
    onShow?.();
  };

  return {
    box, stage, showing,
    sync() {
      const scroller = (document.getElementById("map")?.parentNode ?? null) as HTMLElement | null;
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
      failed = true;
      note.textContent = txt("addon.failed").text.replace("{reason}", message);
      apply();
    },
  };
}
