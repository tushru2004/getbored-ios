import {useCallback, useEffect, useState} from 'react';

import {AccountBridge} from '../native/AccountBridge';
import {nativeErrorCode} from '../native/errors';

export type AccountState =
  | {kind: 'unavailable'}
  | {kind: 'checking'}
  | {kind: 'signedOut'}
  | {kind: 'signingIn'}
  | {kind: 'signedIn'; userId?: string; email?: string}
  | {kind: 'error'; message: string};

export type UseAccount = {
  state: AccountState;
  signIn: () => Promise<void>;
  signOut: () => Promise<void>;
  refresh: () => Promise<void>;
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

  const refresh = useCallback(async () => {
    if (!AccountBridge.isAvailable) {
      setState({kind: 'unavailable'});
      return;
    }
    setState({kind: 'checking'});
    try {
      const summary = await AccountBridge.currentAccount();
      if (summary.signedIn) {
        setState({
          kind: 'signedIn',
          userId: summary.userId,
          email: summary.email,
        });
      } else {
        setState({kind: 'signedOut'});
      }
    } catch (e: unknown) {
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

  useEffect(() => {
    refresh();
  }, [refresh]);

  return {state, signIn, signOut, refresh};
}
