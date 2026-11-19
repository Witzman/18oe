// Head of the action panel in the operating round (#302, mock "Betriebsrunde B"): who operates (company,
// president, du/Bot), its numbers in one line (cash, share price, trains, tokens) and the step strip
// "1 Gleis ... 5 Zug" with the current step marked. Only facts, no rules text; the step's own panel follows
// below it in the panel body. Information layout after 18xx.games `view/game/round/operating.rb` (rule 11):
// the entity card of the acting corporation first, then the actions of the current step.
// The step strip is an ASSUMPTION of #297/#302 (owner has not decided); it can be hidden per theme with
// `.op-strip { display: none }` without touching this code.
// Pure model (`opSheet`) plus the vnode view; the frame puts it at the top of the panel body.
import type { Theme } from "../../themes/schema.ts";
import type { Game } from "../../types.ts";
import { formatGeld, v, type VNode } from "../kit/index.ts";
import { orBand } from "../frame/or-band.ts";
import { playerName } from "../frame/model.ts";
import { fillText, txt } from "../text.ts";
import { LADDER, ladderIndex, operator } from "./operating-model.ts";

export interface OpFact { key: string; label: string; value: string }
export interface OpStep { step: string; label: string; state: "done" | "current" | "next" }
export interface OpSheet {
  id: string; name: string;
  /** "du", "Anna", "Bot 2 (Bot)". */
  who: string;
  mine: boolean;
  facts: OpFact[];
  /** Empty when the round is in a step outside the ladder (merge, consolidation, ...). */
  steps: OpStep[];
}

export function opSheet(g: Game, theme: Theme): OpSheet | null {
  if (g.state.meta.finished || g.state.meta.round.type !== "operating") return null;
  // The acting company from the operating order; states without the order fall back to the current entity.
  const a = orBand(g, theme)?.acting ?? null;
  const c = g.state.corporations.find((x) => x.id === (a?.id ?? operator(g)?.id));
  if (!c) return null;
  const mine = a ? a.mine : c.president !== null && c.president === g.viewer;
  const bot = a ? a.bot : g.seats.some((s) => s.kind === "bot" && s.name === (c.president ? playerName(g, c.president) : null));
  const owner = a ? a.owner : c.president ? playerName(g, c.president) : null;
  const who = mine ? txt("op.you").de : `${owner ?? "?"}${bot ? ` (${txt("frame.bot").de})` : ""}`;
  const fact = (key: string, value: string): OpFact => ({ key, label: txt(key).de, value });
  const facts: OpFact[] = [fact("op.cash", formatGeld(c.cash))];
  if (c.share_price !== null) facts.push(fact("op.price", formatGeld(c.share_price)));
  facts.push(fact("op.trains", c.trains.length > 0 ? c.trains.map((t) => t.name).join(", ") : txt("frame.none").de));
  if (g.state.depot.pullmans?.available) facts.push(fact("op.pullman", c.pullman ? txt("op.pullman_yes").de : txt("frame.none").de));
  if (c.port_authority) facts.push(fact("op.port_authority", txt(`op.port_authority_${c.port_authority}`).de));
  if (c.tokens.length > 0) facts.push(fact("op.tokens", fillText("op.token_short", { free: c.tokens.filter((t) => !t.used).length, all: c.tokens.length })));
  const at = ladderIndex(g);
  const steps: OpStep[] = at < 0 ? [] : LADDER.map((s, i) => ({
    step: s, label: fillText("op.strip_item", { n: i + 1, step: txt(`op.strip_${s}`).de }),
    state: i < at ? "done" : i === at ? "current" : "next",
  }));
  return { id: c.id, name: c.name, who, mine, facts, steps };
}

export function OpSheetView(s: OpSheet): VNode {
  return v("section", { class: "op-sheet", "data-mine": s.mine ? "true" : "false", "aria-label": txt("op.title").de },
    v("p", { class: "op-sheet-who", title: s.name }, v("strong", {}, `${s.id} · ${s.who}`)),
    v("p", { class: "op-sheet-facts" }, ...s.facts.flatMap((f, i) => [
      i > 0 ? v("span", { class: "op-sheet-sep", "aria-hidden": "true" }, " · ") : null,
      v("span", { class: "op-sheet-fact", "data-key": f.key, title: `${txt(f.key).en} (${txt(f.key).regel})` }, `${f.label} `, v("b", {}, f.value)),
    ])),
    s.steps.length > 0 ? v("ol", { class: "op-strip", "aria-label": txt("op.ladder").de },
      ...s.steps.map((st) => v("li", {
        class: "op-strip-item", "data-step": st.step, "data-state": st.state, "aria-current": st.state === "current" ? "step" : undefined,
      }, st.label))) : null);
}
