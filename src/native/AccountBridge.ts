import {NativeModules} from 'react-native';

import {NativeModuleUnavailableError} from './errors';
import {AccountSummary, SignInResult} from './types';

type NativeAccount = {
		signIn: (username: string, password: string) => Promise<SignInResult>;
		signUp: (username: string, password: string) => Promise<SignInResult>;
		signOut: () => Promise<void>;
		currentAccount: () => Promise<AccountSummary>;
		redeemActivationCode: (code: string) => Promise<void>;
		deleteAccount: () => Promise<void>;
};

const native = (NativeModules as {Account?: NativeAccount}).Account;

/**
 * Typed JS facade over the `Account` native module (password auth +
 * server session). Mirrors FilterStatusBridge's guard pattern: `native` is
 * resolved once at import time and may be undefined on a native build that
 * predates this module, hence `isAvailable` and the shared throw-if-missing
 * guard on every method — callers (see useAccount) feature-detect via
 * `isAvailable` up front rather than relying on the throw.
 */
export const AccountBridge = {
		isAvailable: native !== undefined,

		async signIn(username: string, password: string): Promise<SignInResult> {
				if (!native) throw new NativeModuleUnavailableError('Account');
				return native.signIn(username, password);
		},

		async signUp(username: string, password: string): Promise<SignInResult> {
				if (!native) throw new NativeModuleUnavailableError('Account');
				return native.signUp(username, password);
		},

		async signOut(): Promise<void> {
				if (!native) throw new NativeModuleUnavailableError('Account');
				return native.signOut();
		},

		async currentAccount(): Promise<AccountSummary> {
				if (!native) throw new NativeModuleUnavailableError('Account');
				return native.currentAccount();
		},

		async redeemActivationCode(code: string): Promise<void> {
				if (!native) throw new NativeModuleUnavailableError('Account');
				return native.redeemActivationCode(code);
		},

		async deleteAccount(): Promise<void> {
				if (!native) throw new NativeModuleUnavailableError('Account');
				return native.deleteAccount();
		},
};
