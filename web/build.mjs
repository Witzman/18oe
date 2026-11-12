// Bundles web/main.ts into web/dist/ and copies the static files next to it.
// Only web/dist is ever served by the app (see app.rb), never the sources.
import { build } from "esbuild";
import { copyFileSync, cpSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { themesCss } from "./themes/css.ts";
import { DEFAULT_THEME_ID, themes } from "./themes/index.ts";

const root = dirname(fileURLToPath(import.meta.url));
const dist = join(root, "dist");
rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });

await build({
  entryPoints: [join(root, "main.ts")],
  bundle: true,
  format: "esm",
  target: "es2022",
  sourcemap: true,
  minify: process.env.NODE_ENV === "production",
  outfile: join(dist, "main.js"),
  logLevel: "info",
});
for (const file of ["index.html", "theme.css"]) copyFileSync(join(root, file), join(dist, file));
// Theme fonts: @font-face (fonts.css) and the woff2 files, served from our own origin (#98).
cpSync(join(root, "fonts"), join(dist, "fonts"), { recursive: true });
copyFileSync(join(root, "fonts", "fonts.css"), join(dist, "fonts.css"));
copyFileSync(join(root, "ui", "kit", "kit.css"), join(dist, "kit.css"));
// Theme tokens as CSS variables, one rule per theme (#95).
writeFileSync(join(dist, "themes.css"), themesCss(themes, DEFAULT_THEME_ID));
