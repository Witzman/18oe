// The stock sheet panel (#47, ui-spec 4.4): the view "Markt" in the main area, buy / sell / par through the
// order sentence and main button of the action bar (#213), pass as a side button. It claims `buy_shares`,
// `sell_shares`, `par` and `pass` of the stock step; everything else of the step (convert, choose, trades)
// stays in the generic bar. Choosing only selects; the main button sends (owner decision #137, no undo).
import { choiceFromRoot } from "../../themes/choice.ts";
import type { Game } from "../../types.ts";
import type { GameFrame } from "../frame/frame.ts";
import { Geld, toDom } from "../kit/index.ts";
import { txt } from "../text.ts";
import { corpRows, marketModel, mustSell, offerOf, orderModel, passAction, STOCK_STEP, STOCK_TYPES, type Selection } from "./stock-model.ts";
import { sheetNode, type SheetHandlers, type Tab } from "./stock-sheet.ts";

const theme = () => choiceFromRoot(document.documentElement).theme;
export const MARKET_VIEW = "market";

/** Mounts the panel into a game frame; returns the function that takes it out again. */
export function mountStock(frame: GameFrame): () => void {
  let game: Game | null = null;
  let seq = -1;
  let sel: Selection | null = null;
  let focus: string | null = null;
  let tab: Tab = "list";
  let wasStock = false;
  let host: HTMLElement | null = null;
  let releaseOrder: (() => void) | null = null;
  const releaseClaims = STOCK_TYPES.map((t) => frame.claims.claim(STOCK_STEP, t));

  const handlers: SheetHandlers = {
    onFocus(corp) { focus = focus === corp ? null : corp; if (sel && sel.corp !== focus) sel = null; refresh(); },
    onPick(corp, key) {
      // A selection here replaces one made in the generic bar.
      frame.discardSelection();
      focus = corp;
      sel = sel?.corp === corp && sel.key === key ? null : { corp, key };
      refresh();
    },
    onTab(t) { tab = t; draw(); },
    onMap() { frame.views.activate("map"); },
  };

  function draw() {
    const el = host;
    const g = game;
    if (!el || !g || frame.views.activeId !== MARKET_VIEW) return;
    const rows = corpRows(g);
    if (sel && !offerOf(rows, sel)) sel = null;
    // Redrawing replaces the elements: keep the scroll position of the lists and the keyboard focus.
    const scroll = [".stock-list", ".stock-grid-scroll"].map((s) => el.querySelector<HTMLElement>(s)?.scrollTop ?? 0);
    const active = document.activeElement instanceof HTMLElement && el.contains(document.activeElement) ? document.activeElement : null;
    const key = active ? { corp: active.closest<HTMLElement>("[data-corp]")?.dataset.corp, offer: active.dataset.key, tab: active.dataset.tab } : null;
    const tree = sheetNode({ g, theme: theme(), rows, market: marketModel(g, rows, focus, sel), focus, sel, tab, must: mustSell(g) }, handlers);
    el.replaceChildren(toDom(tree));
    [".stock-list", ".stock-grid-scroll"].forEach((s, i) => { const n = el.querySelector<HTMLElement>(s); if (n) n.scrollTop = scroll[i]!; });
    if (key) {
      const next = (key.offer ? el.querySelector<HTMLElement>(`[data-key="${CSS.escape(key.offer)}"]`) : null)
        ?? (key.tab ? el.querySelector<HTMLElement>(`[data-tab="${key.tab}"][role="tab"]`) : null)
        ?? (key.corp ? el.querySelector<HTMLElement>(`[data-corp="${CSS.escape(key.corp)}"] .stock-rowbtn`) : null);
      next?.focus();
    }
  }

  function syncOrder() {
    const g = game;
    const active = g !== null && g.state.prompt.step === STOCK_STEP && g.state.prompt.viewer_to_act && !g.state.meta.finished;
    if (!g || !active) { releaseOrder?.(); releaseOrder = null; return; }
    const rows = corpRows(g);
    const o = orderModel(g, rows, sel);
    const pass = passAction(g);
    releaseOrder = frame.setOrder({
      sentence: o.sentence,
      changes: o.changes.map((c) => ({
        label: c.label,
        before: c.money && typeof c.before === "number" ? Geld(c.before) : String(c.before),
        after: c.money && typeof c.after === "number" ? Geld(c.after) : String(c.after),
      })),
      state: o.state, reason: o.reason, confirmLabel: o.confirmLabel,
      onConfirm: () => { if (o.action) frame.send(o.action); },
      side: pass ? [{ label: txt("stock.pass").de, reason: txt("stock.pass_tip").de, onClick: () => frame.send(pass) }] : [],
    });
  }

  function refresh() { draw(); syncOrder(); }

  const stop = frame.subscribe((g) => {
    game = g;
    if (g.seq !== seq) { seq = g.seq; sel = null; }
    const inStock = g.state.prompt.step === STOCK_STEP && !g.state.meta.finished;
    // The sheet replaces the map while a stock round is on (G7); the player may go back with "Karte".
    if (inStock && !wasStock) frame.views.activate(MARKET_VIEW);
    wasStock = inStock;
    syncOrder();
  });
  const releaseView = frame.views.register({ id: MARKET_VIEW, labelKey: "stock.view", render: ({ container }) => { host = container; draw(); } });

  return () => { stop(); releaseView(); releaseOrder?.(); releaseClaims.forEach((f) => f()); };
}
