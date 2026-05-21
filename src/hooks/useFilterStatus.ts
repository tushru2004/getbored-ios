import {useCallback, useEffect, useRef, useState} from 'react';

import {FilterStatusBridge} from '../native/FilterStatusBridge';
import {StatusViewModel} from '../native/types';

const POLL_INTERVAL_MS = 5000;

export type FilterStatusState =
  | {kind: 'loading'}
  | {kind: 'ready'; status: StatusViewModel}
  | {kind: 'error'; message: string};

export type UseFilterStatus = {
  state: FilterStatusState;
  refresh: () => void;
};

export function useFilterStatus(): UseFilterStatus {
  const [state, setState] = useState<FilterStatusState>({kind: 'loading'});
  const mountedRef = useRef(true);

  const load = useCallback(async () => {
    try {
      const status = await FilterStatusBridge.current();
      if (mountedRef.current) setState({kind: 'ready', status});
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
