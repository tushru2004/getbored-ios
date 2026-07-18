import React from 'react';
import {
  Pressable,
  StyleSheet,
  Text,
  TextStyle,
  View,
  ViewStyle,
} from 'react-native';

import {
  DeviceRegistrationState,
  useDeviceRegistration,
} from '../../hooks/useDeviceRegistration';
import {DeviceRegistration} from '../../native/types';
import {colors, radius, spacing, typography, withAlpha} from '../../theme';

const RegistrationDetails: React.FC<{registration: DeviceRegistration}> = ({
  registration,
}) => (
  <View style={styles.details}>
    <Text style={styles.detailText}>{registration.name}</Text>
    <Text style={styles.metaText}>{registration.model}</Text>
    <Text style={styles.metaText}>Device ID {registration.id}</Text>
  </View>
);

type Tone = 'neutral' | 'success' | 'warn';

function statusTone(state: DeviceRegistrationState): Tone {
  if (state.kind === 'registered') return 'success';
  if (state.kind === 'signedOut' || state.kind === 'subscriptionRequired') {
    return 'warn';
  }
  return 'neutral';
}

function statusLabel(state: DeviceRegistrationState): string {
  if (state.kind === 'checking') return 'Checking';
  if (state.kind === 'registered') return 'Registered';
  if (state.kind === 'signedOut') return 'Signed out';
  if (state.kind === 'subscriptionRequired') return 'Subscription required';
  return 'Not registered';
}

function buttonLabel(state: DeviceRegistrationState): string {
  if (state.kind === 'checking') return 'Checking...';
  if (state.kind === 'saving') return 'Registering...';
  if (state.kind === 'registered') return 'Refresh Sync';
  return 'Set Up This Device';
}

export const DeviceRegistrationCard: React.FC = () => {
  const {state, register} = useDeviceRegistration();
  const isBusy = state.kind === 'checking' || state.kind === 'saving';
  const isBlocked =
    state.kind === 'signedOut' || state.kind === 'subscriptionRequired';
  const tone = statusTone(state);

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <View style={styles.titleColumn}>
          <Text style={styles.title}>Device Sync</Text>
          <Text style={styles.subtitle}>
            Sync this device to your GetBored account so your rules follow you everywhere.
          </Text>
        </View>
        <View style={[styles.statusPill, TONE_PILL_STYLE[tone]]}>
          <Text style={[styles.statusText, TONE_TEXT_STYLE[tone]]}>
            {statusLabel(state)}
          </Text>
        </View>
      </View>

      {state.kind === 'registered' && (
        <RegistrationDetails registration={state.registration} />
      )}
      {state.kind === 'error' && (
        <Text style={styles.errorText}>{state.message}</Text>
      )}
      {state.kind === 'signedOut' && (
        <Text style={styles.noticeText}>
          Sign in again to keep syncing this device.
        </Text>
      )}
      {state.kind === 'subscriptionRequired' && (
        <Text style={styles.noticeText}>
          Device sync is paused until your subscription is active again.
        </Text>
      )}

      {!isBlocked && (
        <Pressable
          disabled={isBusy}
          onPress={register}
          style={({pressed}) => [
            styles.button,
            (pressed || isBusy) && styles.buttonPressed,
          ]}>
          <Text style={styles.buttonText}>{buttonLabel(state)}</Text>
        </Pressable>
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
  headerRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    gap: spacing.md,
  },
  titleColumn: {
    flex: 1,
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
  statusPill: {
    borderRadius: radius.pill,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs,
  },
  pendingPill: {
    backgroundColor: withAlpha(colors.neutral, 0.12),
  },
  registeredPill: {
    backgroundColor: withAlpha(colors.success, 0.12),
  },
  warnPill: {
    backgroundColor: withAlpha(colors.warning, 0.12),
  },
  statusText: {
    ...typography.caption,
  },
  pendingText: {
    color: colors.neutral,
  },
  registeredText: {
    color: colors.success,
  },
  warnText: {
    color: colors.warning,
  },
  details: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
    marginTop: spacing.md,
    paddingTop: spacing.md,
  },
  detailText: {
    ...typography.body,
    color: colors.label,
  },
  metaText: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: spacing.xs,
  },
  errorText: {
    ...typography.subhead,
    color: colors.danger,
    marginTop: spacing.md,
  },
  noticeText: {
    ...typography.subhead,
    color: colors.labelSecondary,
    marginTop: spacing.md,
  },
  button: {
    alignItems: 'center',
    backgroundColor: colors.info,
    borderRadius: radius.sm,
    marginTop: spacing.md,
    paddingVertical: spacing.md,
  },
  buttonPressed: {
    opacity: 0.7,
  },
  buttonText: {
    ...typography.body,
    color: '#FFFFFF',
  },
});

const TONE_PILL_STYLE: Record<Tone, ViewStyle> = {
  neutral: styles.pendingPill,
  success: styles.registeredPill,
  warn: styles.warnPill,
};

const TONE_TEXT_STYLE: Record<Tone, TextStyle> = {
  neutral: styles.pendingText,
  success: styles.registeredText,
  warn: styles.warnText,
};
