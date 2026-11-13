// Token panel of the operating round (#174, ui-spec 4.5 "Token", rulebook 11.2): the cities that can take
// a token glow on the map at their slots, a tap on one (or a row here) picks it, the map shows the token on
// its slot, the action bar says what it costs. Nothing is sent until the main button confirms (#137).
// S1 scope: the normal token step only; the home token stays with the concession panel (#172), special
// tokens and the follow-up step after a multi-city tile are v0.2.
//
// Pure model first (tests run it under node on recorded states), then the view, then `mountToken`.
// The legal placements are exactly `prompt.actions` (type place_token); `prompt.context.token` adds hex,
// city index and price per city.
import type { MapPreview, MapTargets } from "../../render/map.ts";
import type { GameFrame } from "../frame/frame.ts";
import type { OrderSpec } from "../frame/order.ts";
import { formatGeld, toDom, v, type Change, type VNode } from "../kit/index.ts";
import type { Corporation, Game } from "../../types.ts";
import { fillText, txt } from "../text.ts";
import { mapPick } from "./map-pick.ts";

type Action = Record<string, unknown>;

export interface TokenTarget {
  /** Engine city id, what the action carries ("57-7-0"). */
  id: string;
  /** Hex and city index on its tile; null when the view has no context (then the target is not on the map). */
  hex: string | null;
  city: number | null;
  price: number | null;
  action: Action;
}

export const isTokenStep = (g: Game): boolean => g.state.prompt.step === "Token" && !g.state.meta.finished;
export const mineToAct = (g: Game): boolean => isTokenStep(g) && g.state.prompt.viewer_to_act;

export function placer(g: Game): Corporation | null {
  const id = g.state.prompt.actions.find((a) => typeof a.entity === "string")?.entity ?? g.state.meta.current?.id;
  return g.state.corporations.find((c) => c.id === id) ?? null;
}

export function tokenTargets(g: Game): TokenTarget[] {
  if (!mineToAct(g)) return [];
  const ctx = g.state.prompt.context?.token;
  return g.state.prompt.actions.filter((a) => a.type === "place_token").map((a) => {
    const id = String(a.city);
    const c = ctx?.cities?.find((x) => x.id === id);
    return { id, hex: c?.hex ?? null, city: c ? c.city : null, price: c ? c.price : ctx?.price ?? null, action: a };
  });
}

/** The picked city id; a single target counts as picked (it is the only choice, previewed). */
export function effectiveCity(g: Game, sel: string | null): string | null {
  const ts = tokenTargets(g);
  return ts.find((t) => t.id === sel)?.id ?? (ts.length === 1 ? ts[0]!.id : null);
}

/** A tap on the map: on a slot (`city` given) picks that city; on a hex only when it has exactly one target. */
export function tapMap(g: Game, hex: string, city?: number): string | null {
  const on = tokenTargets(g).filter((t) => t.hex === hex);
  const hit = city === undefined ? undefined : on.find((t) => t.city === city);
  return hit?.id ?? (on.length === 1 ? on[0]!.id : null);
}

export function targetsFor(g: Game): MapTargets | null {
  const cities = tokenTargets(g).filter((t) => t.hex !== null && t.city !== null).map((t) => ({ hex: t.hex!, city: t.city! }));
  return cities.length > 0 ? { cities, kind: "token" } : null;
}

export function previewFor(g: Game, sel: string | null): MapPreview {
  const t = tokenTargets(g).find((x) => x.id === effectiveCity(g, sel));
  const corp = placer(g);
  return t && t.hex !== null && t.city !== null && corp ? { hex: t.hex, city: t.city, corp: corp.id } : null;
}

export interface Sentence { text: string; action: Action | null; changes: Change[] }

export function sentenceFor(g: Game, sel: string | null): Sentence {
  const t = tokenTargets(g).find((x) => x.id === effectiveCity(g, sel));
  const corp = placer(g);
  if (!t || !corp) return { text: txt("token.sentence_pick").de, action: null, changes: [] };
  const price = t.price ?? 0;
  const text = fillText("token.sentence", { corp: corp.id, hex: t.hex ?? t.id, city: (t.city ?? 0) + 1, price: formatGeld(price) });
  const changes: Change[] = [{ label: fillText("token.change_cash", { who: corp.id }), before: formatGeld(corp.cash), after: formatGeld(corp.cash - price) }];
  const left = g.state.prompt.context?.token?.tokens_left;
  if (typeof left === "number") changes.push({ label: txt("token.change_left").de, before: String(left), after: String(Math.max(left - 1, 0)) });
  return { text, action: t.action, changes };
}

export function orderFor(g: Game, sel: string | null, send: (a: Action) => void): OrderSpec | null {
  if (!mineToAct(g)) return null;
  const s = sentenceFor(g, sel);
  const pass = g.state.prompt.actions.find((a) => a.type === "pass");
  const action = s.action;
  return {
    sentence: s.text, changes: s.changes, state: action ? "preview" : "invalid", reason: action ? undefined : s.text,
    confirmLabel: txt("token.confirm").de, onConfirm: () => { if (action) send(action); },
    side: pass ? [{ label: txt("token.pass").de, onClick: () => send(pass) }] : [],
  };
}

