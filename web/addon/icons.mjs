// The extension's icon, drawn at build time (no image file to maintain, no library): a map hex with a track and a
// station in the theme's colours. Stores ask for 128 px with the art in the middle 96 px.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { crc32, deflateSync } from "node:zlib";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const SAMPLES = 4;
const RADIUS = 0.375; // of the picture: 96 of 128 px high

function colors() {
  const { map } = JSON.parse(readFileSync(join(root, "themes", "brett.json"), "utf8"));
  const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  return Object.fromEntries(["tileGreen", "tileEdge", "bed", "sleeper", "rail", "city", "cityEdge"].map((k) => [k, rgb(map[k])]));
}

/** Colour at a point (centre 0/0, y up), or null outside the hex. The hex stands on a corner. */
function paint(c, x, y) {
  const inside = (r) => Math.abs(x) <= (r * Math.sqrt(3)) / 2 && Math.abs(y) <= r - Math.abs(x) / Math.sqrt(3);
  if (!inside(RADIUS)) return null;
  if (!inside(RADIUS - 0.035)) return c.cityEdge;
  const d = Math.hypot(x, y);
  if (d <= 0.105) return c.city;
  if (d <= 0.14) return c.cityEdge;
  // the track runs from one side to the opposite one, at 60 degrees
  const across = Math.abs(x * (Math.sqrt(3) / 2) - y / 2), along = x / 2 + y * (Math.sqrt(3) / 2);
  if (across > 0.085) return c.tileGreen;
  if (Math.abs(across - 0.045) <= 0.014) return c.rail;
  return ((along / 0.075) % 1 + 1) % 1 < 0.4 ? c.sleeper : c.bed;
}

function chunk(type, data) {
  const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
  const out = Buffer.alloc(body.length + 8);
  out.writeUInt32BE(data.length, 0);
  body.copy(out, 4);
  out.writeUInt32BE(crc32(body), body.length + 4);
  return out;
}

/** A square RGBA PNG of the icon. */
export function icon(size) {
  const c = colors();
  const rows = Buffer.alloc(size * (size * 4 + 1)); // each row starts with filter byte 0
  for (let py = 0; py < size; py += 1) {
    for (let px = 0; px < size; px += 1) {
      const sum = [0, 0, 0];
      let hit = 0;
      for (let sy = 0; sy < SAMPLES; sy += 1) {
        for (let sx = 0; sx < SAMPLES; sx += 1) {
          const color = paint(c, (px + (sx + 0.5) / SAMPLES) / size - 0.5, 0.5 - (py + (sy + 0.5) / SAMPLES) / size);
          if (color) { hit += 1; color.forEach((v, i) => { sum[i] += v; }); }
        }
      }
      const at = py * (size * 4 + 1) + 1 + px * 4;
      if (hit) sum.forEach((v, i) => { rows[at + i] = Math.round(v / hit); });
      rows[at + 3] = Math.round((255 * hit) / (SAMPLES * SAMPLES));
    }
  }
  const head = Buffer.alloc(13);
  head.writeUInt32BE(size, 0);
  head.writeUInt32BE(size, 4);
  head.set([8, 6, 0, 0, 0], 8); // 8 bit, RGBA
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", head), chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]);
}
