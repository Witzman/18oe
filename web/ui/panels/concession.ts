// Concession round panel (#172, ui-spec 4.3): the concession ladder CON1..CON10, founding (choose minor or
// regional, par value, confirm through the order sentence) and the home token of a founded minor.
//
// Pure model first (tests run it under node on the recorded states), then the view, then `mountConcession`,
// which hangs the panel into the frame (context slot, claims, order sentence of the action bar).
// All numbers come from the view model (`concession`, `zones`, `prompt`); the client checks no rules.
import type { MapGeometry } from "../../render/mapdata.ts";
import { corpColor, playerName } from "../frame/model.ts";
import type { MapPreview, MapTargets } from "../../render/map.ts";
import type { OrderSpec } from "../frame/order.ts";
import type { GameFrame } from "../frame/frame.ts";
import { Geld, Leiter, Siegel, formatGeld, toDom, v, type Step, type VNode } from "../kit/index.ts";
import { choiceFromRoot } from "../../themes/choice.ts";
import type { Theme } from "../../themes/schema.ts";
import type { Corporation, Game, Zone } from "../../types.ts";
import { fillText, txt } from "../text.ts";
import { mapPick } from "./map-pick.ts";

type Action = Record<string, unknown>;

/** Par values of the share-price table in the order the buttons show them (assumption: the engine's par
 *  prices 90..60, ui-spec 4.3). Values the prompt does not offer are shown dimmed with a reason. */
export const PAR_PRICES = [90, 80, 75, 70, 65, 60] as const;

export type OfferKind = "minor" | "regional" | "par_only";
export interface PriceOption { price: number; action: Action | null; cost: number | null; reason: "cash" | "now" | null }
export interface Offer { corp: string; name: string; kind: OfferKind; prices: PriceOption[] }
export interface HomeTarget { city: string; hex: string; index: number; name: string | null; zone: string | null; zoneInfo: Zone | null; action: Action }

export const isConcessionRound = (g: Game): boolean => g.state.meta.round.type === "concession";
export const isFounding = (g: Game): boolean => isConcessionRound(g) && g.state.prompt.step === "Concession";
export const isHomeToken = (g: Game): boolean => isConcessionRound(g) && g.state.prompt.step === "HomeToken";

/** "90,1,0" -> 90 (price, row, column of the share-price table). */
export const parPrice = (sharePrice: unknown): number => Number(String(sharePrice).split(",")[0]);

// ---- ladder -------------------------------------------------------------------------------------
export interface LadderRow { id: string; n: number; label: string; owner: string; mine: boolean; state: Step["state"] }

export function ladder(g: Game): LadderRow[] {
  return (g.state.concession ?? []).map((c, i) => ({
    id: c.id, n: i + 1, label: fillText("concession.n", { n: i + 1 }),
    owner: c.owner ? playerName(g, c.owner) : txt("concession.owner_none").de,
    mine: c.owner !== null && c.owner === g.viewer,
    state: c.status === "done" ? "done" : c.status === "current" ? "active" : "future",
  }));
}

// ---- founding offers ----------------------------------------------------------------------------
export function offers(g: Game): Offer[] {
  const p = g.state.prompt;
  if (!isFounding(g) || !p.viewer_to_act) return [];
  const byCorp = new Map<string, Action[]>();
  for (const a of p.actions) if (a.type === "par") byCorp.set(String(a.corporation), [...(byCorp.get(String(a.corporation)) ?? []), a]);
  const corps = g.state.corporations;
  const typeOf = (id: string) => corps.find((c) => c.id === id)?.type;
  const cash = (a: Action) => g.state.players.find((pl) => pl.id === a.entity)?.cash ?? 0;
  const anyMinor = [...byCorp.keys()].some((id) => typeOf(id) === "minor");
  const rows: Offer[] = [];
  for (const [id, acts] of byCorp) {
    const corp = corps.find((c) => c.id === id);
    const regional = corp?.type !== "minor";
    const money = cash(acts[0]!);
    const offered = new Map(acts.map((a) => [parPrice(a.share_price), a]));
    // The engine offers every par value (also unaffordable ones) only when the player can neither float a
    // minor nor afford a regional: then a regional is only parred for later (step Concession, must_par_only?).
    const parOnly = regional && !anyMinor && [...offered.keys()].some((pr) => pr * 2 > money);
    const kind: OfferKind = !regional ? "minor" : parOnly ? "par_only" : "regional";
    const universe = [...new Set([...PAR_PRICES, ...offered.keys()])].sort((a, b) => b - a);
    rows.push({
      corp: id, name: corp?.name ?? id, kind,
      prices: universe.map((price) => {
        const action = offered.get(price) ?? null;
        return {
          price, action, cost: kind === "regional" ? price * 2 : null,
          reason: action ? null : regional && price * 2 > money ? "cash" : "now",
        };
      }),
    });
  }
  return rows;
}

