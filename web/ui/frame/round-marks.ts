// The round chip of the head bar in the look of the board's "Current Round" (#478): discs Stock, OR 1, OR 2 on
// a ring, the running one filled. Colour is not the only carrier: the running disc is also bold with a frame
// and says "running now" for screen readers (#190). Rounds without markers (auction, concession,
// consolidation, end) keep the plain text chip.
import { v, type VNode } from "../kit/vnode.ts";
import { fillText, txt } from "../text.ts";
import type { RoundMarkers } from "./model.ts";

export function roundChip(long: string, short: string, r: RoundMarkers | null): VNode {
  if (!r) return v("span", { class: "frame-round", "aria-current": "step", title: long }, short);
  const label = `${txt("frame.round_indicator").text}: ${long}`;
  return v("span", { class: "frame-round round-marks", role: "group", "aria-label": label, title: long },
    r.set !== null ? v("span", { class: "round-set", title: fillText("frame.round_set", { n: r.set }) }, fillText("frame.round_set", { n: r.set })) : null,
    v("ol", { class: "round-marks-list" }, ...r.markers.map((m) => v("li", {
      class: "round-mark", "data-key": m.key, "data-active": m.active ? "true" : "false", "aria-current": m.active ? "step" : undefined,
    }, m.label, m.active ? v("span", { class: "or-sr" }, ` ${txt("frame.round_marker_active").text}`) : null))));
}
