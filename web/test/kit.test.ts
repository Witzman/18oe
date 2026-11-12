// UI kit (#160). Runs under `node --test` without a browser: the blocks are pure functions returning
// VNode trees; toDom is checked with a minimal document stub. Not covered here: real layout, CSS
// rendering, hover/focus behaviour and looks in a browser (no screenshot tool yet, #42).
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { contrast } from "../themes/color.ts";
import { themes } from "../themes/index.ts";
import { Auftrag, Dialog, Geld, Leiter, Siegel, STATES, Tabelle, Tooltip, Wimpel, formatGeld, inkFor, inkReadable, mitTooltip, nextSort, playerSlot, sortRows, stepsAt, toDom, v } from "../ui/kit/index.ts";
import { kitSections } from "../ui/kit/page.ts";
import { classes, find, textOf } from "../ui/kit/vnode.ts";

const brett = themes.find((t) => t.id === "brett")!;
const kitDir = join(dirname(fileURLToPath(import.meta.url)), "..", "ui", "kit");

test("Siegel: abbreviation on company colour, text colour computed per theme, readable on all company colours", () => {
  for (const theme of themes) {
    for (const color of Object.values(theme.company)) {
      assert.ok(inkReadable(color, theme), `${theme.id} ${color}`);
      const s = Siegel({ sym: "PLM", color }, { theme });
      assert.equal(textOf(s), "PLM");
      assert.ok(s.attrs.style!.includes(`--seal-bg:${color}`));
      assert.ok(s.attrs.style!.includes(`--seal-ink:${inkFor(color, theme)}`));
    }
  }
  assert.ok(contrast(inkFor(brett.ui.bar, brett), brett.ui.bar) > 4.5);
});

test("Siegel: link makes it a clickable anchor, every state is marked", () => {
  const corp = { sym: "KK", name: "k.k. Staatsbahn", color: brett.company.c2 };
  assert.equal(Siegel(corp, { theme: brett, link: "#/corp/KK" }).tag, "a");
  assert.equal(Siegel(corp, { theme: brett }).tag, "span");
  for (const state of STATES) assert.equal(Siegel(corp, { theme: brett, state }).attrs["data-state"], state);
  assert.equal(Siegel(corp, { theme: brett, state: "invalid" }).attrs["aria-disabled"], "true");
  assert.equal(Siegel(corp, { theme: brett, state: "selected" }).attrs["aria-current"], "true");
});

test("Wimpel: seat digit always present (never colour alone), 7 distinct slots, seat 8 rejected", () => {
  const slots = [1, 2, 3, 4, 5, 6, 7].map(playerSlot);
  assert.equal(new Set(slots).size, 7);
  assert.throws(() => playerSlot(8));
  assert.throws(() => playerSlot(0));
  for (let seat = 1; seat <= 7; seat++) {
    const w = Wimpel({ seat, name: "Anna" }, { theme: brett });
    assert.equal(find(w, (n) => classes(n).includes("kit-flag"))[0]!.children[0], String(seat));
    assert.ok(w.attrs["aria-label"]!.includes(`Spieler ${seat}`));
    for (const theme of themes) assert.ok(inkReadable(theme.player[playerSlot(seat)], theme), `${theme.id} p${seat}`);
  }
  assert.ok(find(Wimpel({ seat: 1, name: "A" }, { theme: brett }), (n) => n.attrs.style?.includes("var(--player-p1)") ?? false).length === 1);
});

test("Geld: pound sign, German grouping, true minus, optional delta sign, integers only", () => {
  assert.equal(formatGeld(0), "£0");
  assert.equal(formatGeld(1250), "£1.250");
  assert.equal(formatGeld(1234567), "£1.234.567");
  assert.equal(formatGeld(-40), "−£40");
  assert.equal(textOf(Geld(5, { delta: true })), "+£5");
  assert.equal(textOf(Geld(-5, { delta: true })), "−£5");
  assert.ok(classes(Geld(-5)).includes("kit-neg"));
  assert.throws(() => formatGeld(1.5));
});

