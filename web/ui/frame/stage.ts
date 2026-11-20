// The two steps of the action box (#497 S2): step 1 shows only the KIND of action, step 2 only the options of
// that kind, with a way back. Pure state machine; the frame holds the one value `stage` (the chosen kind or
// null), never stored (no localStorage, not sent): a new seq, a changed turn or a reload drops it.
import type { Kind } from "./kinds.ts";

export interface StageView {
  step: 1 | 2;
  /** The kind whose options show (step 2); null in step 1 and when nothing is offered. */
  kind: Kind | null;
  /** The back button exists only when there was a choice of kinds to go back to. */
  back: boolean;
}

/** What the box shows for the offered kinds (in their fixed order) and the player's choice `stage`.
 *  A stage that is no longer offered (turn changed, action gone) counts as none; a single kind skips step 1. */
export function stageView(kinds: readonly Kind[], stage: Kind | null): StageView {
  if (kinds.length === 0) return { step: 2, kind: null, back: false };
  if (stage !== null && kinds.includes(stage)) return { step: 2, kind: stage, back: kinds.length > 1 };
  if (kinds.length === 1) return { step: 2, kind: kinds[0]!, back: false };
  return { step: 1, kind: null, back: false };
}

/** Step 1 -> 2: choose a kind; a kind that is not offered leaves the stage as it is. */
export const chooseKind = (kinds: readonly Kind[], stage: Kind | null, kind: Kind): Kind | null => (kinds.includes(kind) ? kind : stage);

/** Back: always to step 1 (the frame also drops a started selection). */
export const backStage = (): null => null;

/** A new seq drops the stage (after executing, step 1 shows again); the same seq keeps it (rotating the iPad). */
export const stageAfterRender = (stage: Kind | null, prevSeq: number | null, seq: number): Kind | null => (prevSeq === seq ? stage : null);
