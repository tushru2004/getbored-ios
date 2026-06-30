import {useCallback, useEffect, useState} from 'react';

import {FilterStatusBridge} from '../native/FilterStatusBridge';
import {ActiveRules} from '../native/types';

type State =
  | {kind: 'loading'}
  | {kind: 'ready'; rules: ActiveRules}
  | {kind: 'error'; message: string};

/**
 * Loads the device's active filter rules from the native FilterStatus module
 * and exposes a manual `reload` so callers (e.g. the Reload button / modal-open
 * effect in ActiveRulesScreen) can re-fetch on demand.
 *
 * Call flow:
 *
 *   useActiveRules() mounts
 *       │
 *       ▼
 *   useEffect → load()            ← also re-invoked whenever caller fires reload()
 *       │
 *       ▼
 *   setState({loading})
 *       │
 *       ▼
 *   FilterStatusBridge.loadActiveRules()  ← async; throws if native unavailable
 *       │
 *       ├── resolves → setState({ready, rules})
 *       └── rejects  → setState({error, message})   ← Error.message or String(err)
 *
 * `load` is a stable useCallback ([] deps), so the mount effect runs exactly
 * once and the same reference is safe to expose as `reload`.
 */
export function useActiveRules() {
  const [state, setState] = useState<State>({kind: 'loading'});

  const load = useCallback(async () => {
    setState({kind: 'loading'});
    try {
      const rules = await FilterStatusBridge.loadActiveRules();
      setState({kind: 'ready', rules});
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setState({kind: 'error', message});
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  return {state, reload: load};
}
