// The map facade (ui-spec 2.3, #44): the only thing panels know about the map.
//
//   const map = await mountMap(el, geometry);   // geometry = GET /map
//   map.setState(game); map.setTargets({ hexes, kind }); map.on("hex", ({ hex }) => ...);
//
// One PixiJS Application, eleven layer containers in the spec's order (LAYERS). The flat layers
// (land, grid, tiles, overlay) hold one container per height level, each carrying the camera matrix
// of its level (projection.levelMatrix); their content is drawn once in flat world coordinates, so
// moving the camera only sets matrices. A RenderLayer per level draws them level by level (land,
// grid, tiles, overlay of the sea level, then of the land level, ...), so a raised hex covers the
// lines and tiles of the lower hexes behind it. Drawing happens on demand (no running ticker).
//
// Cities, towns, off-boards, tokens (#147): flat parts in the tile container, standing tokens in the
// objects layer, revenue shields and token symbols in the labels layer (from Z2).
// Built here: sea and land plates in theme colours, hex lines, province borders, terrain signs
// with costs, tile surfaces with per-hex redraw, hover and valid targets, pan/zoom/centre/fly,
// block culling, redraw on oe:themechange. Stored but drawn by later issues: setPreview (#48),
// setLayers apart from terrainCost (#151), showRoutes (#155), labels (#149).
// Walls (#145): one container per level in the walls layer, drawn in unit screen coordinates
// (zoom 1, pan 0) and carried by position = pan, scale = zoom; redrawn in build() (theme or tile
// height change), not on pan or zoom. A laid tile raises its hex by heightTile: when the set of
// tiled hexes changes, setState rebuilds the scene.
import { Application, Container, Graphics, Matrix, RenderLayer, Text } from "pixi.js";
import type { Game, GameState, HexChange } from "../types.ts";
import { THEME_CHANGED } from "../ui/theme-switch.ts";
import { between, centerOn, clampPan, fit, frame, panBy, zoomAt, zoomStage, Z1_FROM, Z2_FROM, type Viewport } from "./camera.ts";
import { drawGrid, drawPlate, drawWalls, type Block } from "./layers/static.ts";
import { drawTileSurface } from "./layers/tiles.ts";
import { drawTrack, setTrackStage, type TrackNode } from "./track.ts";
import { drawNodes, drawTargetCity, inkOn, makeToken, type Ring } from "./layers/nodes.ts";
import { citySlots, companyIndex, hitSlot, labelAt, revenueAll, revenueNow, shieldAt, medallionExtent, type Slot } from "./stones.ts";
import { hexFrame, tileGeometry, type TileGeometry, type TileParts } from "./track-axes.ts";
import type { MapGeometry } from "./mapdata.ts";
import { levelMatrix, mapCenter, pick, project, unproject, worldCorners, type Vec, type View } from "./projection.ts";
import { boxOnScreen, buildScene, COST_AT, terrainMark, type Scene } from "./scene.ts";
import { currentRenderTheme, type RenderTheme } from "./theme.ts";
import { changedHexes, signatures, type TileSignatures } from "./tilestate.ts";

export const LAYERS = ["sea", "seaMarks", "land", "walls", "grid", "tiles", "overlay", "routes", "objects", "labels", "ui"] as const;
export type LayerName = (typeof LAYERS)[number];
/** Flat layers with one container per height level. */
const LEVELED = ["land", "grid", "tiles", "overlay"] as const satisfies readonly LayerName[];
type Leveled = (typeof LEVELED)[number];

export interface MapTargets {
  hexes?: string[];
  cities?: { hex: string; city: number }[];
  kind: string;
}
export type MapPreview = { hex: string; tile: string; rotation: number } | { hex: string; city: number; corp: string } | null;
export interface MapLayers {
  zones?: boolean;
  seaways?: boolean;
  oeRoute?: boolean;
  terrainCost?: boolean;
  ownership?: boolean;
  lastRuns?: boolean;
}
export type MapEvent = "hex" | "city" | "hover";
export interface MapEventData {
  hex: string | null;
  /** Engine city index and slot of a "city" event (a click on a token slot; "hex" fires as well). */
  city?: number;
  slot?: number;
}

export interface MapOptions {
  /** Overrides the theme camera (dev page and screenshots: ?pitch=60&yaw=0). */
  camera?: { pitch?: number; yaw?: number };
  /** Cache each static block as a texture (ui-spec 2.3). Off by default, see README of #44 measurements. */
  cache?: boolean;
  /** Where the theme comes from (tests); default: the theme on the root element. */
  theme?: () => RenderTheme;
}

