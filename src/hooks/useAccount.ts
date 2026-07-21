import {useCallback, useEffect, useState} from 'react';

import {AccountBridge} from '../native/AccountBridge';
import {nativeErrorCode} from '../native/errors';

export type AccountState =
  | {kind: 'unavailable'}
  | {kind: 'checking'}
  | {kind: 'signedOut'}
  | {kind: 'signingIn'}
  | {kind: 'needsActivation'; userId?: string; email?: string}
  | {kind: 'signedIn'; userId?: string; email?: string}
  | {kind: 'deleting'}
  | {kind: 'error'; message: string};

export type UseAccount = {
  state: AccountState;
  signIn: () => Promise<void>;
  /** Web-flow sign-in: accepts any Apple ID, not just the device's. */
  signInWithDifferentAccount: () => Promise<void>;
  signOut: () => Promise<void>;
  deleteAccount: () => Promise<void>;
  redeemActivationCode: (code: string) => Promise<void>;
  refresh: (showChecking?: boolean) => Promise<void>;
};

/**
 * Drives the account/sign-in lifecycle. Instantiated exactly once, by
 * useConnectedApp — HomeScreen passes the state down to SignInCard and uses
 * it for gating, so every consumer reads the same state machine.
 *
 * Call flow:
 *
 *   mount
 *     │
 *     ▼
 *   AccountBridge.isAvailable?
 *     │
 *     ├── false → setState({unavailable})  ← older native build; HomeScreen
 *     │                                       treats this like the feature
 *     │                                       doesn't exist yet (ungated)
 *     └── true  → refresh()
 *                   │
 *                   ▼
 *                 AccountBridge.currentAccount()  ← async
 *                   │
 *                   ├── {signedIn: true, plan !== 'active'} → setState({needsActivation, userId, email})
 *                   ├── {signedIn: true, plan active/unknown} → setState({signedIn, userId, email})
 *                   ├── {signedIn: false}                    → setState({signedOut})
 *                   └── rejects (only when showChecking)     → setState({error, message})
 *                          └── refresh(false) swallows the reject and keeps
 *                              the current state (background re-enrichment)
 *
 *   signIn() / signInWithDifferentAccount()  ← the two Welcome buttons
 *     │                                         both delegate to runSignIn():
 *     ▼
 *   runSignIn(start)
 *     │
 *     ▼
 *   setState({signingIn})
 *     │
 *     ▼
 *   start()  ← AccountBridge.signIn()            (device Apple ID sheet)
 *     │       or AccountBridge.signInWithWebAccount() (web flow, any Apple ID)
 *     │
 *     ├── resolves            → refresh()            ← re-check via currentAccount()
 *     ├── rejects, CANCELLED  → setState({signedOut}) ← sheet dismissed; no error UI
 *     └── rejects, otherwise  → setState({error, message})
 *
 *   redeemActivationCode(code)  ← ActivationScreen "Activate" press
 *     │
 *     ▼
 *   AccountBridge.redeemActivationCode(code)  ← rejects propagate to caller
 *     │                                          (ActivationScreen shows the error)
 *     └── resolves → refresh()  ← plan is now active → lands on {signedIn}
 *
 *   deleteAccount()  ← Account sheet "Delete Account" (see method doc below)
 *     │
 *     └── setState({deleting}) → native deleteAccount() → {signedOut} on
 *         success or SIGNED_OUT; other rejects → {error, message}
 *
 *   signOut()  ← always lands on {signedOut}, even if the native call
 *                unexpectedly throws (it's contracted to never reject)
 */
export function useAccount(): UseAccount {
  const [state, setState] = useState<AccountState>(
    AccountBridge.isAvailable ? {kind: 'checking'} : {kind: 'unavailable'},
  );

  const refresh = useCallback(async (showChecking = true) => {
    if (!AccountBridge.isAvailable) {
      setState({kind: 'unavailable'});
      return;
    }
    if (showChecking) {
      setState({kind: 'checking'});
    }
    try {
      const summary = await AccountBridge.currentAccount();
      if (summary.signedIn) {
        setState(previous => {
          const previousUserId =
            previous.kind === 'signedIn' || previous.kind === 'needsActivation'
              ? previous.userId
              : undefined;
          const previousEmail =
            previous.kind === 'signedIn' || previous.kind === 'needsActivation'
              ? previous.email
              : undefined;
          const accountDetails = {
            userId: summary.userId ?? previousUserId,
            email: summary.email ?? previousEmail,
          };
          if (summary.plan !== undefined && summary.plan !== 'active') {
            return {kind: 'needsActivation', ...accountDetails};
          }
          return {kind: 'signedIn', ...accountDetails};
        });
      } else {
        setState({kind: 'signedOut'});
      }
    } catch (e: unknown) {
      if (!showChecking) {
        return;
      }
      const message = e instanceof Error ? e.message : String(e);
      setState({kind: 'error', message});
    }
  }, []);

  /**
   * Shared by both sign-in flavors: same lifecycle, same error handling —
   * only the native entry point differs (device-account sheet vs the web
   * flow that accepts any Apple ID).
   */
  const runSignIn = useCallback(
    async (start: () => Promise<unknown>) => {
      setState({kind: 'signingIn'});
      try {
        await start();
        await refresh();
      } catch (e: unknown) {
        if (nativeErrorCode(e) === 'CANCELLED') {
          setState({kind: 'signedOut'});
          return;
        }
        const message = e instanceof Error ? e.message : String(e);
        setState({kind: 'error', message});
      }
    },
    [refresh],
  );

  const signIn = useCallback(
    () => runSignIn(() => AccountBridge.signIn()),
    [runSignIn],
  );

  const signInWithDifferentAccount = useCallback(
    () => runSignIn(() => AccountBridge.signInWithWebAccount()),
    [runSignIn],
  );

  const signOut = useCallback(async () => {
    try {
      await AccountBridge.signOut();
    } finally {
      setState({kind: 'signedOut'});
    }
  }, []);

  const redeemActivationCode = useCallback(
    async (code: string) => {
      await AccountBridge.redeemActivationCode(code);
      await refresh();
    },
    [refresh],
  );

  /**
   * Permanent account deletion (App Review 5.1.1(v)). Native clears the
   * session, the server device id, and the applied rules on success, so
   * landing on {signedOut} here reflects true local state. A SIGNED_OUT
   * rejection means there was no live session to begin with — same outcome.
   * Other failures keep local state intact (native contract) so the user
   * can simply retry.
   */
  const deleteAccount = useCallback(async () => {
    setState({kind: 'deleting'});
    try {
      await AccountBridge.deleteAccount();
      setState({kind: 'signedOut'});
    } catch (e: unknown) {
      if (nativeErrorCode(e) === 'SIGNED_OUT') {
        setState({kind: 'signedOut'});
        return;
      }
      const message = e instanceof Error ? e.message : String(e);
      setState({kind: 'error', message});
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  return {
    state,
    signIn,
    signInWithDifferentAccount,
    signOut,
    deleteAccount,
    redeemActivationCode,
    refresh,
  };
}
