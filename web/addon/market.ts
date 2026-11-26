// Our price board (Kurstafel) in the page of 18xx.games (#619): the web UI's grid, read-only, with the companies
// as seals in their 18xx colours. It lives in a shadow tree, so our styles and the page's do not meet.
import { badgeOf, type Board } from "../render/board.ts";
import { themeVars } from "../themes/css.ts";
import { themeById } from "../themes/index.ts";
import type { Game } from "../types.ts";
import { toDom, type VNode } from "../ui/kit/vnode.ts";
import { marketModel } from "../ui/panels/stock-model.ts";
import { marketGridNode, type SheetInput } from "../ui/panels/stock-sheet.ts";

/** `cellList` is the "row,col" of the open company list; `onCell` asks to open one, or to close it (null). */
export function boardNode(board: Board, cellList: string | null = null, onCell: (cell: string | null) => void = () => {}): VNode {
  const g = { viewer: null, state: { market: board.market ?? { rows: [] }, corporations: board.corporations } } as unknown as Game;
  const input: SheetInput = {
    g, theme: themeById(undefined), rows: [], market: marketModel(g, [], null, null), focus: null, sel: null, tab: "market",
    mode: "buy", must: null, cellList,
    colorOf: (id) => {
      const badge = badgeOf(board.corporations, id);
      return badge && `#${badge.color.toString(16).padStart(6, "0")}`;
    },
  };
  return marketGridNode(input, {
    onCell: (row, col) => onCell(`${row},${col}`), onClose: () => onCell(null),
    onFocus: () => {}, onSell: () => {}, onPick: () => {}, onTab: () => {},
  });
}

/** The web UI's stylesheets for the shadow tree: its root is ours, the theme's variables sit there. */
export function boardStyles(css: string): string {
  const theme = themeById(undefined);
  const variables = themeVars(theme).map(([name, value]) => `${name}: ${value};`).join(" ");
  const own = css.replace(/^body:has[^{]*\{[^}]*\}/gm, "").replace(/^body\b/gm, ":host").replace(/:root/g, ":host");
  // the web UI's stage fills a positioned area; here the board sits in the page's flow and brings its height
  return `${own}\n:host { display: block; min-height: 0; color-scheme: ${theme.colorScheme}; ${variables} }\n` +
    ".stock-stage { position: relative; inset: auto; }\n" +
    // flat like the map's markers; the clipping row of seals cut their soft shadow into a grey square
    ".stock-cell-corps .kit-seal { box-shadow: none; }\n";
}

export function mountMarket(stage: HTMLElement, styles: string): { setBoard(board: Board): void } {
  const root = stage.shadowRoot ?? stage.attachShadow({ mode: "open" });
  const style = document.createElement("style");
  style.textContent = styles;
  const holder = document.createElement("div");
  holder.style.position = "relative";
  root.replaceChildren(style, holder);
  let board: Board | null = null;
  let cell: string | null = null;
  const draw = () => {
    if (board) holder.replaceChildren(toDom(boardNode(board, cell, (next) => { cell = next; draw(); })));
  };
  return { setBoard(next) { board = next; draw(); } };
}
