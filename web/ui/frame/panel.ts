// Collapsed state of the action panel (#301): remembered per device in localStorage (assumption, #301).
// Storage can be missing or throw (private window, blocked site data): the panel then starts open.
export const COLLAPSED_KEY = "oe.panel.collapsed";

export function readCollapsed(storage: Pick<Storage, "getItem"> | null = safeStorage()): boolean {
  try { return storage?.getItem(COLLAPSED_KEY) === "1"; } catch { return false; }
}

export function writeCollapsed(collapsed: boolean, storage: Pick<Storage, "setItem" | "removeItem"> | null = safeStorage()): void {
  try { if (collapsed) storage?.setItem(COLLAPSED_KEY, "1"); else storage?.removeItem(COLLAPSED_KEY); } catch { /* per-viewer convenience only */ }
}

function safeStorage(): Storage | null {
  try { return typeof localStorage === "undefined" ? null : localStorage; } catch { return null; }
}
