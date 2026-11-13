// Which action types a special panel handles itself (ui-spec 3.4, #45). Everything nobody claims stays
// in the generic action bar, so every game is fully playable even for steps without a panel.
export const ANY_STEP = "*";
export const ANY_TYPE = "*";

export function createClaims() {
  const counts = new Map<string, number>();
  const key = (step: string, type: string) => `${step}\u0000${type}`;
  return {
    /** Claim (step, type); `ANY_STEP` / `ANY_TYPE` are wildcards. Returns the release function. */
    claim(step: string, type: string): () => void {
      const k = key(step, type);
      counts.set(k, (counts.get(k) ?? 0) + 1);
      let released = false;
      return () => {
        if (released) return;
        released = true;
        const n = (counts.get(k) ?? 1) - 1;
        if (n <= 0) counts.delete(k); else counts.set(k, n);
      };
    },
    isClaimed(step: string | null, type: string): boolean {
      const s = step ?? "";
      return [key(s, type), key(s, ANY_TYPE), key(ANY_STEP, type), key(ANY_STEP, ANY_TYPE)].some((k) => counts.has(k));
    },
  };
}
export type Claims = ReturnType<typeof createClaims>;
