// Geld(betrag): amounts in pounds as the engine prints them (£%s), German grouping, tabular digits.
import { v, type VNode } from "./vnode.ts";

/**
 * "£1.250", "-£40" (true minus sign), thousands with a dot as in German. Fractions (a dividend per share,
 * e.g. £70 over 8 shares = £8.75, §11.4) show up to two decimals with a comma: "£8,75", "£0,50". Never
 * throws (workshop issue 294: a throw here blanked the whole operating panel); a non-number shows as "£?".
 */
export function formatGeld(amount: number): string {
  if (!Number.isFinite(amount)) return "£?";
  const cents = Math.round(Math.abs(amount) * 100);
  const whole = Math.floor(cents / 100);
  const frac = cents % 100;
  const digits = String(whole).replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  const sign = amount < 0 && cents > 0 ? "−" : "";
  return `${sign}£${digits}${frac === 0 ? "" : `,${String(frac).padStart(2, "0")}`}`;
}

export interface GeldOptions { delta?: boolean }

/** `delta` shows an explicit sign (+£5 / −£5) for changes. */
export function Geld(amount: number, o: GeldOptions = {}): VNode {
  const text = o.delta && amount > 0 ? `+${formatGeld(amount)}` : formatGeld(amount);
  const sign = amount < 0 ? "neg" : amount > 0 && o.delta ? "pos" : "zero";
  return v("span", { class: `kit-money kit-${sign}`, "data-amount": String(amount) }, text);
}
