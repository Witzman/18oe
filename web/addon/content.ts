// The add-on's content script (#614): world MAIN, from document_start. Shows our map instead of the page's map
// in 18OE games and follows the game. Read-only.
import fonts from "oe:fonts";
import geometry from "oe:geometry";
import type { Board } from "../render/board.ts";
import { mount, type StandaloneMap } from "../render/standalone.ts";
import { installHook, readBoard, type PageGame } from "./page.ts";
import { attachMap, type Placed } from "./place.ts";

/** Only the full game: the UK-France variant has another map than the one inside this build. */
const TITLE = "18OE";

/** The page's policy allows no font files of ours; fonts handed over as bytes are no request. */
function addFonts(): void {
  for (const face of fonts) {
    const bytes = Uint8Array.from(atob(face.data), (c) => c.charCodeAt(0));
    document.fonts.add(new FontFace(face.family, bytes, { weight: face.weight, style: face.style, unicodeRange: face.unicodeRange }));
  }
}

function run(Opal: any): void {
  let board: Board | null = null;
  let drawn: Board | null = null;
  let map: StandaloneMap | null = null;
  let mounting = false;
  let placed: Placed | null = null;
  let queued = false;
  let updates = 0;

  // for tests and bug reports: how often the map took a new board, and how many hexes it holds
  const note = (shown: Board) => Object.assign(placed!.stage.dataset, { updates: String(++updates), hexes: String(shown.map.length) });

  async function update() {
    if (!board) return;
    placed ??= attachMap(document, window.localStorage, schedule);
    if (!placed.sync() || !placed.showing() || mounting) return;
    try {
      if (!map) {
        mounting = true;
        addFonts();
        const first = board;
        map = await mount(placed.stage, geometry, first);
        drawn = first;
        mounting = false;
        note(first);
        if (board !== drawn) schedule();
      } else if (board !== drawn) {
        map.setBoard(board);
        drawn = board;
        note(board);
      }
    } catch (error) {
      console.warn("18OE map", error);
      placed.fail(String((error as Error)?.message ?? error));
    }
  }

  function schedule() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; void update(); });
  }

  installHook(Opal, (game: PageGame) => {
    if (String(game.$class().$title()) !== TITLE) return;
    board = readBoard(Opal, game);
    schedule();
  });
  new MutationObserver(() => { if (board) schedule(); }).observe(document.documentElement, { childList: true, subtree: true });
}

// The page's scripts come after us; a script's load event fires right after it ran, before the next one (which
// starts the app).
function whenReady(): boolean {
  const Opal = (window as any).Opal;
  if (!Opal?.Snabberb?.Component) return false;
  document.removeEventListener("load", whenReady, true);
  clearInterval(timer);
  if (!started) { started = true; run(Opal); }
  return true;
}
let started = false;
let tries = 0;
const timer = setInterval(() => { if (whenReady() || ++tries > 600) clearInterval(timer); }, 50);
document.addEventListener("load", whenReady, true);
whenReady();
