// The map on its own (#613): the entry of the standalone bundle (build-standalone.mjs). No server, no panels,
// no page theme; geometry (GET /map as a file) and board are handed in.
//
// "pixi.js/unsafe-eval" replaces PixiJS's generated shader code, so the map also runs where the page's content
// security policy forbids eval (18xx.games).
import "pixi.js/unsafe-eval";
import { themeById } from "../themes/index.ts";
import { badgeOf, boardState, type Board, type BoardCompany } from "./board.ts";
import { mountMap, type MapView } from "./map.ts";
import type { MapGeometry } from "./mapdata.ts";
import { renderTheme, type RenderTheme } from "./theme.ts";

export type { Board } from "./board.ts";

export interface StandaloneMap {
  view: MapView;
  setBoard(board: Board): void;
}

/** Text drawn into the canvas needs its font loaded first, else the first frame keeps the fallback. */
async function loadFonts(theme: RenderTheme): Promise<void> {
  const wanted = Object.values(theme.font).flatMap((family) => [`400 12px ${family}`, `700 12px ${family}`]);
  await Promise.all(wanted.map((font) => document.fonts.load(font).catch(() => [])));
}

export async function mount(el: HTMLElement, geometry: MapGeometry, board?: Board, themeId?: string): Promise<StandaloneMap> {
  const found = themeById(themeId);
  const theme = renderTheme({ theme: found, tileStyle: found.shape.tileStyle });
  await loadFonts(theme);
  // tokens as 18xx.games draws them, in the colours the board brings (#618)
  let companies: BoardCompany[] = [];
  const view = await mountMap(el, geometry, { theme: () => theme, badge: (corp) => badgeOf(companies, corp) });
  const setBoard = (next: Board) => {
    const state = boardState(next);
    companies = next.corporations;
    view.setState(state);
  };
  if (board) setBoard(board);
  return { view, setBoard };
}
