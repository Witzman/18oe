// The game page frame (#45, ui-spec 3.1 to 3.4, rebuilt in #301): head bar (round, order, players), the main
// area full-bleed, and ONE floating action panel (bottom left; bottom sheet on iPad portrait; collapsible to
// one line with the main button). The panel holds the step title, the special panels' slot, the generic action
// bar, the order (sentence, before/after, main button) and the log toggle; the former footer and outliner are
// gone. Special panels and views hook in through `claims` (which action types they handle), `views` (main
// area) and `slots` (containers). The generic action bar stays inside the panel for everything nobody claimed.
import { choiceFromRoot } from "../../themes/choice.ts";
import type { Theme } from "../../themes/schema.ts";
import type { Api } from "../../api.ts";
import type { createSession } from "../../session.ts";
import type { Game } from "../../types.ts";
import { connectionBand, messageArea } from "../connection.ts";
import { h } from "../dom.ts";
import { Auftrag, Dialog, Geld, mitTooltip, Siegel, toDom, v, Wimpel, type VNode } from "../kit/index.ts";
import { THEME_CHANGED } from "../theme-switch.ts";
import { fillText, txt } from "../text.ts";
import { createClaims } from "./claims.ts";
import type { Kind } from "./kinds.ts";
import { backStage, chooseKind, stageAfterRender, stageView } from "./stage.ts";
import { createOrderSlot, orderView, type OrderSlot, type OrderSpec } from "./order.ts";
import { actionKey, genericModel, GenericBar, rangeAction, rangeValue, type Action, type Entry, type RangeEntry } from "./generic.ts";
import { OrderBandView, orBand } from "./or-band.ts";
import { opSheet, OpSheetView } from "../panels/op-sheet.ts";
import { roundChip } from "./round-marks.ts";
import { corpColor, playerRows, roundBar, roundMarkers, stallNotice, stepLabel, type PlayerRow } from "./model.ts";
import { panelIdle, readCollapsed, writeCollapsed } from "./panel.ts";
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
  // Set by main: load the full state again and render it (the "Neu laden" of the stall line, #289).
  reload?: () => void;
  // Hook points for the following UI issues.
  claims: ReturnType<typeof createClaims>;
  views: ReturnType<typeof createViews>;
  slots: { context: HTMLElement; main: HTMLElement };
  // A special panel sets the order sentence, main button and side buttons of the action bar (#213);
  // returns the release function to call on unmount.
  setOrder: (spec: OrderSpec) => () => void;
  // A special panel asks the action panel to stay away while it has nothing to show (#370, the auction); returns the release.
  hidePanel: () => () => void;
  // Sends an action with the current seq (what the main button of the generic bar does).
  send: (action: Record<string, unknown>) => void;
  hooks: { onFocusCorporation?: (id: string) => void; onFocusHome?: (id: string) => void; map?: import("./mapview.ts").FrameMap; onRenderError?: (e: unknown) => void };
  // Runs the cleanups of mounted views and panels when the page leaves the game (the map frees its WebGL context).
  onDispose: (fn: () => void) => void;
  dispose: () => void;
  // The two-step box (#497 S3): a panel draws the options of a kind itself (`provide`, returns the release), reads
  // the kind the player is in (`current`: step 2's kind, null in step 1) and is told when the player changes it.
  // The state stays here, at the frame; a panel never keeps its own copy of the kind.
  // Several panels may provide the same kind (the stock sheet in the stock round, the concession panel in the concession
  // step); each returns no nodes in a step that is not its own. `redraw` redraws the box after a panel's own choice.
  kinds: { provide: (kind: Kind, options: (g: Game) => VNode[]) => () => void; current: () => Kind | null; subscribe: (fn: () => void) => () => void; redraw: () => void };
  // Special panels follow the game state: called with every new state before the frame draws it (#46).
  subscribe: (fn: (g: Game) => void) => () => void;
}

const theme = (): Theme => choiceFromRoot(document.documentElement).theme;
const put = (el: Element, ...nodes: (VNode | string | null)[]) =>
  el.replaceChildren(...nodes.filter((n): n is VNode | string => n !== null).map((n) => toDom(n)));