// ---- view ---------------------------------------------------------------------------------------
export interface TokenHandlers { onCity: (id: string) => void; onMap: () => void }

export function TokenPanel(g: Game, sel: string | null, h: TokenHandlers): VNode {
  const mine = mineToAct(g);
  const ctx = g.state.prompt.context?.token;
  const corp = placer(g);
  const head = v("h3", {}, txt("token.title").de);
  const left = ctx && ctx.price !== null ? v("p", { class: "token-left" }, fillText("token.left", { n: ctx.tokens_left, price: formatGeld(ctx.price) })) : null;
  if (!mine) return v("section", { class: "token-panel", "aria-label": txt("token.title").de }, head, left, v("p", { class: "muted" }, fillText("token.waiting", { corp: corp?.id ?? "" })));
  const ts = tokenTargets(g);
  const eff = effectiveCity(g, sel);
  return v("section", { class: "token-panel", "aria-label": txt("token.title").de },
    head, left,
    v("p", { class: "muted token-hint" }, txt("token.hint").de),
    v("button", { type: "button", class: "track-map", onclick: () => h.onMap() }, txt("track.to_map").de),
    ts.length === 0 ? v("p", { class: "muted" }, txt("token.none").de)
      : v("div", { class: "token-cities", role: "list", "aria-label": txt("token.targets").de }, ...ts.map((t) => v("button", {
        type: "button", class: "token-city", "data-city": t.id, "aria-pressed": String(t.id === eff), "data-state": t.id === eff ? "selected" : "normal",
        onclick: () => h.onCity(t.id),
      }, fillText("token.city_row", { hex: t.hex ?? t.id, city: (t.city ?? 0) + 1, price: t.price === null ? "–" : formatGeld(t.price) })))));
}

// ---- mount --------------------------------------------------------------------------------------
export interface TokenHandle { stop: () => void }

export function mountToken(frame: GameFrame): TokenHandle {
  let game: Game | null = null;
  let seq = -1;
  let sel: string | null = null;
  let wasMine = false;
  let releaseOrder: (() => void) | null = null;
  let shown: Node | null = null;
  const releases: (() => void)[] = [];
  const pick = mapPick(frame);

  const choose = (id: string) => { frame.discardSelection(); sel = id; draw(); };
  const handlers: TokenHandlers = {
    onCity: (id) => { choose(id); const t = game ? tokenTargets(game).find((x) => x.id === id) : undefined; if (t?.hex) pick.flyTo(t.hex); },
    onMap: () => { pick.toMap(); const t = game ? tokenTargets(game).find((x) => x.id === effectiveCity(game!, sel)) : undefined; if (t?.hex) pick.flyTo(t.hex); },
  };
  // A slot tap fires "city" and then "hex": the city wins, the hex only picks when its target is unambiguous.
  let lastCity: { hex: string; at: number } | null = null;
  pick.on("city", ({ hex, city }) => {
    if (!game || !hex || !mineToAct(game)) return;
    const id = tapMap(game, hex, city);
    if (id) { lastCity = { hex, at: Date.now() }; choose(id); }
  });
  pick.on("hex", ({ hex }) => {
    if (!game || !hex || !mineToAct(game)) return;
    if (lastCity && lastCity.hex === hex && Date.now() - lastCity.at < 50) return;
    const id = tapMap(game, hex);
    if (id) choose(id);
  });

  function claim(active: boolean) {
    while (releases.length > 0) releases.pop()!();
    if (active) releases.push(frame.claims.claim("Token", "place_token"), frame.claims.claim("Token", "pass"));
  }

  function draw() {
    const g = game;
    releaseOrder?.();
    releaseOrder = null;
    if (!g || !isTokenStep(g)) {
      claim(false);
      pick.show(null, null);
      wasMine = false;
      shown?.parentNode?.removeChild(shown);
      shown = null;
      return;
    }
    const mine = mineToAct(g);
    claim(mine);
    if (mine && !wasMine) pick.toMap();
    wasMine = mine;
    shown = toDom(TokenPanel(g, sel, handlers));
    frame.slots.context.replaceChildren(shown);
    pick.show(mine ? targetsFor(g) : null, mine ? previewFor(g, sel) : null);
    const spec = orderFor(g, sel, (a) => frame.send(a));
    if (spec) releaseOrder = frame.setOrder(spec);
  }

  const off = frame.subscribe((g) => {
    if (g.seq !== seq) { seq = g.seq; sel = null; }
    game = g;
    draw();
  });
  return { stop: () => { off(); releaseOrder?.(); claim(false); pick.stop(); shown?.parentNode?.removeChild(shown); } };
}
