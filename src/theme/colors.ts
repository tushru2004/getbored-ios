import {ColorValue} from 'react-native';

/**
 * "Still Water" palette. Warm paper ground with a single pine accent; green
 * exists only as the protected state, amber only as the attention state.
 * Deliberately NOT the stock iOS palette — no #007AFF, no systemGroupedGray.
 *
 * All values are plain hex so `withAlpha` and string-typed consumers work.
 * Dark mode is a planned follow-up (DynamicColorIOS pass); until then the
 * app renders the light identity in both appearances.
 */
export const colors = {
  background: '#F6F4EF',
  surface: '#FBFAF6',
  separator: '#E6E2D7',
  label: '#13291F',
  labelSecondary: '#6B7267',

  /** Protected-state green (also the closed rings). */
  success: '#2E7D5B',
  /** Attention amber (paused filter, account warnings). */
  warning: '#B7791F',
  danger: '#A63A2E',
  /** The one brand accent: pine. Buttons, links, the welcome mark. */
  info: '#1E5C48',
  neutral: '#A5A294',
} as const;

export type ColorToken = keyof typeof colors;

export const tint = (token: ColorToken): ColorValue => colors[token];

export const withAlpha = (hex: string, alpha: number): string => {
  const clamped = Math.max(0, Math.min(1, alpha));
  const byte = Math.round(clamped * 255)
    .toString(16)
    .padStart(2, '0');
  return `${hex}${byte}`;
};
