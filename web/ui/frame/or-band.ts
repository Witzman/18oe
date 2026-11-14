// Who operates now and in which order (#291): a card for the acting company and the operating order of this
// OR (done checked, current marked, upcoming). Pure model (`orBand`) plus the vnode view; the frame puts it
// at the top of the context sheet for every operating step. Order and done flags come from
// `meta.operating_order` (lib/oe/view.rb); name, colour, owner come from the corporation/player lists.
import type { Theme } from "../../themes/schema.ts";
import type { Game } from "../../types.ts";
import { Siegel } from "../kit/index.ts";
import { v, type VNode } from "../kit/vnode.ts";
import { fillText, txt } from "../text.ts";
import { corpColor, playerName } from "./model.ts";

export interface OrEntry {
  id: string; name: string; color: string; tier: string; owner: string | null; mine: boolean; bot: boolean;
  state: "done" | "current" | "next";
}
export interface OrBand { acting: OrEntry | null; entries: OrEntry[]; sentence: string }

export function orBand(g: Game, theme: Theme): OrBand | null {
  const m = g.state.meta;
  if (m.finished || m.round.type !== "operating") return null;
  const botNames = new Set(g.seats.filter((s) => s.kind === "bot").map((s) => s.name));
  const curId = m.current?.kind === "corporation" ? m.current.id : null;
  const firstOpen = (m.operating_order ?? []).findIndex((o) => !o.done);
  const entries: OrEntry[] = [];
  (m.operating_order ?? []).forEach((o, i) => {
    const c = g.state.corporations.find((x) => x.id === o.id);
    if (!c) return;
    const owner = c.president ? playerName(g, c.president) : null;
    const state = curId !== null ? (c.id === curId ? "current" : o.done ? "done" : "next") : (o.done ? "done" : i === firstOpen ? "current" : "next");
    entries.push({
      id: c.id, name: c.name, color: corpColor(theme, g, c.id), tier: txt(`tier.${c.type}`).de, owner,
      mine: c.president !== null && c.president === g.viewer, bot: owner !== null && botNames.has(owner), state,
    });
  });
  const acting = entries.find((e) => e.state === "current") ?? null;
  if (!acting) return entries.length > 0 ? { acting, entries, sentence: "" } : null;
  const sentence = acting.mine ? fillText("op.acting_mine", { corp: acting.id, name: acting.name })
    : fillText("op.acting_other", { corp: acting.id, name: acting.name, who: `${acting.owner ?? "?"}${acting.bot ? ` (${txt("frame.bot").de})` : ""}` });
  return { acting, entries, sentence };
}

export function OrBandView(b: OrBand, theme: Theme): VNode {
  const seal = (e: OrEntry) => Siegel({ sym: e.id, color: e.color, name: e.name }, { theme, size: "s" });
  const ownerText = (e: OrEntry) => e.mine ? txt("op.you").de : `${e.owner ?? "?"}${e.bot ? ` · ${txt("frame.bot").de}` : ""}`;
  const card = b.acting ? v("div", { class: "or-acting", "data-mine": b.acting.mine ? "true" : "false", "data-bot": b.acting.bot ? "true" : "false", role: "status" },
    seal(b.acting),
    v("div", { class: "or-acting-text" },
      v("strong", {}, b.sentence),
      v("small", { class: "muted" }, `${b.acting.tier} · ${fillText("op.owner", { who: ownerText(b.acting) })}`))) : null;
  const mark = (s: OrEntry["state"]) => s === "done" ? "✓" : s === "current" ? "▶" : "";
  const list = v("ol", { class: "or-order", "aria-label": txt("op.order").de },
    ...b.entries.map((e) => v("li", {
      class: "or-item", "data-id": e.id, "data-state": e.state, "data-mine": e.mine ? "true" : "false", "data-bot": e.bot ? "true" : "false",
      "aria-current": e.state === "current" ? "step" : undefined,
      title: `${e.id} · ${e.name} · ${e.tier} · ${ownerText(e)} · ${txt(`op.state_${e.state}`).de}`,
    },
    v("span", { class: "or-mark", "aria-hidden": "true" }, mark(e.state)),
    seal(e),
    v("span", { class: "or-owner" }, e.mine ? txt("op.you").de : e.owner ?? "?"),
    e.bot ? v("span", { class: "frame-tag" }, txt("frame.bot").de) : null,
    v("span", { class: "or-sr" }, ` ${txt(`op.state_${e.state}`).de}`))));
  return v("section", { class: "or-band", "aria-label": txt("op.order").de }, card, v("h3", { class: "or-title" }, txt("op.order").de), list);
}
