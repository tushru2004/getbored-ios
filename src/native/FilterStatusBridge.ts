import {NativeModules} from 'react-native';

import {
  DeviceRegistration,
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
};

const native = (NativeModules as {FilterStatus?: NativeFilterStatus})
  .FilterStatus;

export class NativeModuleUnavailableError extends Error {
  constructor() {
    super('FilterStatus native module is not linked');
    this.name = 'NativeModuleUnavailableError';
  }
}

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

export const FilterStatusBridge = {
  isAvailable: native !== undefined,

  async current(): Promise<StatusViewModel> {
    if (!native) throw new NativeModuleUnavailableError();
    const raw = await native.current();
    return {filter: parseFilter(raw), icloud: parseICloud(raw)};
  },

  async registerDevice(): Promise<DeviceRegistration> {
    if (!native) throw new NativeModuleUnavailableError();
    return native.registerDevice();
  },
};
