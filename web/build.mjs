// Bundles web/main.ts into web/dist/ and copies the static files next to it.
// Only web/dist is ever served by the app (see app.rb), never the sources.
import { build } from "esbuild";
import { copyFileSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

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