// ---- home token ---------------------------------------------------------------------------------
/** "Q38-0-0" -> "Q38": the hex of a city id (Engine::Part::Base#id is "<tile id>-<index>"). */
export const hexOfCity = (city: string): string => city.split("-")[0]!;

/** "Q38-0-1" -> 1: the city index on its tile is the last segment (Engine::Part::Base#id is "#{tile.id}-#{index}",
 *  lib/engine/part/base.rb); the view's `context.token.cities` says it too when the actions were computed. */
export function indexOfCity(city: string, g?: Game): number {
  const c = g?.state.prompt.context?.token?.cities?.find((x) => x.id === city);
  if (c) return c.city;
  const n = Number(city.split("-").pop());
  return Number.isInteger(n) && n >= 0 ? n : 0;
}

export function homeTargets(g: Game, map: MapGeometry | null): HomeTarget[] {
  const p = g.state.prompt;
  if (!isHomeToken(g) || !p.viewer_to_act) return [];
  return p.actions.filter((a) => a.type === "place_token").map((a) => {
    const hex = hexOfCity(String(a.city));
    const info = map?.hexes.find((x) => x.id === hex);
    const zone = info?.zone ?? null;
    return { city: String(a.city), hex, index: indexOfCity(String(a.city), g), name: info?.name ?? null, zone, zoneInfo: zone ? g.state.zones.find((z) => z.id === zone) ?? null : null, action: a };
  });
}

export const placeLabel = (t: HomeTarget): string => (t.name ? `${t.name} (${t.hex})` : t.hex);

/** A tap on the map: on a slot (`city` given) picks that city; on a hex only when it has exactly one target. */
export function homeTapMap(g: Game, map: MapGeometry | null, hex: string, city?: number): string | null {
  const on = homeTargets(g, map).filter((t) => t.hex === hex);
  const hit = city === undefined ? undefined : on.find((t) => t.index === city);
  return hit?.city ?? (on.length === 1 ? on[0]!.city : null);
}

export function homeMapTargets(g: Game, map: MapGeometry | null): MapTargets | null {
  const cities = homeTargets(g, map).map((t) => ({ hex: t.hex, city: t.index }));
  return cities.length > 0 ? { cities, kind: "token" } : null;
}

export function homePreview(g: Game, sel: Selection, map: MapGeometry | null): MapPreview {
  const t = homeTargets(g, map).find((x) => x.city === effectiveSelection(g, sel, map).city);
  const corp = g.state.prompt.actions.find((a) => typeof a.entity === "string")?.entity;
  return t && typeof corp === "string" ? { hex: t.hex, city: t.index, corp } : null;
}

// ---- selection and order ------------------------------------------------------------------------
export interface Selection { corp: string | null; price: number | null; city: string | null }
export const emptySelection = (): Selection => ({ corp: null, price: null, city: null });

