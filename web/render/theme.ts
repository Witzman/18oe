// Colour tokens, same values as theme.css (frontend-plan.md). Numeric form for PixiJS.
export const theme = {
  parchment: 0xe8dcc3,
  parchmentDark: 0xd4c4a0,
  ink: 0x3a2f1f,
  inkFaint: 0x6b5d47,
  accentRail: 0x8b3a2f,
  accentSea: 0x5b7a8c,
  accentGold: 0xb8923f,
} as const;

export const cssVars: Record<keyof typeof theme, string> = {
  parchment: "--parchment",
  parchmentDark: "--parchment-dark",
  ink: "--ink",
  inkFaint: "--ink-faint",
  accentRail: "--accent-rail",
  accentSea: "--accent-sea",
  accentGold: "--accent-gold",
};
