export type FilterStatus =
		| {kind: 'active'; label: string}
		| {kind: 'inactive'; label: string}
		| {kind: 'checking'; label: string}
		| {kind: 'error'; label: string};

export type AccountStatus =
		| {kind: 'signedIn'; label: string}
		| {kind: 'signedOut'; label: string};

export type FilterProfileStatus =
		| {kind: 'installed'}
		| {kind: 'missing'}
		| {kind: 'unknown'};

export type StatusViewModel = {
		filter: FilterStatus;
		profile: FilterProfileStatus;
		account: AccountStatus;
};

export type DeviceRegistration = {
		id: string;
		name: string | null;
		model: string | null;
		appVersion: string | null;
		lastSeenAt: string | null;
		createdAt: string;
};

export type DeviceRegistrationSnapshot = {
		isRegistered: boolean;
		registration: DeviceRegistration | null;
};

/** Counts of what a successful sync just applied on-device. */
export type SyncSummary = {
		sites: number;
		exceptions: number;
		allowedApps: number;
		blockedApps: number;
};

export type ActiveRules = {
		mode: 'blockSpecific' | 'whiteList';
		entries: string[];
		exceptions: string[];
		allowedApps: string[];
		blockedApps: string[];
};

export type AccountSummary = {
		signedIn: boolean;
		userId?: string;
		/** Live backend entitlement. Absent only when account enrichment failed. */
		plan?: string;
		/** Canonical first-party username, when this is a password account. */
		username?: string;
		/** Server-owned category. Only review_demo may bypass setup gates. */
		accountKind?: 'customer' | 'review_demo';
		/** Best email for display: contactEmail if set, else the Apple identity
		 * email (possibly an @privaterelay.appleid.com address). Absent when the
		 * enrichment call fails or the account has no stored email. */
		email?: string;
};

export type SignInResult = {
		userId: string;
};
