// Drift guard (#365 slice 11): the recorded view states in test/fixtures/games must agree with the key sets in
// view-keys.json (the contract spec/web_spec.rb checks against lib/oe/view.rb and web/types.ts mirrors).
//  1. No fixture carries a key the contract no longer has (renamed/removed keys left behind in a recording).
//  2. Every contract key appears in at least one fixture (a new key nobody recorded yet), except the keys in
//     NOT_YET_RECORDED. That list must shrink: the test fails when a listed key is recorded after all.
// Fixtures are trimmed on purpose (companies, tiles ...), so a single fixture need not carry every key.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";

const KEYS = JSON.parse(readFileSync(new URL("../view-keys.json", import.meta.url), "utf8")) as Record<string, string[]>;
const DIR = new URL("./fixtures/games/", import.meta.url);

// "<group>.<key>": contract keys that no recorded fixture shows yet. Re-record a fixture, then delete the entry.
// context.trade: the open trade offer (§10.4, #202), only while a seller answers one; no recording has one yet.
const NOT_YET_RECORDED = ["meta.game_end", "prompt.double_head", "prompt.double_head_note", "context.trade"];

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const arr = (v: unknown): Obj[] => (Array.isArray(v) ? v.filter(isObj) : []);

// The (group, object) pairs of one view state, mirroring spec/web_spec.rb "view model contract".
function parts(state: Obj): [string, Obj][] {
  const meta = isObj(state.meta) ? state.meta : {};
  const prompt = isObj(state.prompt) ? state.prompt : null;
  const auction = isObj(state.auction) ? state.auction : null;
  const out: [string, unknown][] = [
    ["state", state], ["meta", meta], ["round", meta.round], ["phase", meta.phase],
    ["prompt", prompt], ["context", prompt?.context], ["depot", state.depot], ["market", state.market], ["auction", auction],
  ];
  for (const p of arr(state.players)) out.push(["player", p]);
  for (const c of arr(state.corporations)) out.push(["corporation", c]);
  for (const c of arr(auction?.cards)) out.push(["auction_card", c]);
  return out.filter((e): e is [string, Obj] => isObj(e[1]));
}

const files = readdirSync(DIR).filter((f) => f.endsWith(".json")).sort();
const seen = new Set<string>();
const stale: string[] = [];
for (const f of files) {
  const game = JSON.parse(readFileSync(new URL(f, DIR), "utf8")) as Obj;
  for (const [group, obj] of parts(game.state as Obj)) {
    const allowed = KEYS[group];
    assert.ok(allowed, `view-keys.json has no group "${group}"`);
    for (const k of Object.keys(obj)) {
      seen.add(`${group}.${k}`);
      if (!allowed.includes(k)) stale.push(`${f}: ${group}.${k}`);
    }
  }
}

test("fixtures exist", () => assert.ok(files.length >= 20, `only ${files.length} fixtures`));

test("no fixture carries a key that view-keys.json does not list", () => {
  assert.deepEqual(stale, [], "keys in recordings but not in view-keys.json (re-record the fixture or fix the contract)");
});

test("every view-keys.json key appears in some fixture", () => {
  const missing = Object.entries(KEYS).flatMap(([g, ks]) => ks.map((k) => `${g}.${k}`))
    .filter((id) => !seen.has(id) && !NOT_YET_RECORDED.includes(id));
  assert.deepEqual(missing, [], "contract keys no fixture records (re-record one, or list it in NOT_YET_RECORDED)");
  const recorded = NOT_YET_RECORDED.filter((id) => seen.has(id));
  assert.deepEqual(recorded, [], "now recorded: remove from NOT_YET_RECORDED");
});
