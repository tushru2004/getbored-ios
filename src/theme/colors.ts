import {ColorValue} from 'react-native';

/**
 * "Still Water" palette. Warm paper ground, pine ink, and restrained
 * yellow/coral accents shared with the desktop admin identity.
 * Deliberately NOT the stock iOS palette — no #007AFF, no systemGroupedGray.
 *
 * All values are plain hex so `withAlpha` and string-typed consumers work.
 * Dark mode is a planned follow-up (DynamicColorIOS pass); until then the
 * app renders the light identity in both appearances.
 */
export const colors = {
		/** Shared with the admin app's warm paper / pine-ink identity. */
		background: '#F1ECDF',
		surface: '#FFFDF6',
		separator: '#A8AFA1',
		label: '#17342F',
		labelSecondary: '#52655E',

		/** Protected state settles into the same pine ink as the admin. */
		success: '#17342F',
		/** Coral is reserved for large attention states, rings, and rules. */
		warning: '#E85C3F',
		danger: '#A63A2E',
		info: '#17342F',
		neutral: '#6F776F',

		/** Desktop-family accents. */
		sun: '#F2C84B',
		signal: '#E85C3F',
		water: '#A8C9BD',
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