export interface MapStats {
  /** Scene build plus first frame, ms. */
  buildMs: number;
  themeMs: number | null;
  stateMs: number | null;
  /** Hexes redrawn by the last setState. */
  stateHexes: number;
  frameMs: number | null;
  blocks: number;
  visibleBlocks: number;
}

export interface MapView {
  setState(game: Game | GameState): void;
  setTargets(targets: MapTargets | null): void;
  setPreview(preview: MapPreview): void;
  setLayers(layers: MapLayers): void;
  showRoutes(routes: unknown[], opts?: { animate?: boolean }): void;
  /** Fly to a hex id or a corporation id (its tokens, else its home). False if unknown. */
  flyTo(target: string): boolean;
  on(event: MapEvent, handler: (data: MapEventData) => void): () => void;
  /** Whole map in view (key `0`). */
  fit(animate?: boolean): void;
  readonly view: View;
  readonly scene: Scene;
  layer(name: LayerName): Container;
  /** Screen position of a hex top centre (tests, screenshots). */
  hexOnScreen(id: string): Vec | null;
  /** Resolves after the next frame is drawn. */
  rendered(): Promise<void>;
  stats(): MapStats;
  destroy(): void;
}

function reducedMotion(theme: RenderTheme): boolean {
  if (!theme.motion.enabled) return true;
  try { return window.matchMedia("(prefers-reduced-motion: reduce)").matches; } catch { return false; }
}

const DRAG_PX = 4;
/** A slot is hit within at least this many px, so a finger finds a small token (ui-spec 6). */
const MIN_HIT_PX = 12;
/** Below this element size in px the map keeps its last size (hidden or collapsed element). */
const MIN_SIZE = 64;