/** The selection as the panel uses it: a single offer or a single target is chosen already (ui-spec 4.3). */
export function effectiveSelection(g: Game, sel: Selection, map: MapGeometry | null): Selection {
  const o = offers(g);
  const corp = sel.corp !== null && o.some((x) => x.corp === sel.corp) ? sel.corp : o.length === 1 ? o[0]!.corp : null;
  const price = corp !== null && sel.price !== null && o.find((x) => x.corp === corp)?.prices.some((pr) => pr.price === sel.price && pr.action) ? sel.price : null;
  const t = homeTargets(g, map);
  const city = sel.city !== null && t.some((x) => x.city === sel.city) ? sel.city : t.length === 1 ? t[0]!.city : null;
  return { corp, price, city };
}

export function sentenceFor(g: Game, sel: Selection, map: MapGeometry | null): { text: string; action: Action | null; confirm: string } {
  const eff = effectiveSelection(g, sel, map);
  if (isHomeToken(g)) {
    const t = homeTargets(g, map).find((x) => x.city === eff.city);
    const confirm = txt("concession.confirm_home").de;
    if (!t) return { text: txt("concession.home_pick").de, action: null, confirm };
    const place = placeLabel(t);
    const text = t.zoneInfo
      ? fillText("concession.home_sentence", { place, zone: t.zoneInfo.id, price: formatGeld(t.zoneInfo.price) })
      : fillText("concession.home_sentence_plain", { place });
    return { text, action: t.action, confirm };
  }
  const offer = offers(g).find((o) => o.corp === eff.corp);
  if (!offer) return { text: txt("concession.sentence_pick").de, action: null, confirm: txt("concession.confirm_float").de };
  const confirm = txt(offer.kind === "par_only" ? "concession.confirm_par" : "concession.confirm_float").de;
  const opt = offer.prices.find((x) => x.price === eff.price && x.action);
  if (!opt) return { text: fillText("concession.sentence_pick_price", { corp: offer.corp }), action: null, confirm };
  return { text: fillText(`concession.sentence_${offer.kind}`, { corp: offer.corp, price: formatGeld(opt.price) }), action: opt.action, confirm };
}

/** The order for the action bar; null when it is not the viewer's turn in this step. */
export function orderFor(g: Game, sel: Selection, map: MapGeometry | null, send: (a: Action) => void): OrderSpec | null {
  if (!(isFounding(g) || isHomeToken(g)) || !g.state.prompt.viewer_to_act) return null;
  const s = sentenceFor(g, sel, map);
  const action = s.action;
  return { sentence: s.text, state: action ? "preview" : "invalid", reason: action ? undefined : s.text, confirmLabel: s.confirm, onConfirm: () => { if (action) send(action); } };
}

// ---- steps --------------------------------------------------------------------------------------
export type StepKind = "corp" | "price" | "city" | "confirm";
/** Where the viewer stands in the flow (#409): founding takes the corporation, the par value, then confirm; the home
 *  token takes the city, then confirm. A single offer or target is chosen already, so that step is left out. */
export interface Progress { n: number; total: number; kind: StepKind }

export function progress(g: Game, sel: Selection, map: MapGeometry | null): Progress | null {
  if (!g.state.prompt.viewer_to_act) return null;
  const eff = effectiveSelection(g, sel, map);
  if (isFounding(g)) {
    const skip = offers(g).length === 1 ? 1 : 0;
    const total = 3 - skip;
    if (eff.corp === null) return { n: 1, total, kind: "corp" };
    return eff.price === null ? { n: 2 - skip, total, kind: "price" } : { n: 3 - skip, total, kind: "confirm" };
  }
  if (isHomeToken(g)) {
    const skip = homeTargets(g, map).length === 1 ? 1 : 0;
    const total = 2 - skip;
    return eff.city === null ? { n: 1, total, kind: "city" } : { n: total, total, kind: "confirm" };
  }
  return null;
}

