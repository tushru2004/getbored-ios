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
  /** In-app filter enable ("Turn Filtering On"); reloads status after. */
  enable: () => Promise<void>;
};

/**
 * Polls the native filter status every POLL_INTERVAL_MS so the hero reflects
 * the user toggling the content filter in Settings without a manual refresh.
 *
 * Call flow:
 *
 *   mount
 *       │
 *       ├── load() once immediately
 *       └── setInterval(load, 5000)  ← repeats until unmount
 *               │
 *               ▼
 *           load(): FilterStatusBridge.current()
 *               ├── resolves → setState({ready, status})
 *               └── rejects  → setState({error, message})
 *                       (both writes guarded by mountedRef — a poll that
 *                        resolves after unmount must not setState)
 *
 *   unmount → mountedRef = false + clearInterval
 *
 *   enable()  ← "Turn Filtering On" press
 *       │
 *       ▼
 *   FilterStatusBridge.enableFilter()
 *       ├── rejects  → setState({error, message}), stop
 *       └── resolves → load()  ← reflect the now-active filter immediately
 *
 * `refresh` is just `load` exposed for pull-to-refresh.
 */
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

  const enable = useCallback(async () => {
    try {
      await FilterStatusBridge.enableFilter();
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : String(e);
      if (mountedRef.current) setState({kind: 'error', message});
      return;
    }
    await load();
  }, [load]);

  return {state, refresh: load, enable};
}
