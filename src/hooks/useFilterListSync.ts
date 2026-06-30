import {useCallback, useState} from 'react';

import {FilterStatusBridge} from '../native/FilterStatusBridge';

export type FilterListSyncState =
  | {kind: 'idle'}
  | {kind: 'syncing'}
  | {kind: 'success'}
  | {kind: 'error'; message: string};

export type UseFilterListSync = {
  state: FilterListSyncState;
  sync: () => Promise<void>;
};

/**
 * Drives a one-shot "pull filter lists from iCloud" action and tracks its
 * lifecycle for the UI (button label, success pill, error text).
 *
 * Call flow:
 *
 *   sync()  ← caller-triggered (button press)
 *       │
 *       ▼
 *   setState({syncing})           ← UI disables button, shows "Refreshing..."
 *       │
 *       ▼
 *   FilterStatusBridge.syncFilterLists()  ← async; throws if native unavailable
 *       │
 *       ├── resolves → setState({success})            ← stays success until next sync()
 *       └── rejects  → setState({error, message})     ← Error.message or String(e)
 *
 * Starts in `idle` (never auto-syncs). `sync` is a stable useCallback ([] deps).
 */
export function useFilterListSync(): UseFilterListSync {
  const [state, setState] = useState<FilterListSyncState>({kind: 'idle'});

  const sync = useCallback(async () => {
    setState({kind: 'syncing'});
    try {
      await FilterStatusBridge.syncFilterLists();
      setState({kind: 'success'});
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : String(e);
      setState({kind: 'error', message});
    }
  }, []);

  return {state, sync};
}
