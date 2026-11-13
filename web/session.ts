// Sending the player's actions (#162, ui-spec §3.6): every action carries the `seq` its selection is
// based on; the poller pauses while it is in flight; the answer (full state) replaces the state.
// Errors are classified in ui/errors.ts; this file only does the wiring and holds no German text.
import { ApiError, type Api } from "./api.ts";
import { classify, type Outcome } from "./ui/errors.ts";
import type { Game } from "./types.ts";

export interface SessionOptions {
  api: Pick<Api, "postAction" | "getGame">;
  gameId: number;
  poller: { pause: () => void; resume: () => void; adopt: (g: Game) => void };
  // Message area of the action bar: show / clear.
  say: (text: string, tone: "error" | "warn") => void;
  clearMessage: () => void;
  setBusy: (busy: boolean) => void;
  discardSelection: () => void;
  onUnauthorized: () => void;
  onNotFound: () => void;
  warn?: (...a: unknown[]) => void;
}

export function createSession(o: SessionOptions) {
  const warn = o.warn ?? ((...a: unknown[]) => console.warn(...a));
  let busy = false;

  // Resolves to the new game on success, or null after the error was handled (never throws).
  async function send(action: Record<string, unknown>, seq: number): Promise<Game | null> {
    if (busy) return null;
    busy = true;
    o.clearMessage();
    o.setBusy(true);
    o.poller.pause();
    try {
      const game = await o.api.postAction(o.gameId, action, seq);
      o.poller.adopt(game);
      return game;
    } catch (e) {
      const err = e instanceof ApiError ? e : new ApiError(0, "network", String(e));
      await handle(err, action);
      return null;
    } finally {
      busy = false;
      o.setBusy(false);
      o.poller.resume();
    }
  }

  async function handle(err: ApiError, action: Record<string, unknown>) {
    const out: Outcome = classify(err);
    if (out.log) warn(`${err.status} ${err.code}: ${err.message}`, action);
    if (out.kind === "unauthorized") return o.onUnauthorized();
    if (out.kind === "not_found") return o.onNotFound();
    o.say(out.text, out.tone);
    if (out.discardSelection) o.discardSelection();
    // A failed reload must not hide the first message; the poller shows connection loss itself.
    if (out.reload) await o.api.getGame(o.gameId).then((g) => o.poller.adopt(g)).catch(() => {});
  }

  return { send, get busy() { return busy; } };
}
