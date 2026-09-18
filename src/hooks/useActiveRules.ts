import {AppState} from 'react-native';
import {useCallback, useEffect, useRef, useState} from 'react';

import {nativeErrorCode} from '../native/errors';
import {FilterStatusBridge} from '../native/FilterStatusBridge';
import {ActiveRules} from '../native/types';

        export type ActiveRulesState =
            | {kind: 'loading'}
            | {kind: 'ready'; rules: ActiveRules}
            | {kind: 'signedOut'}
            | {kind: 'subscriptionRequired'}
            | {kind: 'error'; message: string};

/**
 * Classifies a load rejection into the state the UI should show. Mirrors
 * useDeviceRegistration/useFilterListSync's classifyFailure for the same
 * shape of state everywhere — but note loadActiveRules() is currently a
 * synchronous local read (see the hook's doc comment) that never actually
 * produces SIGNED_OUT/SUBSCRIPTION_REQUIRED; those branches only stand
 * ready for if/when this becomes a live pull.
 */
function classifyFailure(e: unknown): ActiveRulesState {
    const code = nativeErrorCode(e);
    if (code === 'SIGNED_OUT') return {kind: 'signedOut'};
    if (code === 'SUBSCRIPTION_REQUIRED') return {kind: 'subscriptionRequired'};
    const message = e instanceof Error ? e.message : String(e);
    return {kind: 'error', message};
}

        /**
         * Loads the device's active filter rules from the native FilterStatus
         * module. `loadActiveRules()` reads IOSRuleStore — local App-Group
         * UserDefaults holding the last rules snapshot applied to this device, not
         * a fresh server pull — synchronously and resolve-only, so in practice the
         * only way this rejects today is a NativeModuleUnavailableError (native
         * module not linked). Exposes a manual `reload` so callers (e.g. the
         * Reload button / modal-open effect in ActiveRulesScreen) can re-fetch on
         * demand.
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
         *   FilterStatusBridge.loadActiveRules()  ← reads IOSRuleStore locally
         *       │
         *       ├── resolves → setState({ready, rules})
         *       └── rejects  → classifyFailure(e)  ← today always lands in {error, message}
         *                                             (native module not linked)
         *
         * `load` is a stable useCallback ([] deps), so the mount effect runs exactly
         * once and the same reference is safe to expose as `reload`.
         */
        export function useActiveRules({refreshing = true}: {refreshing?: boolean} = {}) {
            const [state, setState] = useState<ActiveRulesState>({kind: 'loading'});
            const requestID = useRef(0);
            const hasLoaded = useRef(false);

            const load = useCallback(async () => {
                const currentRequest = ++requestID.current;
                if (!hasLoaded.current) {
                    setState({kind: 'loading'});
                }
                try {
                    const rules = await FilterStatusBridge.loadActiveRules();
                    if (currentRequest === requestID.current) {
                        hasLoaded.current = true;
                        setState({kind: 'ready', rules});
                    }
                } catch (e: unknown) {
                    if (currentRequest === requestID.current) {
                        setState(classifyFailure(e));
                    }
                }
            }, []);

            useEffect(() => {
                load();
            }, [load]);

            useEffect(() => {
                if (!refreshing) return;
                const interval = setInterval(load, 60_000);
                const subscription = AppState.addEventListener('change', nextState => {
                    if (nextState === 'active') load();
                });
                return () => {
                    clearInterval(interval);
                    subscription.remove();
                };
            }, [load, refreshing]);

            return {state, reload: load};
        }
