// Packages of the browser add-on for passing it on or for a store: the extension as a zip, and the sources it is
// built from with build instructions (Mozilla asks for them because the code is minified). Publishes nothing.
//
//   node pack-addon.mjs --geometry map.json [--site] [--release 1.2.3] [--out dist-addon-release]
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { zip } from "./addon/zip.mjs";
import { buildWithInputs } from "./build-addon.mjs";

const root = dirname(fileURLToPath(import.meta.url));

// what the build reads besides the files in the bundle, and what a reader of the sources wants beside them
const ALSO = [
  "build-addon.mjs", "pack-addon.mjs", "addon/icons.mjs", "addon/zip.mjs", "addon/virtual.d.ts", "types.ts",
  "package.json", "package-lock.json", "tsconfig.json", "themes/brett.json", "theme.css", "ui/kit/kit.css", "ui/panels/stock.css",
  "fonts/fonts.css", "fonts/SOURCES.md",
];

const instructions = (command) => `# Building the extension from these sources

Needs Node.js 22.2 or later (built with ${process.version}) and npm; no other tool.

    cd web
    npm ci
    ${command}

The extension is then in web/dist-addon/. content.js is web/addon/content.ts and what it imports, bundled and
minified (not obfuscated) by esbuild. Libraries come unchanged from the npm registry (web/package-lock.json).
geometry.json is data: the fixed 18OE map (hexes, tiles, names), generated from the 18OE game files of 18xx.games.
`;

/** Every file under `dir`, as paths relative to it. */
const walk = (dir, prefix = "") => readdirSync(join(dir, prefix), { withFileTypes: true }).flatMap((e) =>
  (e.isDirectory() ? walk(dir, `${prefix}${e.name}/`) : [`${prefix}${e.name}`]));

export async function packAddon({ out, geometry, site = false, release }) {
  const built = join(out, "extension");
  const { manifest, inputs } = await buildWithInputs({ out: built, geometry, site, release });
  const entry = (name, path) => ({ name, data: readFileSync(path) });
  const base = join(out, `18oe-visual-map-${manifest.version}`);

  const extension = `${base}.zip`;
  writeFileSync(extension, zip(walk(built).sort().map((f) => entry(f, join(built, f)))));

  const fonts = walk(join(root, "fonts")).filter((f) => f.endsWith(".woff2") || f.startsWith("LICENSES/")).map((f) => `fonts/${f}`);
  const own = inputs.filter((f) => !f.startsWith("oe:") && !f.includes("node_modules/"));
  const files = [...new Set([...own, ...ALSO, ...fonts])].sort().map((f) => entry(`web/${f}`, join(root, f)));
  const command = `node build-addon.mjs --geometry ../geometry.json${site ? " --site" : ""} --release ${manifest.version}`;
  const source = `${base}-source.zip`;
  writeFileSync(source, zip([
    { name: "BUILD.md", data: Buffer.from(instructions(command)) },
    entry("VERSION", join(root, "..", "VERSION")),
    entry("geometry.json", geometry),
    ...files,
  ]));
  return { extension, source };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const option = (name) => { const i = args.indexOf(`--${name}`); return i < 0 ? null : args[i + 1]; };
  const geometry = option("geometry");
  if (!geometry) {
    console.error("usage: node pack-addon.mjs --geometry map.json [--site] [--release 1.2.3] [--out dist-addon-release]");
    process.exit(2);
  }
  const out = option("out") ?? join(root, "dist-addon-release");
  const made = await packAddon({ out, geometry, site: args.includes("--site"), release: option("release") ?? undefined });
  console.log(`${made.extension}\n${made.source}`);
}
