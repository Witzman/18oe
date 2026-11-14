// The game page frame (#45, ui-spec 3.1 to 3.4): round bar, player bar, context sheet, main area,
// outliner, action bar with the generic action bar. Special panels and views hook in through
// `claims` (which action types they handle), `views` (main area) and `slots` (containers).
import { choiceFromRoot } from "../../themes/choice.ts";
import type { Theme } from "../../themes/schema.ts";
import type { Api } from "../../api.ts";
import type { createSession } from "../../session.ts";
import type { Corporation, Game } from "../../types.ts";
import { connectionBand, messageArea } from "../connection.ts";
import { h } from "../dom.ts";
import { Auftrag, Geld, mitTooltip, Siegel, toDom, v, Wimpel, type VNode } from "../kit/index.ts";
import { THEME_CHANGED } from "../theme-switch.ts";
import { fillText, txt } from "../text.ts";
import { createClaims } from "./claims.ts";
import { createOrderSlot, orderView, type OrderSlot, type OrderSpec } from "./order.ts";
import { actionKey, genericModel, GenericBar, rangeAction, rangeValue, type Action, type Entry, type RangeEntry } from "./generic.ts";
import { OrBandView, orBand } from "./or-band.ts";
import { corpColor, outlinerCorps, playerName, playerRows, roundBar, stallNotice, stepLabel, type PlayerRow } from "./model.ts";
import { createViews } from "./views.ts";
import { fetchLogFrom, isAtBottom, mergeLog, nextScrollTop, resumeFrom, type LogLine } from "./log.ts";
import { versionButton } from "../version.ts";
import { endgameModel, Endstand } from "../panels/endgame.ts";

export interface GameFrame {
  root: HTMLElement;
  render: (g: Game) => void;
  band: ReturnType<typeof connectionBand>;
  message: ReturnType<typeof messageArea>;
  // Selection of the action bar; the session calls this when the state is stale (#162).
  discardSelection: () => void;
  setBusy: (busy: boolean) => void;
  // Set by main once the poller exists; the action bar sends through it.
  session?: ReturnType<typeof createSession>;
  // Hook points for the following UI issues.
  claims: ReturnType<typeof createClaims>;
  views: ReturnType<typeof createViews>;
  slots: { context: HTMLElement; main: HTMLElement };
  // A special panel sets the order sentence, main button and side buttons of the action bar (#213);
  // returns the release function to call on unmount.
  setOrder: (spec: OrderSpec) => () => void;
  // Sends an action with the current seq (what the main button of the generic bar does).
  send: (action: Record<string, unknown>) => void;
  hooks: { onFocusCorporation?: (id: string) => void; map?: import("./mapview.ts").FrameMap };
  // Runs the cleanups of mounted views and panels when the page leaves the game (the map frees its WebGL context).
  onDispose: (fn: () => void) => void;
  dispose: () => void;
  // Special panels follow the game state: called with every new state before the frame draws it (#46).
  subscribe: (fn: (g: Game) => void) => () => void;
}

type Focus = { kind: "player" | "corporation"; id: string } | null;

const theme = (): Theme => choiceFromRoot(document.documentElement).theme;
const put = (el: Element, ...nodes: (VNode | string | null)[]) =>
  el.replaceChildren(...nodes.filter((n): n is VNode | string => n !== null).map((n) => toDom(n)));