const rows = [{ n: "b", x: 2 }, { n: "a", x: 10 }, { n: "c", x: 2 }];
const cols = [
  { key: "n", label: "Name", sortBy: (r: (typeof rows)[number]) => r.n, cell: (r: (typeof rows)[number]) => r.n },
  { key: "x", label: "X", align: "right" as const, sortBy: (r: (typeof rows)[number]) => r.x, cell: (r: (typeof rows)[number]) => String(r.x) },
  { key: "plain", label: "Plain", cell: () => "" },
];

test("Tabelle: sorts numbers numerically and stably, texts by German collation, unsortable column ignored", () => {
  assert.deepEqual(sortRows(rows, cols, { key: "x", dir: "asc" }).map((r) => r.n), ["b", "c", "a"]);
  assert.deepEqual(sortRows(rows, cols, { key: "x", dir: "desc" }).map((r) => r.n), ["a", "b", "c"]);
  assert.deepEqual(sortRows(rows, cols, { key: "n", dir: "asc" }).map((r) => r.n), ["a", "b", "c"]);
  assert.deepEqual(sortRows(rows, cols, { key: "plain", dir: "asc" }), rows);
  assert.deepEqual(sortRows(rows, cols), rows);
  assert.deepEqual(nextSort(undefined, "x"), { key: "x", dir: "asc" });
  assert.deepEqual(nextSort({ key: "x", dir: "asc" }, "x"), { key: "x", dir: "desc" });
  assert.equal(nextSort({ key: "x", dir: "desc" }, "x"), undefined);
  assert.deepEqual(nextSort({ key: "x", dir: "desc" }, "n"), { key: "n", dir: "asc" });
});

test("Tabelle: header cells carry aria-sort, sortable headers are buttons, row states and reason", () => {
  let clicked = "";
  const t = Tabelle(cols, rows, { caption: "T", sort: { key: "x", dir: "desc" }, onSort: (k) => { clicked = k; },
    rowState: (_, i) => (i === 0 ? "invalid" : "normal"), rowReason: () => "kein Geld" });
  const ths = find(t, (n) => n.tag === "th");
  assert.deepEqual(ths.map((n) => n.attrs["aria-sort"]), [ "none", "descending", undefined ]);
  assert.equal(find(t, (n) => n.tag === "button").length, 2);
  find(t, (n) => n.tag === "button")[0]!.on.click!(new Event("click"));
  assert.equal(clicked, "n");
  const trs = find(t, (n) => n.tag === "tr" && "data-state" in n.attrs);
  assert.equal(trs[0]!.attrs.title, "kein Geld");
  assert.equal(trs[1]!.attrs.title, undefined);
  assert.equal(textOf(find(t, (n) => n.tag === "td")[0]!), "a");
});

test("Tooltip: title, English term, breakdown rows, total and source; wrapper describes its trigger", () => {
  const tip = Tooltip({ title: "Baukosten", term: "Terrain cost", rows: [{ label: "Gelände", amount: 20 }, { label: "Rabatt", amount: -5 }], total: { label: "Summe", amount: 15 }, source: "Regeln §11.3" }, "t1");
  assert.equal(tip.attrs.role, "tooltip");
  const text = textOf(tip);
  for (const part of ["Baukosten", "Terrain cost", "Gelände", "£20", "−£5", "Summe", "£15", "Quelle: Regeln §11.3"]) assert.ok(text.includes(part), part);
  assert.equal(find(tip, (n) => classes(n).includes("kit-tip-row")).length, 3);
  assert.ok(!textOf(Tooltip({ title: "x" }, "t2")).includes("Quelle"));
  const wrapped = mitTooltip(v("button", {}, "Legen"), { title: "x" }, "t3");
  const trigger = find(wrapped, (n) => n.tag === "button")[0]!;
  assert.equal(trigger.attrs["aria-describedby"], "t3");
  assert.equal(trigger.attrs.tabindex, "0");
  assert.equal(find(wrapped, (n) => n.attrs.id === "t3").length, 1);
});

