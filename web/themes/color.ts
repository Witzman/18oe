// Colour arithmetic on "#rrggbb" strings: numeric form for PixiJS, WCAG contrast for the specs.

export function hexToNumber(hex: string): number {
  if (!/^#[0-9a-f]{6}$/i.test(hex)) throw new Error(`Not a #rrggbb colour: ${hex}`);
  return Number.parseInt(hex.slice(1), 16);
}

function channel(v: number): number {
  const s = v / 255;
  return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
}

/** WCAG 2 relative luminance, 0 (black) to 1 (white). */
export function luminance(hex: string): number {
  const n = hexToNumber(hex);
  return 0.2126 * channel((n >> 16) & 255) + 0.7152 * channel((n >> 8) & 255) + 0.0722 * channel(n & 255);
}

/** WCAG 2 contrast ratio, 1 to 21. */
export function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x) as [number, number];
  return (hi + 0.05) / (lo + 0.05);
}

/** CIELAB of "#rrggbb" (D65), for colour distances. */
function lab(hex: string): [number, number, number] {
  const n = hexToNumber(hex);
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map(channel) as [number, number, number];
  const f = (t: number) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
  const x = f((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047);
  const y = f(0.2126 * r + 0.7152 * g + 0.0722 * b);
  const z = f((0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883);
  return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
}

/** CIE76 colour difference; about 2.3 is a just-noticeable difference, 5 to 10 is distinguishable side by side. */
export function deltaE(a: string, b: string): number {
  const [p, q] = [lab(a), lab(b)];
  return Math.hypot(p[0] - q[0], p[1] - q[1], p[2] - q[2]);
}
