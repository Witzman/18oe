// Geld(betrag): amounts in pounds as the engine prints them (£%s), German grouping, tabular digits.
import { v, type VNode } from "./vnode.ts";

/** "£1.250", "-£40" (true minus sign), thousands with a thin dot as in German. */
export function formatGeld(amount: number): string {
  if (!Number.isInteger(amount)) throw new Error(`Amount not an integer: ${amount}`);
  const digits = String(Math.abs(amount)).replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  return `${amount < 0 ? "−" : ""}£${digits}`;
}

export interface GeldOptions { delta?: boolean }

/** `delta` shows an explicit sign (+£5 / −£5) for changes. */
export function Geld(amount: number, o: GeldOptions = {}): VNode {
  const text = o.delta && amount > 0 ? `+${formatGeld(amount)}` : formatGeld(amount);
  const sign = amount < 0 ? "neg" : amount > 0 && o.delta ? "pos" : "zero";
  return v("span", { class: `kit-money kit-${sign}`, "data-amount": String(amount) }, text);
}
