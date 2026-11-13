// Musterseite #/kit: every block in every state, in the active theme (switch via the Look menu).
// Hover cannot be forced with :hover, so the sample sets data-state="hover" (the CSS treats both alike).
import { choiceFromRoot } from "../../themes/choice.ts";
import { companyBg } from "../../themes/companies.ts";
import type { Theme } from "../../themes/schema.ts";
import { Auftrag, Dialog, Geld, Leiter, mitTooltip, Siegel, stepsAt, STATES, Tabelle, toDom, v, Wimpel, type Corp, type Sort, type State, type VNode } from "./index.ts";
import { nextSort } from "./table.ts";

// Sample data. Company colours are the theme's `companies` tokens (#99); sample syms without a token (KK, DR, SNCB are
// not engine ids) fall back to the placeholders company.c1..c6.
const corps = (theme: Theme): Corp[] => [
  { sym: "PLM", name: "Paris-Lyon-Méditerranée", color: companyBg(theme, "PLM") },
  { sym: "KK", name: "Kaiserlich-Königliche Staatsbahn", color: companyBg(theme, "KK", ["", "KK"]) },
  { sym: "DR", name: "Deutsche Reichsbahn", color: companyBg(theme, "DR", ["", "", "", "DR"]) },
  { sym: "SNCB", name: "Belgische Staatsbahn", color: companyBg(theme, "SNCB", ["", "", "", "", "", "SNCB"]) },
];
const PLAYERS = ["Anna", "Ben", "Clara", "Dirk", "Eva", "Finn", "Gita"].map((name, i) => ({ seat: i + 1, name }));
const rowsOf = (c: Corp[]) => [
  { corp: c[0]!, cash: 410, certs: 7 }, { corp: c[1]!, cash: 95, certs: 11 },
  { corp: c[2]!, cash: 1230, certs: 8 }, { corp: c[3]!, cash: -40, certs: 2 },
];
type Row = ReturnType<typeof rowsOf>[number];

const label = (s: State) => ({ normal: "normal", hover: "Hover", valid: "gültig", selected: "ausgewählt", invalid: "ungültig", preview: "Vorschau", waiting: "wartet" })[s];
const section = (title: string, ...rows: [string, ...VNode[]][]) =>
  v("section", {}, v("h2", {}, title), v("dl", { class: "kit-grid" }, ...rows.flatMap(([k, ...vs]) => [v("dt", {}, k), v("dd", {}, ...vs)])));

