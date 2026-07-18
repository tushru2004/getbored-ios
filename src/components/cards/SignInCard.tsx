import React from 'react';
import {ActivityIndicator, Pressable, StyleSheet, Text, View} from 'react-native';

import {AccountState} from '../../hooks/useAccount';
import {colors, radius, spacing, typography} from '../../theme';

const APPLE_GLYPH = '';

type SignedInBodyProps = {
  email?: string;
  onSignOut: () => void;
};

const SignedInBody: React.FC<SignedInBodyProps> = ({email, onSignOut}) => (
  <>
    <View style={styles.signedInRow}>
      <View style={styles.statusDot} />
      <View style={styles.signedInTextCol}>
        <Text style={styles.signedInTitle}>Signed in</Text>
        {email && (
          <Text style={styles.signedInSubtitle} numberOfLines={1}>
            {email}
          </Text>
        )}
      </View>
    </View>
    <Pressable
      onPress={onSignOut}
      style={({pressed}) => [styles.signOutRow, pressed && styles.buttonPressed]}>
      <Text style={styles.signOutText}>Sign Out</Text>
    </Pressable>
  </>
);

type SignInButtonProps = {
  busy: boolean;
  onPress: () => void;
};

/**
 * Apple HIG asks for the standard Sign in with Apple button (black pill,
 * Apple mark + wordmark); this app doesn't depend on Apple's authentication
 * button library, so this is a styled stand-in consistent with the app's
 * other card buttons rather than the real SFAuthorizationButton.
 */
const SignInButton: React.FC<SignInButtonProps> = ({busy, onPress}) => (
  <Pressable
    disabled={busy}
    onPress={onPress}
    style={({pressed}) => [
      styles.appleButton,
      (pressed || busy) && styles.buttonPressed,
    ]}>
    {busy ? (
      <ActivityIndicator color="#FFFFFF" />
    ) : (
      <Text style={styles.appleButtonText}>{APPLE_GLYPH} Sign in with Apple</Text>
    )}
  </Pressable>
);

type Props = {
  account: AccountState;
  onSignIn: () => void;
  onSignOut: () => void;
};

/**
 * Home-screen account card. Purely presentational: account state lives in
 * useConnectedApp (HomeScreen owns the single instance and passes it down),
 * so this card, the gating logic, and the auto-register/auto-sync effects
 * all read the same state machine.
 *
 *   account.kind
 *     │
 *     ├── 'unavailable'                          → render nothing (older native build)
 *     ├── 'error'                                 → message, then the sign-in button as retry
 *     ├── 'checking' | 'signedOut' | 'signingIn'  → sign-in button (busy while checking/signingIn)
 *     └── 'signedIn'                               → signed-in row (account email) + Sign Out
 */
export const SignInCard: React.FC<Props> = ({account, onSignIn, onSignOut}) => {
  const state = account;

  if (state.kind === 'unavailable') return null;

  return (
    <View style={styles.card}>
      <Text style={styles.title}>Account</Text>
      <Text style={styles.subtitle}>
        Sign in to sync your rules and register this device.
      </Text>

      {state.kind === 'signedIn' && (
        <SignedInBody email={state.email} onSignOut={onSignOut} />
      )}

      {state.kind === 'error' && (
        <Text style={styles.errorText}>{state.message}</Text>
      )}

      {state.kind !== 'signedIn' && (
        <SignInButton
          busy={state.kind === 'checking' || state.kind === 'signingIn'}
          onPress={onSignIn}
        />
      )}
    </View>
  );
};

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    marginHorizontal: spacing.lg,
    marginTop: spacing.lg,
    padding: spacing.md,
  },
  title: {
    ...typography.headline,
    color: colors.label,
  },
  subtitle: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: spacing.xs,
  },
  errorText: {
    ...typography.subhead,
    color: colors.danger,
    marginTop: spacing.md,
  },
  appleButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#000000',
    borderRadius: radius.sm,
    marginTop: spacing.md,
    paddingVertical: spacing.md,
  },
  appleButtonText: {
    ...typography.body,
    color: '#FFFFFF',
  },
  buttonPressed: {
    opacity: 0.7,
  },
  signedInRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginTop: spacing.md,
  },
  statusDot: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: colors.success,
  },
  signedInTextCol: {
    flex: 1,
    marginLeft: spacing.sm,
  },
  signedInTitle: {
    ...typography.body,
    color: colors.label,
  },
  signedInSubtitle: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: 2,
  },
  signOutRow: {
    alignItems: 'center',
    marginTop: spacing.md,
    paddingVertical: spacing.sm,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
  },
  signOutText: {
    ...typography.subhead,
    color: colors.danger,
  },
});
