import {useEffect, useRef, useState} from 'react';
import {AppState} from 'react-native';

import {useAccount, UseAccount} from './useAccount';
import {
  useDeviceRegistration,
  UseDeviceRegistration,
} from './useDeviceRegistration';
import {useFilterListSync, UseFilterListSync} from './useFilterListSync';

export type DeviceRegistrationAndRuleSync = {
  account: UseAccount;
  registration: UseDeviceRegistration;
  filterSync: UseFilterListSync;
};

/**
 * The single owner of account / registration / sync state for the home
 * screen, plus the orchestration that used to be three manual taps. Four
 * effects run in sequence off the account/registration state machines:
 *
 *   signed in? ──── no ──→ every effect early-returns and re-arms its
 *       │                   guards for the next sign-in; HomeScreen hides
 *      yes                  the signed-in UI anyway
 *       │
 *       ├── [effect 1] on signed-out → signed-in transition
 *       │       └──→ refreshRegistration(), THEN flip
 *       │            registrationCheckedForSession = true — a fresh server
 *       │            check must finish before auto-register is allowed, or a
 *       │            stale 'idle' left over from the signed-out mount could
 *       │            race register() and overwrite a good registration
 *       │
 *       ├── [effect 2] registrationChecked + registration 'idle' + armed ref
 *       │       └──→ register() automatically, once per sign-in — the
 *       │            manual "Connect This Device" button remains only as a
 *       │            retry for the failure states
 *       │
 *       ├── [effect 3] device connected ('registered')
 *       │       └──→ sync() when it JUST became registered (fresh connect,
 *       │            including effect 2's auto-register) OR when it was
 *       │            already registered at launch and sync is still 'idle'
 *       │
 *       └── [effect 4] app returns to foreground ('active') while connected
 *               └──→ sync() again — an admin may have re-assigned lists
 *                    while the app was backgrounded; this also keeps the
 *                    server's "last seen" honest
 *
 * Loop safety: every automatic call is gated on the corresponding state
 * machine being in 'idle' (or a one-shot ref). A failed attempt lands in an
 * error/notice state, not 'idle', so autos never retry on their own —
 * retrying stays a human decision via the cards' buttons.
 */
export function useDeviceRegistrationAndRuleSync(): DeviceRegistrationAndRuleSync {
  const account = useAccount();
  const registration = useDeviceRegistration();
  const filterSync = useFilterListSync();

  const signedIn = account.state.kind === 'signedIn';
  const registered = registration.state.kind === 'registered';
  const registrationIdle = registration.state.kind === 'idle';
  const syncIdle = filterSync.state.kind === 'idle';
  const {register, refresh: refreshRegistration} = registration;
  const {sync} = filterSync;
  const [registrationCheckedForSession, setRegistrationCheckedForSession] =
    useState(false);

  // On every signed-out → signed-in transition, finish a fresh server check
  // before auto-registration is allowed. Without this gate, an `idle` result
  // left over from the signed-out mount can start register() in the same
  // render as refreshRegistration(); whichever request finishes last then
  // wins, allowing a stale "not connected" result to overwrite a successful
  // registration and sync.
  useEffect(() => {
    if (!signedIn) {
      setRegistrationCheckedForSession(false);
      return;
    }

    let cancelled = false;
    setRegistrationCheckedForSession(false);
    refreshRegistration().finally(() => {
      if (!cancelled) {
        setRegistrationCheckedForSession(true);
      }
    });

    return () => {
      cancelled = true;
    };
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
    if (
      registrationCheckedForSession &&
      registrationIdle &&
      autoRegisterArmed.current
    ) {
      autoRegisterArmed.current = false;
      register();
    }
  }, [
    signedIn,
    registrationCheckedForSession,
    registrationIdle,
    register,
  ]);

  // Sync when the device BECOMES connected (fresh registration — including
  // the auto-connect above), and once per session when it already was
  // connected at launch (sync still 'idle').
  //
  //   registered edge / state
  //       │
  //       ├── registered flips false → true (becameRegistered) → sync()
  //       │       (covers effect 2's auto-register and manual reconnect)
  //       └── already registered at launch AND sync still 'idle'  → sync()
  //               (cold start where the device was connected last run)
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