export function kitSections(theme: Theme, state: { sort?: Sort; dialog: boolean }, act: { sort: (k: string) => void; dialog: (open: boolean) => void }): VNode[] {
  const CORPS = corps(theme);
  const ROWS = rowsOf(CORPS);
  const columns = [
    { key: "corp", label: "Firma", sortBy: (r: Row) => r.corp.sym, cell: (r: Row) => Siegel(r.corp, { theme, size: "s" }) },
    { key: "cash", label: "Kasse", align: "right" as const, sortBy: (r: Row) => r.cash, cell: (r: Row) => Geld(r.cash) },
    { key: "certs", label: "Zertifikate", align: "right" as const, sortBy: (r: Row) => r.certs, cell: (r: Row) => `${r.certs} / 20` },
  ];
  const tip = { title: "Baukosten V41", term: "Terrain cost", rows: [{ label: "Gelände", amount: 20 }, { label: "Zonenrabatt", amount: -5 }, { label: "Fähre £5 × 3", amount: 15 }], total: { label: "Summe", amount: 30 }, source: "Regeln §11.3" };
  const order = (s: State) => Auftrag({
    sentence: "PLM 10 % aus dem Markt kaufen, £165", state: s,
    changes: [{ label: "Kasse", before: Geld(260), after: Geld(95) }, { label: "Zertifikate", before: "11", after: "12 von 20" }],
    reason: s === "invalid" ? "Die Kasse reicht nicht (£165 nötig, £95 da)." : undefined,
  });
  return [
    section("Siegel, alle Firmen der Engine (#99)", ["Alle 36 (Minors, Regionals)", ...Object.keys(theme.companies).map((sym) => Siegel({ sym, color: theme.companies[sym]!.bg }, { theme }))]),
    section("Siegel", ...STATES.map((s): [string, ...VNode[]] => [label(s), ...CORPS.map((c) => Siegel(c, { theme, state: s })), Siegel(CORPS[0]!, { theme, state: s, size: "l" })])),
    section("Wimpel", ...STATES.map((s): [string, ...VNode[]] => [label(s), ...PLAYERS.slice(0, 3).map((p) => Wimpel(p, { theme, state: s }))]),
      ["alle 7 Farben", ...PLAYERS.map((p) => Wimpel(p, { theme }))]),
    section("Geld", ["Beträge", Geld(0), Geld(5), Geld(1250), Geld(-40)], ["Änderung", Geld(5, { delta: true }), Geld(-5, { delta: true })]),
    section("Tabelle", ["sortierbar", Tabelle(columns, ROWS, { caption: "Firmen", sort: state.sort, onSort: act.sort })],
      ["Zeilenzustände", Tabelle(columns.slice(0, 2), ROWS.slice(0, 1).flatMap((r) => STATES.map(() => r)), { caption: "Je Zustand eine Zeile", wrapClass: "kit-table-all", rowState: (_, i) => STATES[i]!, rowReason: () => "Jetzt nicht möglich" })]),
    section("Tooltip", ["Aufschlüsselung", v("div", { class: "kit-tip-demo" }, mitTooltip(v("button", { type: "button" }, "Legen £30"), tip), " ", v("span", {}, "(Hover oder Tab)"))],
      ["ungültig, Grund", v("div", { class: "kit-tip-demo" }, mitTooltip(v("button", { type: "button", disabled: true }, "Token setzen"), { title: "Jetzt nicht möglich", term: "No free token", reason: "Kein freier Token mehr." }))]),
    section("Dialog", ["Öffnen", v("button", { type: "button", onclick: () => act.dialog(true) }, "Dialog zeigen"), v("span", { class: "muted" }, "liegt nur über dem Hauptbereich, die Rundenleiste bleibt frei")]),
    section("Leiter", ["Schritte", Leiter(stepsAt(["Auktion", "Konzession", "Aktien", "Betrieb"], 2), "Rundenablauf")], ["erster Schritt", Leiter(stepsAt(["Bauen", "Token", "Fahren", "Zahlen"], 0), "Betriebsschritte")]),
    section("Auftrag", ...STATES.map((s): [string, ...VNode[]] => [label(s), order(s)])),
  ];
}

export function kitPage(): HTMLElement {
  const root = document.createElement("div");
  root.className = "kit-page";
  const st: { sort?: Sort; dialog: boolean } = { dialog: false };
  const draw = () => {
    const theme = choiceFromRoot(document.documentElement).theme;
    const dialog = st.dialog
      ? Dialog({ title: "Zug beenden?", body: ["Du kannst danach nicht mehr bauen."], onClose: () => { st.dialog = false; draw(); },
          actions: [v("button", { type: "button", onclick: () => { st.dialog = false; draw(); } }, "Abbrechen"), v("button", { type: "button", class: "kit-main-btn", onclick: () => { st.dialog = false; draw(); } }, "Zug beenden")] })
      : null;
    const stage = v("div", { class: "kit-stage" }, v("div", { class: "kit-roundbar" }, `Rundenleiste (bleibt frei) · Theme ${theme.name}`), v("div", { class: "kit-main" }, "Hauptbereich", dialog));
    const sections = kitSections(theme, st, { sort: (k) => { st.sort = nextSort(st.sort, k); draw(); }, dialog: (o) => { st.dialog = o; draw(); } });
    root.replaceChildren(
      toDom(v("h1", {}, "Bausteine")), toDom(v("p", { class: "muted" }, "Alle Bausteine in allen Zuständen. Theme über das Menü „Look“ unten rechts.")),
      toDom(stage), ...sections.map(toDom));
  };
  draw();
  document.addEventListener("oe:themechange", draw);
  return root;
}
