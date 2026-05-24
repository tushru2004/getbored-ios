import {NativeModules} from 'react-native';

import {AppGroupDefaultsSnapshot} from './types';

type NativeAppGroupDefaults = {
  snapshot: () => Promise<AppGroupDefaultsSnapshot>;
};

const native = (NativeModules as {AppGroupDefaults?: NativeAppGroupDefaults})
  .AppGroupDefaults;

export class AppGroupDefaultsUnavailableError extends Error {
  constructor() {
    super('AppGroupDefaults native module is not linked');
    this.name = 'AppGroupDefaultsUnavailableError';
  }
}

export const AppGroupDefaultsBridge = {
  isAvailable: native !== undefined,

  async snapshot(): Promise<AppGroupDefaultsSnapshot> {
    if (!native) throw new AppGroupDefaultsUnavailableError();
    return native.snapshot();
  },
};
