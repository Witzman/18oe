// Track panel of the operating round (#48, ui-spec 4.5 "Gleis", rulebook 11.1): the buildable hexes glow on
// the map, a tap on one (or a row here) picks it, the tiles that fit are drawn as small tiles, the rotation
// steps through the legal ones only (buttons, or tap the same hex again), the map shows the tile as it would
// lie. Cost and tile points are one line each. Nothing is sent until the main button confirms (#137).
//
// Pure model first (tests run it under node on recorded states), then the view, then `mountTrack`.
// The legal lays are exactly `prompt.actions` (type lay_tile); `prompt.context.track` adds cost and points.
import type { MapGeometry } from "../../render/mapdata.ts";
import type { MapPreview, MapTargets } from "../../render/map.ts";
import { tileName } from "../../render/preview.ts";
import { tileSvg } from "../../render/tile-svg.ts";
import { hexFrame, type HexFrame } from "../../render/track-axes.ts";
import type { GameFrame } from "../frame/frame.ts";
import type { OrderSpec } from "../frame/order.ts";
import { formatGeld, toDom, v, type Change, type VNode } from "../kit/index.ts";
import type { Corporation, Game } from "../../types.ts";
import { fillText, txt } from "../text.ts";
import { mapPick } from "./map-pick.ts";

type Action = Record<string, unknown>;

export interface TrackTile { id: string; name: string; color: string; rotations: { rotation: number; action: Action }[] }
export interface TrackHex {
  hex: string;
  /** Price for this corporation and its parts (context.track); null when the view has no context. */
  cost: number | null;
  costParts: { label: string; amount: number }[];
  points: number | null;
  tiles: TrackTile[];
}
export interface TrackSelection { hex: string | null; tile: string | null; rotation: number | null }
export const emptySelection = (): TrackSelection => ({ hex: null, tile: null, rotation: null });

export const isTrackStep = (g: Game): boolean => g.state.prompt.step === "Track" && !g.state.meta.finished;
export const mineToAct = (g: Game): boolean => isTrackStep(g) && g.state.prompt.viewer_to_act;

/** The corporation that builds: the entity of the offered actions, else the current one of the round. */
export function builder(g: Game): Corporation | null {
  const id = g.state.prompt.actions.find((a) => typeof a.entity === "string")?.entity ?? g.state.meta.current?.id;
  return g.state.corporations.find((c) => c.id === id) ?? null;
}

/** Buildable hexes in the order of the offered actions, each with its tiles and their legal rotations. */
export function trackHexes(g: Game, tiles?: MapGeometry["tiles"]): TrackHex[] {
  if (!mineToAct(g)) return [];
  const ctx = g.state.prompt.context?.track;
  const out = new Map<string, TrackHex>();
  for (const a of g.state.prompt.actions) {
    if (a.type !== "lay_tile") continue;
    const hex = String(a.hex), id = String(a.tile), rotation = Number(a.rotation);
    let h = out.get(hex);
    if (!h) {
      const c = ctx?.hexes?.find((x) => x.hex === hex);
      h = { hex, cost: c ? c.cost : null, costParts: c?.cost_parts ?? [], points: c ? c.points : null, tiles: [] };
      out.set(hex, h);
    }
    let t = h.tiles.find((x) => x.id === id);
    if (!t) {
      const name = tileName(id, tiles);
      const c = ctx?.hexes?.find((x) => x.hex === hex)?.tiles.find((x) => x.name === name);
      t = { id, name, color: c?.color ?? tiles?.[name]?.color ?? "yellow", rotations: [] };
      h.tiles.push(t);
    }
    t.rotations.push({ rotation, action: a });
  }
  for (const h of out.values()) for (const t of h.tiles) t.rotations.sort((a, b) => a.rotation - b.rotation);
  return [...out.values()];
}

/** The selection made whole: a picked hex gets its first tile, a tile its first legal rotation. */
export function effectiveSelection(g: Game, sel: TrackSelection, tiles?: MapGeometry["tiles"]): TrackSelection {
  const hexes = trackHexes(g, tiles);
  const h = hexes.find((x) => x.hex === sel.hex);
  if (!h) return emptySelection();
  const t = h.tiles.find((x) => x.id === sel.tile) ?? h.tiles[0];
  if (!t) return emptySelection();
  const r = t.rotations.find((x) => x.rotation === sel.rotation) ?? t.rotations[0]!;
  return { hex: h.hex, tile: t.id, rotation: r.rotation };
}

