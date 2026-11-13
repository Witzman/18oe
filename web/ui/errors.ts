// Server errors -> what the UI does (ui-spec §3.6, #162). Pure: no DOM, no fetch. All German text
// comes from text.ts; the engine's own message is shown unchanged (it is English by design).
import { ApiError } from "../api.ts";
import { txt } from "./text.ts";

export type ErrorKind = "rejected" | "conflict" | "forbidden" | "unauthorized" | "bad_request" | "network" | "not_found" | "server";

export interface Outcome {
  kind: ErrorKind;
  text: string;
  tone: "error" | "warn";
  // Selection and preview are thrown away (state is stale or the player may not act).
  discardSelection: boolean;
  // Load the full state again.
  reload: boolean;
  // Log the sent action to the console (a rejected offered action is a finding, bad requests a bug).
  log: boolean;
}

const fill = (key: string, vars: Record<string, string | number>): string =>
  txt(key).de.replace(/\{(\w+)\}/g, (_, k: string) => String(vars[k] ?? ""));

export function classify(err: ApiError): Outcome {
  const message = err.message;
  const base = { discardSelection: false, reload: false, log: false, tone: "error" as const };
  switch (err.status) {
    case 0:
      return { ...base, kind: "network", text: txt("msg.network_action").de };
    case 401:
      return { ...base, kind: "unauthorized", text: txt("error.login_required").de };
    case 403:
      return { ...base, kind: "forbidden", text: txt("msg.not_your_turn").de, discardSelection: true, reload: true };
    case 404:
      return { ...base, kind: "not_found", text: txt("msg.not_found_title").de };
    case 409:
      return { ...base, kind: "conflict", text: txt("msg.conflict").de, tone: "warn", discardSelection: true, reload: true };
    case 400:
      return { ...base, kind: "bad_request", text: fill("msg.bad_request", { message }), reload: true, log: true };
    case 422:
      return { ...base, kind: "rejected", text: fill("msg.rejected", { message }), log: true };
    default:
      return { ...base, kind: "server", text: fill("msg.server_error", { message }) };
  }
}
