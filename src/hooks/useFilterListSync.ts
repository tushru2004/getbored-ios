import {useCallback, useState} from 'react';

import {nativeErrorCode} from '../native/errors';
import {FilterStatusBridge} from '../native/FilterStatusBridge';
import {SyncSummary} from '../native/types';

export type FilterListSyncState =
  | {kind: 'idle'}
  | {kind: 'syncing'}
  | {kind: 'success'; summary: SyncSummary; syncedAtMs: number}
  | {kind: 'signedOut'}
  | {kind: 'subscriptionRequired'}
  | {kind: 'notRegistered'}
  | {kind: 'error'; message: string};

export type UseFilterListSync = {
  state: FilterListSyncState;
  sync: () => Promise<void>;
};

/**
 * Classifies a sync rejection into the state the UI should show.
 * SIGNED_OUT / SUBSCRIPTION_REQUIRED / NOT_REGISTERED are expected,
 * non-alarming outcomes — the device keeps its last-applied rules either
 * way — so they get their own calm states instead of the red error box.
 * NOT_REGISTERED means the session is fine but this device has no server
 * id yet (connect it first (automatic via useDeviceRegistrationAndRuleSync)).
 */
function classifyFailure(e: unknown): FilterListSyncState {
  const code = nativeErrorCode(e);
  if (code === 'SIGNED_OUT') return {kind: 'signedOut'};
  if (code === 'SUBSCRIPTION_REQUIRED') return {kind: 'subscriptionRequired'};
  if (code === 'NOT_REGISTERED') return {kind: 'notRegistered'};
  const message = e instanceof Error ? e.message : String(e);
  return {kind: 'error', message};
}

/**
 * Drives a one-shot "pull filter lists from the server" action and tracks
 * its lifecycle for the UI (button label, success pill, error text).
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
 *       ├── resolves(summary)      → setState({success, summary, syncedAtMs})
 *       └── rejects → classifyFailure(e)
 *               ├── SIGNED_OUT             → setState({signedOut})            ← rules were kept
 *               ├── SUBSCRIPTION_REQUIRED  → setState({subscriptionRequired}) ← filtering stopped on device
 *               ├── NOT_REGISTERED         → setState({notRegistered})        ← register the device first
 *               └── otherwise (NETWORK/SERVER/…) → setState({error, message})
 *
 * Starts in `idle` (never auto-syncs). `sync` is a stable useCallback ([] deps).
 */
export function useFilterListSync(): UseFilterListSync {
  const [state, setState] = useState<FilterListSyncState>({kind: 'idle'});

  const sync = useCallback(async () => {
    setState({kind: 'syncing'});
    try {
      const summary = await FilterStatusBridge.syncFilterLists();
      setState({kind: 'success', summary, syncedAtMs: Date.now()});
    } catch (e: unknown) {
      setState(classifyFailure(e));
    }
  }, []);

  return {state, sync};
}
