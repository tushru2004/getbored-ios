import {useEffect, useRef} from 'react';
import {AppState} from 'react-native';

import {useAccount, UseAccount} from './useAccount';
import {
  useDeviceRegistration,
  UseDeviceRegistration,
} from './useDeviceRegistration';
import {useFilterListSync, UseFilterListSync} from './useFilterListSync';

export type ConnectedApp = {
  account: UseAccount;
  registration: UseDeviceRegistration;
  filterSync: UseFilterListSync;
};

/**
 * The single owner of account / registration / sync state for the home
 * screen, plus the orchestration that used to be three manual taps:
 *
 *   signed in? ──── no ──→ nothing runs; cards below the sign-in card are
 *       │                   hidden by HomeScreen anyway
 *      yes
 *       │
 *       ├── device not connected yet (registration 'idle')
 *       │       └──→ register() automatically, once per sign-in — the
 *       │            "Connect This Device" button remains only as a manual
 *       │            retry for the failure states
 *       │
 *       ├── device connected + no sync attempted yet (sync 'idle')
 *       │       └──→ sync() automatically (fresh rules on every cold start)
 *       │
 *       └── app returns to foreground ('active')
 *               └──→ sync() again — an admin may have re-assigned lists
 *                    while the app was backgrounded; this also keeps the
 *                    server's "last seen" honest
 *
 * Loop safety: every automatic call is gated on the corresponding state
 * machine being in 'idle'. A failed attempt lands in an error/notice state,
 * not 'idle', so autos never retry on their own — retrying stays a human
 * decision via the cards' buttons.
 */
export function useConnectedApp(): ConnectedApp {
  const account = useAccount();
  const registration = useDeviceRegistration();
  const filterSync = useFilterListSync();

  const signedIn = account.state.kind === 'signedIn';
  const registered = registration.state.kind === 'registered';
  const registrationIdle = registration.state.kind === 'idle';
  const syncIdle = filterSync.state.kind === 'idle';
  const {register, refresh: refreshRegistration} = registration;
  const {sync} = filterSync;

  // On every signed-out → signed-in transition, re-check the device's server
  // registration instead of trusting the cached machine state. Matters after
  // account deletion or a sign-out/sign-in cycle: the old 'registered' state
  // is stale (the server row may be gone), and refreshing lands the machine
  // back in 'idle', which re-triggers auto-connect below.
  const wasSignedIn = useRef(false);
  useEffect(() => {
    if (signedIn && !wasSignedIn.current) {
      refreshRegistration();
    }
    wasSignedIn.current = signedIn;
  }, [signedIn, refreshRegistration]);

  // Auto-connect the device after sign-in. The ref limits this to one
  // attempt per signed-in period even across transient re-renders; it
  // re-arms when the user signs out.
  const autoRegisterArmed = useRef(true);
  useEffect(() => {
    if (!signedIn) {
      autoRegisterArmed.current = true;
      return;
    }
    if (registrationIdle && autoRegisterArmed.current) {
      autoRegisterArmed.current = false;
      register();
    }
  }, [signedIn, registrationIdle, register]);

  // Sync when the device BECOMES connected (fresh registration — including
  // the auto-connect above), and once per session when it already was
  // connected at launch (sync still 'idle').
  const wasRegistered = useRef(false);
  useEffect(() => {
    const becameRegistered = registered && !wasRegistered.current;
    wasRegistered.current = registered;
    if (signedIn && registered && (becameRegistered || syncIdle)) {
      sync();
    }
  }, [signedIn, registered, syncIdle, sync]);

  // Re-sync whenever the app comes back to the foreground.
  useEffect(() => {
    const subscription = AppState.addEventListener('change', status => {
      if (status === 'active' && signedIn && registered) {
        sync();
      }
    });
    return () => subscription.remove();
  }, [signedIn, registered, sync]);

  return {account, registration, filterSync};
}
