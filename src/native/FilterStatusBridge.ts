import {NativeModules} from 'react-native';

import {
  ActiveRules,
  DeviceRegistration,
  DeviceRegistrationSnapshot,
  FilterStatus,
  ICloudStatus,
  StatusViewModel,
} from './types';

type RawStatus = {
  filterState: string;
  filterLabel: string;
  icloudState: string;
  icloudLabel: string;
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

export class NativeModuleUnavailableError extends Error {
  constructor() {
    super('FilterStatus native module is not linked');
    this.name = 'NativeModuleUnavailableError';
  }
}

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
 * Maps the native `icloudState` string onto the ICloudStatus union. Unknown
 * values fall back to `unavailable` (fail-safe: treat unrecognized as not-ready)
 * instead of throwing.
 *
 *   raw.icloudState
 *       │
 *       ├── 'available' | 'unavailable' | 'checking' → {kind, label}
 *       └── default (unknown)                        → {kind:'unavailable', label:'Unknown iCloud state: …'}
 */
const parseICloud = (raw: RawStatus): ICloudStatus => {
  switch (raw.icloudState) {
    case 'available':
    case 'unavailable':
    case 'checking':
      return {kind: raw.icloudState, label: raw.icloudLabel};
    default:
      return {
        kind: 'unavailable',
        label: `Unknown iCloud state: ${raw.icloudState}`,
      };
  }
};

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
   *   native.current()  ← async, returns RawStatus (loose strings)
   *       │
   *       ├── parseFilter(raw) → FilterStatus
   *       └── parseICloud(raw) → ICloudStatus
   *       │
   *       ▼
   *   {filter, icloud}  ← StatusViewModel
   */
  async current(): Promise<StatusViewModel> {
    if (!native) throw new NativeModuleUnavailableError();
    const raw = await native.current();
    const filter = parseFilter(raw);
    const icloud = parseICloud(raw);
    return {filter, icloud};
  },

  async registerDevice(): Promise<DeviceRegistration> {
    if (!native) throw new NativeModuleUnavailableError();
    return native.registerDevice();
  },

  async currentDeviceRegistration(): Promise<DeviceRegistrationSnapshot> {
    if (!native) throw new NativeModuleUnavailableError();
    return native.currentDeviceRegistration();
  },

  async syncFilterLists(): Promise<void> {
    if (!native) throw new NativeModuleUnavailableError();
    return native.syncFilterLists();
  },

  async loadActiveRules(): Promise<ActiveRules> {
    if (!native) throw new NativeModuleUnavailableError();
    return native.loadActiveRules();
  },
};
