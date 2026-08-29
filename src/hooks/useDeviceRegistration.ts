import {useCallback, useEffect, useState} from 'react';

import {nativeErrorCode} from '../native/errors';
import {FilterStatusBridge} from '../native/FilterStatusBridge';
import {DeviceRegistration} from '../native/types';

export type DeviceRegistrationState =
		| {kind: 'checking'}
		| {kind: 'idle'}
		| {kind: 'saving'}
		| {kind: 'registered'; registration: DeviceRegistration}
		| {kind: 'signedOut'}
		| {kind: 'subscriptionRequired'}
		| {kind: 'error'; message: string};

export type UseDeviceRegistration = {
		state: DeviceRegistrationState;
		refresh: (showErrors?: boolean) => Promise<void>;
		register: () => Promise<void>;
};

/**
 * Classifies a rejection from a device-registration call into the state the
 * UI should show. SIGNED_OUT / SUBSCRIPTION_REQUIRED are expected, calm
 * outcomes — the on-device rules are kept either way — so they get their own
 * states instead of the red error box; everything else (NETWORK, SERVER, an
 * unrecognized code, or a plain Error) falls back to the generic error state.
 */
function classifyFailure(e: unknown): DeviceRegistrationState {
		const code = nativeErrorCode(e);
		if (code === 'SIGNED_OUT') return {kind: 'signedOut'};
		if (code === 'SUBSCRIPTION_REQUIRED') return {kind: 'subscriptionRequired'};
		const message = e instanceof Error ? e.message : String(e);
		return {kind: 'error', message};
}

/**
 * Tracks whether THIS iPhone has a server-side device registration, and
 * exposes the two writes (refresh = re-check, register = create) that
 * useDeviceRegistrationAndRuleSync orchestrates automatically.
 *
 * Call flow:
 *
 *   mount → refresh(false)  ← silent background check
 *
 *   refresh(showErrors = false)
 *       │
 *       ▼
 *   setState({checking}) → currentDeviceRegistration()
 *       │
 *       ├── isRegistered + registration present → setState({registered, registration})
 *       ├── otherwise                            → setState({idle})
 *       └── rejects → classifyFailure(e)
 *               ├── SIGNED_OUT / SUBSCRIPTION_REQUIRED → that calm state (always shown)
 *               └── generic error
 *                       ├── showErrors === false → setState({idle})  ← swallow, mount default
 *                       └── showErrors === true  → setState({error, message})
 *
 *   register()  ← auto-connect (useDeviceRegistrationAndRuleSync) or manual retry button
 *       │
 *       ▼
 *   setState({saving}) → registerDevice()
 *       │
 *       ├── resolves → setState({registered, registration})
 *       └── rejects  → classifyFailure(e)  ← calm state or {error, message}
 */
export function useDeviceRegistration(): UseDeviceRegistration {
		const [state, setState] = useState<DeviceRegistrationState>({
				kind: 'checking',
		});

		const refresh = useCallback(async (showErrors = false) => {
				setState({kind: 'checking'});
				try {
						const snapshot = await FilterStatusBridge.currentDeviceRegistration();
						if (snapshot.isRegistered && snapshot.registration) {
								setState({kind: 'registered', registration: snapshot.registration});
						} else {
								setState({kind: 'idle'});
						}
				} catch (e: unknown) {
						const failure = classifyFailure(e);
						// A silent background refresh (mount) only surfaces the calm states;
						// a generic error still collapses to idle unless the caller opted in
						// via showErrors, same suppression as before this hook learned codes.
						if (failure.kind === 'error' && !showErrors) {
								setState({kind: 'idle'});
								return;
						}
						setState(failure);
				}
		}, []);

		const register = useCallback(async () => {
				setState({kind: 'saving'});
				try {
						const registration = await FilterStatusBridge.registerDevice();
						setState({kind: 'registered', registration});
				} catch (e: unknown) {
						setState(classifyFailure(e));
				}
		}, []);

		useEffect(() => {
				refresh(false);
		}, [refresh]);

		return {state, refresh, register};
}
