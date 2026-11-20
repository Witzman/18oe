// Action kinds of the action box (#497 S1): the step before the options. The player first picks the KIND of
// action, then only the options of that kind. Pure: sorts what the engine offers (`prompt.actions`) into
// kinds, no rule of its own and no table "phase -> allowed kinds" (the engine offers by phase, #493); a kind
// exists exactly when at least one offered action fits. Grouping is frontend only, no view field (rule 27).
// Applies only to the stock round step and the concession step; every other step is left to the generic bar.
import type { Game } from "../../types.ts";
import { offers } from "../panels/concession.ts";

type Action = Record<string, unknown>;

/** Fixed order of the kinds in step 1: found, buy, sell, remove, privates, the rest, pass, the catch-all last. */
export const KINDS = [
  "float_regional", "float_minor", "par_regional", "buy", "sell", "remove_regional",
  "private_close", "private_remove", "private_act", "reserve", "offer", "convert", "trade", "pass", "other",
] as const;
export type Kind = (typeof KINDS)[number];

const STEPS = ["BuySellParShares", "Concession"];

/** Do the kinds apply to this state? Only the stock round step and the concession step. */
export const usesKinds = (g: Game): boolean => STEPS.includes(g.state.prompt.step ?? "");

/** The kind of one offered action; whatever is not recognised is `other`, so nothing becomes unreachable.
 *  `choose` is a collective type: it is told apart by `choice` and `target_type` (lib/oe/legal_actions.rb
 *  `stock_choices`: a private's choices, a corporation's remove/reserve/offer_or_merge, and a bare minor id
 *  for the merge offer), never by a label. */
export function kindOfAction(g: Game, a: Action): Kind {
  switch (a.type) {
    case "par": return parKind(g, a);
    case "buy_shares": return "buy";
    case "sell_shares": return "sell";
    case "pass": return "pass";
    case "convert": return "convert";
    case "buy_company": case "buy_corporation": return "trade";
    case "choose": return chooseKind(a);
    default: return "other";
  }
}

function parKind(g: Game, a: Action): Kind {
  const corp = g.state.corporations.find((c) => c.id === a.corporation);
  if (corp?.type === "minor") return "float_minor";
  // The engine floats a regional at once when it is parred in the stock round; only the concession step has the
  // par-only case (a regional parred for later, §8.1): the same reading as the concession panel.
  if (g.state.prompt.step === "Concession" && parOnly(g).has(String(a.corporation))) return "par_regional";
  return "float_regional";
}

// offers() walks the whole prompt; once per prompt object is enough.
const parOnlyCache = new WeakMap<object, Set<string>>();
function parOnly(g: Game): Set<string> {
  const key = g.state.prompt;
  let set = parOnlyCache.get(key);
  if (!set) parOnlyCache.set(key, set = new Set(offers(g).filter((o) => o.kind === "par_only").map((o) => o.corp)));
  return set;
}

function chooseKind(a: Action): Kind {
  const choice = String(a.choice ?? "");
  if (a.target_type === "company") {
    if (choice === "flip_private") return "private_close";
    if (choice === "remove_private") return "private_remove";
    return "private_act"; // bbbt_custody / bbbt_protect / bbbt_repar and any later private ability
  }
  if (a.target_type === "corporation") {
    if (choice === "remove") return "remove_regional";
    if (choice === "reserve") return "reserve";
    if (choice === "offer_or_merge") return "offer";
    return "other";
  }
  return a.target === undefined || a.target === null ? "offer" : "other"; // a bare minor id: offer it for merging
}

/** Step 1: the kinds offered now, in the fixed order. Empty outside the stock and concession steps. */
export function kindsOf(g: Game): Kind[] {
  return kindGroups(g).map((x) => x.kind);
}

/** Step 2: the offered actions of one kind, in the order of the prompt. */
export function actionsOfKind(g: Game, kind: Kind): Action[] {
  return usesKinds(g) ? g.state.prompt.actions.filter((a) => kindOfAction(g, a) === kind) : [];
}

/** All offered actions grouped by kind, kinds in the fixed order, only kinds with an action. */
export function kindGroups(g: Game): { kind: Kind; actions: Action[] }[] {
  if (!usesKinds(g)) return [];
  const by = new Map<Kind, Action[]>();
  for (const a of g.state.prompt.actions) {
    const k = kindOfAction(g, a);
    by.set(k, [...(by.get(k) ?? []), a]);
  }
  return KINDS.filter((k) => by.has(k)).map((kind) => ({ kind, actions: by.get(kind)! }));
}
