// The kit builds plain element descriptions (VNode), not DOM: tests inspect the structure under
// `node --test` without a browser, and toDom() turns the same tree into real elements (#160).
export type VChild = VNode | string | null | undefined | false;
export interface VNode {
  tag: string;
  attrs: Record<string, string>;
  /** Event handlers by DOM event name ("click", "keydown"); attached by toDom only. */
  on: Record<string, (e: Event) => void>;
  children: (VNode | string)[];
}

type Attrs = Record<string, string | boolean | undefined | null | ((e: Event) => void)>;

export function v(tag: string, attrs: Attrs = {}, ...children: VChild[]): VNode {
  const out: VNode = { tag, attrs: {}, on: {}, children: [] };
  for (const [k, val] of Object.entries(attrs)) {
    if (typeof val === "function") out.on[k.replace(/^on/, "")] = val;
    else if (val === true) out.attrs[k] = "";
    else if (typeof val === "string") out.attrs[k] = val;
  }
  for (const c of children) if (c !== null && c !== undefined && c !== false) out.children.push(c);
  return out;
}

const SVG_TAGS = new Set(["svg", "circle", "path", "text", "g", "polygon"]);

export function toDom(node: VNode | string): Node {
  if (typeof node === "string") return document.createTextNode(node);
  const el = SVG_TAGS.has(node.tag)
    ? document.createElementNS("http://www.w3.org/2000/svg", node.tag)
    : document.createElement(node.tag);
  for (const [k, val] of Object.entries(node.attrs)) el.setAttribute(k, val);
  for (const [k, fn] of Object.entries(node.on)) el.addEventListener(k, fn);
  for (const c of node.children) el.append(toDom(c));
  return el;
}

/** Visible text of a tree (tests, labels). */
export function textOf(node: VNode | string): string {
  return typeof node === "string" ? node : node.children.map(textOf).join("");
}

export function find(node: VNode | string, pred: (n: VNode) => boolean): VNode[] {
  if (typeof node === "string") return [];
  return [...(pred(node) ? [node] : []), ...node.children.flatMap((c) => find(c, pred))];
}

export function classes(node: VNode): string[] {
  return (node.attrs.class ?? "").split(/\s+/).filter(Boolean);
}

/** The states every block shows the same way (ui-spec 3.5). */
export const STATES = ["normal", "hover", "valid", "selected", "invalid", "preview", "waiting"] as const;
export type State = (typeof STATES)[number];
