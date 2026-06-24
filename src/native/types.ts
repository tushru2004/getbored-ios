export type FilterStatus =
  | {kind: 'active'; label: string}
  | {kind: 'inactive'; label: string}
  | {kind: 'checking'; label: string}
  | {kind: 'error'; label: string};

export type ICloudStatus =
  | {kind: 'available'; label: string}
  | {kind: 'unavailable'; label: string}
  | {kind: 'checking'; label: string};

export type StatusViewModel = {
  filter: FilterStatus;
  icloud: ICloudStatus;
};

export type DeviceRegistration = {
  id: string;
  deviceName: string;
  deviceModel: string;
  systemVersion: string;
  appVersion: string;
  lastSeenAt: string;
  buildConfiguration: string;
  registeredDeviceCount: number;
};

export type DeviceRegistrationSnapshot = {
  isRegistered: boolean;
  registration: DeviceRegistration | null;
  registeredDeviceCount: number;
};

export type ActiveRules = {
  mode: 'blockSpecific' | 'whiteList';
  entries: string[];
  exceptions: string[];
  allowedApps: string[];
};

export type AppGroupDefaultsKey = {
  key: string;
  type: string;
  preview: string;
};

export type AppGroupDefaultsSnapshot = {
  groupIdentifier: string;
  flowLogKey: string;
  flowLogLimit: number;
  flowLogCount: number;
  flowLog: string[];
  keys: AppGroupDefaultsKey[];
};
