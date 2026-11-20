// The stock sheet panel (#47, ui-spec 4.4): the view "Markt" in the main area. A corporation card opens a dialog to buy
// or found (#408), a share of the viewer's own opens the dialog to sell (#407); the order and its main button are in
// the dialog. It claims `buy_shares`, `sell_shares` and `par` of the stock step; the action row of the sheet (#527, was the box of #497 S3) leads by KIND
// (float, buy, sell; pass, merger, trade and the like open in a dialog of the frame) and filters the cards to the kind;
// the kind the player is in is read from the frame (`frame.kinds.current()`), never kept here, and the sheet then
// shows only the cards and offers of that kind. Everything else of the step (convert, choose, trades) stays in the generic bar. Choosing only selects; the main
// button sends (owner decision #137, no undo).
import { choiceFromRoot } from "../../themes/choice.ts";
import type { Game } from "../../types.ts";
import type { GameFrame } from "../frame/frame.ts";
import { toDom } from "../kit/index.ts";
import type { Kind } from "../frame/kinds.ts";
import { corpRows, isMarketKind, MARKET_KINDS, marketModel, mustSell, offerOf, orderModel, STOCK_STEP, STOCK_TYPES, type Mode, type Selection, type Tab } from "./stock-model.ts";
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
  let cellList: string | null = null;
  let wasStock = false;
  let host: HTMLElement | null = null;
  let lastKind: Kind | null = null;
  const releaseClaims = STOCK_TYPES.map((t) => frame.claims.claim(STOCK_STEP, t));

  // The mode follows the kind of the box; without a kind (step 1) the card opens buying, the share of the viewer selling.
  const modeOf = (k: Kind | null, m: Mode): Mode => (isMarketKind(k) ? (k === "sell" ? "sell" : "buy") : m);
  const open = (corp: string, m: Mode) => { frame.discardSelection(); cellList = null; focus = corp; mode = m; sel = null; draw(); };
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
    onTab(t) { tab = t; focus = null; sel = null; cellList = null; draw(); },
    onCell(row, col) { frame.discardSelection(); focus = null; sel = null; cellList = `${row},${col}`; draw(); },
    onClose() { focus = null; sel = null; cellList = null; draw(); },
    onKind(kind) { frame.kinds.choose(kind); },
    onConfirm() {
      const a = game ? orderModel(game, corpRows(game), sel).action : null;
      if (a) frame.send(a);
    },
  };

  const inputOf = (g: Game, rows: ReturnType<typeof corpRows>, kind: Kind | null) => ({ g, theme: theme(), rows, market: marketModel(g, rows, focus, sel), focus, sel, tab, mode: modeOf(kind, mode), must: mustSell(g), cellList, kind, kinds: frame.kinds.available() });

  function draw() {
    const el = host;
    const g = game;
    if (!el || !g || frame.views.activeId !== MARKET_VIEW) return;
    const rows = corpRows(g);
    // The player changed the kind in the box (or back to step 1): what was open belongs to the kind left.
    const kind = frame.kinds.current();
    if (kind !== lastKind) { lastKind = kind; focus = null; sel = null; cellList = null; }
    if (sel && !offerOf(rows, sel)) sel = null;
    if (focus && !rows.some((r) => r.id === focus)) focus = null;
    // Redrawing replaces the elements: keep the scroll position of the lists and the keyboard focus.
    const scroll = [".stock-list", ".stock-grid-scroll"].map((s) => el.querySelector<HTMLElement>(s)?.scrollTop ?? 0);
    const active = document.activeElement instanceof HTMLElement && el.contains(document.activeElement) ? document.activeElement : null;
    const key = active ? { corp: active.closest<HTMLElement>("[data-corp]")?.dataset.corp, offer: active.dataset.key, tab: active.dataset.tab, hold: active.classList.contains("stock-hold") } : null;
    const tree = sheetNode(inputOf(g, rows, kind), handlers);
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
    if (g.seq !== seq) { seq = g.seq; sel = null; focus = null; cellList = null; }
    const inStock = g.state.prompt.step === STOCK_STEP && !g.state.meta.finished;
    // The sheet replaces the map while a stock round is on (G7); the player may go back with the tab "Karte".
    if (inStock && !wasStock) frame.views.activate(MARKET_VIEW);
    // Back to the map when the operating round begins (the tab "Markt" stays for reading).
    if (!inStock && wasStock && frame.views.activeId === MARKET_VIEW) frame.views.activate("map");
    wasStock = inStock;
  });
  // The sheet draws the market kinds itself (cards and dialog), so the box has no options for them; providing the kinds keeps
  // their actions claimed and counted. The kind row of the sheet replaces the box in the stock round (#527).
  const releaseKinds = MARKET_KINDS.map((k) => frame.kinds.provide(k, () => []));
  const releaseRow = frame.kinds.useRow();
  // Choosing a market kind in the box brings the sheet forward; the sheet redraws for the kind.
  const stopKinds = frame.kinds.subscribe(() => {
    // The same kinds occur in the concession step (#497 S4), which has its own panel: the sheet stays out of it.
    if (game?.state.prompt.step === STOCK_STEP && isMarketKind(frame.kinds.current()) && frame.views.activeId !== MARKET_VIEW) frame.views.activate(MARKET_VIEW);
    draw();
  });
  const releaseView = frame.views.register({ id: MARKET_VIEW, labelKey: "stock.view", render: ({ container }) => { host = container; draw(); } });

  return () => { stop(); stopKinds(); releaseKinds.forEach((f) => f()); releaseRow(); releaseView(); releaseClaims.forEach((f) => f()); };
}
