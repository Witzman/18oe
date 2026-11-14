// What the frame shows, derived from the view model (pure: no DOM, tests run under node).
// Everything here only reads `Game`; no rule checks in the client (ui-spec 3.5).
import { companyBg } from "../../themes/companies.ts";
import type { Theme } from "../../themes/schema.ts";
import type { Corporation, Game, Player } from "../../types.ts";
import { fillText, txt } from "../text.ts";

export interface PhaseInfo { label: string; tiles: string; operatingRounds: number }
export interface WhoInfo {
  text: string;
  mine: boolean;
  corp: { sym: string; color: string } | null;
}
export interface RoundBarModel {
  rrPhase: string;
  phase: PhaseInfo;
  round: string;
  who: WhoInfo;
  bank: number;
  finished: boolean;
}
export interface PlayerRow {
  id: string; seat: number; name: string; cash: number; value: number;
  certs: number; certLimit: number; priority: boolean; toAct: boolean; bot: boolean; me: boolean;
}

export const playerName = (g: Game, id: string): string => g.state.players.find((p) => p.id === id)?.name ?? id;

// Company colour by id from the theme's `companies` tokens (#99); an id without a token falls back to the
// placeholder palette by the corporation's position in the list.
export function corpColor(theme: Theme, g: Game, id: string): string {
  return companyBg(theme, id, g.state.corporations.map((c) => c.id));
}

export function stepLabel(step: string | null): string {
  if (!step) return txt("frame.step_none").de;
  const e = txt(`step.${step}`);
  return e.de === `step.${step}` ? fillText("frame.step_unknown", { step }) : e.de;
}

export function roundLabel(g: Game): string {
  const r = g.state.meta.round;
  if (g.state.meta.finished) return txt("frame.over").de;
  const name = txt(`round.${r.type}`).de;
  if (r.type === "operating" && r.number !== null) return fillText("frame.round_nt", { name, n: r.number, t: r.turn });
  if (r.number !== null) return fillText("frame.round_n", { name, n: r.number });
  return name;
}

export function whoActs(g: Game, theme: Theme): WhoInfo {
  const m = g.state.meta;
  const mine = g.state.prompt.viewer_to_act;
  if (m.finished) {
    return { text: fillText("frame.finished", { winner: m.winner ? playerName(g, m.winner) : txt("frame.unknown").de }), mine: false, corp: null };
  }
  const cur = m.current;
  const corp = cur?.kind === "corporation" ? g.state.corporations.find((c) => c.id === cur.id) : undefined;
  const seal = corp ? { sym: corp.id, color: corpColor(theme, g, corp.id) } : null;
  const names = m.active_players.map((id) => playerName(g, id)).join(", ");
  if (mine) {
    const what = corp ? `${corp.id}, ${stepLabel(g.state.prompt.step)}` : stepLabel(g.state.prompt.step);
    return { text: fillText("frame.who_mine", { what }), mine: true, corp: seal };
  }
  if (corp) {
    const who = corp.president ? playerName(g, corp.president) : names;
    return { text: fillText("frame.who_other", { who, corp: corp.id }), mine: false, corp: seal };
  }
  return { text: names ? fillText("frame.who_players", { names }) : txt("frame.who_nobody").de, mine: false, corp: null };
}

export function roundBar(g: Game, theme: Theme): RoundBarModel {
  const m = g.state.meta;
  return {
    rrPhase: m.rr_phase,
    phase: { label: fillText("frame.train_phase", { name: m.phase.name }), tiles: m.phase.tiles.join(", "), operatingRounds: m.phase.operating_rounds },
    round: roundLabel(g),
    who: whoActs(g, theme),
    bank: g.state.bank.cash,
    finished: m.finished,
  };
}

export function playerRows(g: Game): PlayerRow[] {
  const botNames = new Set(g.seats.filter((s) => s.kind === "bot").map((s) => s.name));
  const active = new Set(g.state.meta.active_players);
  return g.state.players.map((p: Player, i) => ({
    id: p.id, seat: i + 1, name: p.name, cash: p.cash, value: p.value, certs: p.certs, certLimit: p.cert_limit,
    priority: p.order === 0, toAct: !g.state.meta.finished && active.has(p.id), bot: botNames.has(p.name), me: p.id === g.viewer,
  }));
}

// A hang is never silent (#289): what the frame says when the game cannot go on by itself. `waitedMs` is
// how long the state (seq) has not changed. Null when everything is normal.
//  - nobody to act in a running game, or the viewer is to act but the server offers no action: error;
//  - only bots to act and nothing happened for BOT_STALL_MS: warning (a bot that does not move);
//  - another human to act: the plain "waiting for X" (always, so the viewer knows why nothing moves).
export const BOT_STALL_MS = 30_000;
export interface StallNotice { kind: "nobody" | "no_action" | "bot_stall" | "waiting"; tone: "error" | "warn" | "info"; text: string }

export function stallNotice(g: Game, waitedMs: number): StallNotice | null {
  if (g.state.meta.finished) return null;
  const p = g.state.prompt;
  const acting = g.state.meta.active_players;
  if (acting.length === 0) return { kind: "nobody", tone: "error", text: txt("frame.stall_nobody").de };
  if (p.viewer_to_act) {
    const offered = p.actions.length + p.ranges.length + p.choices.length;
    return offered === 0 ? { kind: "no_action", tone: "error", text: txt("frame.stall_no_action").de } : null;
  }
  const rows = playerRows(g).filter((r) => r.toAct);
  const names = rows.map((r) => r.name).join(", ");
  if (rows.length > 0 && rows.every((r) => r.bot) && waitedMs >= BOT_STALL_MS) {
    return { kind: "bot_stall", tone: "warn", text: fillText("frame.stall_bot", { names, s: Math.floor(waitedMs / 1000) }) };
  }
  return { kind: "waiting", tone: "info", text: fillText("frame.stall_waiting", { names: names || acting.join(", ") }) };
}

// Founded corporations in operating order (meta.operating_order, #122); corporations the order does not
// name (and states recorded before #122) keep the engine's list order after the named ones.
export function outlinerCorps(g: Game): { shown: Corporation[]; hidden: number } {
  const order = new Map((g.state.meta.operating_order ?? []).map((o, i) => [o.id, i]));
  const rank = (c: Corporation) => order.get(c.id) ?? Number.MAX_SAFE_INTEGER;
  const shown = g.state.corporations.filter((c) => !c.closed && (c.ipoed || c.floated)).sort((a, b) => rank(a) - rank(b));
  return { shown, hidden: g.state.corporations.filter((c) => !c.closed).length - shown.length };
}
