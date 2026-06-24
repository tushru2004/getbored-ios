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
