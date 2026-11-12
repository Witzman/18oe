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
// Built here: sea and land plates in theme colours, hex lines, province borders, terrain signs
// with costs, tile surfaces with per-hex redraw, hover and valid targets, pan/zoom/centre/fly,
// block culling, redraw on oe:themechange. Stored but drawn by later issues: setPreview (#48),
// setLayers apart from terrainCost (#151), showRoutes (#155), cities and the "city" event (#147),
// walls (#145), labels (#149).
import { Application, Container, Graphics, Matrix, RenderLayer, Text } from "pixi.js";
import type { Game, GameState, HexChange } from "../types.ts";
import { THEME_CHANGED } from "../ui/theme-switch.ts";
import { between, centerOn, clampPan, fit, frame, panBy, zoomAt, zoomStage, Z1_FROM, Z2_FROM, type Viewport } from "./camera.ts";
import { drawGrid, drawPlate, type Block } from "./layers/static.ts";
import { drawTileSurface } from "./layers/tiles.ts";
import type { MapGeometry } from "./mapdata.ts";
import { levelMatrix, mapCenter, pick, project, worldCorners, type Vec, type View } from "./projection.ts";
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
  city?: number;
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
    resolution: dpr, autoDensity: true, width: el.clientWidth || 800, height: el.clientHeight || 600, preference: "webgl",
  });
  app.ticker.stop();
  const canvas = app.canvas;
  canvas.style.display = "block";
  canvas.style.touchAction = "none";
  el.append(canvas);
  if (el.tabIndex < 0) el.tabIndex = 0;

  const layers = Object.fromEntries(LAYERS.map((n) => {
    const c = new Container({ label: n });
    app.stage.addChild(c);
    return [n, c];
  })) as Record<LayerName, Container>;

  // Per-build state (rebuilt on theme change).
  let scene!: Scene;
  let levelRL: RenderLayer[] = [];
  let levelNodes: Record<Leveled, Container[]> = { land: [], grid: [], tiles: [], overlay: [] };
  let seaLevel!: Container;
  let seaMarksLevel!: Container;
  let blocks: Block[] = [];
  let tileNodes = new Map<string, Container>();
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
    scene = buildScene(geometry, theme);
    printed = new Map(geometry.hexes.filter((h) => h.color && h.color !== "white" && h.color !== "blue").map((h) => [h.id, h.color!]));
    seaLevel = layers.sea.addChild(new Container({ label: "level0" }));
    seaMarksLevel = layers.seaMarks.addChild(new Container({ label: "level0" }));
    levelNodes = { land: [], grid: [], tiles: [], overlay: [] };
    scene.levels.forEach((z, i) => {
      const rl = new RenderLayer();
      app.stage.addChildAt(rl, 2 + i);
      levelRL.push(rl);
      for (const n of LEVELED) {
        const c = layers[n].addChild(new Container({ label: `level${i} z=${z}` }));
        levelNodes[n].push(c);
        rl.attach(c);
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
    for (const id of new Set([...printed.keys(), ...entries.keys()])) drawTile(id);
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

  function drawTile(id: string) {
    const g = scene.grid.byId.get(id);
    if (!g) return;
    const old = tileNodes.get(id);
    if (old) { old.destroy({ children: true }); tileNodes.delete(id); }
    const color = entries.get(id)?.tile.color ?? printed.get(id);
    const surface = drawTileSurface(scene.grid, g, color, theme);
    if (!surface) return;
    const node = new Container({ label: id });
    node.addChild(surface);
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
    const stage = zoomStage(view.zoom);
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
    canvas.setPointerCapture?.(e.pointerId);
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
      const id = pickId(pos(e));
      if (id) emit("hex", { hex: id });
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
    if (!w || !h || (w === size.width && h === size.height)) return;
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
  const c = mapCenter(scene.grid);
  view = { ...view, centerX: c.x, centerY: c.y };
  fitView();
  await rendered();
  stats.buildMs = performance.now() - t0;

  return {
    setState(game) {
      const t = performance.now();
      state = "state" in game ? game.state : game;
      entries = new Map(state.map.map((m) => [m.hex, m]));
      const next = signatures(state.map);
      const changed = changedHexes(sigs, next);
      sigs = next;
      changed.forEach(drawTile);
      stats.stateHexes = changed.length;
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
