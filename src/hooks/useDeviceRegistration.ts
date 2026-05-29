import {useCallback, useState} from 'react';

import {FilterStatusBridge} from '../native/FilterStatusBridge';
import {DeviceRegistration} from '../native/types';

export type DeviceRegistrationState =
  | {kind: 'idle'}
  | {kind: 'saving'}
  | {kind: 'registered'; registration: DeviceRegistration}
  | {kind: 'error'; message: string};

export type UseDeviceRegistration = {
  state: DeviceRegistrationState;
  register: () => Promise<void>;
};

export function useDeviceRegistration(): UseDeviceRegistration {
  const [state, setState] = useState<DeviceRegistrationState>({kind: 'idle'});

  const register = useCallback(async () => {
    setState({kind: 'saving'});
    try {
      const registration = await FilterStatusBridge.registerDevice();
      setState({kind: 'registered', registration});
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : String(e);
      setState({kind: 'error', message});
    }
  }, []);

  return {state, register};
}
