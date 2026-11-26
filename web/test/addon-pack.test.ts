// Preparing the browser add-on for publishing: what the stores ask for, the packages and their sources.
import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { inflateRawSync, inflateSync } from "node:zlib";

import { icon } from "../addon/icons.mjs";
import { zip } from "../addon/zip.mjs";
import { buildAddon } from "../build-addon.mjs";
import { packAddon } from "../pack-addon.mjs";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const geometry = join(web, "test", "fixtures", "map-geometry.json");
const temp = () => mkdtempSync(join(tmpdir(), "oe-pack-"));

/** The entries of a zip file, read through its central directory. */
function unzip(data: Buffer): Map<string, Buffer> {
  const end = data.length - 22;
  assert.equal(data.readUInt32LE(end), 0x06054b50, "end of central directory");
  const out = new Map<string, Buffer>();
  let at = data.readUInt32LE(end + 16);
  for (let i = 0; i < data.readUInt16LE(end + 10); i += 1) {
    assert.equal(data.readUInt32LE(at), 0x02014b50, "central entry");
    const size = data.readUInt32LE(at + 20), nameLength = data.readUInt16LE(at + 28), local = data.readUInt32LE(at + 42);
    const name = data.toString("utf8", at + 46, at + 46 + nameLength);
    const start = local + 30 + data.readUInt16LE(local + 26) + data.readUInt16LE(local + 28);
    out.set(name, inflateRawSync(data.subarray(start, start + size)));
    at += 46 + nameLength + data.readUInt16LE(at + 30) + data.readUInt16LE(at + 32);
  }
  return out;
}

test("a zip holds its files byte for byte and is the same on every run", () => {
  const files = [{ name: "a.txt", data: Buffer.from("hello hello hello") }, { name: "dir/b.bin", data: Buffer.from([0, 1, 2, 255]) }];
  const made = zip(files);
  assert.deepEqual([...unzip(made)], files.map((f) => [f.name, f.data]));
  assert.deepEqual(zip(files), made);
});

test("the icons are square PNGs with a transparent margin", () => {
  for (const size of [16, 32, 48, 128]) {
    const png = icon(size);
    assert.equal(png.toString("latin1", 1, 4), "PNG");
    assert.deepEqual([png.readUInt32BE(16), png.readUInt32BE(20), png[24], png[25]], [size, size, 8, 6], "8 bit RGBA");
    const pixels = inflateSync(png.subarray(41, 41 + png.readUInt32BE(33)));
    const alpha = (x: number, y: number) => pixels[y * (size * 4 + 1) + 1 + x * 4 + 3];
    assert.equal(alpha(0, 0), 0, "corner");
    assert.equal(alpha(size >> 1, size >> 1), 255, "centre");
  }
});

test("the manifest has what the stores ask for", async () => {
  const out = temp();
  await buildAddon({ out, geometry });
  const manifest = JSON.parse(readFileSync(join(out, "manifest.json"), "utf8"));
  assert.equal(manifest.name, "18OE Visual Map");
  assert.ok(manifest.description.length <= 132, "Chrome's limit");
  assert.match(manifest.version, /^\d+(\.\d+){0,3}$/);
  assert.deepEqual(Object.keys(manifest.icons), ["16", "32", "48", "128"]);
  for (const file of Object.values(manifest.icons)) assert.ok(readFileSync(join(out, file as string)).length > 50);
  // Firefox: new extensions must say what they collect; the key needs Firefox 140
  assert.deepEqual(manifest.browser_specific_settings.gecko.data_collection_permissions, { required: ["none"] });
  assert.equal(manifest.browser_specific_settings.gecko.strict_min_version, "140.0");

  await buildAddon({ out, geometry, release: "1.2.3" });
  assert.equal(JSON.parse(readFileSync(join(out, "manifest.json"), "utf8")).version, "1.2.3");
  await assert.rejects(buildAddon({ out, geometry, release: "1.2.3-dev" }), /version/);
});

test("the licenses of every bundled library and font travel with the extension", async () => {
  const out = temp();
  await buildAddon({ out, geometry });
  const text = readFileSync(join(out, "THIRD_PARTY_LICENSES.txt"), "utf8");
  for (const name of ["pixi.js", "eventemitter3", "colord", "earcut", "ismobilejs", "parse-svg-path", "tiny-lru"]) {
    assert.match(text, new RegExp(`^== ${name.replace(".", "\\.")} \\d`, "m"), name);
  }
  for (const font of ["barlow", "barlow-condensed", "old-standard-tt", "source-serif-4"]) assert.match(text, new RegExp(`^== font ${font} `, "m"), font);
  assert.match(text, /SIL OPEN FONT LICENSE/);
});

test("packing writes the extension zip and the sources it is built from", async () => {
  const out = temp();
  const made = await packAddon({ out, geometry, site: true, release: "0.2.0" });
  const extension = unzip(readFileSync(made.extension));
  assert.match(made.extension, /18oe-visual-map-0\.2\.0\.zip$/);
  assert.deepEqual([...extension.keys()].sort(), ["THIRD_PARTY_LICENSES.txt", "content.js", "icons/128.png", "icons/16.png", "icons/32.png", "icons/48.png", "manifest.json"]);
  assert.ok(JSON.parse(String(extension.get("manifest.json"))).content_scripts[0].matches.includes("https://18xx.games/*"));
  const source = unzip(readFileSync(made.source));
  for (const name of ["BUILD.md", "VERSION", "geometry.json", "web/package.json", "web/package-lock.json", "web/build-addon.mjs",
    "web/addon/content.ts", "web/addon/icons.mjs", "web/render/map.ts", "web/theme.css", "web/fonts/fonts.css", "web/types.ts"]) {
    assert.ok(source.has(name), name);
  }
  assert.ok([...source.keys()].some((n) => n.endsWith(".woff2")), "font files");
  assert.ok(![...source.keys()].some((n) => n.includes("node_modules")), "libraries come from the registry");
  assert.match(String(source.get("BUILD.md")), /node build-addon\.mjs --geometry \.\.\/geometry\.json --site --release 0\.2\.0/);

  // what a reviewer does: unpack, take the libraries from the registry (here: ours), run the command
  const copy = temp();
  for (const [name, data] of source) {
    mkdirSync(dirname(join(copy, name)), { recursive: true });
    writeFileSync(join(copy, name), data);
  }
  symlinkSync(join(web, "node_modules"), join(copy, "web", "node_modules"), "dir");
  execFileSync(process.execPath, ["build-addon.mjs", "--geometry", "../geometry.json", "--site", "--release", "0.2.0"], { cwd: join(copy, "web") });
  for (const file of ["content.js", "manifest.json", "THIRD_PARTY_LICENSES.txt", "icons/128.png"]) {
    assert.ok(readFileSync(join(copy, "web", "dist-addon", file)).equals(extension.get(file)!), `${file} from the sources`);
  }
});
