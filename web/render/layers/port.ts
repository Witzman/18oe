// Port mark (#451): a round badge with an anchor, blue for a public port and pink for a private one, as on map.jpg. Drawn
// in world units around `at`; size and colours are theme tokens (shape.portMark, map.portPublic, map.portPrivate).
import { Container, Graphics } from "pixi.js";
import type { PortKind } from "../ports.ts";
import type { RenderTheme } from "../theme.ts";
import type { Vec } from "../track-axes.ts";

export function drawPortMark(kind: PortKind, at: Vec, theme: RenderTheme): Container {
  const r = theme.portMark;
  const color = kind === "public" ? theme.map.portPublic : theme.map.portPrivate;
  const w = r * 0.16;
  const node = new Container({ label: `port-${kind}` });
  const g = new Graphics();
  g.circle(at.x, at.y, r).fill({ color: theme.map.city }).stroke({ width: w, color });
  // anchor: ring on top, shaft, crossbar, curved arms with flukes at the bottom
  const top = at.y - r * 0.55, bottom = at.y + r * 0.55, bar = at.y - r * 0.2;
  g.circle(at.x, top, r * 0.14).stroke({ width: w, color });
  g.moveTo(at.x, top + r * 0.14).lineTo(at.x, bottom).stroke({ width: w, color, cap: "round" });
  g.moveTo(at.x - r * 0.26, bar).lineTo(at.x + r * 0.26, bar).stroke({ width: w, color, cap: "round" });
  g.arc(at.x, bottom - r * 0.34, r * 0.5, Math.PI * 0.12, Math.PI * 0.88).stroke({ width: w, color, cap: "round" });
  node.addChild(g);
  return node;
}