/** The next (dir 1) or previous (dir -1) legal rotation of the selected tile, wrapping around. */
export function turn(g: Game, sel: TrackSelection, dir: 1 | -1, tiles?: MapGeometry["tiles"]): TrackSelection {
  const eff = effectiveSelection(g, sel, tiles);
  const t = trackHexes(g, tiles).find((x) => x.hex === eff.hex)?.tiles.find((x) => x.id === eff.tile);
  if (!t) return eff;
  const i = t.rotations.findIndex((x) => x.rotation === eff.rotation);
  const n = t.rotations.length;
  return { ...eff, rotation: t.rotations[(i + dir + n) % n]!.rotation };
}

/** A tap on hex `hex` of the map: picks it, or turns the tile when it is already picked. Null = not buildable. */
export function tapHex(g: Game, sel: TrackSelection, hex: string, tiles?: MapGeometry["tiles"]): TrackSelection | null {
  if (!trackHexes(g, tiles).some((h) => h.hex === hex)) return null;
  const eff = effectiveSelection(g, sel, tiles);
  if (eff.hex === hex) return turn(g, eff, 1, tiles);
  return effectiveSelection(g, { hex, tile: null, rotation: null }, tiles);
}

interface Picked { hex: TrackHex; tile: TrackTile; index: number; action: Action }
function picked(g: Game, sel: TrackSelection, tiles?: MapGeometry["tiles"]): Picked | null {
  const eff = effectiveSelection(g, sel, tiles);
  const hex = trackHexes(g, tiles).find((x) => x.hex === eff.hex);
  const tile = hex?.tiles.find((x) => x.id === eff.tile);
  const index = tile ? tile.rotations.findIndex((x) => x.rotation === eff.rotation) : -1;
  return hex && tile && index >= 0 ? { hex, tile, index, action: tile.rotations[index]!.action } : null;
}

export function previewFor(g: Game, sel: TrackSelection, tiles?: MapGeometry["tiles"]): MapPreview {
  const p = picked(g, sel, tiles);
  return p ? { hex: p.hex.hex, tile: p.tile.name, rotation: Number(p.action.rotation) } : null;
}

export function targetsFor(g: Game, tiles?: MapGeometry["tiles"]): MapTargets | null {
  const hexes = trackHexes(g, tiles).map((h) => h.hex);
  return hexes.length > 0 ? { hexes, kind: "track" } : null;
}

const costLabel = (label: string) => (label === "terrain" || label === "discount" ? txt(`track.cost_part_${label}`).de : label);
export const costLine = (h: TrackHex): string | null => {
  if (h.cost === null) return null;
  const parts = h.costParts.map((p) => `${costLabel(p.label)} ${formatGeld(p.amount)}`).join(", ");
  return fillText("track.cost", { cost: formatGeld(h.cost) }) + (parts ? ` (${parts})` : "");
};

export interface Sentence { text: string; action: Action | null; changes: Change[] }

export function sentenceFor(g: Game, sel: TrackSelection, tiles?: MapGeometry["tiles"]): Sentence {
  const p = picked(g, sel, tiles);
  const corp = builder(g);
  if (!p || !corp) return { text: txt("track.sentence_pick").de, action: null, changes: [] };
  const cost = p.hex.cost ?? 0;
  const text = fillText("track.sentence", {
    corp: corp.id, tile: p.tile.name, hex: p.hex.hex, n: p.index + 1, m: p.tile.rotations.length, cost: formatGeld(cost),
  });
  const changes: Change[] = [{ label: fillText("track.change_cash", { who: corp.id }), before: formatGeld(corp.cash), after: formatGeld(corp.cash - cost) }];
  const pts = g.state.prompt.context?.track?.points;
  if (pts && p.hex.points !== null) changes.push({ label: txt("track.change_points").de, before: String(pts.left), after: String(Math.max(pts.left - p.hex.points, 0)) });
  return { text, action: p.action, changes };
}

