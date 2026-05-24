import {useCallback, useEffect, useRef, useState} from 'react';

import {AppGroupDefaultsBridge} from '../native/AppGroupDefaultsBridge';
import {AppGroupDefaultsSnapshot} from '../native/types';

const POLL_INTERVAL_MS = 3000;

export type AppGroupDefaultsState =
  | {kind: 'loading'}
  | {kind: 'ready'; snapshot: AppGroupDefaultsSnapshot}
  | {kind: 'error'; message: string};

export type UseAppGroupDefaults = {
  state: AppGroupDefaultsState;
  refresh: () => void;
};

export function useAppGroupDefaults(): UseAppGroupDefaults {
  const [state, setState] = useState<AppGroupDefaultsState>({kind: 'loading'});
  const mountedRef = useRef(true);

  const load = useCallback(async () => {
    try {
      const snapshot = await AppGroupDefaultsBridge.snapshot();
      if (mountedRef.current) setState({kind: 'ready', snapshot});
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : String(e);
      if (mountedRef.current) setState({kind: 'error', message});
    }
  }, []);

  useEffect(() => {
    mountedRef.current = true;
    load();
    const id = setInterval(load, POLL_INTERVAL_MS);
    return () => {
      mountedRef.current = false;
      clearInterval(id);
    };
  }, [load]);

  return {state, refresh: load};
}
