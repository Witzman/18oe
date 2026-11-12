// Wimpel(player): pennant in the player colour plus the seat number, never colour alone (ui-spec 1.2).
import type { Theme } from "../../themes/schema.ts";
import { inkFor } from "./ink.ts";
import { v, type State, type VNode } from "./vnode.ts";

export interface Player { seat: number; name: string }
export interface PennantOptions { theme: Theme; state?: State; link?: string; showName?: boolean }

const SLOTS = ["p1", "p2", "p3", "p4", "p5", "p6", "p7"] as const;
export type PlayerSlot = (typeof SLOTS)[number];

export function playerSlot(seat: number): PlayerSlot {
  const slot = SLOTS[seat - 1];
  if (!slot) throw new Error(`Seat ${seat} outside 1..${SLOTS.length}`);
  return slot;
}

export function Wimpel(player: Player, o: PennantOptions): VNode {
  const slot = playerSlot(player.seat);
  const state = o.state ?? "normal";
  const ink = inkFor(o.theme.player[slot], o.theme);
  const flag = v("span", { class: "kit-flag", style: `--flag-bg:var(--player-${slot});--flag-ink:${ink}`, "aria-hidden": "true" }, String(player.seat));
  const attrs = {
    class: "kit-pennant",
    "data-state": state,
    "aria-label": `Spieler ${player.seat}, ${player.name}`,
    "aria-disabled": state === "invalid" ? "true" : undefined,
    "aria-current": state === "selected" ? "true" : undefined,
  };
  const body = [flag, o.showName === false ? null : v("span", { class: "kit-pname" }, player.name)];
  return o.link ? v("a", { ...attrs, href: o.link }, ...body) : v("span", attrs, ...body);
}
