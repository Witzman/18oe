// Mount point for the views of the main area (#114 fills it: map, market, holdings, ...).
// The frame only knows the registry; a view renders into the container it is given.
export interface ViewContext { container: HTMLElement }
export interface ViewDef {
  id: string;
  /** Key in text.ts for the tab label. */
  labelKey: string;
  /** Draws the view into `ctx.container`; called again on every new game state. */
  render: (ctx: ViewContext) => void;
}

export function createViews(initial: ViewDef[] = []) {
  const defs = new Map<string, ViewDef>();
  let active: string | null = null;
  const listeners = new Set<() => void>();
  const changed = () => listeners.forEach((f) => f());
  const api = {
    register(def: ViewDef): () => void {
      defs.set(def.id, def);
      if (active === null || !defs.has(active)) active = def.id;
      changed();
      return () => { defs.delete(def.id); if (active === def.id) active = defs.keys().next().value ?? null; changed(); };
    },
    activate(id: string) { if (defs.has(id) && active !== id) { active = id; changed(); } },
    get list(): ViewDef[] { return [...defs.values()]; },
    get activeId(): string | null { return active; },
    get active(): ViewDef | null { return active ? defs.get(active) ?? null : null; },
    onChange(f: () => void): () => void { listeners.add(f); return () => { listeners.delete(f); }; },
  };
  initial.forEach((d) => api.register(d));
  return api;
}
export type Views = ReturnType<typeof createViews>;
