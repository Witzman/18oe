// Slides of the title screen (#460): screenshots of the running UI, the scenes of the feedback board (bin/boardshots.json
// of the product). Files in web/title/, copied to dist by build.mjs. Order: the map first. The pictures show recorded example
// games, not a running game. Interval and fade are theme tokens (motion.titleSlideMs, motion.titleFadeMs).
export interface Slide { scene: string; alt: string }

export const SLIDES: readonly Slide[] = [
  { scene: "s06-gleis", alt: "Die Karte mit Gleisen, Häfen und Grenzen" },
  { scene: "s13-karte-haefen", alt: "Ausschnitt der Karte mit Häfen und Ortsnamen" },
  { scene: "s02-auktion-los", alt: "Die Auktion mit einem gewählten Los" },
  { scene: "s03-aktienrunde", alt: "Die Aktienrunde mit dem Markt" },
  { scene: "s10-route", alt: "Eine Fahrt im Betrieb" },
  { scene: "s12-spielende", alt: "Das Spielende" },
];

/** The slide after `i`, wrapping round; an index out of range is taken modulo `n`. */
export function nextSlide(i: number, n: number): number {
  return n <= 1 ? 0 : (((i + 1) % n) + n) % n;
}
