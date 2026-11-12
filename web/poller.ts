import { ApiError, type Api } from "./api.ts";
import type { Game } from "./types.ts";

export interface PollerOptions {
  api: Pick<Api, "version" | "getGame">;
  gameId: number;
  onGame: (game: Game) => void;
  onError?: (e: ApiError) => void;
  onUnauthorized?: () => void;
  isVisible?: () => boolean;
  intervalMs?: number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
}

export type PollState = "stopped" | "waiting" | "checking" | "loading";

// Polls GET /games/:id/version (cheap) and loads the full state only when seq
// moved. Skips while the tab is hidden; resumes with an immediate check.
export function createPoller(opts: PollerOptions) {
  const interval = opts.intervalMs ?? 5000;
  const visible = opts.isVisible ?? (() => true);
  const setTimer = opts.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
  const clearTimer = opts.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
  let state: PollState = "stopped";
  // `state` changes across awaits; a function keeps TypeScript from narrowing it.
  const is = (s: PollState) => (state as PollState) === s;
  let lastSeq: number | null = null;
  let handle: unknown = null;

  function schedule() {
    if (is("stopped")) return;
    state = "waiting";
    handle = setTimer(() => void tick(), interval);
  }

  // One check; used by the timer, on first start and on "tab visible again".
  async function tick(force = false): Promise<void> {
    if (is("stopped") || is("checking") || is("loading")) return;
    if (handle !== null) clearTimer(handle);
    handle = null;
    if (!visible() && !force) return schedule();
    try {
      state = "checking";
      const v = await opts.api.version(opts.gameId);
      if (is("stopped")) return;
      if (v.seq !== lastSeq) {
        state = "loading";
        const game = await opts.api.getGame(opts.gameId);
        if (is("stopped")) return;
        lastSeq = game.seq;
        opts.onGame(game);
      }
    } catch (e) {
      if (is("stopped")) return;
      const err = e instanceof ApiError ? e : new ApiError(0, "network", String(e));
      if (err.status === 401) {
        stop();
        opts.onUnauthorized?.();
        return;
      }
      opts.onError?.(err);
    }
    schedule();
  }

  function start() {
    if (!is("stopped")) return;
    state = "waiting";
    void tick(true);
  }

  function stop() {
    state = "stopped";
    if (handle !== null) clearTimer(handle);
    handle = null;
  }

  // After the player's own action: show the new state right away.
  function adopt(game: Game) {
    lastSeq = game.seq;
    opts.onGame(game);
  }

  return { start, stop, tick: () => tick(), adopt, get state() { return state; }, get lastSeq() { return lastSeq; } };
}
