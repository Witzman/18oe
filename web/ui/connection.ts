// Message area of the action bar and the "no connection" band (ui-spec §3.6, #162). Text from text.ts.
import { h } from "./dom.ts";
import { txt } from "./text.ts";

export function messageArea() {
  const el = h("div", { class: "msg", role: "status", "aria-live": "polite" });
  return {
    el,
    say(text: string, tone: "error" | "warn") {
      el.className = `msg msg-${tone}`;
      el.textContent = text;
    },
    clear() {
      el.className = "msg";
      el.textContent = "";
    },
  };
}

export interface BandOptions {
  retryNow: () => void;
  setInterval?: (fn: () => void, ms: number) => unknown;
  clearInterval?: (h: unknown) => void;
}

// Band below the round bar: counts down to the next automatic attempt of the poller, "Jetzt" tries now.
// Only polling is retried automatically; an action is never resent.
export function connectionBand(o: BandOptions) {
  const setI = o.setInterval ?? ((fn, ms) => setInterval(fn, ms));
  const clearI = o.clearInterval ?? ((hd) => clearInterval(hd as ReturnType<typeof setInterval>));
  const label = h("span", {});
  const el = h("div", { class: "band", role: "alert", hidden: true }, label, h("button", { type: "button", onclick: () => o.retryNow() }, txt("msg.network_retry").de));
  let left = 0;
  let timer: unknown = null;
  const draw = () => { label.textContent = txt("msg.network_band").de.replace("{n}", String(Math.max(0, left))); };
  const stopTimer = () => { if (timer !== null) clearI(timer); timer = null; };
  return {
    el,
    // The poller reports a failed check; `ms` until the next one.
    failed(ms: number) {
      left = Math.ceil(ms / 1000);
      el.hidden = false;
      draw();
      stopTimer();
      timer = setI(() => { left = Math.max(0, left - 1); draw(); }, 1000);
    },
    ok() { stopTimer(); el.hidden = true; },
    get visible() { return !el.hidden; },
    get seconds() { return left; },
  };
}