test("Dialog: modal, labelled by its title, Escape and backdrop click close, inner click does not", () => {
  let closed = 0;
  const d = Dialog({ title: "Beenden?", body: ["Sicher?"], actions: [v("button", {}, "Ja")], onClose: () => { closed++; } });
  const dlg = find(d, (n) => n.attrs.role === "dialog")[0]!;
  assert.equal(dlg.attrs["aria-modal"], "true");
  assert.equal(find(d, (n) => n.attrs.id === dlg.attrs["aria-labelledby"]).length, 1);
  d.on.keydown!({ key: "Enter" } as unknown as Event);
  assert.equal(closed, 0);
  d.on.keydown!({ key: "Escape" } as unknown as Event);
  assert.equal(closed, 1);
  d.on.click!({ target: d, currentTarget: d } as unknown as Event);
  assert.equal(closed, 2);
  d.on.click!({ target: dlg, currentTarget: d } as unknown as Event);
  assert.equal(closed, 2);
});

test("Dialog never covers the round bar: backdrop is absolute inside .kit-main, not fixed", () => {
  const css = readFileSync(join(kitDir, "kit.css"), "utf8");
  assert.match(css, /\.kit-main \{[^}]*position: relative/);
  assert.match(css, /\.kit-backdrop \{[^}]*position: absolute/);
  assert.doesNotMatch(css, /position: fixed/);
});

test("Leiter: done/active/future with glyph and aria-current on the active step only", () => {
  const steps = stepsAt(["a", "b", "c", "d"], 2);
  assert.deepEqual(steps.map((s) => s.state), ["done", "done", "active", "future"]);
  const l = Leiter(steps, "Ablauf");
  const items = find(l, (n) => n.tag === "li");
  assert.deepEqual(items.map((n) => n.attrs["aria-current"]), [undefined, undefined, "step", undefined]);
  assert.equal(new Set(items.map((n) => textOf(n.children[0]!))).size, 3);
});

const order = (state: Parameters<typeof Auftrag>[0]["state"], extra: Partial<Parameters<typeof Auftrag>[0]> = {}) =>
  Auftrag({ sentence: "PLM kaufen", state, changes: [{ label: "Kasse", before: "£260", after: "£95" }], ...extra });
const confirmBtn = (n: ReturnType<typeof order>) => find(n, (x) => classes(x).includes("kit-main-btn"))[0]!;

test("Auftrag: sentence plus before -> after, confirm and cancel call back", () => {
  let ok = 0, no = 0;
  const o = order("preview", { onConfirm: () => { ok++; }, onCancel: () => { no++; } });
  assert.ok(textOf(o).includes("PLM kaufen"));
  assert.ok(textOf(find(o, (n) => n.tag === "dd")[0]!).includes("£260 → £95"));
  assert.equal(textOf(confirmBtn(o)), "Bestätigen");
  confirmBtn(o).on.click!(new Event("click"));
  find(o, (n) => classes(n).includes("kit-side-btn"))[0]!.on.click!(new Event("click"));
  assert.deepEqual([ok, no], [1, 1]);
});

test("Auftrag: waiting shows dots and locks everything; invalid locks confirm and explains why", () => {
  let ok = 0;
  const w = order("waiting", { onConfirm: () => { ok++; } });
  assert.equal(confirmBtn(w).attrs.disabled, "");
  assert.equal(find(w, (n) => classes(n).includes("kit-side-btn"))[0]!.attrs.disabled, "");
  assert.ok(textOf(confirmBtn(w)).includes("•••"));
  confirmBtn(w).on.click!(new Event("click"));
  const bad = order("invalid", { reason: "Kasse reicht nicht", onConfirm: () => { ok++; } });
  assert.equal(confirmBtn(bad).attrs.disabled, "");
  confirmBtn(bad).on.click!(new Event("click"));
  assert.equal(ok, 0);
  assert.ok(textOf(bad).includes("Kasse reicht nicht"));
  assert.equal(confirmBtn(bad).attrs["aria-describedby"], find(bad, (n) => n.attrs.role === "tooltip")[0]!.attrs.id);
  assert.equal(confirmBtn(order("valid")).attrs.disabled, undefined);
});

