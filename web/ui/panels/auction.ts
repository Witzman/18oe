// The auction panel (#46, ui-spec 4.2): the opening packet as a sheet in the main area, bid and buy through
// the order sentence and main button of the action bar (#213), pass as a side button. It claims `bid` and
// `pass` of the WaterfallAuction step so the generic bar does not offer them twice. Choosing a lot only
// selects; the main button sends (owner decision #137, no undo).
import { choiceFromRoot } from "../../themes/choice.ts";
import type { Api } from "../../api.ts";
import type { Catalog, Game } from "../../types.ts";
import type { GameFrame } from "../frame/frame.ts";
import { Geld, toDom } from "../kit/index.ts";
import { AUCTION_STEP, openingModel, orderModel, passAction, sheetModel, type Selection } from "./auction-model.ts";
import { openingNode, sheetNode, type SheetHandlers } from "./auction-sheet.ts";

const theme = () => choiceFromRoot(document.documentElement).theme;

/** Mounts the panel into a game frame; returns the function that takes it out again. */
export function mountAuction(frame: GameFrame, api?: Pick<Api, "catalog">): () => void {
  let catalog: Catalog | null = null;
  // The ability texts come from GET /catalog, loaded once; the sheet shows without them until they arrive.
  api?.catalog().then((c) => { catalog = c; draw(); }, () => {});
  let game: Game | null = null;
  let seq = -1;
  let sel: Selection | null = null;
  let host: HTMLElement | null = null;
  // After Abbrechen the running lot is not preselected again for the same state.
  let dismissedSeq = -1;
  let releaseAuctionView: (() => void) | null = null;
  // While the auction step runs the action panel has nothing to say, so it stays away (#370).
  let releasePanel: (() => void) | null = null;
  const releaseClaims = [frame.claims.claim(AUCTION_STEP, "bid"), frame.claims.claim(AUCTION_STEP, "pass")];

  const handlers: SheetHandlers = {
    onSelect(id) {
      const range = game?.state.prompt.ranges.find((r) => r.type === "bid" && r.company === id);
      if (!range) return;
      sel = { id, amount: String(range.min) };
      draw();
      host?.querySelector<HTMLInputElement>(".auction-bidform input")?.focus();
    },
    onAmount(value) {
      if (!sel) return;
      sel = { ...sel, amount: value };
      // Only the hint, the order sentence and the main button follow the input; redrawing would take the focus from the field.
      const hint = host?.querySelector<HTMLElement>("#auction-amount-hint");
      const input = host?.querySelector<HTMLInputElement>(".auction-bidform input");
      if (hint && input && game) {
        const o = orderModel(game, sel);
        const bad = o.action === null;
        hint.dataset.bad = bad ? "true" : "false";
        hint.className = bad ? "msg-error" : "muted";
        input.setAttribute("aria-invalid", bad ? "true" : "false");
        const main = host?.querySelector<HTMLButtonElement>(".kit-dialog .kit-main-btn");
        const sentence = host?.querySelector<HTMLElement>(".kit-dialog .kit-order-sentence");
        if (main) { main.disabled = bad; main.textContent = o.confirmLabel; }
        if (sentence) sentence.textContent = o.sentence;
        const after = host?.querySelector<HTMLElement>(".kit-dialog .kit-after");
        if (after && o.changes[0]) after.replaceChildren(toDom(Geld(o.changes[0].after)));
      }
    },
    onConfirm() {
      const a = game && sel ? orderModel(game, sel).action : null;
      if (a) frame.send(a);
    },
    onCancel() {
      sel = null;
      dismissedSeq = seq;
      draw();
    },
    onPass() {
      const pass = game ? passAction(game) : null;
      if (pass) frame.send(pass);
    },
  };

  function drawSheet(container: HTMLElement) {
    host = container;
    const g = game;
    const m = g ? sheetModel(g, sel?.id ?? null, catalog) : null;
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

  const stop = frame.subscribe((g) => {
    game = g;
    if (g.seq !== seq) { seq = g.seq; sel = null; }
    const range = sel ? g.state.prompt.ranges.find((r) => r.type === "bid" && r.company === sel!.id) : undefined;
    if (sel && !range) sel = null;
    // A running auction has exactly one lot to bid on: preselect it.
    const cur = g.state.auction?.current;
    if (!sel && cur && g.state.prompt.viewer_to_act && dismissedSeq !== g.seq) {
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
    if (active && !releasePanel) releasePanel = frame.hidePanel();
    else if (!active && releasePanel) { releasePanel(); releasePanel = null; }
  });
  const releaseOpening = frame.views.register({ id: "opening", labelKey: "auction.view_opening", render: ({ container }) => drawOpening(container) });

  return () => {
    stop(); releaseOpening(); releaseAuctionView?.(); releasePanel?.(); releaseClaims.forEach((f) => f());
  };
}
