import {useCallback, useEffect, useRef, useState} from 'react';

import {DiagnosticsBridge} from '../native/DiagnosticsBridge';
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
            /** Opens the authenticated customer-profile download in the browser. */
            downloadProfile: () => Promise<void>;
            /**
             * The last enable() failure, held OUTSIDE the polled `state` so the
             * status poll can't overwrite it a few seconds later (the bug where the
             * error flashed and vanished). Cleared when the user retries enable().
             */
            enableError: string | null;
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
         *       ├── enableError = null   ← retry clears the previous failure
         *       ▼
         *   FilterStatusBridge.enableFilter()
         *       ├── rejects  → enableError = message  ← sticky: the poll can't clear it
         *       │             DiagnosticsBridge.reportRecentLogs('enable-filter-failed')
         *       │                 ← fire-and-forget: ships the last minutes of native
         *       │                   logs (incl. the NEFilterManager error) to the server
         *       └── resolves → load()  ← reflect the now-active filter immediately
         *
         * `refresh` is just `load` exposed for pull-to-refresh.
         */
        export function useFilterStatus(): UseFilterStatus {
            const [state, setState] = useState<FilterStatusState>({kind: 'loading'});
            const [enableError, setEnableError] = useState<string | null>(null);
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
                if (mountedRef.current) setEnableError(null);
                try {
                    await FilterStatusBridge.enableFilter();
                } catch (e: unknown) {
                    const message = e instanceof Error ? e.message : String(e);
                    if (mountedRef.current) setEnableError(message);
                    DiagnosticsBridge.reportRecentLogs('enable-filter-failed');
                    return;
                }
                await load();
            }, [load]);

            const downloadProfile = useCallback(
                () => FilterStatusBridge.downloadProfile(),
                [],
            );

            return {state, refresh: load, enable, downloadProfile, enableError};
        }
