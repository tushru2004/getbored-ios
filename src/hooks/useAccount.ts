import {useCallback, useEffect, useState} from 'react';

import {AccountBridge} from '../native/AccountBridge';
import {nativeErrorCode} from '../native/errors';

export type AccountState =
  | {kind: 'unavailable'}
  | {kind: 'checking'}
  | {kind: 'signedOut'}
  | {kind: 'signingIn'}
  | {kind: 'needsActivation'; userId?: string; accountLabel?: string}
  | {kind: 'signedIn'; userId?: string; accountLabel?: string; reviewDemo: boolean}
  | {kind: 'deleting'}
  | {kind: 'error'; message: string};

export type UseAccount = {
  state: AccountState;
  signIn: (username: string, password: string) => Promise<void>;
  signUp: (username: string, password: string) => Promise<void>;
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
 *                   ├── {signedIn: true, accountKind review_demo} → setState({signedIn, reviewDemo: true})
 *                   ├── {signedIn: true, plan active}       → setState({signedIn, reviewDemo: false})
 *                   ├── {signedIn: true, other plan}        → setState({needsActivation, userId, label})
 *                   ├── {signedIn: false}                    → setState({signedOut})
 *                   └── rejects (only when showChecking)     → setState({error, message})
 *                          └── refresh(false) swallows the reject and keeps
 *                              the current state (background re-enrichment)
 *
 *   signIn() / signUp()  ← the two Welcome actions
 *     │                   both delegate to runSignIn():
 *     ▼
 *   runSignIn(start)
 *     │
 *     ▼
 *   setState({signingIn})
 *     │
 *     ▼
 *   start()  ← AccountBridge.signIn() or AccountBridge.signUp()
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
          const previousAccountLabel =
            previous.kind === 'signedIn' || previous.kind === 'needsActivation'
              ? previous.accountLabel
              : undefined;
          const accountDetails = {
            userId: summary.userId ?? previousUserId,
            accountLabel: summary.username ?? summary.email ?? previousAccountLabel,
          };
          const reviewDemo = summary.accountKind === 'review_demo';
          if (reviewDemo) {
            return {kind: 'signedIn', ...accountDetails, reviewDemo: true};
          }
          if (summary.plan === 'active') {
            return {kind: 'signedIn', ...accountDetails, reviewDemo: false};
          }
          return {kind: 'needsActivation', ...accountDetails};
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
   * Shared by sign-in and sign-up: same lifecycle and error handling; only
   * the native endpoint differs.
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
    (username: string, password: string) =>
      runSignIn(() => AccountBridge.signIn(username, password)),
    [runSignIn],
  );

  const signUp = useCallback(
    (username: string, password: string) =>
      runSignIn(() => AccountBridge.signUp(username, password)),
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
    signUp,
    signOut,
    deleteAccount,
    redeemActivationCode,
    refresh,
  };
}
