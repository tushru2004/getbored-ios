import React, {useState} from 'react';
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import {StillWaterRings} from '../components/StillWaterRings';
import {nativeErrorCode} from '../native/errors';
import {colors, hardShadow, spacing, typography} from '../theme';

type Props = {
  accountLabel?: string;
  onActivate: (code: string) => Promise<void>;
  onSignOut: () => void;
};

function activationError(error: unknown): string {
  const code = nativeErrorCode(error);
  if (code === 'INVALID_CODE') {
    return 'That code is invalid or no longer available.';
  }
  if (code === 'RATE_LIMITED') {
    return 'Too many attempts. Wait a few minutes and try again.';
  }
  if (code === 'NETWORK') {
    return 'Could not reach GetBored. Check your connection and try again.';
  }
  return error instanceof Error ? error.message : String(error);
}

export const ActivationScreen: React.FC<Props> = ({
  accountLabel,
  onActivate,
  onSignOut,
}) => {
  const [code, setCode] = useState('');
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function activate() {
    setPending(true);
    setError(null);
    try {
      await onActivate(code.trim());
    } catch (activationFailure) {
      setError(activationError(activationFailure));
    } finally {
      setPending(false);
    }
  }

  return (
    <View style={styles.root}>
      <View style={styles.masthead}>
        <View>
          <View style={styles.wordmarkRow}>
            <Text style={styles.wordmark}>Get</Text>
            <Text style={[styles.wordmark, styles.wordmarkAccent]}>Bored.</Text>
          </View>
          <Text style={styles.tagline}>
            Bored minds{`\n`}go interesting places.
          </Text>
        </View>
        <StillWaterRings size={72} color={colors.surface} variant="closed" />
      </View>

      <View style={styles.body}>
        <Text style={styles.eyebrow}>One last step</Text>
        <Text style={styles.title}>Activate your account.</Text>
        <Text style={styles.copy}>
          Enter the one-time code you received from GetBored.
          {accountLabel ? ` Signed in as ${accountLabel}.` : ''}
        </Text>

        <Text style={styles.fieldLabel}>Activation code</Text>
        <TextInput
          autoCapitalize="characters"
          autoComplete="one-time-code"
          autoCorrect={false}
          editable={!pending}
          onChangeText={value => setCode(value.toUpperCase())}
          placeholder="GB-XXXX-XXXX-XXXX-XXXX-XXXX"
          placeholderTextColor={colors.neutral}
          returnKeyType="done"
          style={styles.input}
          value={code}
        />

        {error ? <Text style={styles.error}>{error}</Text> : null}

        <Pressable
          disabled={pending || code.trim() === ''}
          onPress={activate}
          style={({pressed}) => [
            styles.activateButton,
            (pressed || pending || code.trim() === '') && styles.dimmed,
          ]}>
          {pending ? (
            <ActivityIndicator color={colors.surface} />
          ) : (
            <Text style={styles.activateButtonText}>Activate account</Text>
          )}
        </Pressable>

        <Pressable disabled={pending} onPress={onSignOut} style={styles.signOutButton}>
          <Text style={styles.signOutText}>Use a different Apple account</Text>
        </Pressable>
      </View>
    </View>
  );
};

const styles = StyleSheet.create({
  root: {
    flex: 1,
    paddingHorizontal: spacing.xl,
  },
  masthead: {
    backgroundColor: colors.label,
    borderBottomColor: colors.sun,
    borderBottomWidth: 3,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    minHeight: 124,
    marginHorizontal: -spacing.xl,
    paddingHorizontal: spacing.xl,
    paddingVertical: spacing.lg,
  },
  wordmarkRow: {
    alignItems: 'baseline',
    flexDirection: 'row',
    gap: 4,
  },
  wordmark: {
    ...typography.wordmarkLarge,
    color: colors.surface,
  },
  wordmarkAccent: {
    color: colors.sun,
    transform: [{translateY: 3}, {rotate: '-2deg'}],
  },
  tagline: {
    ...typography.microFooter,
    color: colors.surface,
    lineHeight: 16,
    marginTop: spacing.md,
  },
  body: {
    flex: 1,
    justifyContent: 'center',
    paddingBottom: spacing.xxl,
  },
  eyebrow: {
    ...typography.eyebrow,
    color: colors.label,
    marginBottom: spacing.md,
  },
  title: {
    ...typography.display,
    color: colors.label,
    fontSize: 34,
    lineHeight: 36,
  },
  copy: {
    ...typography.subhead,
    color: colors.labelSecondary,
    lineHeight: 19,
    marginTop: spacing.md,
  },
  fieldLabel: {
    ...typography.eyebrow,
    color: colors.label,
    marginTop: spacing.xl,
    marginBottom: spacing.sm,
  },
  input: {
    backgroundColor: colors.surface,
    borderColor: colors.label,
    borderWidth: 1,
    color: colors.label,
    fontFamily: 'Menlo',
    fontSize: 13,
    fontWeight: '600',
    letterSpacing: 0.7,
    minHeight: 50,
    paddingHorizontal: spacing.md,
  },
  error: {
    ...typography.subhead,
    color: colors.danger,
    lineHeight: 18,
    marginTop: spacing.md,
  },
  activateButton: {
    ...hardShadow,
    alignItems: 'center',
    backgroundColor: colors.label,
    borderColor: colors.label,
    borderWidth: 1,
    justifyContent: 'center',
    minHeight: 50,
    marginTop: spacing.lg,
  },
  activateButtonText: {
    ...typography.eyebrow,
    color: colors.surface,
  },
  signOutButton: {
    alignItems: 'center',
    minHeight: 44,
    justifyContent: 'center',
    marginTop: spacing.md,
  },
  signOutText: {
    ...typography.subhead,
    color: colors.labelSecondary,
    textDecorationLine: 'underline',
  },
  dimmed: {
    opacity: 0.48,
  },
});