/** The selection one step back, or null when there is nothing to take back (first step, or the step before was chosen for the viewer). */
export function backSelection(g: Game, sel: Selection, map: MapGeometry | null): Selection | null {
  const p = progress(g, sel, map);
  if (!p) return null;
  const eff = effectiveSelection(g, sel, map);
  if (isFounding(g)) {
    if (p.kind === "confirm") return { corp: eff.corp, price: null, city: null };
    return p.kind === "price" && offers(g).length > 1 ? emptySelection() : null;
  }
  return p.kind === "confirm" && homeTargets(g, map).length > 1 ? emptySelection() : null;
}

// ---- view ---------------------------------------------------------------------------------------
export interface Handlers {
  onCorp: (corp: string) => void; onPrice: (corp: string, price: number) => void; onCity: (city: string) => void;
  /** One step back (#409); the zones and the ladder fold open and shut. */
  onBack?: () => void; onToggle?: (part: Fold, open: boolean) => void;
}
export type Fold = "zones" | "ladder";
export type Open = Record<Fold, boolean>;

/** A fold the viewer opens on demand (#409): the panel stays short, so it does not scroll. Its state outlives a redraw (`open`). */
function fold(part: Fold, title: string, open: boolean, h: Handlers, ...content: (VNode | null)[]): VNode {
  return v("details", { class: "concession-fold", "data-fold": part, open: open ? "" : undefined, ontoggle: (e: Event) => h.onToggle?.(part, (e.currentTarget as HTMLDetailsElement).open) },
    v("summary", {}, title), ...content);
}

function zoneRows(g: Game, open: boolean, h: Handlers): VNode {
  return fold("zones", txt("concession.zones").de, open, h,
    v("ul", { class: "concession-zone-list" }, ...g.state.zones.map((z) => v("li", { "data-zone": z.id, "data-free": String(z.free) },
      fillText("concession.zone_row", { zone: z.id, price: formatGeld(z.price), left: z.chits_left }),
      z.discount > 0 ? ` · ${fillText("concession.zone_discount", { pct: z.discount })}` : "",
      z.free ? "" : ` · ${txt("concession.zone_full").de}`))));
}

function offerCard(g: Game, o: Offer, selected: boolean, h: Handlers, theme: Theme): VNode {
  const corp = g.state.corporations.find((c) => c.id === o.corp) as Corporation | undefined;
  const color = corpColor(theme, g, o.corp);
  return v("button", {
    type: "button", class: "concession-card", "data-corp": o.corp, "data-kind": o.kind,
    "aria-pressed": String(selected), "data-state": selected ? "selected" : "normal",
    onclick: () => h.onCorp(o.corp),
  },
  Siegel({ sym: o.corp, name: corp?.name, color }, { theme, size: "s", state: selected ? "selected" : "normal" }),
  v("span", { class: "concession-card-text" }, fillText(`concession.card_${o.kind}`, { corp: o.corp }), v("small", { class: "muted" }, o.name)));
}

function priceRow(o: Offer, sel: Selection, h: Handlers): VNode {
  return v("div", { class: "concession-prices", role: "group", "aria-label": fillText("concession.par_row", { corp: o.corp }) },
    ...o.prices.map((pr) => {
      const picked = sel.price === pr.price;
      const cost = pr.cost !== null ? fillText("concession.cost_regional", { amount: formatGeld(pr.cost) }) : o.kind === "minor" ? fillText("concession.cost_minor", { price: formatGeld(pr.price) }) : txt("concession.cost_par_only").de;
      const reason = pr.reason === null ? undefined : txt(pr.reason === "cash" ? "concession.invalid_cash" : "concession.invalid_now").de;
      return v("button", {
        type: "button", class: "concession-price", "data-price": String(pr.price), "aria-pressed": String(picked),
        "data-state": reason ? "invalid" : picked ? "selected" : "normal", disabled: reason !== undefined, title: reason ?? cost,
        onclick: () => h.onPrice(o.corp, pr.price),
      }, v("strong", {}, Geld(pr.price)), v("small", {}, reason ?? cost));
    }));
}