export function createGameFrame(retryNow: () => void = () => {}, api?: Api): GameFrame {
  const claims = createClaims();
  const orderSlot: OrderSlot = createOrderSlot(() => { if (game) drawBar(); });
  const views = createViews([{
    id: "map", labelKey: "frame.view_map",
    render: ({ container }) => { if (container.childElementCount === 0) container.append(h("p", { class: "muted frame-placeholder" }, txt("frame.view_placeholder").de)); },
  }]);
  const band = connectionBand({ retryNow });
  const message = messageArea();

  let game: Game | null = null;
  let selected: Action | null = null;
  let armed = false;
  let busy = false;
  let rangeError: { key: string; text: string } | null = null;
  let focus: Focus = null;
  let outlinerOpen = true;
  let genericOpen: boolean | null = null; // null = automatic (open while there is something to choose)
  let logOpen = false;
  // The full log (#292): fetched from /games/:id/log while the sheet is open; the sheet element lives on
  // between redraws so the reader's scroll position survives.
  let fullLog: LogLine[] = [];
  let fullLogSeq = -1;
  let fullLogLoading = false;
  const logList = h("div", { class: "frame-log-scroll", tabindex: "0" });
  let logScroll = { top: 0, atBottom: true };
  logList.addEventListener("scroll", () => { logScroll = { top: logList.scrollTop, atBottom: isAtBottom(logList.scrollTop, logList.scrollHeight, logList.clientHeight) }; });
  function syncFullLog(g: Game) {
    if (!api || !logOpen || fullLogLoading || fullLogSeq === g.seq) return;
    fullLogLoading = true;
    const seq = g.seq;
    const id = Number(g.state.meta.game_id);
    fetchLogFrom((from) => api.log(id, from), resumeFrom(fullLog))
      .then((lines) => { fullLog = mergeLog(fullLog, lines); fullLogSeq = seq; }, () => {})
      .finally(() => { fullLogLoading = false; if (logOpen && game) { if (fullLogSeq !== game.seq && fullLogSeq === seq) fullLogSeq = -1; drawBar(); } });
  }
  let endOpen = true;
  const frame: GameFrame = {} as GameFrame;
  const listeners = new Set<(g: Game) => void>();
  const disposers: (() => void)[] = [];

  const roundEl = h("header", { class: "frame-roundbar" });
  const playersEl = h("nav", { class: "frame-players", "aria-label": txt("frame.player_bar").de });
  const contextEl = h("aside", { class: "frame-context", "aria-label": txt("frame.context").de });
  const contextSlot = h("div", { class: "frame-context-slot" });
  const mainEl = h("main", { class: "frame-main", "aria-label": txt("frame.main").de });
  const tabsEl = h("div", { class: "frame-tabs", role: "tablist" });
  const viewEl = h("div", { class: "frame-view" });
  const endEl = h("div", { class: "frame-end-slot" });
  mainEl.append(endEl, tabsEl, viewEl);
  const outlinerEl = h("aside", { class: "frame-outliner", "aria-label": txt("frame.outliner").de });
  const drawerEl = h("div", { class: "frame-drawer" });
  const barEl = h("footer", { class: "frame-bar", "aria-label": txt("frame.action_bar").de });
  const barMain = h("div", { class: "frame-bar-order" });
  const barTools = h("div", { class: "frame-bar-tools" });
  // #289: "nobody can act" / "the bot does not move" / "no action offered", never a silent hang.
  const stallEl = h("p", { class: "frame-stall", role: "status", "aria-live": "polite" });
  stallEl.hidden = true;
  barEl.append(barMain, stallEl, message.el, barTools);
  let seqSince = Date.now();
  function drawStall() {
    let n: ReturnType<typeof stallNotice> = null;
    try { n = game ? stallNotice(game, Date.now() - seqSince) : null; } catch (e) { console.warn("stall notice", e); } // a notice never breaks the frame
    const show = n !== null && n.tone !== "info"; // "waiting for X" is already the bar's sentence
    stallEl.hidden = !show;
    stallEl.className = show ? `frame-stall msg-${n!.tone}` : "frame-stall";
    stallEl.dataset.kind = show ? n!.kind : "";
    stallEl.textContent = show ? n!.text : "";
  }
  const stallTimer = setInterval(() => { if (root.isConnected) drawStall(); }, 5000);
  disposers.push(() => clearInterval(stallTimer));
  const body = h("div", { class: "frame-body" }, contextEl, mainEl, outlinerEl);
  const root = h("div", { class: "frame" }, roundEl, band.el, playersEl, body, drawerEl, barEl, versionButton());

  const model = () => (game ? genericModel(game, claims) : null);

  // While an action is in flight every button is locked. Only the buttons this lock disabled are marked and
  // opened again afterwards (#289): the panels redraw when the answer arrives, still inside the lock, and
  // without the mark their fresh buttons stayed disabled until the next seq change. When the same player
  // acts again (a 2nd concession of the same owner, the next step of a run) no seq change came: the game
  // looked hung.
  function applyBusy() {
    root.toggleAttribute("aria-busy", busy);
    if (busy) {
      for (const b of root.querySelectorAll("button")) if (!b.disabled) { b.disabled = true; b.dataset.busyLock = ""; }
    } else {
      for (const b of root.querySelectorAll<HTMLButtonElement>("button[data-busy-lock]")) { b.disabled = false; delete b.dataset.busyLock; }
    }
  }

  // ---- round bar -------------------------------------------------------------------------------
  function drawRound() {
    if (!game) return put(roundEl);
    const t = theme();
    const m = roundBar(game, t);
    const phase = mitTooltip(v("span", { class: "frame-phase" }, m.phase.label),
      { title: m.phase.label, term: "Train phase", rows: [{ label: txt("frame.phase_tiles").de, value: m.phase.tiles }, { label: txt("frame.phase_ors").de, value: String(m.phase.operatingRounds) }], source: txt("frame.phase_tiles").regel });
    put(roundEl,
      v("a", { class: "frame-signet", href: "#/", title: txt("frame.signet_title").de }, "18OE"),
      v("span", { class: "frame-rr", title: txt(`rrphase.${m.rrPhase}`).en }, txt(`rrphase.${m.rrPhase}`).de),
      phase,
      v("span", { class: "frame-round", "aria-current": "step" }, m.round),
      v("div", { class: "frame-who", "data-mine": m.who.mine ? "true" : "false", role: "status" },
        m.who.corp ? Siegel({ sym: m.who.corp.sym, color: m.who.corp.color }, { theme: t, size: "s" }) : null,
        v("span", {}, m.who.text)),
      v("span", { class: "frame-bank" }, `${txt("frame.bank").de} `, Geld(m.bank)));
  }

  // ---- player bar ------------------------------------------------------------------------------
  function playerEntry(p: PlayerRow, t: Theme): VNode {
    const btn = v("button", {
      type: "button", class: "frame-player", "data-me": p.me ? "true" : "false", "data-to-act": p.toAct ? "true" : "false",
      "aria-pressed": String(focus?.kind === "player" && focus.id === p.id),
      onclick: () => { focus = { kind: "player", id: p.id }; outlinerOpen = true; drawOutliner(); drawLayout(); },
    },
    Wimpel({ seat: p.seat, name: p.name }, { theme: t }),
    v("span", { class: "frame-cash" }, Geld(p.cash)),
    v("span", { class: "frame-certs", title: txt("frame.certs_title").de }, fillText("frame.certs", { n: p.certs, limit: p.certLimit })),
    p.priority ? v("span", { class: "frame-star", title: txt("frame.priority").de, "aria-label": txt("frame.priority").de }, "★") : null,
    p.bot ? v("span", { class: "frame-tag" }, txt("frame.bot").de) : null,
    p.toAct ? v("span", { class: "frame-tag frame-tag-act" }, txt("frame.to_act").de) : null);
    return mitTooltip(btn, { title: p.name, term: txt("frame.worth").en, total: { label: txt("frame.worth").de, amount: p.value }, rows: [{ label: txt("frame.cash").de, amount: p.cash }] });
  }
  function drawPlayers() {
    if (!game) return put(playersEl);
    const t = theme();
    put(playersEl, ...playerRows(game).map((p) => playerEntry(p, t)));
  }

  // ---- context sheet ---------------------------------------------------------------------------
  function drawContext() {
    if (!game) return put(contextEl);
    const p = game.state.prompt;
    const entry = p.step ? txt(`step.${p.step}`) : null;
    const rule = entry && entry.regel !== "—" ? entry.regel : null;
    put(contextEl,
      v("h2", {}, roundBar(game, theme()).round),
      (() => { const b = orBand(game, theme()); return b ? OrBandView(b, theme()) : null; })(),
      v("p", { class: "frame-step" }, v("strong", {}, `${txt("frame.step").de}: `), stepLabel(p.step)),
      rule ? v("p", { class: "muted", title: entry?.en }, fillText("frame.rule", { ref: rule })) : null,
      p.types.length > 0 ? v("div", {}, v("strong", {}, txt("frame.allowed").de), v("ul", {}, ...p.types.map((ty) => v("li", { title: txt(`action.${ty}`).en }, txt(`action.${ty}`).de)))) : null);
    contextEl.append(contextSlot);
  }

  // ---- outliner --------------------------------------------------------------------------------
  function corpCard(c: Corporation, t: Theme, g: Game): VNode {
    const open = focus?.kind === "corporation" && focus.id === c.id;
    const head = v("button", {
      type: "button", class: "frame-corp", "aria-expanded": String(open), "data-id": c.id,
      onclick: () => { focus = open ? null : { kind: "corporation", id: c.id }; drawOutliner(); },
    }, Siegel({ sym: c.id, name: c.name, color: corpColor(t, g, c.id) }, { theme: t, size: "s" }),
    v("span", { class: "frame-corp-name" }, c.name),
    v("span", { class: "muted" }, txt(`tier.${c.type}`).de),
    c.share_price !== null ? v("span", {}, Geld(c.share_price)) : null,
    v("span", {}, Geld(c.cash)),
    v("span", { title: txt("frame.trains").de }, `${c.trains.length}×`));
    if (!open) return v("li", {}, head);
    const holders = c.shares.map((s) => `${playerName(g, s.holder)} ${s.percent}%`).join(", ");
    return v("li", {}, head, v("dl", { class: "frame-detail" },
      v("dt", {}, txt("frame.president").de), v("dd", {}, c.president ? playerName(g, c.president) : txt("frame.none").de),
      v("dt", {}, txt("frame.share_price").de), v("dd", {}, c.share_price !== null ? Geld(c.share_price) : txt("frame.none").de),
      v("dt", {}, txt("frame.trains").de), v("dd", {}, c.trains.length > 0 ? c.trains.map((x) => x.name).join(", ") : txt("frame.none").de),
      v("dt", {}, txt("frame.shares").de), v("dd", {}, holders || txt("frame.none").de),
      c.floated ? null : v("dd", { class: "muted" }, txt("frame.not_floated").de)),
    v("button", { type: "button", class: "frame-focus", onclick: () => frame.hooks.onFocusCorporation?.(c.id) }, txt("frame.focus_home").de));
  }
  function drawOutliner() {
    if (!game) return put(outlinerEl);
    const g = game;
    const t = theme();
    const toggle = v("button", {
      type: "button", class: "frame-collapse", "aria-expanded": String(outlinerOpen),
      title: txt(outlinerOpen ? "frame.outliner_collapse" : "frame.outliner_expand").de,
      "aria-label": txt(outlinerOpen ? "frame.outliner_collapse" : "frame.outliner_expand").de,
      onclick: () => { outlinerOpen = !outlinerOpen; drawOutliner(); drawLayout(); },
    }, outlinerOpen ? "▸" : "◂");
    if (!outlinerOpen) return put(outlinerEl, toggle);
    const { shown, hidden } = outlinerCorps(g);
    put(outlinerEl,
      v("div", { class: "frame-outliner-head" }, v("h2", {}, txt("frame.outliner").de), toggle),
      v("h3", {}, txt("frame.players").de),
      v("ul", { class: "frame-list" }, ...playerRows(g).map((p) => {
        const open = focus?.kind === "player" && focus.id === p.id;
        const pl = g.state.players.find((x) => x.id === p.id)!;
        return v("li", {},
          v("button", { type: "button", class: "frame-corp", "aria-expanded": String(open), onclick: () => { focus = open ? null : { kind: "player", id: p.id }; drawOutliner(); } },
            Wimpel({ seat: p.seat, name: p.name }, { theme: t }), v("span", {}, Geld(p.cash)), v("span", { class: "muted" }, fillText("frame.certs", { n: p.certs, limit: p.certLimit }))),
          open ? v("dl", { class: "frame-detail" },
            v("dt", {}, txt("frame.cash").de), v("dd", {}, Geld(p.cash)),
            v("dt", {}, txt("frame.worth").de), v("dd", {}, Geld(p.value)),
            v("dt", {}, txt("frame.shares").de), v("dd", {}, pl.shares.map((s) => `${s.corporation} ${s.percent}%${s.president ? " ★" : ""}`).join(", ") || txt("frame.none").de),
            v("dt", {}, txt("frame.companies").de), v("dd", {}, pl.companies.map((c) => c.name ?? c.id).join(", ") || txt("frame.none").de)) : null);
      })),
      v("h3", {}, txt("frame.corps").de),
      shown.length === 0 ? v("p", { class: "muted" }, txt("frame.corps_empty").de) : v("ul", { class: "frame-list" }, ...shown.map((c) => corpCard(c, t, g))),
      hidden > 0 ? v("p", { class: "muted" }, fillText("frame.corps_hidden", { n: hidden })) : null);
  }

  // ---- main area -------------------------------------------------------------------------------
  function drawMain() {
    const list = views.list;
    put(tabsEl, ...(list.length > 1 ? list.map((d) => v("button", {
      type: "button", role: "tab", "aria-selected": String(d.id === views.activeId),
      onclick: () => views.activate(d.id),
    }, txt(d.labelKey).de)) : []));
    tabsEl.hidden = list.length <= 1;
    views.active?.render({ container: viewEl });
  }
  views.onChange(() => { viewEl.replaceChildren(); drawMain(); });

  // ---- end of game (#176): the final standings above the views; the views and the log stay readable --------
  function drawEnd() {
    endEl.hidden = !game?.state.meta.finished;
    if (!game || !game.state.meta.finished) return put(endEl);
    const g = game;
    put(endEl, Endstand(endgameModel(g), {
      theme: theme(), corpColor: (id) => corpColor(theme(), g, id), open: endOpen,
      onToggle: () => { endOpen = true; drawEnd(); },
      onMap: () => { endOpen = false; drawEnd(); },
      onLog: () => { logOpen = true; drawBar(); },
    }));
  }

  // ---- action bar ------------------------------------------------------------------------------
  function send(a: Action) {
    if (!game || !frame.session || busy) return;
    void frame.session.send(a, game.seq);
  }
  function select(a: Action) { selected = a; armed = false; rangeError = null; drawBar(); }
  function onRange(r: RangeEntry, input: string) {
    if (!game) return;
    const price = rangeValue(r.range, input);
    if (price === null) {
      rangeError = { key: r.key, text: fillText("frame.range_invalid", { min: r.range.min, max: r.range.max, step: r.range.step }) };
      return drawBar();
    }
    select(rangeAction(game, r.range, price));
  }
  function orderSentence(g: Game, m: NonNullable<ReturnType<typeof model>>): string {
    const who = roundBar(g, theme()).who;
    if (g.state.meta.finished || !g.state.prompt.viewer_to_act) return who.text;
    return m.count > 0 ? txt("frame.order_idle").de : txt("frame.order_nothing").de;
  }
  function drawBar() {
    const g = game;
    const m = model();
    if (!g || !m) { put(barMain); put(barTools); return; }
    const danger = selected !== null && (m.groups.flatMap((gr) => gr.entries).find((e) => e.key === actionKey(selected!))?.danger ?? false);
    // A choice in the generic bar (an action no panel claimed) wins over the panel's order until it is dropped.
    if (orderSlot.spec && !selected) {
      put(barMain, orderView(orderSlot.spec, { busy, armed: orderSlot.armed, onArm: () => orderSlot.arm() }));
    } else if (selected) {
      const type = String(selected.type);
      const order = Auftrag({
        sentence: txt(`action.${type}`).de + (danger ? ` ${txt("frame.danger_note").de}` : ""),
        changes: [], state: busy ? "waiting" : "preview",
        confirmLabel: danger && armed ? txt("frame.confirm_danger").de : txt("frame.confirm").de,
        onConfirm: () => { if (danger && !armed) { armed = true; drawBar(); } else send(selected!); },
        onCancel: () => frame.discardSelection(),
      });
      put(barMain, v("p", { class: "frame-detailline" }, genericDetail(g, selected)), order);
    } else {
      put(barMain, v("p", { class: "frame-sentence" }, orderSentence(g, m)));
    }
    const mine = g.state.prompt.viewer_to_act;
    const showGeneric = mine && (m.count > 0 || m.unsupported.length > 0);
    const open = genericOpen ?? showGeneric;
    put(barTools,
      showGeneric ? v("button", { type: "button", class: "frame-toggle", "aria-expanded": String(open), onclick: () => { genericOpen = !open; drawBar(); } }, fillText("frame.generic_open", { n: m.count })) : null,
      v("button", { type: "button", class: "frame-toggle", "aria-expanded": String(logOpen), onclick: () => { logOpen = !logOpen; drawBar(); } }, `${txt("frame.log").de} ${logOpen ? "▾" : "▴"}`));
    const drawerNodes: VNode[] = [];
    if (showGeneric && open) {
      drawerNodes.push(v("section", { class: "frame-drawer-sheet", "aria-label": txt("frame.generic_title").de },
        v("h3", {}, txt("frame.generic_title").de),
        GenericBar(m, { selectedKey: selected ? actionKey(selected) : null, onSelect: (e: Entry) => select(e.action), onRange, rangeError })));
    }
    let logSheet: HTMLElement | null = null;
    if (logOpen) {
      // Until the full log has arrived, show the tail the state carries.
      const lines: LogLine[] = fullLog.length > 0 ? fullLog : g.state.log;
      const sheet = toDom(v("section", { class: "frame-drawer-sheet frame-log", "aria-label": txt("frame.log").de },
        v("h3", {}, txt("frame.log").de),
        lines.length === 0 ? v("p", { class: "muted" }, txt("frame.log_empty").de) : null));
      logList.replaceChildren(...(lines.length === 0 ? [] : [toDom(v("ol", {}, ...lines.map((l) => v("li", {}, l.text))))]));
      (sheet as HTMLElement).append(logList);
      logSheet = sheet as HTMLElement;
      syncFullLog(g);
    }
    const keep = { ...logScroll };
    put(drawerEl, ...drawerNodes);
    if (logSheet) drawerEl.append(logSheet);
    drawerEl.hidden = drawerNodes.length === 0 && !logSheet;
    if (logSheet) { logList.scrollTop = nextScrollTop(keep, logList.scrollHeight, logList.clientHeight); }
    applyBusy();
  }
  const genericDetail = (g: Game, a: Action) => {
    const m = model();
    const e = m?.groups.flatMap((gr) => gr.entries).find((x) => x.key === actionKey(a));
    return e?.detail ?? Object.entries(a).filter(([k]) => k !== "type").map(([k, val]) => `${k} ${String(val)}`).join(" · ");
  };

  function drawLayout() {
    root.dataset.outliner = outlinerOpen ? "open" : "closed";
  }

  function drawAll() {
    drawLayout(); drawRound(); drawPlayers(); drawContext(); drawOutliner(); drawMain(); drawEnd(); drawBar();
  }

  document.addEventListener(THEME_CHANGED, () => { if (root.isConnected) drawAll(); });

  Object.assign(frame, {
    root, band, message, claims, views, setOrder: (spec: OrderSpec) => orderSlot.set(spec), send: (a: Action) => send(a), slots: { context: contextSlot, main: viewEl }, hooks: {},
    onDispose: (fn: () => void) => { disposers.push(fn); },
    dispose: () => { disposers.splice(0).forEach((f) => f()); },
    subscribe: (fn: (g: Game) => void) => { listeners.add(fn); return () => { listeners.delete(fn); }; },
    render(g: Game) {
      for (const fn of listeners) fn(g);
      if (!game || game.seq !== g.seq) { selected = null; armed = false; rangeError = null; seqSince = Date.now(); }
      game = g;
      drawAll();
      drawStall();
    },
    discardSelection() { selected = null; armed = false; rangeError = null; drawBar(); },
    setBusy(b: boolean) { busy = b; if (game) drawBar(); else applyBusy(); },
  });
  drawLayout();
  return frame;
}
