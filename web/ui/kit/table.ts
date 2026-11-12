// Tabelle: sortable, zebra rows, sticky header (ui-spec 5.3). Sorting is a pure function so it is tested alone.
import { v, type State, type VChild, type VNode } from "./vnode.ts";

export interface Column<R> {
  key: string;
  label: string;
  align?: "left" | "right";
  /** Sort value; a column without it is not sortable. */
  sortBy?: (row: R) => number | string;
  cell: (row: R) => VChild;
}
export interface Sort { key: string; dir: "asc" | "desc" }
export interface TableOptions<R> {
  caption: string;
  sort?: Sort;
  onSort?: (key: string) => void;
  rowState?: (row: R, index: number) => State;
  /** Reason shown as title on an invalid row. */
  /** Extra class on the wrapper, e.g. to lift the height limit. */
  wrapClass?: string;
  rowReason?: (row: R) => string | undefined;
}

export function sortRows<R>(rows: readonly R[], columns: readonly Column<R>[], sort?: Sort): R[] {
  const col = columns.find((c) => c.key === sort?.key);
  if (!sort || !col?.sortBy) return [...rows];
  const by = col.sortBy;
  const sign = sort.dir === "asc" ? 1 : -1;
  // Stable: Array.prototype.sort keeps the original order of equal keys.
  return [...rows].sort((a, b) => {
    const x = by(a), y = by(b);
    const r = typeof x === "number" && typeof y === "number" ? x - y : String(x).localeCompare(String(y), "de");
    return sign * r;
  });
}

/** Click on a header: new column ascending, same column flips, flipped twice returns to unsorted. */
export function nextSort(current: Sort | undefined, key: string): Sort | undefined {
  if (current?.key !== key) return { key, dir: "asc" };
  return current.dir === "asc" ? { key, dir: "desc" } : undefined;
}

export function Tabelle<R>(columns: readonly Column<R>[], rows: readonly R[], o: TableOptions<R>): VNode {
  const ariaSort = (c: Column<R>) => o.sort?.key === c.key ? (o.sort.dir === "asc" ? "ascending" : "descending") : c.sortBy ? "none" : undefined;
  const head = columns.map((c) => {
    const arrow = o.sort?.key === c.key ? (o.sort.dir === "asc" ? " ▲" : " ▼") : "";
    const inner = c.sortBy
      ? v("button", { type: "button", class: "kit-sort", onclick: () => o.onSort?.(c.key) }, c.label + arrow)
      : c.label;
    return v("th", { scope: "col", class: c.align === "right" ? "kit-right" : "", "aria-sort": ariaSort(c) }, inner);
  });
  const body = sortRows(rows, columns, o.sort).map((row, i) => {
    const state = o.rowState?.(row, i) ?? "normal";
    return v("tr", { "data-state": state, title: state === "invalid" ? o.rowReason?.(row) : undefined, "aria-selected": state === "selected" ? "true" : undefined },
      ...columns.map((c) => v("td", { class: c.align === "right" ? "kit-right" : "" }, c.cell(row))));
  });
  return v("div", { class: o.wrapClass ? `kit-table-wrap ${o.wrapClass}` : "kit-table-wrap" },
    v("table", { class: "kit-table" }, v("caption", {}, o.caption), v("thead", {}, v("tr", {}, ...head)), v("tbody", {}, ...body)));
}
