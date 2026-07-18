import {NativeModules} from 'react-native';

import {NativeModuleUnavailableError} from './errors';
import {
  AccountStatus,
  ActiveRules,
  DeviceRegistration,
  DeviceRegistrationSnapshot,
  FilterStatus,
  StatusViewModel,
} from './types';

type RawStatus = {
  filterState: string;
  filterLabel: string;
  signedIn: boolean;
};

type NativeFilterStatus = {
  current: () => Promise<RawStatus>;
  registerDevice: () => Promise<DeviceRegistration>;
  currentDeviceRegistration: () => Promise<DeviceRegistrationSnapshot>;
  syncFilterLists: () => Promise<void>;
  loadActiveRules: () => Promise<ActiveRules>;
};

const native = (NativeModules as {FilterStatus?: NativeFilterStatus})
  .FilterStatus;

/**
 * Maps the loosely-typed native `filterState` string onto the discriminated
 * FilterStatus union. Any unrecognized value (native/JS enum drift) is coerced
 * to a self-describing `error` rather than throwing, so the UI degrades softly.
 *
 *   raw.filterState
 *       │
 *       ├── 'active' | 'inactive' | 'checking' | 'error' → {kind, label}
 *       └── default (unknown)                            → {kind:'error', label:'Unknown filter state: …'}
 */
const parseFilter = (raw: RawStatus): FilterStatus => {
  switch (raw.filterState) {
    case 'active':
    case 'inactive':
    case 'checking':
    case 'error':
      return {kind: raw.filterState, label: raw.filterLabel};
    default:
      return {kind: 'error', label: `Unknown filter state: ${raw.filterState}`};
  }
};

/**
 * Maps the native `signedIn` flag onto the AccountStatus union (session
 * presence in the Keychain — a plain boolean now that the async CloudKit
 * account check is gone, so there's no `checking` state to represent here).
 *
 *   raw.signedIn
 *       │
 *       ├── true  → {kind: 'signedIn', label: 'Signed in'}
 *       └── false → {kind: 'signedOut', label: 'Signed out'}
 */
const parseAccount = (raw: RawStatus): AccountStatus =>
  raw.signedIn
    ? {kind: 'signedIn', label: 'Signed in'}
    : {kind: 'signedOut', label: 'Signed out'};

/**
 * Typed JS facade over the `FilterStatus` native module (registered by the iOS
 * side via NativeModules). `native` is resolved once at import time and may be
 * undefined in environments where the module isn't linked (tests, JS-only dev),
 * hence the shared guard below.
 *
 * Guard pattern (every async method):
 *
 *   method()
 *       │
 *       ├── native === undefined → throw NativeModuleUnavailableError
 *       └── otherwise            → delegate to native.<method>()  ← Promise
 *
 * Callers surface that rejection as their `error` state. `isAvailable` lets the
 * UI check linkage up front without triggering the throw.
 */
export const FilterStatusBridge = {
  isAvailable: native !== undefined,

  /**
   * Fetches the raw status blob and normalizes it into a view model.
   *
   *   native.current()  ← async, returns RawStatus (loose strings + a flag)
   *       │
   *       ├── parseFilter(raw)  → FilterStatus
   *       └── parseAccount(raw) → AccountStatus
   *       │
   *       ▼
   *   {filter, account}  ← StatusViewModel
   */
  async current(): Promise<StatusViewModel> {
    if (!native) throw new NativeModuleUnavailableError('FilterStatus');
    const raw = await native.current();
    const filter = parseFilter(raw);
    const account = parseAccount(raw);
    return {filter, account};
  },

  async registerDevice(): Promise<DeviceRegistration> {
    if (!native) throw new NativeModuleUnavailableError('FilterStatus');
    return native.registerDevice();
  },

  async currentDeviceRegistration(): Promise<DeviceRegistrationSnapshot> {
    if (!native) throw new NativeModuleUnavailableError('FilterStatus');
    return native.currentDeviceRegistration();
  },

  async syncFilterLists(): Promise<void> {
    if (!native) throw new NativeModuleUnavailableError('FilterStatus');
    return native.syncFilterLists();
  },

  async loadActiveRules(): Promise<ActiveRules> {
    if (!native) throw new NativeModuleUnavailableError('FilterStatus');
    return native.loadActiveRules();
  },
};
