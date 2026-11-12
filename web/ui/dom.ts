type Child = Node | string | null | undefined | false;

// Tiny element builder; no framework (#2). Text goes in as text nodes, never as HTML.
export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, string | boolean | ((e: Event) => void)> = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (typeof v === "function") el.addEventListener(k.replace(/^on/, ""), v);
    else if (typeof v === "boolean") { if (v) el.setAttribute(k, ""); }
    else el.setAttribute(k, v);
  }
  for (const c of children) if (c) el.append(c);
  return el;
}

export function mount(root: HTMLElement, ...nodes: Node[]) {
  root.replaceChildren(...nodes);
}
