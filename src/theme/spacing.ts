export const spacing = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
} as const;

export const radius = {
  sm: 8,
  md: 12,
  pill: 999,
} as const;

export const typography = {
  title: {fontSize: 28, fontWeight: '700' as const},
  headline: {fontSize: 17, fontWeight: '600' as const},
  body: {fontSize: 15, fontWeight: '600' as const},
  subhead: {fontSize: 13, fontWeight: '400' as const},
  caption: {fontSize: 12, fontWeight: '700' as const},
  /** The hero state word ("Protected" / "Paused"). */
  hero: {fontSize: 40, fontWeight: '800' as const, letterSpacing: -0.8},
  /** Serif wordmark — the one typographic flourish. */
  wordmark: {fontFamily: 'Georgia', fontSize: 17, fontWeight: '600' as const},
  wordmarkLarge: {fontFamily: 'Georgia', fontSize: 34, fontWeight: '600' as const},
};