export async function mountMap(el: HTMLElement, geometry: MapGeometry, options: MapOptions = {}): Promise<MapView> {
  const t0 = performance.now();
  const readTheme = () => {
    const t = (options.theme ?? currentRenderTheme)();
    return { ...t, camera: { ...t.camera, ...options.camera } };
  };
  let theme = readTheme();
  const app = new Application();
  const dpr = Math.max(1, window.devicePixelRatio || 1);
  await app.init({
    background: theme.ui.bg, antialias: true, autoStart: false, sharedTicker: false,
    resolution: dpr, autoDensity: true, width: el.clientWidth >= MIN_SIZE ? el.clientWidth : 800, height: el.clientHeight >= MIN_SIZE ? el.clientHeight : 600, preference: "webgl",
  });
  app.ticker.stop();
  const canvas = app.canvas;
  // The canvas follows the element's size and never sets it (no feedback through layout).
  canvas.style.cssText = "position:absolute;left:0;top:0;display:block;touch-action:none";
  if (getComputedStyle(el).position === "static") el.style.position = "relative";
  el.style.overflow = "hidden";
  el.append(canvas);
  if (el.tabIndex < 0) el.tabIndex = 0;

  const layers = Object.fromEntries(LAYERS.map((n) => {
    const c = new Container({ label: n });
    app.stage.addChild(c);
    return [n, c];
  })) as Record<LayerName, Container>;

  layers.objects.sortableChildren = true; // tokens nearer the viewer cover those behind (zIndex = screen y)

  // Per-build state (rebuilt on theme change).
  let scene!: Scene;
  let levelRL: RenderLayer[] = [];
  let levelNodes: Record<Leveled, Container[]> = { land: [], grid: [], tiles: [], overlay: [] };
  let wallNodes: Container[] = [];
  let seaLevel!: Container;
  let seaMarksLevel!: Container;
  let blocks: Block[] = [];
  let tileNodes = new Map<string, Container>();
  let trackNodes = new Map<string, TrackNode>();
  /** Standing tokens and text marks (token symbols, revenue shields, tile labels) per hex. */
  interface TokenObj { c: Container; at: Vec; z: number; sym: Text; symWidth: number }
  interface Mark { text: Text; at: Vec; z: number }
  let tokenObjs = new Map<string, TokenObj[]>();
  let marks = new Map<string, Mark[]>();
  const frame3 = hexFrame(geometry.layout.edge_vectors);
  const geomCache = new Map<string, TileGeometry>();
  let targetG: Graphics[] = [];
  let hoverG!: Graphics;
  let costs: { id: string; text: Text; at: Vec; z: number }[] = [];
  let printed = new Map<string, string>();

  // Session state.
  const vp = (): Viewport => ({ width: app.renderer.width / app.renderer.resolution, height: app.renderer.height / app.renderer.resolution });
  let view: View = { pitch: theme.camera.pitch, yaw: theme.camera.yaw, zoom: 10, panX: 0, panY: 0, centerX: 0, centerY: 0 };
  let baseZoom = 10;
  let state: GameState | null = null;
  let sigs: TileSignatures = new Map();
  let nodeSigs: TileSignatures = new Map();
  let entries = new Map<string, HexChange>();
  let targets: MapTargets | null = null;
  let preview: MapPreview = null;
  let shownLayers: MapLayers = { terrainCost: true };
  let routes: unknown[] = [];
  let hover: string | null = null;
  let cacheRes = 0;
  const handlers = new Map<MapEvent, Set<(d: MapEventData) => void>>();
  const stats: MapStats = { buildMs: 0, themeMs: null, stateMs: null, stateHexes: 0, frameMs: null, blocks: 0, visibleBlocks: 0 };
  void preview; void routes;

  const emit = (e: MapEvent, d: MapEventData) => handlers.get(e)?.forEach((h) => h(d));

  function clearLayers() {
    for (const rl of levelRL) { rl.detachAll(); rl.destroy(); }
    levelRL = [];
    for (const n of LAYERS) for (const c of layers[n].removeChildren()) c.destroy({ children: true });
  }

  function build() {
    clearLayers();
    printed = new Map(geometry.hexes.filter((h) => h.color && h.color !== "white" && h.color !== "blue").map((h) => [h.id, h.color!]));
    scene = buildScene(geometry, theme, tiledHexes());
    const c = mapCenter(scene.grid);
    view = { ...view, centerX: c.x, centerY: c.y };
    seaLevel = layers.sea.addChild(new Container({ label: "level0" }));
    seaMarksLevel = layers.seaMarks.addChild(new Container({ label: "level0" }));
    levelNodes = { land: [], grid: [], tiles: [], overlay: [] };
    wallNodes = [];
    const wallGraphics = drawWalls(scene, { ...view, zoom: 1, panX: 0, panY: 0 }, theme);
    scene.levels.forEach((z, i) => {
      const rl = new RenderLayer();
      app.stage.addChildAt(rl, 2 + i);
      levelRL.push(rl);
      for (const n of LEVELED) {
        const c = layers[n].addChild(new Container({ label: `level${i} z=${z}` }));
        levelNodes[n].push(c);
        rl.attach(c);
        if (n === "land") {
          // The walls of this level come right after its tops: higher hexes cover them, lower ones do not.
          const w = layers.walls.addChild(new Container({ label: `walls${i} z=${z}` }));
          w.addChild(wallGraphics[i]!);
          wallNodes.push(w);
          rl.attach(w);
        }
      }
    });
    blocks = [];
    for (const plate of scene.plates) {
      const b = drawPlate(scene, plate, theme);
      (plate.level === 0 ? seaLevel : levelNodes.land[plate.level]!).addChild(b.node);
      blocks.push(b);
    }
    for (const b of drawGrid(scene, theme)) {
      levelNodes.grid[b.level]!.addChild(b.node);
      blocks.push(b);
    }
    cacheRes = 0;
    stats.blocks = blocks.length;
    // Tiles: printed and laid.
    tileNodes = new Map();
    trackNodes = new Map();
    tokenObjs = new Map();
    marks = new Map();
    for (const id of new Set([...printed.keys(), ...entries.keys(), ...geometry.hexes.filter((h) => h.paths?.length || hasNodes(h)).map((h) => h.id)])) drawTile(id);
    nodeSigs = computeNodeSigs();
    // Overlay: targets per level, one hover outline.
    targetG = levelNodes.overlay.map((c) => c.addChild(new Graphics()));
    hoverG = new Graphics();
    drawTargets();
    hover = null;
    // Terrain costs (screen space, labels layer).
    costs = [];
    const fontFamily = theme.font.body;
    for (const g of scene.grid.hexes) {
      const mark = terrainMark(scene.hexById.get(g.id)!);
      if (!mark) continue;
      const text = new Text({
        text: String(mark.cost), resolution: dpr,
        style: { fontFamily, fontSize: 11, fontWeight: "600", fill: theme.map.label, stroke: { color: theme.map.labelHalo, width: 3, join: "round" } },
      });
      text.anchor.set(0, 0.5);
      layers.labels.addChild(text);
      costs.push({ id: g.id, text, at: { x: g.x + COST_AT.x, y: g.y + COST_AT.y }, z: g.z });
    }
    app.renderer.background.color = theme.ui.bg;
  }

  /** Hexes raised by a laid tile, with the tile colour. ASSUMPTION: an entry whose colour differs from the printed one (so a hex that only reports its printed tile because of tokens stays low). */
  function tiledHexes(): Map<string, string> {
    const out = new Map<string, string>();
    for (const [id, e] of entries) {
      const color = e.tile.color;
      if (color && color !== "white" && color !== "blue" && color !== printed.get(id)) out.set(id, color);
    }
    return out;
  }

  const hasNodes = (p: TileParts) => !!(p.cities?.length || p.towns?.length || p.double_towns?.length || p.offboards?.length);

  /** Parts of the tile on hex id: the laid tile from the catalog, else the printed one (rotation 0). */
  function partsOf(id: string): TileParts | undefined {
    const laid = entries.get(id)?.tile;
    // A hex with tokens but no laid tile reports its printed tile, which is not in the catalog: draw the printed parts.
    return (laid && geometry.tiles?.[laid.name]) || scene.hexById.get(id);
  }

  /** Axes and nodes of that tile. Cached per tile and rotation. */
  function geomOf(id: string): TileGeometry | null {
    const laid = entries.get(id)?.tile;
    const parts = partsOf(id);
    if (!parts || !(parts.paths?.length || hasNodes(parts))) return null;
    const key = laid && geometry.tiles?.[laid.name] ? `${laid.name}|${laid.rotation}` : `printed|${id}`;
    let geom = geomCache.get(key);
    if (!geom) geomCache.set(key, (geom = tileGeometry(parts, laid ? laid.rotation : 0, frame3)));
    return geom;
  }

  // ---- game state seen by the nodes (tokens, home rings, revenue) ----------------------------

  /** Company colour: stable index into the placeholder colours company.c1..c6 (ASSUMPTION until #99). */
  const corpColor = (corp: string) => theme.company[`c${companyIndex(state?.corporations ?? [], corp, 6) + 1}` as keyof typeof theme.company];
  const homeHexes = (corp: string) => (geometry.homes ?? []).filter((h) => h.corporation === corp).map((h) => h.hex);
  const phaseColors = () => state?.meta.phase?.tiles ?? ["yellow"];
  /** Tokens per city of the hex: corporation ids per slot. */
  const tokensOf = (id: string) => entries.get(id)?.tokens ?? [];
  const minSlotsOf = (id: string) => tokensOf(id).reduce<number[]>((m, t) => { m[t.city] = t.corporations.length; return m; }, []);

  /** Slots of the tile on hex id (hex coordinates), for drawing, tokens and hit tests. */
  function slotsOf(id: string): Slot[] {
    const parts = partsOf(id), geom = geomOf(id);
    if (!parts || !geom) return [];
    return citySlots(parts, geom.nodes, theme.slotRadius, minSlotsOf(id));
  }

  /** Home token (light ring at the foot) or reserved home slot (dashed ring). ASSUMPTION: the home city is city 0, its first free slot. */
  function ringsOf(id: string, slots: Slot[]): Ring[] {
    if (!state) return [];
    const out: Ring[] = [];
    const taken = new Set<string>();
    tokensOf(id).forEach((t) => t.corporations.forEach((c, i) => {
      if (!c) return;
      taken.add(`${t.city}/${i}`);
      if (!homeHexes(c).includes(id)) return;
      const slot = slots.find((s) => s.city === t.city && s.slot === i);
      if (slot) out.push({ slot, kind: "home", color: corpColor(c) });
    }));
    for (const corp of state.corporations) {
      if (corp.closed || !homeHexes(corp.id).includes(id)) continue;
      if (tokensOf(id).some((t) => t.corporations.includes(corp.id))) continue;
      const slot = slots.find((s) => s.city === 0 && !taken.has(`0/${s.slot}`));
      if (!slot) continue;
      taken.add(`0/${slot.slot}`);
      out.push({ slot, kind: "reserved", color: corpColor(corp.id) });
    }
    return out;
  }

  /** What the nodes of a hex show that does not come from state.map: rings, colours, revenue now. Compared per setState. */
  function nodeSig(id: string): string {
    const parts = partsOf(id);
    if (!parts || !hasNodes(parts)) return "";
    const colors = phaseColors();
    const revs = [...(parts.cities ?? []), ...(parts.towns ?? []), ...(parts.double_towns ?? [])].map((n) => revenueNow(n.revenue, colors));
    return JSON.stringify([ringsOf(id, slotsOf(id)).map((r) => [r.kind, r.slot.city, r.slot.slot, r.color]), revs, tokensOf(id).flatMap((t) => t.corporations.map((c) => c && corpColor(c)))]);
  }

  const computeNodeSigs = (): TileSignatures => new Map(geometry.hexes.map((x) => [x.id, nodeSig(x.id)] as const).filter(([, v]) => v !== ""));

  function mark(id: string, text: string, at: Vec, z: number) {
    const t = new Text({
      text, resolution: dpr,
      style: { fontFamily: theme.font.body, fontSize: 10, fontWeight: "700", fill: theme.map.label, stroke: { color: theme.map.labelHalo, width: 3, join: "round" } },
    });
    t.anchor.set(0.5);
    t.visible = false;
    layers.labels.addChild(t);
    const m = marks.get(id) ?? [];
    m.push({ text: t, at, z });
    marks.set(id, m);
  }

  function dropMarks(id: string) {
    for (const m of marks.get(id) ?? []) m.text.destroy();
    marks.delete(id);
    for (const t of tokenObjs.get(id) ?? []) { t.c.destroy({ children: true }); t.sym.destroy(); }
    tokenObjs.delete(id);
  }

  function drawTile(id: string) {
    const g = scene.grid.byId.get(id);
    if (!g) return;
    const old = tileNodes.get(id);
    if (old) { old.destroy({ children: true }); tileNodes.delete(id); trackNodes.delete(id); }
    dropMarks(id);
    const color = entries.get(id)?.tile.color ?? printed.get(id);
    const surface = drawTileSurface(scene.grid, g, color, theme);
    const geom = geomOf(id);
    const axes = geom?.axes ?? [];
    if (!surface && !geom) return;
    const node = new Container({ label: id });
    const origin = { x: g.x, y: g.y };
    if (surface) node.addChild(surface);
    if (axes.length) {
      const t = drawTrack(axes, origin, theme);
      setTrackStage(t, zoomStage(view.zoom));
      node.addChild(t.node);
      trackNodes.set(id, t);
    }
    const parts = partsOf(id);
    if (geom && parts && hasNodes(parts)) {
      const slots = slotsOf(id);
      const patronage = Object.keys(entries.get(id)?.patronage ?? {}).length ? (parts.cities ?? []).map((_, i) => i) : [];
      node.addChild(drawNodes({ parts, nodes: geom.nodes, axes, frame: frame3, origin, rings: ringsOf(id, slots), patronage, minSlots: minSlotsOf(id) }, theme));
      // Tokens: standing cylinders in the objects layer, symbol on top from Z2.
      const objs: TokenObj[] = [];
      for (const t of tokensOf(id)) {
        t.corporations.forEach((corp, i) => {
          const s = corp && slots.find((x) => x.city === t.city && x.slot === i);
          if (!corp || !s) return;
          const c = makeToken(theme, corpColor(corp));
          layers.objects.addChild(c);
          const sym = new Text({ text: corp, resolution: dpr, style: { fontFamily: theme.font.body, fontSize: 11, fontWeight: "700", fill: inkOn(corpColor(corp), theme) } });
          sym.anchor.set(0.5);
          sym.visible = false;
          layers.labels.addChild(sym);
          objs.push({ c, sym, symWidth: sym.width, at: { x: g.x + s.pos.x, y: g.y + s.pos.y }, z: g.z });
        });
      }
      if (objs.length) tokenObjs.set(id, objs);
      // Revenue shields (from Z2): cities and towns by the phase now, double towns on revenue_loc, off-boards all phases.
      const colors = phaseColors();
      for (const n of geom.nodes) {
        const part = [...(parts.cities ?? []), ...(parts.towns ?? []), ...(parts.double_towns ?? []), ...(parts.offboards ?? [])].find((x) => x.node === n.node);
        const v = revenueNow(part?.revenue, colors);
        const text = n.kind === "offboard" ? revenueAll(part?.revenue) : v ? String(v) : null;
        if (!text) continue;
        const slotsN = n.kind === "city" ? (parts.cities?.find((c) => c.node === n.node)?.slots ?? 1) : 1;
        const at = shieldAt(n, medallionExtent(slotsN, theme.slotRadius), frame3);
        mark(id, text, { x: g.x + at.x, y: g.y + at.y }, g.z);
      }
    }
    if (parts?.labels?.length) {
      const at = labelAt(frame3);
      mark(id, parts.labels.join(""), { x: g.x + at.x, y: g.y + at.y }, g.z);
    }
    levelNodes.tiles[scene.levelOf.get(id)!]!.addChild(node);
    tileNodes.set(id, node);
  }

  function drawTargets() {
    targetG.forEach((g) => g.clear());
    for (const id of targets?.hexes ?? []) {
      const h = scene.grid.byId.get(id);
      if (!h) continue;
      const g = targetG[scene.levelOf.get(id)!]!;
      g.poly(worldCorners(scene.grid, h).flatMap((p) => [p.x, p.y]))
        .fill({ color: theme.map.valid, alpha: theme.targetAlpha })
        .stroke({ width: theme.focusLine * 0.6, color: theme.map.valid });
    }
    drawCityTargets();
  }

  function drawCityTargets() {
    for (const c of targets?.cities ?? []) {
      const h = scene.grid.byId.get(c.hex);
      if (!h) continue;
      drawTargetCity(targetG[scene.levelOf.get(c.hex)!]!, slotsOf(c.hex).filter((s) => s.city === c.city), { x: h.x, y: h.y }, theme);
    }
  }

  function drawHover() {
    hoverG.clear();
    hoverG.removeFromParent();
    const h = hover ? scene.grid.byId.get(hover) : undefined;
    if (!h) return;
    levelNodes.overlay[scene.levelOf.get(h.id)!]!.addChild(hoverG);
    hoverG.poly(worldCorners(scene.grid, h).flatMap((p) => [p.x, p.y])).stroke({ width: theme.focusLine, color: theme.map.selected, join: "round" });
    canvas.style.cursor = targets?.hexes?.includes(h.id) ? "pointer" : "";
  }

  /** Camera to containers: matrices, culling, zoom-stage detail, cost positions, cache resolution. */
  function applyView() {
    const { width, height } = vp();
    const mats = scene.levels.map((z) => {
      const m = levelMatrix(view, z);
      return new Matrix(m.a, m.b, m.c, m.d, m.tx, m.ty);
    });
    seaLevel.setFromMatrix(mats[0]!);
    seaMarksLevel.setFromMatrix(mats[0]!);
    for (const n of LEVELED) levelNodes[n].forEach((c, i) => c.setFromMatrix(mats[i]!));
    for (const w of wallNodes) { w.position.set(view.panX, view.panY); w.scale.set(view.zoom); }
    const stage = zoomStage(view.zoom);
    for (const t of trackNodes.values()) setTrackStage(t, stage);
    let visible = 0;
    for (const b of blocks) {
      b.node.visible = boxOnScreen(b.box, view, scene.levels[b.level]!, width, height, 8);
      if (b.detail) b.detail.visible = stage >= 1;
      if (b.node.visible) visible++;
    }
    stats.visibleBlocks = visible;
    const showCosts = stage >= 2 && shownLayers.terrainCost !== false;
    for (const c of costs) {
      const p = project(view, c.at, c.z);
      const on = showCosts && !entries.has(c.id) && p.x > -40 && p.x < width + 40 && p.y > -20 && p.y < height + 20;
      c.text.visible = on;
      if (on) c.text.position.set(Math.round(p.x), Math.round(p.y));
    }
    for (const list of tokenObjs.values()) {
      for (const t of list) {
        const p = project(view, t.at, t.z);
        const on = p.x > -40 && p.x < width + 40 && p.y > -40 && p.y < height + 40;
        t.c.visible = on;
        if (!on) { t.sym.visible = false; continue; }
        t.c.position.set(p.x, p.y);
        t.c.scale.set(view.zoom);
        t.c.zIndex = p.y;
        const top = p.y - theme.camera.heightToken * Math.sin((view.pitch * Math.PI) / 180) * view.zoom;
        t.sym.visible = stage >= 2;
        // The symbol shrinks to fit the top of the token (never grows past its font size).
        t.sym.scale.set(Math.min(1, (1.75 * theme.tokenRadius * view.zoom) / t.symWidth));
        t.sym.position.set(Math.round(p.x), Math.round(top));
      }
    }
    for (const list of marks.values()) {
      for (const m of list) {
        const p = project(view, m.at, m.z);
        const on = stage >= 2 && p.x > -40 && p.x < width + 40 && p.y > -20 && p.y < height + 20;
        m.text.visible = on;
        if (on) m.text.position.set(Math.round(p.x), Math.round(p.y));
      }
    }
    if (options.cache) {
      // One texture resolution per power of two of the zoom: re-rendered only when that changes.
      const res = Math.min(64, 2 ** Math.ceil(Math.log2(Math.max(1, view.zoom * dpr))));
      if (res !== cacheRes) {
        cacheRes = res;
        for (const b of blocks) { b.node.cacheAsTexture(false); b.node.cacheAsTexture({ resolution: res, antialias: true }); }
      }
    }
  }

  let frameReq = 0;
  let waiting: (() => void)[] = [];
  function render() {
    if (frameReq) return;
    frameReq = requestAnimationFrame(() => {
      frameReq = 0;
      const t = performance.now();
      applyView();
      app.renderer.render(app.stage);
      stats.frameMs = performance.now() - t;
      const w = waiting;
      waiting = [];
      w.forEach((f) => f());
    });
  }

  function setView(v: View) {
    view = clampPan(v, scene.bounds, vp());
    render();
  }

  let flight = 0;
  function animateTo(to: View) {
    cancelAnimationFrame(flight);
    const ms = theme.motion.flyMs;
    if (reducedMotion(theme) || ms <= 0) { setView(to); return; }
    const from = view, start = performance.now(), size = vp();
    const step = () => {
      const t = Math.min(1, (performance.now() - start) / ms);
      view = between(from, to, t, size);
      render();
      if (t < 1) flight = requestAnimationFrame(step);
    };
    flight = requestAnimationFrame(step);
  }

  function fitView(animate = false) {
    const v = fit(scene.grid, view, vp());
    baseZoom = v.zoom;
    if (animate) animateTo(v);
    else setView(v);
  }

  function hexCenter(id: string): { p: Vec; z: number } | null {
    const h = scene.grid.byId.get(id);
    return h ? { p: { x: h.x, y: h.y }, z: h.z } : null;
  }

  const DETAIL_ZOOM = (Z1_FROM + Z2_FROM) / 2;

  function flyTo(target: string): boolean {
    const c = hexCenter(target);
    if (c) {
      animateTo(centerOn(view, c.p, c.z, vp(), Math.min(baseZoom * 4, Math.max(view.zoom, DETAIL_ZOOM))));
      return true;
    }
    const corp = state?.corporations.find((k) => k.id === target);
    let hexes = (corp?.tokens ?? []).filter((t) => t.used && t.hex).map((t) => t.hex!);
    if (hexes.length === 0) hexes = (geometry.homes ?? []).filter((h) => h.corporation === target).map((h) => h.hex);
    const pts = hexes.map(hexCenter).filter((x): x is { p: Vec; z: number } => !!x);
    if (pts.length === 0) return false;
    animateTo(frame(view, pts.map((x) => x.p), pts[0]!.z, vp(), Math.min(baseZoom * 4, DETAIL_ZOOM)));
    return true;
  }

  // ---- input -------------------------------------------------------------------------------

  const pos = (e: { clientX: number; clientY: number }): Vec => {
    const r = canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  };
  const pickId = (p: Vec) => pick(scene.grid, view, p)?.id ?? null;
  const pointers = new Map<number, Vec>();
  let drag: { start: Vec; moved: boolean } | null = null;

  function setHover(id: string | null) {
    if (id === hover) return;
    hover = id;
    drawHover();
    render();
    emit("hover", { hex: id });
  }

  const onDown = (e: PointerEvent) => {
    if (e.pointerType === "mouse" && e.button !== 0) return;
    try { canvas.setPointerCapture(e.pointerId); } catch { /* synthetic or already released pointer */ }
    const p = pos(e);
    pointers.set(e.pointerId, p);
    drag = pointers.size === 1 ? { start: p, moved: false } : drag && { ...drag, moved: true };
    cancelAnimationFrame(flight);
  };
  const onMove = (e: PointerEvent) => {
    const p = pos(e);
    const prev = pointers.get(e.pointerId);
    if (!prev) { setHover(pickId(p)); return; }
    if (pointers.size === 1 && drag) {
      if (!drag.moved && Math.hypot(p.x - drag.start.x, p.y - drag.start.y) > DRAG_PX) drag.moved = true;
      pointers.set(e.pointerId, p);
      if (drag.moved) setView(panBy(view, p.x - prev.x, p.y - prev.y));
    } else if (pointers.size === 2) {
      const [a, b] = [...pointers.entries()].map(([id, q]) => [id, q] as const);
      const other = (a![0] === e.pointerId ? b! : a!)[1];
      const mid0 = { x: (prev.x + other.x) / 2, y: (prev.y + other.y) / 2 };
      const mid1 = { x: (p.x + other.x) / 2, y: (p.y + other.y) / 2 };
      const d0 = Math.hypot(prev.x - other.x, prev.y - other.y), d1 = Math.hypot(p.x - other.x, p.y - other.y);
      pointers.set(e.pointerId, p);
      if (d0 > 0) setView(panBy(zoomAt(view, mid0, d1 / d0, baseZoom), mid1.x - mid0.x, mid1.y - mid0.y));
    }
  };
  const onUp = (e: PointerEvent) => {
    if (!pointers.has(e.pointerId)) return;
    pointers.delete(e.pointerId);
    if (e.type === "pointerup" && drag && !drag.moved && pointers.size === 0) {
      const p = pos(e);
      const id = pickId(p);
      if (id) {
        const h = scene.grid.byId.get(id)!;
        const w = unproject(view, p, h.z);
        const hit = hitSlot(slotsOf(id), { x: w.x - h.x, y: w.y - h.y }, theme.slotRadius, MIN_HIT_PX / view.zoom);
        if (hit) emit("city", { hex: id, city: hit.city, slot: hit.slot });
        emit("hex", { hex: id });
      }
    }
    if (pointers.size === 0) drag = null;
  };
  const onLeave = () => { if (pointers.size === 0) setHover(null); };
  const onWheel = (e: WheelEvent) => {
    e.preventDefault();
    const step = e.deltaMode === 1 ? 0.05 : e.deltaMode === 2 ? 1 : 0.0015;
    setView(zoomAt(view, pos(e), Math.exp(-e.deltaY * step), baseZoom));
  };
  const onDbl = (e: MouseEvent) => {
    const id = pickId(pos(e));
    const c = id ? hexCenter(id) : null;
    if (c) animateTo(centerOn(view, c.p, c.z, vp()));
  };
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "0") { fitView(true); e.preventDefault(); }
    else if (e.key === "Home") {
      const cur = state?.meta.current;
      if (cur?.kind === "corporation" && flyTo(cur.id)) e.preventDefault();
    }
  };
  canvas.addEventListener("pointerdown", onDown);
  canvas.addEventListener("pointermove", onMove);
  canvas.addEventListener("pointerup", onUp);
  canvas.addEventListener("pointercancel", onUp);
  canvas.addEventListener("pointerleave", onLeave);
  canvas.addEventListener("wheel", onWheel, { passive: false });
  canvas.addEventListener("dblclick", onDbl);
  el.addEventListener("keydown", onKey);

  const onTheme = () => {
    const t = performance.now();
    theme = readTheme();
    view = { ...view, pitch: theme.camera.pitch, yaw: theme.camera.yaw };
    build();
    baseZoom = fit(scene.grid, view, vp()).zoom;
    setView(view);
    void rendered().then(() => { stats.themeMs = performance.now() - t; });
  };
  document.addEventListener(THEME_CHANGED, onTheme);

  let size = vp();
  const resize = new ResizeObserver(() => {
    const w = el.clientWidth, h = el.clientHeight;
    if (w < MIN_SIZE || h < MIN_SIZE || (w === size.width && h === size.height)) return;
    app.renderer.resize(w, h);
    view = panBy(view, (w - size.width) / 2, (h - size.height) / 2);
    size = vp();
    baseZoom = fit(scene.grid, view, size).zoom;
    setView(view);
  });
  resize.observe(el);

  function rendered(): Promise<void> {
    return new Promise((ok) => { waiting.push(ok); render(); });
  }

  // ---- first build -------------------------------------------------------------------------
  build();
  fitView();
  await rendered();
  stats.buildMs = performance.now() - t0;

  return {
    setState(game) {
      const t = performance.now();
      state = "state" in game ? game.state : game;
      entries = new Map(state.map.map((m) => [m.hex, m]));
      const next = signatures(state.map);
      const nextNodes = computeNodeSigs();
      const changed = [...new Set([...changedHexes(sigs, next), ...changedHexes(nodeSigs, nextNodes)])];
      sigs = next;
      nodeSigs = nextNodes;
      const tiled = tiledHexes();
      if (tiled.size !== scene.tiled.size || [...tiled].some(([id, c]) => scene.tiled.get(id) !== c)) {
        // The set of raised hexes changed: heights, levels and walls change with it.
        build();
        stats.stateHexes = geometry.hexes.length;
        setView(view);
      } else {
        changed.forEach(drawTile);
        stats.stateHexes = changed.length;
      }
      render();
      void rendered().then(() => { stats.stateMs = performance.now() - t; });
    },
    setTargets(t) { targets = t; drawTargets(); drawHover(); render(); },
    setPreview(p) { preview = p; },
    setLayers(l) { shownLayers = { ...shownLayers, ...l }; render(); },
    showRoutes(r) { routes = r; },
    flyTo,
    on(event, handler) {
      let set = handlers.get(event);
      if (!set) handlers.set(event, (set = new Set()));
      set.add(handler);
      return () => set!.delete(handler);
    },
    fit: fitView,
    get view() { return view; },
    get scene() { return scene; },
    layer: (name) => layers[name],
    hexOnScreen(id) {
      const h = hexCenter(id);
      return h ? project(view, h.p, h.z) : null;
    },
    rendered,
    stats: () => ({ ...stats }),
    destroy() {
      cancelAnimationFrame(frameReq);
      cancelAnimationFrame(flight);
      resize.disconnect();
      document.removeEventListener(THEME_CHANGED, onTheme);
      el.removeEventListener("keydown", onKey);
      clearLayers();
      app.destroy(true, { children: true });
    },
  };
}
