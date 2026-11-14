// The full game log (#292): the frame's log sheet shows the whole game from the first line, not just the
// last 40 of the state. Lines come from GET /games/:id/log (#152), paged; new lines are appended.
import type { LogPage } from "../../types.ts";

export type LogLine = { action: number; text: string };
export type LogPager = (from: number) => Promise<LogPage>;

/** Appends `incoming` to `have`; lines of `have` from the first incoming action on are replaced (no duplicates). */
export function mergeLog(have: LogLine[], incoming: LogLine[]): LogLine[] {
  if (incoming.length === 0) return have;
  const first = incoming[0]!.action;
  let keep = have.length;
  while (keep > 0 && have[keep - 1]!.action >= first) keep--;
  return [...have.slice(0, keep), ...incoming];
}

/** All lines after action id `from`, following the pages. A page that was cut inside an action is
 *  re-requested from that action's start, so the lines of one action are never split or lost. */
export async function fetchLogFrom(page: LogPager, from: number): Promise<LogLine[]> {
  let out: LogLine[] = [];
  let cursor = from;
  for (let guard = 0; guard < 1000; guard++) {
    const p = await page(cursor);
    let lines = p.lines;
    if (p.next === null || lines.length === 0) return mergeLog(out, lines);
    const last = lines[lines.length - 1]!.action;
    const cut = lines.filter((l) => l.action < last);
    if (cut.length > 0) { lines = cut; cursor = last - 1; } else cursor = p.next;
    out = mergeLog(out, lines);
  }
  return out;
}

/** Where to continue after what is loaded: one action before the last one, as its lines may have grown. */
export const resumeFrom = (have: LogLine[]): number => (have.length === 0 ? 0 : Math.max(0, have[have.length - 1]!.action - 1));

/** Scroll bookkeeping: stay at the end only if the reader was at the end; otherwise keep the position. */
export function nextScrollTop(prev: { top: number; atBottom: boolean }, scrollHeight: number, clientHeight: number): number {
  return prev.atBottom ? Math.max(0, scrollHeight - clientHeight) : prev.top;
}
export const isAtBottom = (top: number, scrollHeight: number, clientHeight: number): boolean => scrollHeight - clientHeight - top <= 8;
