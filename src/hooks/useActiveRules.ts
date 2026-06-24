import {useCallback, useEffect, useState} from 'react';

import {FilterStatusBridge} from '../native/FilterStatusBridge';
import {ActiveRules} from '../native/types';

type State =
  | {kind: 'loading'}
  | {kind: 'ready'; rules: ActiveRules}
  | {kind: 'error'; message: string};

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
