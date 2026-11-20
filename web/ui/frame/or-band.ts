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
// `preview`: outside an operating round (stock round, #416) the order the next operating round would have by
// the current state (the view's `operating_order`); nobody is acting, nothing is done.
export interface OrBand { acting: OrEntry | null; entries: OrEntry[]; sentence: string; preview?: boolean }

export function orBand(g: Game, theme: Theme): OrBand | null {
  const m = g.state.meta;
  if (m.finished) return null;
  if (m.round.type !== "operating") return orPreview(g, theme);
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
      id: c.id, name: c.name, color: corpColor(theme, g, c.id), tier: txt(`tier.${c.type}`).text, owner,
      mine: c.president !== null && c.president === g.viewer, bot: owner !== null && botNames.has(owner), state,
    });
  });
  const acting = entries.find((e) => e.state === "current") ?? null;
  if (!acting) return entries.length > 0 ? { acting, entries, sentence: "" } : null;
  const sentence = acting.mine ? fillText("op.acting_mine", { corp: acting.id, name: acting.name })
    : fillText("op.acting_other", { corp: acting.id, name: acting.name, who: `${acting.owner ?? "?"}${acting.bot ? ` (${txt("frame.bot").text})` : ""}` });
  return { acting, entries, sentence };
}

function orPreview(g: Game, theme: Theme): OrBand | null {
  const botNames = new Set(g.seats.filter((s) => s.kind === "bot").map((s) => s.name));
  const entries: OrEntry[] = [];
  for (const o of g.state.meta.operating_order ?? []) {
    const c = g.state.corporations.find((x) => x.id === o.id);
    if (!c) continue;
    const owner = c.president ? playerName(g, c.president) : null;
    entries.push({
      id: c.id, name: c.name, color: corpColor(theme, g, c.id), tier: txt(`tier.${c.type}`).text, owner,
      mine: c.president !== null && c.president === g.viewer, bot: owner !== null && botNames.has(owner), state: "next",
    });
  }
  return entries.length > 0 ? { acting: null, entries, sentence: "", preview: true } : null;
}

export function OrBandView(b: OrBand, theme: Theme, opts: { order?: boolean } = {}): VNode {
  const seal = (e: OrEntry) => Siegel({ sym: e.id, color: e.color, name: e.name }, { theme, size: "s" });
  const ownerText = (e: OrEntry) => e.mine ? txt("op.you").text : `${e.owner ?? "?"}${e.bot ? ` · ${txt("frame.bot").text}` : ""}`;
  const card = b.acting ? v("div", { class: "or-acting", "data-mine": b.acting.mine ? "true" : "false", "data-bot": b.acting.bot ? "true" : "false", role: "status" },
    seal(b.acting),
    v("div", { class: "or-acting-text" },
      v("strong", {}, b.sentence),
      v("small", { class: "muted" }, `${b.acting.tier} · ${fillText("op.owner", { who: ownerText(b.acting) })}`))) : null;
  const mark = (s: OrEntry["state"]) => s === "done" ? "✓" : s === "current" ? "▶" : "";
  const list = opts.order === false ? null : v("ol", { class: "or-order", "aria-label": txt("op.order").text },
    ...b.entries.map((e) => v("li", {
      class: "or-item", "data-id": e.id, "data-state": e.state, "data-mine": e.mine ? "true" : "false", "data-bot": e.bot ? "true" : "false",
      "aria-current": e.state === "current" ? "step" : undefined,
      title: `${e.id} · ${e.name} · ${e.tier} · ${ownerText(e)} · ${txt(`op.state_${e.state}`).text}`,
    },
    v("span", { class: "or-mark", "aria-hidden": "true" }, mark(e.state)),
    seal(e),
    v("span", { class: "or-owner" }, e.mine ? txt("op.you").text : e.owner ?? "?"),
    e.bot ? v("span", { class: "frame-tag" }, txt("frame.bot").text) : null,
    v("span", { class: "or-sr" }, ` ${txt(`op.state_${e.state}`).text}`))));
  return v("section", { class: "or-band", "aria-label": txt("op.order").text }, card, list ? v("h3", { class: "or-title" }, txt("op.order").text) : null, list);
}

// Thin collapsible band under the head bar (#416): one chip per company in operating order (seal in company
// colour, owner), the acting one marked, done ones muted. In a stock round the preview order. Not interactive
// except the fold button; the title of a chip carries the details.
export function OrderBandView(b: OrBand, theme: Theme, opts: { collapsed: boolean; onToggle: () => void }): VNode {
  const ownerText = (e: OrEntry) => e.mine ? txt("op.you").text : `${e.owner ?? "?"}${e.bot ? ` · ${txt("frame.bot").text}` : ""}`;
  const label = txt(b.preview ? "frame.order_band_next" : "frame.head_order").text;
  const toggleLabel = txt(opts.collapsed ? "frame.order_band_expand" : "frame.order_band_collapse").text;
  const list = v("ol", { class: "order-strip", "aria-label": label },
    ...b.entries.map((e, i) => v("li", {
      class: "order-strip-item", "data-id": e.id, "data-state": e.state, "data-mine": e.mine ? "true" : "false",
      "aria-current": e.state === "current" ? "step" : undefined,
      title: `${e.id} · ${e.name} · ${e.tier} · ${ownerText(e)} · ${txt(`op.state_${e.state}`).text}`,
    },
    // Board look (#478): a numbered cell; the finished and the running cell carry a mark besides the colour (#190).
    v("span", { class: "order-strip-no", "aria-hidden": "true" }, String(i + 1)),
    v("span", { class: "order-strip-mark", "aria-hidden": "true" }, e.state === "done" ? "✓" : e.state === "current" ? "▶" : ""),
    Siegel({ sym: e.id, color: e.color, name: e.name }, { theme, size: "s" }),
    v("span", { class: "order-strip-owner" }, e.mine ? txt("op.you").text : e.owner ?? "?"),
    v("span", { class: "or-sr" }, ` ${txt(`op.state_${e.state}`).text}`))));
  return v("section", { class: "order-band", "data-collapsed": opts.collapsed ? "true" : "false", "data-preview": b.preview ? "true" : "false", "aria-label": label },
    v("button", { type: "button", class: "order-band-toggle", "aria-expanded": String(!opts.collapsed), title: toggleLabel, "aria-label": toggleLabel, onclick: opts.onToggle },
      v("span", { "aria-hidden": "true" }, opts.collapsed ? "▸" : "▾"),
      v("span", { class: "order-band-title" }, label)),
    opts.collapsed ? null : list);
}
