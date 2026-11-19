// Run bands on the map (#155, ui-spec 2.9 view 1): the band of each proposed run in company colour with a light
// outline (always), a ring with the revenue at every stop (from Z1), a shield with train name and sum at the start
// (from Z2). Geometry is runs.ts; this only draws. Display only, nothing here takes input. Static: no animation.
//
// The band and the rings are flat Graphics in the overlay container of the level of the hex they lie in (world
// coordinates, like the track); revenue figures and shields are screen-space objects in the labels layer that
// `RunScene.update` places on every frame. Colour is not the only carrier: the shield names the train and the sum,
// the offset keeps two trains apart, rings carry numbers.
import { Container, Graphics, Text } from "pixi.js";
import { project, type View } from "../projection.ts";
import type { ZoomStage } from "../camera.ts";
import { offsetPoints, routeLine, runOffsets, runVisibility, type RunLine, type RunRouteInput, type RunWorld } from "../runs.ts";
import type { RenderTheme } from "../theme.ts";
import { inkOn } from "./nodes.ts";
import type { Vec } from "../track-axes.ts";

/** The proposed run of one company: its colour and routes with the train names for the shields. */
export interface MapRun {
  corporation: string;
  routes: (RunRouteInput & { name?: string })[];
}

export interface RunScene {
  /** Place screen-space parts for this camera and redraw the band when its on-screen minimum width changes. */
  update(view: View, stage: ZoomStage): void;
  lines: readonly RunLine[];
  destroy(): void;
}

export interface RunSceneInput {
  run: MapRun;
  world: RunWorld;
  theme: RenderTheme;
  color: number;
  /** Container of each height level (overlay layer) and the level of a hex. */
  levels: readonly Container[];
  levelOf(hex: string): number;
  zOf(hex: string): number;
  labels: Container;
  /** Revenue of a stop node (assumption: the node's printed revenue for the phase now), null if unknown. */
  stopRevenue(hex: string, node: number): number | null;
  dpr: number;
}

const flat = (pts: readonly Vec[]): number[] => pts.flatMap((p) => [p.x, p.y]);

/** Width of one band in side lengths: the full token width for one train, scaled down for several. */
export function bandWidth(theme: RenderTheme, trains: number): number {
  return trains > 1 ? theme.track.runWidth * theme.track.runMultiScale : theme.track.runWidth;
}

/** Width in world units at `zoom`: never thinner than runMinPx on the screen. */
export function effectiveWidth(width: number, zoom: number, minPx: number): number {
  return Math.max(width, minPx / Math.max(zoom, 1e-6));
}

