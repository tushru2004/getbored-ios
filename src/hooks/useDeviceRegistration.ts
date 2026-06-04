import {useCallback, useEffect, useState} from 'react';

import {FilterStatusBridge} from '../native/FilterStatusBridge';
import {DeviceRegistration} from '../native/types';

export type DeviceRegistrationState =
  | {kind: 'checking'}
  | {kind: 'idle'}
  | {kind: 'saving'}
  | {kind: 'registered'; registration: DeviceRegistration}
  | {kind: 'error'; message: string};

export type UseDeviceRegistration = {
  state: DeviceRegistrationState;
  refresh: (showErrors?: boolean) => Promise<void>;
  register: () => Promise<void>;
};

export function useDeviceRegistration(): UseDeviceRegistration {
  const [state, setState] = useState<DeviceRegistrationState>({
    kind: 'checking',
  });

  const refresh = useCallback(async (showErrors = false) => {
    setState({kind: 'checking'});
    try {
      const snapshot = await FilterStatusBridge.currentDeviceRegistration();
      if (snapshot.isRegistered && snapshot.registration) {
        setState({kind: 'registered', registration: snapshot.registration});
      } else {
        setState({kind: 'idle'});
      }
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : String(e);
      setState(showErrors ? {kind: 'error', message} : {kind: 'idle'});
    }
  }, []);

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

  useEffect(() => {
    refresh(false);
  }, [refresh]);

  return {state, refresh, register};
}