/** The order for the action bar; null when it is not the viewer's turn in this step. */
export function orderFor(g: Game, sel: TrackSelection, send: (a: Action) => void, rotate: () => void, tiles?: MapGeometry["tiles"]): OrderSpec | null {
  if (!mineToAct(g)) return null;
  const s = sentenceFor(g, sel, tiles);
  const pass = g.state.prompt.actions.find((a) => a.type === "pass");
  const p = picked(g, sel, tiles);
  const action = s.action;
  const side = [];
  if (p && p.tile.rotations.length > 1) side.push({ label: txt("track.rotate").de, onClick: rotate });
  if (pass) side.push({ label: txt("track.pass").de, onClick: () => send(pass) });
  return {
    sentence: s.text, changes: s.changes, state: action ? "preview" : "invalid", reason: action ? undefined : s.text,
    confirmLabel: txt("track.confirm").de, onConfirm: () => { if (action) send(action); }, side,
  };
}

// ---- view ---------------------------------------------------------------------------------------
export interface TrackHandlers {
  onHex: (hex: string) => void;
  onTile: (tile: string) => void;
  onTurn: (dir: 1 | -1) => void;
  onMap: () => void;
}

function tileButton(t: TrackTile, selected: boolean, rotation: number, geo: { tiles: MapGeometry["tiles"]; frame: HexFrame } | null, h: TrackHandlers): VNode {
  const label = fillText("track.tile", { tile: t.name });
  const parts = geo?.tiles?.[t.name];
  return v("button", {
    type: "button", class: "track-tile", "data-tile": t.id, "aria-pressed": String(selected), "data-state": selected ? "selected" : "normal",
    title: label, onclick: () => h.onTile(t.id),
  }, parts && geo ? tileSvg(parts, rotation, geo.frame, { color: t.color, label, size: 56 }) : null, v("span", { class: "track-tile-name" }, t.name));
}

export function TrackPanel(g: Game, sel: TrackSelection, h: TrackHandlers, geometry: MapGeometry | null = null): VNode {
  const tiles = geometry?.tiles;
  const mine = mineToAct(g);
  const ctx = g.state.prompt.context?.track;
  const corp = builder(g);
  const head = v("h3", {}, txt("track.title").de);
  const points = ctx ? v("p", { class: "track-points" }, fillText("track.points", { left: ctx.points.left, budget: ctx.points.budget })) : null;
  if (!mine) return v("section", { class: "track-panel", "aria-label": txt("track.title").de }, head, points, v("p", { class: "muted" }, fillText("track.waiting", { corp: corp?.id ?? "" })));
  const hexes = trackHexes(g, tiles);
  const eff = effectiveSelection(g, sel, tiles);
  const chosen = hexes.find((x) => x.hex === eff.hex);
  const tile = chosen?.tiles.find((x) => x.id === eff.tile);
  const index = tile ? tile.rotations.findIndex((x) => x.rotation === eff.rotation) : -1;
  const geo = geometry?.tiles ? { tiles: geometry.tiles, frame: hexFrame(geometry.layout.edge_vectors) } : null;
  return v("section", { class: "track-panel", "aria-label": txt("track.title").de },
    head, points,
    v("p", { class: "muted track-hint" }, txt("track.hint").de),
    v("button", { type: "button", class: "track-map", onclick: () => h.onMap() }, txt("track.to_map").de),
    hexes.length === 0 ? v("p", { class: "muted" }, txt("track.none").de)
      : v("div", { class: "track-hexes", role: "list", "aria-label": txt("track.hexes").de }, ...hexes.map((x) => v("button", {
        type: "button", class: "track-hex", "data-hex": x.hex, "aria-pressed": String(x.hex === eff.hex), "data-state": x.hex === eff.hex ? "selected" : "normal",
        onclick: () => h.onHex(x.hex),
      }, fillText("track.hex_row", { hex: x.hex, cost: x.cost === null ? "–" : formatGeld(x.cost), points: x.points ?? "–" })))),
    chosen ? v("div", { class: "track-choice" },
      v("h4", {}, fillText("track.tiles", { hex: chosen.hex })),
      v("div", { class: "track-tiles", role: "group", "aria-label": fillText("track.tiles", { hex: chosen.hex }) },
        ...chosen.tiles.map((t) => tileButton(t, t.id === eff.tile, t.id === eff.tile ? eff.rotation! : t.rotations[0]!.rotation, geo, h))),
      tile ? v("div", { class: "track-rotation", role: "group", "aria-label": fillText("track.rotation", { n: index + 1, m: tile.rotations.length }) },
        v("button", { type: "button", class: "track-turn", "data-dir": "-1", title: txt("track.rotate_left").de, "aria-label": txt("track.rotate_left").de, disabled: tile.rotations.length < 2, onclick: () => h.onTurn(-1) }, "↺"),
        v("span", { class: "track-rotation-label" }, fillText("track.rotation", { n: index + 1, m: tile.rotations.length })),
        v("button", { type: "button", class: "track-turn", "data-dir": "1", title: txt("track.rotate_right").de, "aria-label": txt("track.rotate_right").de, disabled: tile.rotations.length < 2, onclick: () => h.onTurn(1) }, "↻")) : null,
      costLine(chosen) ? v("p", { class: "track-cost" }, costLine(chosen)) : null) : null);
}

