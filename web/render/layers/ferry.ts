// Ferry lines (#452): the blue line of a ferry over the sea hexes with its distance in an oval, as on map.jpg. The line
// of one hex is its ferry paths drawn as one stroke (they are not track: no bed, no sleepers); the oval sits on the middle
// path of the whole ferry, at the middle of that path.
import { Container, Graphics } from "pixi.js";
import { pointAt, polyline } from "../axis-sample.ts";
import { worldText } from "../world-text.ts";
import type { RenderTheme } from "../theme.ts";
import type { Axis, Vec } from "../track-axes.ts";

/** Maximum distance of polyline points, as the track picture. */
const MAX_STEP = 0.05;

export interface FerryOval { /** Index into the axes drawn. */ axis: number; distance: number }

export function drawFerryLine(axes: readonly Axis[], origin: Vec, theme: RenderTheme, oval?: FerryOval): Container {
  const node = new Container({ label: "ferry" });
  const line = new Graphics();
  for (const a of axes) line.poly(polyline(a, MAX_STEP, origin).flatMap((p) => [p.x, p.y]), false);
  line.stroke({ width: theme.ferryWidth, color: theme.map.ferry, cap: "round", join: "round" });
  node.addChild(line);
  const axis = oval ? axes[oval.axis] : undefined;
  if (oval && axis) {
    const at = pointAt(axis, axis.length / 2, origin);
    const o = new Graphics();
    o.ellipse(at.x, at.y, theme.ferryOval, theme.ferryOval * 0.7).fill({ color: theme.map.city }).stroke({ width: theme.ferryWidth * 0.5, color: theme.map.ferry });
    node.addChild(o, worldText(String(oval.distance), theme.ferryOval * 1.15, theme.map.ferry, theme, { x: at.x, y: at.y }));
  }
  return node;
}
