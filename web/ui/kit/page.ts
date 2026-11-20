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
  { sym: "KK", name: "Imperial and Royal State Railways", color: companyBg(theme, "KK", ["", "KK"]) },
  { sym: "DR", name: "German Imperial Railways", color: companyBg(theme, "DR", ["", "", "", "DR"]) },
  { sym: "SNCB", name: "Belgian State Railways", color: companyBg(theme, "SNCB", ["", "", "", "", "", "SNCB"]) },
];
const PLAYERS = ["Anna", "Ben", "Clara", "Dirk", "Eva", "Finn", "Gita"].map((name, i) => ({ seat: i + 1, name }));
const rowsOf = (c: Corp[]) => [
  { corp: c[0]!, cash: 410, certs: 7 }, { corp: c[1]!, cash: 95, certs: 11 },
  { corp: c[2]!, cash: 1230, certs: 8 }, { corp: c[3]!, cash: -40, certs: 2 },
];
type Row = ReturnType<typeof rowsOf>[number];

const label = (s: State) => ({ normal: "normal", hover: "hover", valid: "valid", selected: "selected", invalid: "invalid", preview: "preview", waiting: "waiting" })[s];
const section = (title: string, ...rows: [string, ...VNode[]][]) =>
  v("section", {}, v("h2", {}, title), v("dl", { class: "kit-grid" }, ...rows.flatMap(([k, ...vs]) => [v("dt", {}, k), v("dd", {}, ...vs)])));

export function kitSections(theme: Theme, state: { sort?: Sort; dialog: boolean }, act: { sort: (k: string) => void; dialog: (open: boolean) => void }): VNode[] {
  const CORPS = corps(theme);
  const ROWS = rowsOf(CORPS);
  const columns = [
    { key: "corp", label: "Corporation", sortBy: (r: Row) => r.corp.sym, cell: (r: Row) => Siegel(r.corp, { theme, size: "s" }) },
    { key: "cash", label: "Cash", align: "right" as const, sortBy: (r: Row) => r.cash, cell: (r: Row) => Geld(r.cash) },
    { key: "certs", label: "Certificates", align: "right" as const, sortBy: (r: Row) => r.certs, cell: (r: Row) => `${r.certs} / 20` },
  ];
  const tip = { title: "Track cost V41", term: "Terrain cost", rows: [{ label: "Terrain", amount: 20 }, { label: "Zone discount", amount: -5 }, { label: "Ferry £5 × 3", amount: 15 }], total: { label: "Total", amount: 30 }, source: "Rulebook §11.3" };
  const order = (s: State) => Auftrag({
    sentence: "PLM: buy 10 % from the Open Market for £165.", state: s,
    changes: [{ label: "Cash", before: Geld(260), after: Geld(95) }, { label: "Certificates", before: "11", after: "12 of 20" }],
    reason: s === "invalid" ? "Not enough cash (£165 needed, £95 available)." : undefined,
  });
  return [
    section("Seal", ["All 36 (minors, regionals)", ...Object.keys(theme.companies).map((sym) => Siegel({ sym, color: theme.companies[sym]!.bg }, { theme }))], ...STATES.map((s): [string, ...VNode[]] => [label(s), ...CORPS.map((c) => Siegel(c, { theme, state: s })), Siegel(CORPS[0]!, { theme, state: s, size: "l" })])),
    section("Pennant", ...STATES.map((s): [string, ...VNode[]] => [label(s), ...PLAYERS.slice(0, 3).map((p) => Wimpel(p, { theme, state: s }))]),
      ["all 7 colours", ...PLAYERS.map((p) => Wimpel(p, { theme }))]),
    section("Money", ["Amounts", Geld(0), Geld(5), Geld(1250), Geld(-40)], ["Change", Geld(5, { delta: true }), Geld(-5, { delta: true })]),
    section("Table", ["sortable", Tabelle(columns, ROWS, { caption: "Corporations", sort: state.sort, onSort: act.sort })],
      ["Row states", Tabelle(columns.slice(0, 2), ROWS.slice(0, 1).flatMap((r) => STATES.map(() => r)), { caption: "One row per state", wrapClass: "kit-table-all", rowState: (_, i) => STATES[i]!, rowReason: () => "Not possible now" })]),
    section("Tooltip", ["Breakdown", v("div", { class: "kit-tip-demo" }, mitTooltip(v("button", { type: "button" }, "Lay £30"), tip), " ", v("span", {}, "(hover or Tab)"))],
      ["invalid, reason", v("div", { class: "kit-tip-demo" }, mitTooltip(v("button", { type: "button", disabled: true }, "Place token"), { title: "Not possible now", term: "No free token", reason: "No free token left." }))]),
    section("Dialog", ["Open", v("button", { type: "button", onclick: () => act.dialog(true) }, "Show dialog"), v("span", { class: "muted" }, "covers only the main area, the round bar stays free")]),
    section("Ladder", ["Steps", Leiter(stepsAt(["Auction", "Concession", "Stock", "Operating"], 2), "Round sequence")], ["first step", Leiter(stepsAt(["Track", "Token", "Run", "Dividend"], 0), "Operating steps")]),
    section("Order", ...STATES.map((s): [string, ...VNode[]] => [label(s), order(s)])),
  ];
}

export function kitPage(): HTMLElement {
  const root = document.createElement("div");
  root.className = "kit-page";
  const st: { sort?: Sort; dialog: boolean } = { dialog: false };
  const draw = () => {
    const theme = choiceFromRoot(document.documentElement).theme;
    const dialog = st.dialog
      ? Dialog({ title: "End the turn?", body: ["You cannot lay track afterwards."], onClose: () => { st.dialog = false; draw(); },
          actions: [v("button", { type: "button", onclick: () => { st.dialog = false; draw(); } }, "Cancel"), v("button", { type: "button", class: "kit-main-btn", onclick: () => { st.dialog = false; draw(); } }, "End the turn")] })
      : null;
    const stage = v("div", { class: "kit-stage" }, v("div", { class: "kit-roundbar" }, `Round bar (stays free) · theme ${theme.name}`), v("div", { class: "kit-main" }, "Main area", dialog));
    const sections = kitSections(theme, st, { sort: (k) => { st.sort = nextSort(st.sort, k); draw(); }, dialog: (o) => { st.dialog = o; draw(); } });
    root.replaceChildren(
      toDom(v("h1", {}, "Components")), toDom(v("p", { class: "muted" }, "All components in all states. Change the theme in the \"Look\" menu at the bottom right.")),
      toDom(stage), ...sections.map(toDom));
  };
  draw();
  document.addEventListener("oe:themechange", draw);
  return root;
}
