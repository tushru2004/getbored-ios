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
		/** Editorial faces shared with the desktop admin visual system. */
		display: {
				fontFamily: 'Iowan Old Style',
				fontSize: 34,
				fontWeight: '500' as const,
				letterSpacing: -1.1,
		},
		eyebrow: {
				fontFamily: 'Menlo',
				fontSize: 11,
				fontWeight: '700' as const,
				letterSpacing: 1.15,
				textTransform: 'uppercase' as const,
		},
		microFooter: {
				fontFamily: 'Menlo',
				fontSize: 11,
				fontWeight: '400' as const,
				letterSpacing: 0.75,
				textTransform: 'uppercase' as const,
		},
		hero: {
				fontFamily: 'Iowan Old Style',
				fontSize: 36,
				fontWeight: '500' as const,
				letterSpacing: -1,
		},
		wordmark: {
				fontFamily: 'Iowan Old Style',
				fontSize: 17,
				fontWeight: '600' as const,
		},
		wordmarkLarge: {
				fontFamily: 'Iowan Old Style',
				fontSize: 34,
				fontWeight: '600' as const,
		},
};

export const hardShadow = {
		shadowColor: '#17342F',
		shadowOffset: {width: 4, height: 4},
		shadowOpacity: 1,
		shadowRadius: 0,
} as const;
