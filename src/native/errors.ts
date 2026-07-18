const NATIVE_ERROR_CODES = [
  'SIGNED_OUT',
  'SUBSCRIPTION_REQUIRED',
  'NETWORK',
  'SERVER',
  'CANCELLED',
  'NOT_REGISTERED',
] as const;

export type NativeErrorCode = (typeof NATIVE_ERROR_CODES)[number];

/**
 * Thrown by the FilterStatus/Account bridges when their native module isn't
 * linked yet (JS-only tooling, or an older native build mid-rollout).
 */
export class NativeModuleUnavailableError extends Error {
  constructor(moduleName: string) {
    super(`${moduleName} native module is not linked`);
    this.name = 'NativeModuleUnavailableError';
  }
}

/**
 * Extracts a recognized rejection code from a native bridge error. Both the
 * `FilterStatus` and `Account` native modules reject with an `Error` whose
 * `.code` is one of NativeErrorCode.
 *
 *   e
 *     │
 *     ├── not an Error, or `.code` isn't a recognized NativeErrorCode → undefined
 *     └── otherwise                                                   → the code
 *
 * Callers fall back to generic error handling on `undefined` rather than
 * risk misreading an unrelated thrown value as a known state.
 */
export function nativeErrorCode(e: unknown): NativeErrorCode | undefined {
  if (!(e instanceof Error)) return undefined;
  const code = (e as Error & {code?: unknown}).code;
  if (typeof code !== 'string') return undefined;
  const isKnownCode = (NATIVE_ERROR_CODES as readonly string[]).includes(code);
  if (!isKnownCode) return undefined;
  return code as NativeErrorCode;
}
