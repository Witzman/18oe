// The add-on's content script (#614): world MAIN, from document_start. Shows our map (#614) and price board
// (#619) instead of the page's in 18OE games and follows the game; the page's own come back when it cannot (#627).
// Read-only.
import fonts from "oe:fonts";
import marketCss from "oe:market-css";
import { mount } from "../render/standalone.ts";
import { readGeometry } from "./geometry.ts";
import { boardStyles, mountMarket } from "./market.ts";
import { followGame, installMarketTag } from "./page.ts";
import { createViews } from "./views.ts";

/** Only the full game: the UK-France scenario is not tried. */
const TITLE = "18OE";

/** The page's policy allows no font files of ours; fonts handed over as bytes are no request. */
let fontsAdded = false;
function addFonts(): void {
  if (fontsAdded) return;
  fontsAdded = true;
  for (const face of fonts) {
    const bytes = Uint8Array.from(atob(face.data), (c) => c.charCodeAt(0));
    document.fonts.add(new FontFace(face.family, bytes, { weight: face.weight, style: face.style, unicodeRange: face.unicodeRange }));
  }
}

function run(Opal: any): void {
  const views = createViews({
    document,
    storage: window.localStorage,
    frame: (draw) => { requestAnimationFrame(draw); },
    map: (stage, game, first) => {
      addFonts();
      return mount(stage, readGeometry(Opal, game), first);
    },
    market: (stage) => {
      addFonts();
      return mountMarket(stage, boardStyles(marketCss));
    },
  });

  // the page's market view arrives after the UI library: ask after each of its scripts, and before each board
  const tagMarketView = () => installMarketTag(Opal, TITLE);
  if (!tagMarketView()) document.addEventListener("load", tagMarketView, true);
  followGame(Opal, TITLE, { ...views, show: (board, game) => { tagMarketView(); views.show(board, game); } });
  new MutationObserver(views.refresh).observe(document.documentElement, { childList: true, subtree: true });
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
