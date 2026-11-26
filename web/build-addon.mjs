// Builds the browser add-on (#614) as an unpacked Manifest V3 extension: Chrome, Edge ("Load unpacked") and
// Firefox 140+ ("Load Temporary Add-on"). Packages for the stores: pack-addon.mjs.
//
//   node build-addon.mjs [--site] [--release 1.2.3] [--out dist-addon]
//
// Without --site it runs on a local 18xx server only; --site adds https://18xx.games (the owner decides when,
// workshop #606). The build holds no map data: the add-on reads the map from the page (addon/geometry.ts, #626).
import { build } from "esbuild";
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { icon } from "./addon/icons.mjs";

const root = dirname(fileURLToPath(import.meta.url));
const LOCAL = ["http://localhost/*", "http://127.0.0.1/*"];
const SITE = "https://18xx.games/*";
const SIZES = [16, 32, 48, 128];
// stores: one to four numbers without leading zeros
const STORE_VERSION = /^(0|[1-9]\d{0,4})(\.(0|[1-9]\d{0,4})){0,3}$/;

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

/** A theme file without its table of 18OE company colours: the add-on takes the colours from the page. */
export const withoutGameData = (theme) => JSON.stringify({ ...JSON.parse(theme), companies: {} }, null, 2) + "\n";

const themes = {
  name: "oe-themes",
  setup(b) {
    b.onLoad({ filter: /[\\/]themes[\\/][^\\/]+\.json$/ }, (args) => ({ contents: withoutGameData(readFileSync(args.path, "utf8")), loader: "json" }));
  },
};

/** Name, version and license text of every library in the bundle, and the fonts' licenses. */
function licenses(inputs) {
  const packages = new Map();
  for (const input of inputs) {
    const found = input.match(/^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//);
    if (found) packages.set(found[1].split("node_modules/").pop(), join(root, found[1]));
  }
  const libraries = [...packages].sort(([a], [b]) => (a < b ? -1 : 1)).map(([name, dir]) => {
    const file = readdirSync(dir).find((f) => /^(licen[sc]e|copying)/i.test(f));
    if (!file) throw new Error(`no license file in ${name}`);
    const { version } = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
    return `== ${name} ${version}\n\n${readFileSync(join(dir, file), "utf8").trim()}\n`;
  });
  const dir = join(root, "fonts", "LICENSES");
  const fonts = readdirSync(dir).sort().map((file) =>
    `== font ${file.replace(/-OFL\.txt$/, "")} (SIL Open Font License 1.1)\n\n${readFileSync(join(dir, file), "utf8").trim()}\n`);
  return ["Third-party software and fonts contained in this extension.\n", ...libraries, ...fonts].join("\n");
}

/** The build with the list of files it read (relative to web/), also those it shook out of the bundle. */
export async function buildWithInputs({ out, site = false, release }) {
  const version = readFileSync(join(root, "..", "VERSION"), "utf8").trim();
  const numbered = release ?? version.match(/^[\d.]*\d/)?.[0] ?? "";
  if (!STORE_VERSION.test(numbered) || /^[0.]+$/.test(numbered)) throw new Error(`not a store version: "${numbered}"`);
  mkdirSync(join(out, "icons"), { recursive: true });
  const result = await build({
    entryPoints: [join(root, "addon", "content.ts")],
    bundle: true,
    format: "iife",
    target: "es2022",
    minify: true,
    charset: "utf8",
    outfile: join(out, "content.js"),
    metafile: true,
    absWorkingDir: root,
    define: { __OE_VERSION__: JSON.stringify(version) },
    plugins: [themes, virtual({
      "oe:fonts": fontFaces(),
      // the web UI's styles of the price board (#619), for its shadow tree
      "oe:market-css": ["theme.css", "ui/kit/kit.css", "ui/panels/stock.css"].map((f) => readFileSync(join(root, f), "utf8")).join("\n"),
    })],
    logLevel: "warning",
  });
  const manifest = {
    manifest_version: 3,
    name: "18OE Visual Map",
    version: numbered,
    description: "Restyles the 18OE map and stock market on 18xx.games. Visual only: reads the page, sends nothing. Unofficial.",
    icons: Object.fromEntries(SIZES.map((size) => [size, `icons/${size}.png`])),
    content_scripts: [{ matches: site ? [...LOCAL, SITE] : LOCAL, js: ["content.js"], run_at: "document_start", world: "MAIN" }],
    // Firefox asks new extensions to declare what they collect; it knows the key from version 140
    browser_specific_settings: {
      gecko: { id: "oe-map@18oe.local", strict_min_version: "140.0", data_collection_permissions: { required: ["none"] } },
    },
  };
  const bundled = Object.keys(Object.values(result.metafile.outputs)[0].inputs);
  const inputs = Object.keys(result.metafile.inputs);
  writeFileSync(join(out, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  for (const size of SIZES) writeFileSync(join(out, "icons", `${size}.png`), icon(size));
  writeFileSync(join(out, "THIRD_PARTY_LICENSES.txt"), licenses(bundled));
  return { manifest, inputs };
}

export const buildAddon = async (options) => (await buildWithInputs(options)).manifest;

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const option = (name) => { const i = args.indexOf(`--${name}`); return i < 0 ? null : args[i + 1]; };
  const out = option("out") ?? join(root, "dist-addon");
  const manifest = await buildAddon({ out, site: args.includes("--site"), release: option("release") ?? undefined });
  console.log(`${out}: matches ${manifest.content_scripts[0].matches.join(", ")}`);
}