export function buildRunScene(input: RunSceneInput): RunScene {
  const { run, world, theme, color, levels, levelOf, labels } = input;
  const t = theme.track;
  const lines = run.routes.map((r) => routeLine(r, world));
  const n = lines.length;
  const width = bandWidth(theme, n);
  const offsets = runOffsets(n, t.runGap);
  const shifted = lines.map((l, i) => offsetPoints(l.points, offsets[i]!, l.breaks));
  const ink = inkOn(color, theme);

  const bandGraphics = new Map<number, Graphics>();
  const ringGraphics = new Map<number, Graphics>();
  const graphicsOf = (map: Map<number, Graphics>, level: number): Graphics => {
    let g = map.get(level);
    if (!g) { g = new Graphics(); levels[level]?.addChild(g); map.set(level, g); }
    return g;
  };

  /** Runs of consecutive points in one level; neighbouring runs share their boundary point so the band does not tear. */
  function byLevel(i: number): { level: number; pts: Vec[] }[] {
    const out: { level: number; pts: Vec[] }[] = [];
    const l = lines[i]!, pts = shifted[i]!;
    pts.forEach((p, k) => {
      const level = levelOf(l.hexes[k]!);
      const cur = out[out.length - 1];
      if (cur && cur.level === level) cur.pts.push(p);
      else {
        if (cur) cur.pts.push(p);
        out.push({ level, pts: [...(cur ? [cur.pts[cur.pts.length - 1]!] : []), p] });
      }
    });
    return out;
  }
  const runs = lines.map((_, i) => byLevel(i));

  let drawnWidth = -1;
  function drawBand(w: number) {
    drawnWidth = w;
    for (const g of bandGraphics.values()) g.clear();
    lines.forEach((_, i) => {
      for (const part of runs[i]!) {
        if (part.pts.length < 2) continue;
        const g = graphicsOf(bandGraphics, part.level);
        g.poly(flat(part.pts), false).stroke({ width: w + 2 * t.runOutline, color: theme.map.labelHalo, join: "round", cap: "round" });
        g.poly(flat(part.pts), false).stroke({ width: w, color, join: "round", cap: "round" });
      }
    });
  }

  // Rings at the stops (flat, in the level of their hex); the figures are screen text.
  const figures: { text: Text; at: Vec; z: number; r: number }[] = [];
  const shields: { box: Container; at: Vec; z: number; row: number }[] = [];
  const seen = new Set<string>();
  lines.forEach((l, i) => {
    for (const s of l.stops) {
      const id = `${s.hex}/${s.node}`;
      if (seen.has(id)) continue;
      seen.add(id);
      const g = graphicsOf(ringGraphics, levelOf(s.hex));
      const r = t.runRing;
      g.circle(s.at.x, s.at.y, r).stroke({ width: t.runOutline * 2.2, color: theme.map.labelHalo });
      g.circle(s.at.x, s.at.y, r).stroke({ width: t.runOutline, color });
      const rev = input.stopRevenue(s.hex, s.node);
      if (rev !== null) {
        const text = new Text({
          text: String(rev), resolution: input.dpr,
          style: { fontFamily: theme.font.body, fontSize: 11, fontWeight: "700", fill: theme.map.label, stroke: { color: theme.map.labelHalo, width: 3, join: "round" } },
        });
        text.anchor.set(0, 0);
        text.visible = false;
        labels.addChild(text);
        figures.push({ text, at: s.at, z: input.zOf(s.hex), r });
      }
    }
    // Shield at the start of the band: train name and the sum of this train.
    const start = shifted[i]![0];
    if (!start) return;
    const box = new Container({ label: "run-shield" });
    const label = new Text({
      text: `${run.routes[i]!.name ?? l.train} ${l.revenue}`, resolution: input.dpr,
      style: { fontFamily: theme.font.body, fontSize: 11, fontWeight: "700", fill: ink },
    });
    label.anchor.set(0.5);
    const w = label.width + 12, h = label.height + 4;
    const bg = new Graphics().roundRect(-w / 2, -h / 2, w, h, h / 2).fill({ color }).stroke({ width: 2, color: theme.map.labelHalo });
    box.addChild(bg, label);
    box.visible = false;
    labels.addChild(box);
    shields.push({ box, at: start, z: input.zOf(l.hexes[0]!), row: i });
  });

  return {
    lines,
    update(view, stage) {
      const vis = runVisibility(stage);
      const w = effectiveWidth(width, view.zoom, t.runMinPx);
      if (Math.abs(w - drawnWidth) > drawnWidth * 0.05 || drawnWidth < 0) drawBand(w);
      for (const g of bandGraphics.values()) g.visible = vis.band;
      for (const g of ringGraphics.values()) g.visible = vis.rings;
      for (const f of figures) {
        f.text.visible = vis.rings;
        if (vis.rings) {
          const p = project(view, f.at, f.z);
          f.text.position.set(Math.round(p.x + f.r * view.zoom + 2), Math.round(p.y + 1));
        }
      }
      for (const s of shields) {
        s.box.visible = vis.shields;
        if (vis.shields) {
          const p = project(view, s.at, s.z);
          s.box.position.set(Math.round(p.x), Math.round(p.y - 16 - s.row * 20));
        }
      }
    },
    destroy() {
      for (const g of [...bandGraphics.values(), ...ringGraphics.values()]) g.destroy();
      for (const f of figures) f.text.destroy();
      for (const s of shields) s.box.destroy({ children: true });
    },
  };
}
