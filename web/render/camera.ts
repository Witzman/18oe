// Pan, zoom, centre and "fly to" for the map camera (ui-spec 2.2 Kamerabedienung, 2.8 Zoomstufen).
// Pure functions on the View of projection.ts; map.ts wires them to pointer, wheel and keys.
// Pitch and yaw are theme values, not player controls (ui-spec 2.2); nothing here changes them.
import { apply, fitView, invert, levelMatrix, type Box, type HexGrid, type Vec, type View } from "./projection.ts";

/** Zoom limits as factors of the base zoom (the zoom at which the whole map fits, key `0`). */
export const ZOOM_MIN = 0.35;
export const ZOOM_MAX = 4;

/** Zoom stages by hex side length on screen in px (ui-spec 2.8). */
export const Z1_FROM = 14;
export const Z2_FROM = 34;
export type ZoomStage = 0 | 1 | 2;

export function zoomStage(zoom: number): ZoomStage {
  return zoom < Z1_FROM ? 0 : zoom <= Z2_FROM ? 1 : 2;
}

export interface Viewport {
  width: number;
  height: number;
}

/** Margin in px around the whole map for `fit`. */
export const FIT_MARGIN = 16;

export function fit(grid: HexGrid, view: View, vp: Viewport): View {
  return fitView(grid, view, vp.width, vp.height, FIT_MARGIN);
}

/**
 * Zoom by `factor` about the screen point s: whatever lies under s stays under s, at every
 * height (screen = pan + zoom * f(world, z), so pan' = s - k (s - pan) holds for all z).
 * The new zoom is clamped to [ZOOM_MIN, ZOOM_MAX] x base.
 */
export function zoomAt(view: View, s: Vec, factor: number, base: number): View {
  const zoom = Math.min(base * ZOOM_MAX, Math.max(base * ZOOM_MIN, view.zoom * factor));
  const k = zoom / view.zoom;
  return { ...view, zoom, panX: s.x - k * (s.x - view.panX), panY: s.y - k * (s.y - view.panY) };
}

export function panBy(view: View, dx: number, dy: number): View {
  return { ...view, panX: view.panX + dx, panY: view.panY + dy };
}

/**
 * Keeps the map from being dragged away: the ground point under the middle of the window stays
 * inside the map's world box (works for any yaw, unlike a screen-box rule).
 */
export function clampPan(view: View, world: Box, vp: Viewport): View {
  const mid = { x: vp.width / 2, y: vp.height / 2 };
  const f = apply(invert(levelMatrix(view, 0)), mid);
  const c = { x: Math.min(world.maxX, Math.max(world.minX, f.x)), y: Math.min(world.maxY, Math.max(world.minY, f.y)) };
  if (c.x === f.x && c.y === f.y) return view;
  const s = apply(levelMatrix(view, 0), c);
  return panBy(view, mid.x - s.x, mid.y - s.y);
}

/** Pan so the world point p (on height z) is in the middle of the viewport; zoom unchanged unless given. */
export function centerOn(view: View, p: Vec, z: number, vp: Viewport, zoom = view.zoom): View {
  const v = { ...view, zoom };
  const s = apply(levelMatrix(v, z), p);
  return panBy(v, vp.width / 2 - s.x, vp.height / 2 - s.y);
}

/**
 * Centre on a set of world points (key `Pos1`: the acting company's network) and zoom so they fit,
 * but never further in than `maxZoom` (a single hex should not fill the screen).
 */
export function frame(view: View, points: Vec[], z: number, vp: Viewport, maxZoom: number, margin = 3): View {
  if (points.length === 0) return view;
  const unit = { ...view, zoom: 1, panX: 0, panY: 0 };
  const m = levelMatrix(unit, z);
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const p of points) {
    const s = apply(m, p);
    minX = Math.min(minX, s.x); maxX = Math.max(maxX, s.x);
    minY = Math.min(minY, s.y); maxY = Math.max(maxY, s.y);
  }
  const zoom = Math.min(maxZoom, (vp.width - 2 * FIT_MARGIN) / (maxX - minX + 2 * margin), (vp.height - 2 * FIT_MARGIN) / (maxY - minY + 2 * margin));
  return {
    ...unit, zoom,
    panX: vp.width / 2 - zoom * (minX + maxX) / 2,
    panY: vp.height / 2 - zoom * (minY + maxY) / 2,
  };
}

/**
 * Camera between a and b at t (0..1), eased: the point at the viewport centre moves on a straight
 * line over the map, zoom changes geometrically.
 */
export function between(a: View, b: View, t: number, vp: Viewport): View {
  const e = t <= 0 ? 0 : t >= 1 ? 1 : t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t);
  const zoom = a.zoom * (b.zoom / a.zoom) ** e;
  const cx = vp.width / 2, cy = vp.height / 2;
  // screen = pan + zoom * f, so the f under the centre is (centre - pan) / zoom.
  const fa = { x: (cx - a.panX) / a.zoom, y: (cy - a.panY) / a.zoom };
  const fb = { x: (cx - b.panX) / b.zoom, y: (cy - b.panY) / b.zoom };
  const f = { x: fa.x + (fb.x - fa.x) * e, y: fa.y + (fb.y - fa.y) * e };
  return { ...b, zoom, panX: cx - f.x * zoom, panY: cy - f.y * zoom };
}
