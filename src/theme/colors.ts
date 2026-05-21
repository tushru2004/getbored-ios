import {PlatformColor, ColorValue} from 'react-native';

export const colors = {
  background: PlatformColor('systemGroupedBackground'),
  surface: PlatformColor('secondarySystemGroupedBackground'),
  separator: PlatformColor('separator'),
  label: PlatformColor('label'),
  labelSecondary: PlatformColor('secondaryLabel'),

  success: '#34C759',
  warning: '#FF9500',
  danger: '#FF3B30',
  info: '#007AFF',
  neutral: '#8E8E93',
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
