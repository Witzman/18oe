// Builds the map as a bundle of its own (#613), apart from the web UI's build (build.mjs):
//   oe-map.js   global `OeMap` (render/standalone.ts), for a browser add-on
//   map.html    one self-contained test page: bundle, fonts, map data and a board inside, openable from disk,
//               under a content security policy without eval and without any network access
//
//   node build-standalone.mjs --geometry map.json --board board.json [--out dist-standalone]
//
// geometry = GET /map (Oe::MapData.build) as a file; board = render/board.ts.
import { build } from "esbuild";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));

const POLICY = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; img-src data: blob:";

/** fonts/fonts.css with the files inside. */
function inlineFonts() {
  return readFileSync(join(root, "fonts", "fonts.css"), "utf8").replace(/url\(\/fonts\/([^)]+)\)/g, (_, file) =>
    `url(data:font/woff2;base64,${readFileSync(join(root, "fonts", file)).toString("base64")})`);
}

// Safe inside <script>: no "</script" can end the element early.
const inScript = (text) => text.replace(/<\/script/gi, "<\\/script");
const data = (value) => JSON.stringify(value).replace(/</g, "\\u003c");

function page(bundle, geometry, board) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="${POLICY}">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>18OE map</title>
<style>
${inlineFonts()}
html, body { margin: 0; height: 100%; overflow: hidden; }
#map { width: 100vw; height: 100vh; }
#status { position: fixed; left: 8px; bottom: 8px; padding: 4px 8px; font: 13px/1.4 monospace; background: Canvas; color: CanvasText; }
#status:empty { display: none; }
</style>
</head>
<body>
<div id="map"></div>
<div id="status">loading the map</div>
<script>${inScript(bundle)}</script>
<script>
(async () => {
  const status = document.getElementById("status");
  try {
    const started = performance.now();
    window.oeMap = await OeMap.mount(document.getElementById("map"), ${data(geometry)}, ${data(board)});
    await window.oeMap.view.rendered();
    status.textContent = "";
    document.body.dataset.ready = String(Math.round(performance.now() - started));
  } catch (error) {
    status.textContent = "map failed: " + (error && error.message || error);
    document.body.dataset.failed = "1";
  }
})();
</script>
</body>
</html>
`;
}

export async function buildStandalone({ out, geometry, board }) {
  const version = readFileSync(join(root, "..", "VERSION"), "utf8").trim();
  const result = await build({
    entryPoints: [join(root, "render", "standalone.ts")],
    bundle: true,
    format: "iife",
    globalName: "OeMap",
    target: "es2022",
    minify: true,
    write: false,
    metafile: true,
    absWorkingDir: root,
    define: { __OE_VERSION__: JSON.stringify(version) },
    logLevel: "warning",
  });
  const bundle = result.outputFiles[0].text;
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, "oe-map.js"), bundle);
  const read = (file) => JSON.parse(readFileSync(file, "utf8"));
  writeFileSync(join(out, "map.html"), page(bundle, read(geometry), read(board)));
  const [outputInfo] = Object.values(result.metafile.outputs);
  return { inputs: Object.keys(result.metafile.inputs), bytes: outputInfo.bytes, sizes: outputInfo.inputs };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const option = (name) => { const i = args.indexOf(`--${name}`); return i < 0 ? null : args[i + 1]; };
  const geometry = option("geometry"), board = option("board");
  if (!geometry || !board) {
    console.error("usage: node build-standalone.mjs --geometry map.json --board board.json [--out dist-standalone]");
    process.exit(2);
  }
  const out = option("out") ?? join(root, "dist-standalone");
  const { bytes, sizes } = await buildStandalone({ out, geometry, board });
  const groups = {};
  for (const [file, info] of Object.entries(sizes)) {
    const group = file.startsWith("node_modules/") ? file.split("/")[1] : file.split("/")[0];
    groups[group] = (groups[group] ?? 0) + info.bytesInOutput;
  }
  console.log(`${out}: oe-map.js ${bytes} bytes`, groups);
}