export function createGameFrame(retryNow: () => void = () => {}, api?: Api): GameFrame {
  const claims = createClaims();
  const orderSlot: OrderSlot = createOrderSlot(() => { if (game) drawBar(); });
  const views = createViews([{
    id: "map", labelKey: "frame.view_map",
    render: ({ container }) => { if (container.childElementCount === 0) container.append(h("p", { class: "muted frame-placeholder" }, txt("frame.view_placeholder").text)); },
  }]);
  const band = connectionBand({ retryNow });
  const message = messageArea();

  let game: Game | null = null;
  let selected: Action | null = null;
  let stage: Kind | null = null; // two-step box (#497 S2): the chosen kind of action, null = step 1; never stored
  let armed = false;
  let busy = false;
  let rangeError: { key: string; text: string } | null = null;
  let collapsed = readCollapsed();
  let genericOpen: boolean | null = null; // null = automatic (open while there is something to choose)
  let logOpen = false;
  // The full log (#292): fetched from /games/:id/log while the sheet is open; the sheet element lives on
  // between redraws so the reader's scroll position survives.
  let fullLog: LogLine[] = [];
  let fullLogSeq = -1;
  let fullLogLoading = false;
  const logList = h("div", { class: "frame-log-scroll", tabindex: "0" });
  const logHost = h("div", { class: "frame-log-host" });
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
  let panelHides = 0;
  const frame: GameFrame = {} as GameFrame;
  const listeners = new Set<(g: Game) => void>();
  const disposers: (() => void)[] = [];

  const roundEl = h("div", { class: "frame-roundbar" });
  const orderEl = h("div", { class: "frame-orderband" });
  orderEl.hidden = true;
  const playersEl = h("nav", { class: "frame-players", "aria-label": txt("frame.player_bar").text });
  const contextEl = h("div", { class: "frame-context" });
  const contextSlot = h("div", { class: "frame-context-slot" });
  const mainEl = h("main", { class: "frame-main", "aria-label": txt("frame.main").text });
  const tabsEl = h("div", { class: "frame-tabs", role: "tablist" });
  const viewEl = h("div", { class: "frame-view" });
  const endEl = h("div", { class: "frame-end-slot" });
  mainEl.append(endEl, viewEl); // the view tabs live in the head bar (#417), see drawRound
  // The action panel (#301): head (collapse button, step title), body (context, slot, generic bar, log), foot
  // (order with the main button, stall line, messages, tools).
  const panelTitle = h("div", { class: "frame-panel-title" });
  const panelToggle = h("button", { type: "button", class: "frame-panel-toggle" });
  const panelHome = h("button", { type: "button", class: "frame-panel-home", title: txt("frame.home_title").text, "aria-label": txt("frame.home_title").text }, "⌂");
  panelHome.hidden = true;
  const panelHead = h("div", { class: "frame-panel-head" }, panelToggle, panelTitle, panelHome);
  const drawerEl = h("div", { class: "frame-drawer" });
  const panelBody = h("div", { class: "frame-panel-body" }, contextEl, drawerEl);
  const barEl = h("div", { class: "frame-panel-foot" });
  const barMain = h("div", { class: "frame-bar-order" });
  const barTools = h("div", { class: "frame-bar-tools" });
  const panelEl = h("aside", { class: "frame-panel", "aria-label": txt("frame.panel").text }, panelHead, panelBody, barEl);
  // #289: "nobody can act" / "the bot does not move" / "no action offered", never a silent hang.
  const stallEl = h("p", { class: "frame-stall", role: "status", "aria-live": "polite" });
  stallEl.hidden = true;
  barEl.append(barMain, stallEl, message.el, barTools);
  let seqSince = Date.now();
  function drawStall() {
    let n: ReturnType<typeof stallNotice> = null;
    try { n = game ? stallNotice(game, Date.now() - seqSince) : null; } catch (e) { console.warn("stall notice", e); } // a notice never breaks the frame
    // Client side (#289): an answer that does not come, a panel that failed to draw, or controls that stay
    // locked although nothing is in flight. Locked controls are opened again right away (self-healing).
    if (!busy && root.querySelector("button[data-busy-lock]")) { console.warn("#289: busy lock left over, released"); releaseLock(); }
    const now = Date.now();
    if (busy && now - busySince >= SLOW_ANSWER_MS) n = { kind: "slow_answer", tone: "warn", text: fillText("frame.stall_slow", { s: Math.floor((now - busySince) / 1000) }) };
    else if (panelError) n = { kind: "panel_error", tone: "error", text: fillText("frame.stall_panel", { error: panelError }) };
    const show = n !== null && n.tone !== "info"; // "waiting for X" is already the bar's sentence
    stallEl.hidden = !show;
    stallEl.className = show ? `frame-stall msg-${n!.tone}` : "frame-stall";
    stallEl.dataset.kind = show ? n!.kind : "";
    stallEl.replaceChildren();
    if (!show) return;
    stallEl.append(n!.text);
    if (frame.reload && n!.kind !== "slow_answer") {
      const b = h("button", { type: "button", class: "frame-stall-reload" }, txt("frame.stall_reload").text);
      b.addEventListener("click", () => frame.reload?.());
      stallEl.append(" ", b);
    }
  }
  const SLOW_ANSWER_MS = 15_000;
  let busySince = 0;
  let panelError: string | null = null;
  const stallTimer = setInterval(() => { if (root.isConnected) drawStall(); }, 3000);
  disposers.push(() => clearInterval(stallTimer));
  // Until the first state is drawn the context sheet says so (#294): never a bare map without a word. A
  // failed load shows in the band above (reason and "Jetzt"), this line stays until a state arrives.
  const loadingEl = h("p", { class: "muted frame-loading", role: "status" }, txt("frame.loading").text);
  contextEl.append(loadingEl);
  const body = h("div", { class: "frame-body" }, mainEl, panelEl, logHost);
  logHost.hidden = true;
  const headEl = h("header", { class: "frame-head" }, roundEl, playersEl);
  const root = h("div", { class: "frame" }, headEl, orderEl, band.el, body, versionButton());

  const providers = new Map<Kind, Set<(g: Game) => VNode[]>>();
  const stageListeners = new Set<() => void>();
  const model = () => (game ? genericModel(game, claims, new Set(providers.keys())) : null);
  const currentKind = (): Kind | null => {
    const kinds = model()?.kinds?.map((b) => b.kind);
    return kinds ? stageView(kinds, stage).kind : null;
  };

  // While an action is in flight every button is locked. Only the buttons this lock disabled are marked and
  // opened again afterwards (#289): the panels redraw when the answer arrives, still inside the lock, and
  // without the mark their fresh buttons stayed disabled until the next seq change. When the same player
  // acts again (a 2nd concession of the same owner, the next step of a run) no seq change came: the game
  // looked hung.
  function applyBusy() {
    root.toggleAttribute("aria-busy", busy);
    if (busy) {
      for (const b of root.querySelectorAll("button")) if (!b.disabled) { b.disabled = true; b.dataset.busyLock = ""; }
    } else releaseLock();
  }
  function releaseLock() {
    for (const b of root.querySelectorAll<HTMLButtonElement>("button[data-busy-lock]")) { b.disabled = false; delete b.dataset.busyLock; }
  }

  // ---- round bar -------------------------------------------------------------------------------
  function drawRound() {
    if (!game) return put(roundEl);
    const t = theme();
    const m = roundBar(game, t);
    const phase = mitTooltip(v("span", { class: "frame-phase" }, m.phase.label),
      { title: m.phase.label, term: "Train phase", rows: [{ label: txt("frame.phase_tiles").text, value: m.phase.tiles }, { label: txt("frame.phase_ors").text, value: String(m.phase.operatingRounds) }], source: txt("frame.phase_tiles").regel });
    put(roundEl,
      v("a", { class: "frame-signet", href: "#/", title: txt("frame.signet_title").text }, "18OE"),
      v("span", { class: "frame-rr", title: txt(`rrphase.${m.rrPhase}`).en }, txt(`rrphase.${m.rrPhase}`).text),
      phase,
      roundChip(m.round, m.roundShort, roundMarkers(game)),
      v("div", { class: "frame-who", "data-mine": m.who.mine ? "true" : "false", role: "status", title: m.who.text },
        m.who.corp ? Siegel({ sym: m.who.corp.sym, color: m.who.corp.color }, { theme: t, size: "s" }) : null,
        v("span", {}, m.who.text)),
      );
    // #417: the view tabs and the log link take the place the order chips left (before the "who" marker).
    roundEl.querySelector(".frame-who")?.before(tabsEl);
  }

  // ---- order band (#416): operating order under the head bar; stock round: the order the next OR would have --
  function drawOrderBand() {
    const b = game ? orBand(game, theme()) : null;
    orderEl.hidden = b === null;
    if (b === null) return orderEl.replaceChildren();
    put(orderEl, OrderBandView(b, theme()));
  }

  // ---- player bar ------------------------------------------------------------------------------
  function playerEntry(p: PlayerRow, t: Theme): VNode {
    const btn = v("span", {
      class: "frame-player", tabindex: "0", "data-me": p.me ? "true" : "false", "data-to-act": p.toAct ? "true" : "false",
    },
    Wimpel({ seat: p.seat, name: p.name }, { theme: t }),
    v("span", { class: "frame-cash" }, Geld(p.cash)),
    v("span", { class: "frame-certs", title: txt("frame.certs_title").text }, fillText("frame.certs", { n: p.certs, limit: p.certLimit })),
    p.priority ? v("span", { class: "frame-star", title: txt("frame.priority").text, "aria-label": txt("frame.priority").text }, "★") : null,
    p.bot ? v("span", { class: "frame-tag" }, txt("frame.bot").text) : null,
    p.toAct ? v("span", { class: "frame-tag frame-tag-act" }, txt("frame.to_act").text) : null);
    return mitTooltip(btn, { title: p.name, term: txt("frame.worth").en, total: { label: txt("frame.worth").text, amount: p.value }, rows: [{ label: txt("frame.cash").text, amount: p.cash }] });
  }
  function drawPlayers() {
    if (!game) return put(playersEl);
    const t = theme();
    put(playersEl, ...playerRows(game).map((p) => playerEntry(p, t)),
      v("span", { class: "frame-bank" }, `${txt("frame.bank").text} `, Geld(game.state.bank.cash)));
  }

  // ---- action panel: context (only the current step, no rules text) -------------------------------------
  function drawContext() {
    if (!game) { contextEl.replaceChildren(loadingEl); put(panelTitle); return; }
    const p = game.state.prompt;
    const t = theme();
    const b = orBand(game, t);
    const acting = b?.acting ?? null;
    put(panelTitle,
      acting ? Siegel({ sym: acting.id, name: acting.name, color: acting.color }, { theme: t, size: "s" }) : null,
      v("span", { class: "frame-panel-step", title: p.step ? txt(`step.${p.step}`).en : undefined }, stepLabel(p.step)));
    // #415: centre the map on the home station of the acting company.
    panelHome.hidden = !acting;
    panelHome.dataset.corp = acting?.id ?? "";
    // Operating round (#302): the compact head of the acting company (numbers, step strip), no rules text.
    const sheet = opSheet(game, t);
    put(contextEl, sheet ? OpSheetView(sheet) : null);
    contextEl.append(contextSlot);
  }

  // ---- main area -------------------------------------------------------------------------------
  function drawMain() {
    const list = views.list;
    // The log link sits right after the tabs and is always there, also with a single view (#370).
    put(tabsEl, ...(list.length > 1 ? list.map((d) => v("button", {
      type: "button", role: "tab", "aria-selected": String(d.id === views.activeId),
      onclick: () => views.activate(d.id),
    }, txt(d.labelKey).text)) : []),
      v("button", { type: "button", class: "frame-log-link", title: txt("frame.log_hint").text, "aria-haspopup": "dialog", onclick: () => { logOpen = true; drawLog(); } }, txt("frame.log").text));
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
      onLog: () => { logOpen = true; drawLog(); },
    }));
  }

  // ---- the log as a large dialog over the body (#370; the sheet of #292 moved out of the panel) ----------
  function closeLog() { logOpen = false; drawLog(); }
  function drawLog() {
    const g = game;
    logHost.hidden = !logOpen || !g;
    if (!logOpen || !g) { logHost.replaceChildren(); return; }
    // Until the full log has arrived, show the tail the state carries.
    const lines: LogLine[] = fullLog.length > 0 ? fullLog : g.state.log;
    const keep = { ...logScroll };
    const wasOpen = logHost.childElementCount > 0;
    logList.replaceChildren(...(lines.length === 0 ? [] : [toDom(v("ol", {}, ...lines.map((l) => v("li", {}, l.text))))]));
    if (!wasOpen) {
      logHost.replaceChildren(toDom(Dialog({
        id: "frame-log", title: txt("frame.log").text, onClose: closeLog,
        body: [v("div", { class: "frame-log" }, lines.length === 0 ? v("p", { class: "muted" }, txt("frame.log_empty").text) : null)],
        actions: [v("button", { type: "button", class: "kit-side-btn", "data-action": "close-log", onclick: closeLog }, txt("frame.log_close").text)],
      })));
      logHost.querySelector(".frame-log")!.append(logList);
      logHost.querySelector<HTMLElement>("[data-action='close-log']")!.focus();
    }
    logList.scrollTop = nextScrollTop(keep, logList.scrollHeight, logList.clientHeight);
    syncFullLog(g);
  }

  // ---- action bar ------------------------------------------------------------------------------
  function send(a: Action) {
    if (!game || !frame.session || busy) return;
    void frame.session.send(a, game.seq);
  }
  function onStage(kind: Kind | null) {
    // Back drops a started selection: nothing is sent, nothing stays chosen from the kind left.
    stage = kind === null ? backStage() : chooseKind(model()?.kinds?.map((b) => b.kind) ?? [], stage, kind);
    selected = null; armed = false; rangeError = null;
    drawBar();
    for (const fn of [...stageListeners]) fn();
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
    return m.count > 0 ? txt("frame.order_idle").text : txt("frame.order_nothing").text;
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
        sentence: txt(`action.${type}`).text + (danger ? ` ${txt("frame.danger_note").text}` : ""),
        changes: [], state: busy ? "waiting" : "preview",
        confirmLabel: danger && armed ? txt("frame.confirm_danger").text : txt("frame.confirm").text,
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
      null);
    const drawerNodes: VNode[] = [];
    if (showGeneric && open) {
      drawerNodes.push(v("section", { class: "frame-drawer-sheet", "aria-label": txt("frame.generic_title").text },
        v("h3", {}, txt("frame.generic_title").text),
        GenericBar(m, { selectedKey: selected ? actionKey(selected) : null, onSelect: (e: Entry) => select(e.action), onRange, rangeError, stage, onStage, provided: (k: Kind) => [...(providers.get(k) ?? [])].flatMap((fn) => fn(g)) })));
    }
    put(drawerEl, ...drawerNodes);
    drawerEl.hidden = drawerNodes.length === 0;
    drawLog();
    drawLayout();
    applyBusy();
  }
  const genericDetail = (g: Game, a: Action) => {
    const m = model();
    const e = m?.groups.flatMap((gr) => gr.entries).find((x) => x.key === actionKey(a));
    return e?.detail ?? Object.entries(a).filter(([k]) => k !== "type").map(([k, val]) => `${k} ${String(val)}`).join(" · ");
  };

  function drawLayout() {
    // Hidden only while someone asked for it and there is nothing to say (#370); messages and errors always show.
    const idle = panelIdle({
      order: orderSlot.spec !== null, selected: selected !== null, generic: barTools.childElementCount > 0,
      context: contextEl.querySelector(".op-sheet") !== null || contextSlot.childElementCount > 0 || loadingEl.isConnected,
      message: (message.el.textContent ?? "") !== "", stall: !stallEl.hidden,
    });
    panelEl.hidden = panelHides > 0 && idle;
    panelEl.dataset.collapsed = collapsed ? "true" : "false";
    panelToggle.setAttribute("aria-expanded", String(!collapsed));
    const label = txt(collapsed ? "frame.panel_expand" : "frame.panel_collapse").text;
    panelToggle.title = label;
    panelToggle.setAttribute("aria-label", label);
    panelToggle.textContent = collapsed ? "▴" : "▾";
  }
  panelHome.addEventListener("click", () => { const id = panelHome.dataset.corp; if (id) frame.hooks.onFocusHome?.(id); });
  panelToggle.addEventListener("click", () => { collapsed = !collapsed; writeCollapsed(collapsed); drawLayout(); });

  // Enter = the main button (#301), unless the focus is in something that uses Enter itself.
  const onKey = (e: KeyboardEvent) => {
    if (e.key !== "Enter" || e.defaultPrevented || e.isComposing || e.ctrlKey || e.metaKey || e.altKey || !root.isConnected) return;
    const t = e.target as HTMLElement | null;
    if (t && t !== document.body && t.closest("input, textarea, select, button, a, summary, [contenteditable], dialog")) return;
    if (document.querySelector("dialog[open]")) return;
    const main = root.querySelector<HTMLButtonElement>(".kit-dialog .kit-main-btn") ?? panelEl.querySelector<HTMLButtonElement>(".kit-main-btn");
    if (!main || main.disabled) return;
    e.preventDefault();
    main.click();
  };
  document.addEventListener("keydown", onKey);
  disposers.push(() => document.removeEventListener("keydown", onKey));

  function drawAll() {
    drawLayout(); drawRound(); drawOrderBand(); drawPlayers(); drawContext(); drawMain(); drawEnd(); drawBar();
  }

  document.addEventListener(THEME_CHANGED, () => { if (root.isConnected) drawAll(); });

  Object.assign(frame, {
    root, band, message, claims, views, setOrder: (spec: OrderSpec) => orderSlot.set(spec), hidePanel: () => { panelHides++; drawLayout(); let done = false; return () => { if (done) return; done = true; panelHides--; drawLayout(); }; }, send: (a: Action) => send(a), slots: { context: contextSlot, main: viewEl }, hooks: {},
    kinds: {
      provide(kind: Kind, options: (g: Game) => VNode[]) {
        const set = providers.get(kind) ?? new Set();
        set.add(options);
        providers.set(kind, set);
        return () => { set.delete(options); if (set.size === 0 && providers.get(kind) === set) providers.delete(kind); };
      },
      redraw: () => { if (game) drawBar(); },
      current: currentKind,
      subscribe(fn: () => void) { stageListeners.add(fn); return () => { stageListeners.delete(fn); }; },
    },
    onDispose: (fn: () => void) => { disposers.push(fn); },
    dispose: () => { disposers.splice(0).forEach((f) => f()); },
    subscribe: (fn: (g: Game) => void) => { listeners.add(fn); return () => { listeners.delete(fn); }; },
    render(g: Game) {
      // One panel that throws must not stop the others nor the frame (#289): the error is shown in the
      // stall line (with "Neu laden") instead of leaving a half-drawn, unusable screen.
      // #294: the map is one of these listeners; before, a throw there left a map-only page. The error also
      // goes to hooks.onRenderError (main.ts sends it to the server log).
      panelError = null;
      // The state and the stage are current before the panels hear of the new state: a panel reads `kinds.current()` (#497 S4).
      stage = stageAfterRender(stage, game?.seq ?? null, g.seq);
      if (!game || game.seq !== g.seq) { selected = null; armed = false; rangeError = null; seqSince = Date.now(); }
      game = g;
      for (const fn of listeners) {
        try { fn(g); } catch (e) { panelError = e instanceof Error ? e.message : String(e); console.error("panel failed to draw", e); frame.hooks.onRenderError?.(e); }
      }
      try { drawAll(); } catch (e) { panelError = e instanceof Error ? e.message : String(e); console.error("frame failed to draw", e); frame.hooks.onRenderError?.(e); applyBusy(); }
      drawStall();
    },
    discardSelection() { selected = null; armed = false; rangeError = null; drawBar(); }, // keeps the stage: the player stays in the kind
    setBusy(b: boolean) {
      if (b && !busy) busySince = Date.now();
      busy = b;
      // The lock is released even if drawing the bar fails (#289).
      try { if (game) drawBar(); } finally { applyBusy(); drawStall(); }
    },
  });
  drawLayout();
  return frame;
}