test("sample page shows every block in all seven states", () => {
  for (const theme of themes) {
    const secs = kitSections(theme, { dialog: false }, { sort: () => {}, dialog: () => {} });
    const rowsOf = (title: string) => find(secs.find((s) => textOf(find(s, (n) => n.tag === "h2")[0]!) === title)!, (n) => n.tag === "dt" && !["Kasse", "Zertifikate"].includes(textOf(n))).length;
    assert.deepEqual(["Siegel", "Wimpel", "Auftrag"].map(rowsOf), [7, 8, 7]);
    const states = (title: string) => new Set(find(secs.find((s) => textOf(find(s, (n) => n.tag === "h2")[0]!) === title)!, (n) => "data-state" in n.attrs).map((n) => n.attrs["data-state"]));
    for (const title of ["Siegel", "Wimpel", "Tabelle", "Auftrag"]) assert.deepEqual([...states(title)].sort(), [...STATES].sort(), title);
    assert.deepEqual(secs.length, 8);
  }
});

test("kit code and styles contain no colour literals (Rule 10: theme tokens only)", () => {
  const literal = /#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(|\b(?:white|black|red|green|blue|gray|grey)\b(?=\s*[;,)])/;
  for (const f of readdirSync(kitDir).filter((n) => /\.(ts|css)$/.test(n))) {
    const text = readFileSync(join(kitDir, f), "utf8").split("\n").filter((l) => !l.trimStart().startsWith("//") && !l.trimStart().startsWith("/*")).join("\n");
    assert.doesNotMatch(text, literal, f);
  }
});

test("every var(--x) in kit.css exists in the generated theme CSS or is kit-local", async () => {
  const { themesCss } = await import("../themes/css.ts");
  const generated = themesCss(themes, "brett");
  const css = readFileSync(join(kitDir, "kit.css"), "utf8");
  const local = new Set(["--k", "--seal-bg", "--seal-ink", "--flag-bg", "--flag-ink", "--seal-fs", "--kit-invalid-mark", "--kit-table-max"]);
  const missing = [...new Set([...css.matchAll(/var\((--[a-z0-9-]+)/g)].map((m) => m[1]!))].filter((n) => !local.has(n) && !generated.includes(`${n}:`));
  assert.deepEqual(missing, []);
});

test("toDom builds elements, text, attributes and handlers with a document stub", () => {
  class El { tag: string; attrs: Record<string, string> = {}; kids: unknown[] = []; ls: Record<string, unknown> = {};
    constructor(tag: string) { this.tag = tag; }
    setAttribute(k: string, val: string) { this.attrs[k] = val; }
    addEventListener(k: string, f: unknown) { this.ls[k] = f; }
    append(...c: unknown[]) { this.kids.push(...c); } }
  const g = globalThis as unknown as { document?: unknown };
  const before = g.document;
  g.document = { createElement: (t: string) => new El(t), createElementNS: (_: string, t: string) => new El(t), createTextNode: (t: string) => ({ text: t }) };
  try {
    const dom = toDom(v("button", { class: "x", disabled: true, onclick: () => {} }, "Hi", null, v("b", {}, "!"))) as unknown as El;
    assert.equal(dom.tag, "button");
    assert.deepEqual(dom.attrs, { class: "x", disabled: "" });
    assert.ok(typeof dom.ls.click === "function");
    assert.deepEqual(dom.kids[0], { text: "Hi" });
    assert.equal((dom.kids[1] as El).tag, "b");
  } finally { g.document = before; }
});