function targetButton(t: HomeTarget, selected: boolean, h: Handlers): VNode {
  const price = t.zoneInfo ? formatGeld(t.zoneInfo.price) : "";
  const text = t.zone && t.zoneInfo ? fillText("concession.home_target", { place: placeLabel(t), zone: t.zone, price }) : placeLabel(t);
  return v("button", {
    type: "button", class: "concession-target", "data-city": t.city, "data-zone": t.zone ?? undefined,
    "aria-pressed": String(selected), "data-state": selected ? "selected" : "normal", onclick: () => h.onCity(t.city),
  }, text);
}

/** The panel content for the context slot of the frame: one step at a time (#409), the zones and the ladder folded below. */
export function ConcessionPanel(g: Game, sel: Selection, map: MapGeometry | null, h: Handlers, theme: Theme, open: Open = { zones: false, ladder: false }): VNode {
  const eff = effectiveSelection(g, sel, map);
  const rows = ladder(g);
  const steps: Step[] = rows.map((r) => ({ label: `${r.label} · ${r.mine ? fillText("concession.owner_mine", { who: r.owner }) : r.owner}`, state: r.state }));
  const p = g.state.prompt;
  const mine = p.viewer_to_act;
  const running = rows.find((r) => r.state === "active");
  const step = progress(g, sel, map);
  const back = backSelection(g, sel, map) !== null;
  const body: (VNode | null)[] = [];
  if (step) {
    body.push(v("div", { class: "concession-stephead" },
      v("p", { class: "concession-step", role: "status" }, fillText("concession.step", { n: step.n, total: step.total, title: txt(`concession.step_${step.kind}`).de })),
      back ? v("button", { type: "button", class: "concession-back", onclick: () => h.onBack?.() }, txt("concession.back").de) : null));
  }
  if (isFounding(g) && mine) {
    const os = offers(g);
    const parOnly = os.some((o) => o.kind === "par_only");
    const chosen = os.find((o) => o.corp === eff.corp);
    body.push(
      // Once a corporation is chosen only its card stays, pressed, above the par values.
      v("div", { class: "concession-cards" }, ...(chosen ? [chosen] : os).map((o) => offerCard(g, o, o.corp === eff.corp, h, theme))),
      chosen ? priceRow(chosen, eff, h) : null,
      // Assumption: the engine's help text for the step (D7) is not in the view yet; the two cases are told here.
      v("p", { class: "muted concession-help" }, txt(step?.kind === "confirm" ? "concession.confirm_hint" : parOnly ? "concession.help_par_only" : "concession.help_float").de));
  } else if (isHomeToken(g) && mine) {
    const corp = String(p.actions[0]?.entity ?? "");
    body.push(
      v("p", {}, fillText("concession.home_for", { corp })),
      v("div", { class: "concession-targets" }, ...homeTargets(g, map).map((t) => targetButton(t, t.city === eff.city, h))),
      v("p", { class: "muted concession-help" }, txt(step?.kind === "confirm" ? "concession.confirm_hint" : "concession.home_hint").de));
  } else if (running) {
    body.push(v("p", { class: "concession-running" }, fillText("concession.running", { who: running.owner, n: running.n })));
  }
  const showZones = mine && (isFounding(g) || isHomeToken(g));
  return v("section", { class: "concession-panel", "aria-label": txt("concession.title").de },
    // What the viewer must decide comes first; the folds below it never push it out of view.
    ...body,
    showZones ? zoneRows(g, open.zones, h) : null,
    fold("ladder", txt("concession.ladder").de, open.ladder || !mine, h, Leiter(steps, txt("concession.ladder").de)));
}

// ---- mount --------------------------------------------------------------------------------------
export interface ConcessionHandle {
  /** Select a home city (by city id) from outside, e.g. a click on the map (map.on("city"), #147). */
  selectCity: (city: string) => void;
  /** Home token targets of the current state (for the map to mark them as valid). */
  targets: () => HomeTarget[];
  /** Redraw with the current state, e.g. after the map geometry arrived. */
  refresh: () => void;
  stop: () => void;
}

