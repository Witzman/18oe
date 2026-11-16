// The stock sheet panel (#47, ui-spec 4.4): the view "Markt" in the main area. A corporation card opens a dialog to buy
// or found (#408), a share of the viewer's own opens the dialog to sell (#407); the order and its main button are in
// the dialog, pass is a button in the head. It claims `buy_shares`, `sell_shares`, `par` and `pass` of the stock step;
// everything else of the step (convert, choose, trades) stays in the generic bar. Choosing only selects; the main
// button sends (owner decision #137, no undo).
import { choiceFromRoot } from "../../themes/choice.ts";
import type { Game } from "../../types.ts";
import type { GameFrame } from "../frame/frame.ts";
import { toDom } from "../kit/index.ts";
import { corpRows, marketModel, mustSell, offerOf, orderModel, passAction, STOCK_STEP, STOCK_TYPES, type Mode, type Selection, type Tab } from "./stock-model.ts";
import { sheetNode, type SheetHandlers } from "./stock-sheet.ts";

const theme = () => choiceFromRoot(document.documentElement).theme;
export const MARKET_VIEW = "market";

/** Mounts the panel into a game frame; returns the function that takes it out again. */
export function mountStock(frame: GameFrame): () => void {
  let game: Game | null = null;
  let seq = -1;
  let sel: Selection | null = null;
  let focus: string | null = null;
  let mode: Mode = "buy";
  let tab: Tab = "stock";
  let wasStock = false;
  let host: HTMLElement | null = null;
  const releaseClaims = STOCK_TYPES.map((t) => frame.claims.claim(STOCK_STEP, t));

  const open = (corp: string, m: Mode) => { frame.discardSelection(); focus = corp; mode = m; sel = null; draw(); };
  const handlers: SheetHandlers = {
    onFocus: (corp) => open(corp, "buy"),
    onSell: (corp) => open(corp, "sell"),
    onPick(corp, key) {
      // A selection here replaces one made in the generic bar.
      frame.discardSelection();
      focus = corp;
      sel = sel?.corp === corp && sel.key === key ? null : { corp, key };
      draw();
    },
    onTab(t) { tab = t; focus = null; sel = null; draw(); },
    onClose() { focus = null; sel = null; draw(); },
    onConfirm() {
      const a = game ? orderModel(game, corpRows(game), sel).action : null;
      if (a) frame.send(a);
    },
    onPass() {
      const pass = game ? passAction(game) : null;
      if (pass) frame.send(pass);
    },
  };

  const inputOf = (g: Game, rows: ReturnType<typeof corpRows>) => ({ g, theme: theme(), rows, market: marketModel(g, rows, focus, sel), focus, sel, tab, mode, must: mustSell(g) });

  function draw() {
    const el = host;
    const g = game;
    if (!el || !g || frame.views.activeId !== MARKET_VIEW) return;
    const rows = corpRows(g);
    if (sel && !offerOf(rows, sel)) sel = null;
    if (focus && !rows.some((r) => r.id === focus)) focus = null;
    // Redrawing replaces the elements: keep the scroll position of the lists and the keyboard focus.
    const scroll = [".stock-list", ".stock-grid-scroll"].map((s) => el.querySelector<HTMLElement>(s)?.scrollTop ?? 0);
    const active = document.activeElement instanceof HTMLElement && el.contains(document.activeElement) ? document.activeElement : null;
    const key = active ? { corp: active.closest<HTMLElement>("[data-corp]")?.dataset.corp, offer: active.dataset.key, tab: active.dataset.tab, hold: active.classList.contains("stock-hold") } : null;
    const tree = sheetNode(inputOf(g, rows), handlers);
    el.replaceChildren(toDom(tree));
    [".stock-list", ".stock-grid-scroll"].forEach((s, i) => { const n = el.querySelector<HTMLElement>(s); if (n) n.scrollTop = scroll[i]!; });
    const dialog = el.querySelector<HTMLElement>(".kit-dialog");
    if (dialog) {
      // The dialog takes the focus (first offer, else its first button); closing it returns to the card or share that opened it.
      const next = (key?.offer ? dialog.querySelector<HTMLElement>(`[data-key="${CSS.escape(key.offer)}"]`) : null) ?? dialog.querySelector<HTMLElement>("button");
      if (!dialog.contains(document.activeElement)) next?.focus();
      return;
    }
    if (key) {
      const next = (key.tab ? el.querySelector<HTMLElement>(`[data-tab="${key.tab}"][role="tab"]`) : null)
        ?? (key.corp ? el.querySelector<HTMLElement>(`[data-corp="${CSS.escape(key.corp)}"] .stock-rowbtn, .stock-hold[data-corp="${CSS.escape(key.corp)}"]`) : null);
      next?.focus();
    }
  }

  const stop = frame.subscribe((g) => {
    game = g;
    // A new state closes the dialog: the action was sent (or the turn moved on).
    if (g.seq !== seq) { seq = g.seq; sel = null; focus = null; }
    const inStock = g.state.prompt.step === STOCK_STEP && !g.state.meta.finished;
    // The sheet replaces the map while a stock round is on (G7); the player may go back with the tab "Karte".
    if (inStock && !wasStock) frame.views.activate(MARKET_VIEW);
    // Back to the map when the operating round begins (the tab "Markt" stays for reading).
    if (!inStock && wasStock && frame.views.activeId === MARKET_VIEW) frame.views.activate("map");
    wasStock = inStock;
  });
  const releaseView = frame.views.register({ id: MARKET_VIEW, labelKey: "stock.view", render: ({ container }) => { host = container; draw(); } });

  return () => { stop(); releaseView(); releaseClaims.forEach((f) => f()); };
}
