// Smoke test for bin/shot (#42): static page in, PNG of the requested size out. Skipped without a browser.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const browser = process.env.OE_BROWSER ?? ["/usr/bin/chromium-headless-shell", "/usr/bin/chromium"].find((p) => existsSync(p));
const shot = new URL("../../bin/shot.mjs", import.meta.url).pathname;

test("bin/shot renders a static page to a PNG of the requested size", { skip: browser ? false : "no headless browser installed" }, () => {
  const dir = mkdtempSync(join(tmpdir(), "oe-shot-test-"));
  try {
    const page = join(dir, "page.html");
    const out = join(dir, "out.png");
    writeFileSync(page, `<!doctype html><body style="margin:0;background:#c33"><p id="x">Hallo</p></body>`);
    const r = spawnSync(process.execPath, [shot, page, out, "--width", "320", "--height", "200", "--wait-for", "#x"], { encoding: "utf8", timeout: 60000 });
    assert.equal(r.status, 0, r.stderr);
    const png = readFileSync(out);
    assert.ok(png.length > 100, "file not empty");
    assert.equal(png.subarray(1, 4).toString(), "PNG");
    assert.equal(png.readUInt32BE(16), 320);
    assert.equal(png.readUInt32BE(20), 200);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
