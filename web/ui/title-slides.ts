// Slides of the title screen (#460): screenshots of the running UI, the scenes of the feedback board (bin/boardshots.json
// of the workshop repo). Files in web/title/, copied to dist by build.mjs. Order: the map first. The pictures show recorded example
// games, not a running game. Interval and fade are theme tokens (motion.titleSlideMs, motion.titleFadeMs).
export interface Slide { scene: string; alt: string /* text.ts key */ }

export const SLIDES: readonly Slide[] = [
  { scene: "s06-gleis", alt: "access.slide_map" },
  { scene: "s13-karte-haefen", alt: "access.slide_ports" },
  { scene: "s02-auktion-los", alt: "access.slide_auction" },
  { scene: "s03-aktienrunde", alt: "access.slide_stock" },
  { scene: "s10-route", alt: "access.slide_run" },
  { scene: "s12-spielende", alt: "access.slide_end" },
];

/** The slide after `i`, wrapping round; an index out of range is taken modulo `n`. */
export function nextSlide(i: number, n: number): number {
  return n <= 1 ? 0 : (((i + 1) % n) + n) % n;
}
