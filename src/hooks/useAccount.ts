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
 *                   ├── {signedIn: true, userId}  → setState({signedIn, userId})
 *                   ├── {signedIn: false}         → setState({signedOut})
 *                   └── rejects                    → setState({error, message})
 *
 *   signIn()  ← "Sign in with Apple" press
 *     │
 *     ▼
 *   setState({signingIn})
 *     │
 *     ▼
 *   AccountBridge.signIn()  ← native Sign in with Apple sheet
 *     │
 *     ├── resolves            → refresh()            ← re-check via currentAccount()
 *     ├── rejects, CANCELLED  → setState({signedOut}) ← sheet dismissed; no error UI
 *     └── rejects, otherwise  → setState({error, message})
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

  const signIn = useCallback(async () => {
    setState({kind: 'signingIn'});
    try {
      await AccountBridge.signIn();
      await refresh();
    } catch (e: unknown) {
      if (nativeErrorCode(e) === 'CANCELLED') {
        setState({kind: 'signedOut'});
        return;
      }
      const message = e instanceof Error ? e.message : String(e);
      setState({kind: 'error', message});
    }
  }, [refresh]);

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
    signOut,
    deleteAccount,
    redeemActivationCode,
    refresh,
  };
}
