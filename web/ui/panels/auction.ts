// The auction panel (#46, ui-spec 4.2): the opening packet as a sheet in the main area, bid and buy through
// the order sentence and main button of the action bar (#213), pass as a side button. It claims `bid` and
// `pass` of the WaterfallAuction step so the generic bar does not offer them twice. Choosing a lot only
// selects; the main button sends (owner decision #137, no undo).
import { choiceFromRoot } from "../../themes/choice.ts";
import type { Game } from "../../types.ts";
import type { GameFrame } from "../frame/frame.ts";
import { Geld, toDom } from "../kit/index.ts";
import { txt } from "../text.ts";
import { AUCTION_STEP, openingModel, orderModel, passAction, sheetModel, type Selection } from "./auction-model.ts";
import { openingNode, sheetNode, type SheetHandlers } from "./auction-sheet.ts";

const theme = () => choiceFromRoot(document.documentElement).theme;

/** Mounts the panel into a game frame; returns the function that takes it out again. */
export function mountAuction(frame: GameFrame): () => void {
  let game: Game | null = null;
  let seq = -1;
  let sel: Selection | null = null;
  let host: HTMLElement | null = null;
  let releaseOrder: (() => void) | null = null;
  let releaseAuctionView: (() => void) | null = null;
  const releaseClaims = [frame.claims.claim(AUCTION_STEP, "bid"), frame.claims.claim(AUCTION_STEP, "pass")];

  const handlers: SheetHandlers = {
    onSelect(id) {
      const range = game?.state.prompt.ranges.find((r) => r.type === "bid" && r.company === id);
      if (!range) return;
      sel = { id, amount: String(range.min) };
      draw();
      syncOrder();
      host?.querySelector<HTMLInputElement>(".auction-bidform input")?.focus();
    },
    onAmount(value) {
      if (!sel) return;
      sel = { ...sel, amount: value };
      syncOrder();
      // Only the hint line follows the input; redrawing the sheet would take the focus from the field.
      const hint = host?.querySelector<HTMLElement>("#auction-amount-hint");
      const input = host?.querySelector<HTMLInputElement>(".auction-bidform input");
      if (hint && input && game) {
        const bad = orderModel(game, sel).action === null;
        hint.dataset.bad = bad ? "true" : "false";
        hint.className = bad ? "msg-error" : "muted";
        input.setAttribute("aria-invalid", bad ? "true" : "false");
      }
    },
  };

  function drawSheet(container: HTMLElement) {
    host = container;
    const g = game;
    const m = g ? sheetModel(g, sel?.id ?? null) : null;
    if (!g || !m) { container.replaceChildren(); return; }
    container.replaceChildren(toDom(sheetNode(m, g, sel, theme(), handlers)));
  }
  function drawOpening(container: HTMLElement) {
    host = container;
    container.replaceChildren(game ? toDom(openingNode(openingModel(game), theme())) : "");
  }
  function draw() {
    if (host && frame.views.activeId === "auction") drawSheet(host);
  }

  function syncOrder() {
    const g = game;
    const active = g !== null && g.state.prompt.step === AUCTION_STEP && g.state.auction !== null && g.state.prompt.viewer_to_act;
    if (!g || !active) { releaseOrder?.(); releaseOrder = null; return; }
    const o = orderModel(g, sel);
    const pass = passAction(g);
    const running = g.state.auction?.current != null;
    releaseOrder = frame.setOrder({
      sentence: o.sentence,
      changes: o.changes.map((c) => ({ label: c.label, before: Geld(c.before), after: Geld(c.after) })),
      state: o.state, reason: o.reason, confirmLabel: o.confirmLabel,
      onConfirm: () => { if (o.action) frame.send(o.action); },
      side: pass ? [{
        label: txt("auction.pass").de,
        reason: running ? txt("auction.pass_running_tip").de : txt("auction.pass_tip").de,
        onClick: () => frame.send(pass),
      }] : [],
    });
  }

  const stop = frame.subscribe((g) => {
    game = g;
    if (g.seq !== seq) { seq = g.seq; sel = null; }
    const range = sel ? g.state.prompt.ranges.find((r) => r.type === "bid" && r.company === sel!.id) : undefined;
    if (sel && !range) sel = null;
    // A running auction has exactly one lot to bid on: preselect it.
    const cur = g.state.auction?.current;
    if (!sel && cur && g.state.prompt.viewer_to_act) {
      const r = g.state.prompt.ranges.find((x) => x.type === "bid" && x.company === cur);
      if (r) sel = { id: cur, amount: String(r.min) };
    }
    const active = g.state.prompt.step === AUCTION_STEP && g.state.auction !== null;
    if (active && !releaseAuctionView) {
      releaseAuctionView = frame.views.register({ id: "auction", labelKey: "auction.view", render: ({ container }) => drawSheet(container) });
      frame.views.activate("auction");
    } else if (!active && releaseAuctionView) {
      releaseAuctionView(); releaseAuctionView = null;
    }
    syncOrder();
  });
  const releaseOpening = frame.views.register({ id: "opening", labelKey: "auction.view_opening", render: ({ container }) => drawOpening(container) });

  return () => {
    stop(); releaseOpening(); releaseAuctionView?.(); releaseOrder?.(); releaseClaims.forEach((f) => f());
  };
}
