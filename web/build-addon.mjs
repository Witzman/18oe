// Builds the browser add-on (#614) as an unpacked Manifest V3 extension: Chrome, Edge ("Load unpacked") and
// Firefox 128+ ("Load Temporary Add-on").
//
//   node build-addon.mjs --geometry map.json [--site] [--out dist-addon]
//
// geometry = Oe::MapData.build of upstream's engine, as a file. Without --site it runs on a local 18xx server
// only; --site adds https://18xx.games (the owner decides when, workshop #606).
import { build } from "esbuild";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const LOCAL = ["http://localhost/*", "http://127.0.0.1/*"];
const SITE = "https://18xx.games/*";

/** fonts/fonts.css as data: family, weight, range and the file's bytes. */
function fontFaces() {
  const css = readFileSync(join(root, "fonts", "fonts.css"), "utf8");
  return [...css.matchAll(/@font-face\s*{([^}]*)}/g)].map(([, body]) => {
    const get = (name) => body.match(new RegExp(`${name}:\\s*([^;]+);`))[1].trim();
    const file = body.match(/url\(\/fonts\/([^)]+)\)/)[1];
    return {
      family: get("font-family").replace(/^'|'$/g, ""), weight: get("font-weight"), style: get("font-style"),
      unicodeRange: get("unicode-range"), data: readFileSync(join(root, "fonts", file)).toString("base64"),
    };
  });
}

function virtual(modules) {
  return {
    name: "oe-virtual",
    setup(b) {
      b.onResolve({ filter: /^oe:/ }, (args) => ({ path: args.path, namespace: "oe" }));
      b.onLoad({ filter: /.*/, namespace: "oe" }, (args) => ({ contents: JSON.stringify(modules[args.path]), loader: "json" }));
    },
  };
}

export async function buildAddon({ out, geometry, site = false }) {
  const version = readFileSync(join(root, "..", "VERSION"), "utf8").trim();
  mkdirSync(out, { recursive: true });
  await build({
    entryPoints: [join(root, "addon", "content.ts")],
    bundle: true,
    format: "iife",
    target: "es2022",
    minify: true,
    charset: "utf8",
    outfile: join(out, "content.js"),
    absWorkingDir: root,
    define: { __OE_VERSION__: JSON.stringify(version) },
    plugins: [virtual({ "oe:geometry": JSON.parse(readFileSync(geometry, "utf8")), "oe:fonts": fontFaces() })],
    logLevel: "warning",
  });
  const manifest = {
    manifest_version: 3,
    name: "18OE map (private)",
    version: "0.1.0",
    description: "Shows the 18OE map in its own style on 18xx games. Reads the page, sends nothing.",
    content_scripts: [{ matches: site ? [...LOCAL, SITE] : LOCAL, js: ["content.js"], run_at: "document_start", world: "MAIN" }],
    browser_specific_settings: { gecko: { id: "oe-map@18oe.local", strict_min_version: "128.0" } },
  };
  writeFileSync(join(out, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  return manifest;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const option = (name) => { const i = args.indexOf(`--${name}`); return i < 0 ? null : args[i + 1]; };
  const geometry = option("geometry");
  if (!geometry) {
    console.error("usage: node build-addon.mjs --geometry map.json [--site] [--out dist-addon]");
    process.exit(2);
  }
  const out = option("out") ?? join(root, "dist-addon");
  const manifest = await buildAddon({ out, geometry, site: args.includes("--site") });
  console.log(`${out}: matches ${manifest.content_scripts[0].matches.join(", ")}`);
}