// ---- mount --------------------------------------------------------------------------------------
export interface TrackHandle { stop: () => void; refresh: () => void }

export function mountTrack(frame: GameFrame, opts: { map?: () => MapGeometry | null } = {}): TrackHandle {
  let game: Game | null = null;
  let seq = -1;
  let sel = emptySelection();
  let wasMine = false;
  let releaseOrder: (() => void) | null = null;
  let shown: Node | null = null;
  const releases: (() => void)[] = [];
  const geometry = () => opts.map?.() ?? null;
  const tiles = () => geometry()?.tiles;
  const pick = mapPick(frame);

  const choose = (next: TrackSelection) => { frame.discardSelection(); sel = next; draw(); };
  const handlers: TrackHandlers = {
    onHex: (hex) => { if (game) { choose(effectiveSelection(game, { hex, tile: null, rotation: null }, tiles())); pick.flyTo(hex); } },
    onTile: (tile) => { if (game) choose(effectiveSelection(game, { ...sel, tile, rotation: null }, tiles())); },
    onTurn: (dir) => { if (game) choose(turn(game, sel, dir, tiles())); },
    onMap: () => { pick.toMap(); const hex = game ? effectiveSelection(game, sel, tiles()).hex : null; if (hex) pick.flyTo(hex); },
  };
  pick.on("hex", ({ hex }) => {
    if (!game || !hex || !mineToAct(game)) return;
    const next = tapHex(game, sel, hex, tiles());
    if (next) choose(next);
  });

  function claim(active: boolean) {
    while (releases.length > 0) releases.pop()!();
    if (active) releases.push(frame.claims.claim("Track", "lay_tile"), frame.claims.claim("Track", "pass"));
  }

  function draw() {
    const g = game;
    releaseOrder?.();
    releaseOrder = null;
    if (!g || !isTrackStep(g)) {
      claim(false);
      pick.show(null, null);
      wasMine = false;
      // Only remove what this panel drew; the context slot is shared with the other round panels.
      shown?.parentNode?.removeChild(shown);
      shown = null;
      return;
    }
    const mine = mineToAct(g);
    claim(mine);
    // The way back to the map (#114 rest): the own track step starts on the map.
    if (mine && !wasMine) pick.toMap();
    wasMine = mine;
    shown = toDom(TrackPanel(g, sel, handlers, geometry()));
    frame.slots.context.replaceChildren(shown);
    pick.show(mine ? targetsFor(g, tiles()) : null, mine ? previewFor(g, sel, tiles()) : null);
    const spec = orderFor(g, sel, (a) => frame.send(a), () => handlers.onTurn(1), tiles());
    if (spec) releaseOrder = frame.setOrder(spec);
  }

  const off = frame.subscribe((g) => {
    if (g.seq !== seq) { seq = g.seq; sel = emptySelection(); }
    game = g;
    draw();
  });
  return {
    stop: () => { off(); releaseOrder?.(); claim(false); pick.stop(); shown?.parentNode?.removeChild(shown); },
    refresh: () => draw(),
  };
}
