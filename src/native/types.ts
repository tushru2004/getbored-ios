export type FilterStatus =
  | {kind: 'active'; label: string}
  | {kind: 'inactive'; label: string}
  | {kind: 'checking'; label: string}
  | {kind: 'error'; label: string};

export type AccountStatus =
  | {kind: 'signedIn'; label: string}
  | {kind: 'signedOut'; label: string};

export type StatusViewModel = {
  filter: FilterStatus;
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
  /** Best email for display: contactEmail if set, else the Apple identity
   * email (possibly an @privaterelay.appleid.com address). Absent when the
   * enrichment call fails or the account has no stored email. */
  email?: string;
};

export type SignInResult = {
  userId: string;
};
