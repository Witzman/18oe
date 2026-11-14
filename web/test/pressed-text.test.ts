// #288: the global button[aria-pressed="true"] rule (theme.css) sets light text on a dark ink background. A panel rule that resets
// the background of a pressed button to the panel colour must also reset the text to the ink colour, or the text is light on light.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";

const dir = new URL("../ui/panels/", import.meta.url);

test("pressed buttons that reset the background to the panel colour also set the ink colour", () => {
  let seen = 0;
  for (const f of readdirSync(dir).filter((n) => n.endsWith(".css"))) {
    const css = readFileSync(new URL(f, dir), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
    for (const m of css.matchAll(/([^{}]*aria-pressed="true"[^{}]*)\{([^}]*)\}/g)) {
      const body = m[2]!;
      if (!/background:\s*var\(--ui-panel\)/.test(body)) continue;
      seen++;
      assert.match(body, /(^|[;\s])color:\s*var\(--ui-ink\)/, `${f}: ${m[1]!.trim()} sets a panel background without var(--ui-ink) text`);
    }
  }
  assert.ok(seen >= 5, `expected the rules of track, train, operating and concession, saw ${seen}`);
});