export function mountConcession(frame: GameFrame, opts: { map?: () => MapGeometry | null } = {}): ConcessionHandle {
  let game: Game | null = null;
  let seq = -1;
  let sel = emptySelection();
  let releaseOrder: (() => void) | null = null;
  const releases: (() => void)[] = [];
  const map = () => opts.map?.() ?? null;
  const pick = mapPick(frame);
  let wasHome = false;

  const mineHome = () => game !== null && isHomeToken(game) && game.state.prompt.viewer_to_act;
  const choose = (city: string) => { frame.discardSelection(); handlers.onCity(city); };
  // A slot tap fires "city" and then "hex": the city wins, the hex only picks when its target is unambiguous.
  let lastCity: { hex: string; at: number } | null = null;
  pick.on("city", ({ hex, city }) => {
    if (!game || !hex || !mineHome()) return;
    const id = homeTapMap(game, map(), hex, city);
    if (id) { lastCity = { hex, at: Date.now() }; choose(id); }
  });
  pick.on("hex", ({ hex }) => {
    if (!game || !hex || !mineHome()) return;
    if (lastCity && lastCity.hex === hex && Date.now() - lastCity.at < 50) return;
    const id = homeTapMap(game, map(), hex);
    if (id) choose(id);
  });

  const open: Open = { zones: false, ladder: false };
  const handlers: Handlers = {
    onBack: () => { if (game) sel = backSelection(game, sel, map()) ?? sel; draw(); },
    onToggle: (part, isOpen) => { open[part] = isOpen; },
    onCorp: (corp) => { sel = { corp, price: null, city: null }; draw(); },
    onPrice: (corp, price) => { sel = { corp, price, city: null }; draw(); },
    onCity: (city) => { sel = { corp: null, price: null, city }; draw(); },
  };
  // The list stays (iPad, 44 px targets); a row also flies to its city.
  const listHandlers: Handlers = { ...handlers, onCity: (city) => { handlers.onCity(city); const t = game ? homeTargets(game, map()).find((x) => x.city === city) : undefined; if (t) pick.flyTo(t.hex); } };

  function claim(active: boolean) {
    while (releases.length > 0) releases.pop()!();
    if (active) releases.push(frame.claims.claim("Concession", "par"), frame.claims.claim("HomeToken", "place_token"));
  }

  let owns = false;
  function draw() {
    const g = game;
    releaseOrder?.();
    releaseOrder = null;
    // Only clear what this panel drew; the context slot is shared with the other round panels (#49).
    if (!g || !isConcessionRound(g)) { claim(false); pick.show(null, null); wasHome = false; if (owns) { frame.slots.context.replaceChildren(); owns = false; } return; }
    owns = true;
    // The claims only hold while this panel owns the step: HomeToken also occurs in other rounds.
    claim(isFounding(g) || isHomeToken(g));
    frame.slots.context.replaceChildren(toDom(ConcessionPanel(g, sel, map(), listHandlers, choiceFromRoot(document.documentElement).theme, open)));
    const home = isHomeToken(g) && g.state.prompt.viewer_to_act;
    if (home && !wasHome) { pick.toMap(); const t = homeTargets(g, map())[0]; if (t) pick.flyTo(t.hex); }
    wasHome = home;
    pick.show(home ? homeMapTargets(g, map()) : null, home ? homePreview(g, sel, map()) : null);
    const spec = orderFor(g, sel, map(), (a) => frame.send(a));
    if (spec) releaseOrder = frame.setOrder(spec);
  }

  const off = frame.subscribe((g) => {
    if (g.seq !== seq) { seq = g.seq; sel = emptySelection(); }
    game = g;
    draw();
  });
  return {
    selectCity: (city) => { if (game && homeTargets(game, map()).some((t) => t.city === city)) handlers.onCity(city); },
    targets: () => (game ? homeTargets(game, map()) : []),
    refresh: draw,
    stop: () => { off(); releaseOrder?.(); claim(false); pick.stop(); if (owns) frame.slots.context.replaceChildren(); },
  };
}
